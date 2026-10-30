#!/usr/bin/env bash
# Validates the inputs, creates the work directory and loads the signing key. This is the only step that sees the key
# material in its environment. Later steps only get the file, which cleanup.sh removes.

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KEY_HINT="If this runs on a pull request from a fork, secrets aren't available there. If the secret is an environment secret, set 'environment:' on the job."

if [ "${RUNNER_OS:-}" = "Windows" ]; then
	die "Windows runners aren't supported. Run this on Linux or macOS: one runner can publish the binaries of every platform."
fi

mode=${INPUT_MODE:-publish}
case "$mode" in
publish | sign-only) ;;
*) die "Input 'mode' must be 'publish' or 'sign-only', got '$mode'." ;;
esac

check_bool upload-latest "${INPUT_UPLOAD_LATEST:-true}"
check_bool upload-versioned "${INPUT_UPLOAD_VERSIONED:-true}"
check_bool overwrite-versioned "${INPUT_OVERWRITE_VERSIONED:-false}"
check_bool publish-key-file "${INPUT_PUBLISH_KEY_FILE:-true}"
check_bool smoke-test "${INPUT_SMOKE_TEST:-true}"

if ! is_true "${INPUT_UPLOAD_LATEST:-true}" && ! is_true "${INPUT_UPLOAD_VERSIONED:-true}"; then
	die "Inputs 'upload-latest' and 'upload-versioned' are both false, so there is nothing to publish."
fi

if [ -z "${INPUT_SIGNING_KEY:-}" ]; then
	die "Input 'signing-key' is empty. $KEY_HINT"
fi

if [ -n "${INPUT_PATH:-}" ]; then
	[ -d "$INPUT_PATH" ] || die "Input 'path' is not a directory: $INPUT_PATH"
elif [ -z "${INPUT_EXTENSION_NAME:-}" ] && [ -z "${INPUT_ARTIFACT_PATTERN:-}" ]; then
	die "Set 'extension-name', 'artifact-pattern' or 'path' so the action knows which binaries to sign."
fi

if [ "$mode" = "publish" ]; then
	[ -n "${INPUT_S3_BUCKET:-}" ] || die "Input 's3-bucket' is required in publish mode. Use 'mode: sign-only' to only sign."
	case "${INPUT_S3_ENDPOINT:-}" in
	http://*) warn "Input 's3-endpoint' uses plain HTTP. rclone refuses most uploads without TLS, so use an https:// endpoint." ;;
	esac
fi

require_tool openssl
require_tool gzip
require_tool jq

umask 077
work_dir=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/duckdb-extension-publisher.XXXXXX")
mkdir -p "$work_dir/artifacts" "$work_dir/keys" "$work_dir/tmp" "$work_dir/signed"
set_output work-dir "$work_dir"

# Rejects anything but an RSA-2048 public key. Never prints the key.
check_public_key() { # <pem file> <description>
	local text
	text=$(openssl pkey -pubin -in "$1" -noout -text 2>/dev/null) || die "$2 is not a valid public key."
	case "$text" in
	*"(2048 bit"*) ;;
	*) die "$2 must be a 2048-bit RSA key, because the signature slot in an extension file is 256 bytes." ;;
	esac
	case "$text" in
	*Modulus*) ;;
	*) die "$2 must be an RSA key." ;;
	esac
}

fingerprint_of() { # <pem file>
	local line
	line=$(openssl pkey -pubin -in "$1" -outform DER | openssl dgst -sha256)
	printf 'sha256:%s' "${line##* }"
}

key_file="$work_dir/keys/signing_key.pem"
case "$INPUT_SIGNING_KEY" in
*$'\n'*) printf '%s\n' "$INPUT_SIGNING_KEY" >"$key_file" ;;
*'\n'*) printf '%b\n' "$INPUT_SIGNING_KEY" >"$key_file" ;;
*) printf '%s\n' "$INPUT_SIGNING_KEY" >"$key_file" ;;
esac

public_key_file="$work_dir/keys/signing_key.pub"
if ! openssl pkey -in "$key_file" -pubout -out "$public_key_file" 2>/dev/null; then
	die "Input 'signing-key' is not a readable PEM private key. It must not be encrypted. $KEY_HINT"
fi
check_public_key "$public_key_file" "Input 'signing-key'"

fingerprint=$(fingerprint_of "$public_key_file")
set_output fingerprint "$fingerprint"
info "Signing key fingerprint: $fingerprint"

# The key file lists the signing key first, then any further keys.
cp "$public_key_file" "$work_dir/keys/public_0.pem"
if [ -n "${INPUT_ADDITIONAL_PUBLIC_KEYS:-}" ]; then
	printf '%s\n' "$INPUT_ADDITIONAL_PUBLIC_KEYS" | awk -v dir="$work_dir/keys" '
		/-----BEGIN PUBLIC KEY-----/ { count++; file = dir "/public_" count ".pem" }
		file { print > file }
		/-----END PUBLIC KEY-----/ { close(file); file = "" }
	'
	if [ ! -f "$work_dir/keys/public_1.pem" ]; then
		die "Input 'additional-public-keys' holds no PEM public key (-----BEGIN PUBLIC KEY-----)."
	fi
	index=1
	while [ -f "$work_dir/keys/public_$index.pem" ]; do
		check_public_key "$work_dir/keys/public_$index.pem" "Additional public key $index"
		info "Additional public key $index: $(fingerprint_of "$work_dir/keys/public_$index.pem")"
		index=$((index + 1))
	done
fi
