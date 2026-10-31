#!/usr/bin/env bash
# Validates the inputs for this mode and creates the work directory. Sees no secrets: it only learns whether they were
# passed, from the HAS_* variables.

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KEY_HINT="If this runs on a pull request from a fork, secrets aren't available there. If the secret is an environment secret, set 'environment:' on the job."

if [ "${RUNNER_OS:-}" = "Windows" ]; then
	die "Windows runners aren't supported. Run this on Linux or macOS: one runner can sign and publish the binaries of every platform."
fi

mode=${INPUT_MODE:-}
case "$mode" in
sign | verify | publish) ;;
'') die "Input 'mode' is required: 'sign', 'verify' or 'publish', each in its own job. See the README." ;;
*) die "Input 'mode' must be 'sign', 'verify' or 'publish', got '$mode'." ;;
esac

check_bool all-extensions "${INPUT_ALL_EXTENSIONS:-false}"
check_bool upload-latest "${INPUT_UPLOAD_LATEST:-true}"
check_bool upload-versioned "${INPUT_UPLOAD_VERSIONED:-true}"
check_bool overwrite-versioned "${INPUT_OVERWRITE_VERSIONED:-false}"
check_bool publish-key-file "${INPUT_PUBLISH_KEY_FILE:-true}"
check_bool allow-key-change "${INPUT_ALLOW_KEY_CHANGE:-false}"
check_bool allow-downgrade "${INPUT_ALLOW_DOWNGRADE:-false}"
check_bool check-repository "${INPUT_CHECK_REPOSITORY:-true}"

# The runner keeps a job's secrets in its own memory for all of the job's steps, and a step can read them from there. So
# the mode that runs the extension's native code can't share a job with a mode that uses a secret, in either order.
if [ -n "${RUNNER_TEMP:-}" ]; then
	case "$mode" in
	verify) conflicting="sign publish" ;;
	*) conflicting="verify" ;;
	esac
	for other in $conflicting; do
		if [ -e "$RUNNER_TEMP/duckdb-extension-publisher-ran-$other" ]; then
			die "Modes '$mode' and '$other' ran in one job. 'verify' runs the extension's native code, which can read every secret the job has, so give it its own job."
		fi
	done
	: >"$RUNNER_TEMP/duckdb-extension-publisher-ran-$mode"
fi

check_credentials() {
	local id=${HAS_S3_ACCESS_KEY_ID:-false} secret=${HAS_S3_SECRET_ACCESS_KEY:-false} token=${HAS_S3_SESSION_TOKEN:-false}
	if [ "$id" != "$secret" ]; then
		die "Set both 's3-access-key-id' and 's3-secret-access-key', or neither. A key and a secret from different sources can't sign a request."
	fi
	if is_true "$token" && ! is_true "$id"; then
		die "Input 's3-session-token' only works together with 's3-access-key-id' and 's3-secret-access-key'."
	fi
	if is_true "$id"; then return 0; fi
	if [ -n "${AWS_ACCESS_KEY_ID:-}" ] && [ -n "${AWS_SECRET_ACCESS_KEY:-}" ]; then return 0; fi
	if [ -n "${AWS_WEB_IDENTITY_TOKEN_FILE:-}" ] || [ -n "${AWS_PROFILE:-}" ] || [ -n "${AWS_SHARED_CREDENTIALS_FILE:-}" ] ||
		[ -n "${AWS_CONTAINER_CREDENTIALS_RELATIVE_URI:-}" ] || [ -n "${AWS_CONTAINER_CREDENTIALS_FULL_URI:-}" ]; then
		return 0
	fi
	# Only your own machines can have an instance role.
	if [ "${RUNNER_ENVIRONMENT:-}" = "self-hosted" ]; then return 0; fi
	if [ -n "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]; then
		die "No S3 credentials found. This job has 'id-token: write', but nothing has assumed a role yet. Run aws-actions/configure-aws-credentials before this step."
	fi
	die "No S3 credentials found. Set 's3-access-key-id' and 's3-secret-access-key', or assume a role in an earlier step. $KEY_HINT"
}

# Otherwise a typo in a platform or a label would only show up when the verify job can't find a runner, or not at all.
check_runner_labels() { # <JSON object>
	local problem
	problem=$(printf '%s' "$1" | jq -s -r --argjson runners "$VERIFY_RUNNERS" '
		if length != 1 or (.[0] | type) != "object" then "it must be one JSON object"
		else
			[.[0] | to_entries[] |
				if $runners[.key] == null then "no runner can load \(.key)"
				elif (.value | type) != "string" or (.value | test("^[A-Za-z0-9][A-Za-z0-9._-]*$") | not) then "\(.key) needs a single runner label"
				else empty end] | first // ""
		end
	' 2>/dev/null) || die "Input 'verify-runner-labels' isn't valid JSON."
	[ -z "$problem" ] || die "Input 'verify-runner-labels' doesn't work: $problem. Example: {\"osx_arm64\": \"my-mac-runner\"}"
}

case "$mode" in
sign)
	if ! is_true "${HAS_SIGNING_KEY:-false}"; then
		die "Input 'signing-key' is empty. $KEY_HINT"
	fi
	if ! is_true "${INPUT_UPLOAD_LATEST:-true}" && ! is_true "${INPUT_UPLOAD_VERSIONED:-true}"; then
		die "Inputs 'upload-latest' and 'upload-versioned' are both false, so there is nothing to publish."
	fi
	if [ -n "${INPUT_PATH:-}" ]; then
		[ -d "$INPUT_PATH" ] || die "Input 'path' is not a directory: $INPUT_PATH"
	elif [ -z "${INPUT_EXTENSION_NAME:-}" ] && [ -z "${INPUT_ARTIFACT_PATTERN:-}" ]; then
		die "Set 'extension-name', 'artifact-pattern' or 'path' so the action knows which binaries to sign."
	fi
	# A build tree holds more extensions than the one being released, and the key would sign them all.
	if [ -z "${INPUT_EXTENSION_NAME:-}" ] && ! is_true "${INPUT_ALL_EXTENSIONS:-false}"; then
		die "Set 'extension-name' to the extension to sign, or 'all-extensions: true' to sign every extension that's found."
	fi
	require_tool openssl
	require_tool gzip
	;;
verify)
	if is_true "${HAS_SIGNING_KEY:-false}"; then
		die "Don't pass 'signing-key' to mode 'verify'. It runs the extension's native code, which could read the key."
	fi
	if is_true "${HAS_S3_ACCESS_KEY_ID:-false}" || is_true "${HAS_S3_SECRET_ACCESS_KEY:-false}" || is_true "${HAS_S3_SESSION_TOKEN:-false}"; then
		die "Don't pass S3 credentials to mode 'verify'. It runs the extension's native code, which could read them, and it doesn't need the bucket."
	fi
	# GitHub sets these when a job has the permission, and any code in the job can then request a token and assume a role.
	if [ -n "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ] || [ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ]; then
		die "This job has 'id-token: write', and mode 'verify' runs the extension's native code, which could use it to assume your publishing role. Set 'permissions: {}' on this job, and grant 'id-token: write' only on the publish job."
	fi
	for variable in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_ROLE_ARN AWS_WEB_IDENTITY_TOKEN_FILE AWS_PROFILE AWS_SHARED_CREDENTIALS_FILE; do
		if [ -n "${!variable:-}" ]; then
			die "This job has $variable in its environment, and mode 'verify' runs the extension's native code, which could use it to reach your AWS account. Remove it from this job."
		fi
	done
	require_tool openssl
	require_tool curl
	require_tool tar
	;;
publish)
	if is_true "${HAS_SIGNING_KEY:-false}"; then
		die "Don't pass 'signing-key' to mode 'publish'. Only mode 'sign' needs it."
	fi
	[ -n "${INPUT_S3_BUCKET:-}" ] || die "Input 's3-bucket' is required in mode 'publish'."
	[ -n "${INPUT_BUNDLE_DIGEST:-}" ] || die "Input 'bundle-digest' is required in mode 'publish'. Pass the output of the same name from the sign job, which proves that the signed tree hasn't changed since."
	case "${INPUT_REPOSITORY_URL:-}" in
	*[[:space:]]*) die "Input 'repository-url' contains whitespace." ;;
	esac
	case "${INPUT_S3_ENDPOINT:-}" in
	http://*) warn "Input 's3-endpoint' uses plain HTTP, which sends everything unencrypted. rclone's AWS provider refuses to upload over it, so use an https:// endpoint." ;;
	esac
	check_credentials
	require_tool openssl
	require_tool curl
	require_tool unzip
	;;
esac
require_tool jq
if [ "$mode" = "sign" ] && [ -n "${INPUT_VERIFY_RUNNER_LABELS:-}" ]; then
	check_runner_labels "$INPUT_VERIFY_RUNNER_LABELS"
fi

umask 077
work_dir=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/duckdb-extension-publisher.XXXXXX")
mkdir -p "$work_dir/artifacts" "$work_dir/tmp" "$work_dir/bundle"
set_output work-dir "$work_dir"
