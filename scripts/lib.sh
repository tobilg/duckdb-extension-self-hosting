#!/usr/bin/env bash
# Shared helpers, sourced by the other scripts.
#
# Everything here must run on bash 3.2, the stock bash on macOS: no associative arrays or mapfile, and no expansion of
# an array that may be empty. Never use `set -x`, and never read one end of a pipe partially under pipefail.

set -euo pipefail

# Encodes the text of a workflow command, so that it stays on one line and can't start another command.
escape_command() {
	local text=$1
	text=${text//'%'/%25}
	text=${text//$'\r'/%0D}
	text=${text//$'\n'/%0A}
	printf '%s' "$text"
}

error() { printf '::error::%s\n' "$(escape_command "$*")" >&2; }
warn() { printf '::warning::%s\n' "$(escape_command "$*")" >&2; }
notice() { printf '::notice::%s\n' "$(escape_command "$*")"; }
info() { printf '%s\n' "$*"; }
die() {
	error "$*"
	exit 1
}

set_output() { # <name> <value>
	[ -n "${GITHUB_OUTPUT:-}" ] || return 0
	case "$2" in
	*$'\n'*) set_output_block "$1" "$2" ;; # A second line in the plain form would set another output.
	*) printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT" ;;
	esac
}

set_output_block() { # <name> <value>
	[ -n "${GITHUB_OUTPUT:-}" ] || return 0
	local delimiter
	delimiter="EOF_$(openssl rand -hex 16)"
	printf '%s<<%s\n%s\n%s\n' "$1" "$delimiter" "$2" "$delimiter" >>"$GITHUB_OUTPUT"
}

require_tool() { # <tool> [hint]
	command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed. ${2:-}"
}

check_bool() { # <input name> <value>
	case "$2" in
	true | false) ;;
	*) die "Input '$1' must be 'true' or 'false', got '$2'." ;;
	esac
}

is_true() { [ "${1:-}" = "true" ]; }

file_size() { wc -c <"$1" | tr -d '[:space:]'; }

sha256_of() { # <file>
	local line
	if command -v sha256sum >/dev/null 2>&1; then
		line=$(sha256sum "$1")
	else
		line=$(shasum -a 256 "$1")
	fi
	printf '%s' "${line%% *}"
}

# One 32-byte metadata field of the footer, addressed by its offset from the end of the file.
footer_field() { # <file> <size> <offset from end>
	dd if="$1" bs=1 skip=$(($2 - $3)) count=32 2>/dev/null | tr -d '\0'
}

# Splits a comma or whitespace separated list into one word per line.
split_list() { # <list>
	printf '%s\n' "$1" | tr ',' '\n' | tr -s ' \t' '\n' | sed '/^$/d'
}

# Reads the list line by line, so that an entry like wasm_* can't expand to file names in the current directory.
in_list() { # <word> <list>
	local item
	while IFS= read -r item; do
		[ "$item" = "$1" ] && return 0
	done <<EOF
$(split_list "$2")
EOF
	return 1
}

sql_quote() { printf '%s' "$1" | sed "s/'/''/g"; }

normalize_prefix() { # <prefix>
	local prefix=$1
	while [ "${prefix#/}" != "$prefix" ]; do prefix=${prefix#/}; done
	while [ "${prefix%/}" != "$prefix" ]; do prefix=${prefix%/}; done
	printf '%s' "$prefix"
}

# The platform name DuckDB uses for this machine, empty if it isn't one the smoke test can run on.
runner_platform() {
	local os arch
	case "$(uname -s)" in
	Linux) os=linux ;;
	Darwin) os=osx ;;
	*) return 0 ;;
	esac
	case "$(uname -m)" in
	x86_64 | amd64) arch=amd64 ;;
	aarch64 | arm64) arch=arm64 ;;
	*) return 0 ;;
	esac
	printf '%s_%s' "$os" "$arch"
}

# The DuckDB CLI's release asset for a platform, without its file extension.
cli_asset() { # <platform>
	printf 'duckdb-cli-%s' "$(printf '%s' "$1" | tr '_' '-')"
}

# The GitHub-hosted runner that can load each platform's builds. Other platforms have none: the action doesn't run on
# Windows, GitHub has no musl runners, and Wasm runs in a browser. These aren't upstream's build runners, because upstream
# cross-compiles osx_amd64 on an Arm Mac.
VERIFY_RUNNERS='{"linux_amd64":"ubuntu-24.04","linux_arm64":"ubuntu-24.04-arm","osx_amd64":"macos-26-intel","osx_arm64":"macos-26"}'

# A JSON array for the verify job's matrix: one runner for each platform in the manifest that has one. Never empty, because
# an empty matrix fails the job, and 'publish' would then need a condition that also lets it run after a skipped verify job.
verify_runners() { # <manifest> <JSON object of labels that replace the defaults, or nothing>
	local labels=${2:-}
	[ -n "$labels" ] || labels='{}'
	jq -s -c --argjson defaults "$VERIFY_RUNNERS" --argjson labels "$labels" '
		($defaults + $labels) as $runners
		| [.[].platform | $runners[.] // empty] | unique
		| if . == [] then [$runners.linux_amd64] else . end
	' "$1"
}

# The platforms in the manifest that no runner can load, comma separated.
platforms_without_runner() { # <manifest>
	jq -s -r --argjson runners "$VERIFY_RUNNERS" '[.[].platform | select($runners[.] == null)] | unique | join(", ")' "$1"
}

# Prints lt, eq or gt for two versions that start with major.minor.patch, and unknown if either doesn't, like a commit hash.
compare_versions() { # <a> <b>
	local pattern='^v?([0-9]+)\.([0-9]+)\.([0-9]+)' a_major a_minor a_patch pair a b
	[[ "$1" =~ $pattern ]] || {
		printf 'unknown'
		return 0
	}
	a_major=${BASH_REMATCH[1]} a_minor=${BASH_REMATCH[2]} a_patch=${BASH_REMATCH[3]}
	[[ "$2" =~ $pattern ]] || {
		printf 'unknown'
		return 0
	}
	for pair in "$a_major ${BASH_REMATCH[1]}" "$a_minor ${BASH_REMATCH[2]}" "$a_patch ${BASH_REMATCH[3]}"; do
		a=${pair% *} b=${pair#* }
		if ((10#$a < 10#$b)); then
			printf 'lt'
			return 0
		elif ((10#$a > 10#$b)); then
			printf 'gt'
			return 0
		fi
	done
	printf 'eq'
}

# A PEM block from an input. Secret stores sometimes hold it on one line with literal \n.
pem_text() { # <value>
	case "$1" in
	*$'\n'*) printf '%s\n' "$1" ;;
	*'\n'*) printf '%b\n' "$1" ;;
	*) printf '%s\n' "$1" ;;
	esac
}

# Rejects anything but a plain RSA-2048 public key. Never prints the key.
check_public_key() { # <pem file> <description>
	local text structure
	text=$(openssl pkey -pubin -in "$1" -noout -text 2>/dev/null) || die "$2 is not a valid public key."
	structure=$(openssl asn1parse -in "$1" 2>/dev/null) || die "$2 is not a valid public key."
	# OpenSSL prints an RSA-PSS key the same way as an RSA key, but DuckDB rejects it.
	case "$structure" in
	*":rsaEncryption"*) ;;
	*) die "$2 must be an RSA key." ;;
	esac
	case "$text" in
	*"(2048 bit"*) ;;
	*) die "$2 must be a 2048-bit RSA key, because the signature slot in an extension file is 256 bytes." ;;
	esac
}

fingerprint_of() { # <pem file>
	local line
	line=$(openssl pkey -pubin -in "$1" -outform DER | openssl dgst -sha256)
	printf 'sha256:%s' "${line##* }"
}

# The base64 body of a PEM file, the form that DuckDB also compares keys in.
compact_key() { # <pem file>
	sed '/-----/d' "$1" | tr -d ' \t\r\n'
}

# A digest of everything a later job gets from the sign job, which the job that runs native code can't change unnoticed.
bundle_digest() { # <bundle directory>
	local line
	line=$(
		cd "$1"
		find . -type f | LC_ALL=C sort | while IFS= read -r file; do
			printf '%s  %s\n' "$(sha256_of "$file")" "$file"
		done | openssl dgst -sha256
	)
	printf '%s' "${line##* }"
}

# Runs a command in the background with its standard input from a file, and kills it after a number of seconds. macOS has
# no timeout(1). A killed command returns 143 or 137.
run_with_timeout() { # <seconds> <stdin file> <command...>
	local seconds=$1 input=$2 pid watchdog status=0
	shift 2
	"$@" <"$input" &
	pid=$!
	# Without the redirect, a command substitution around this function would wait for the watchdog's output to close.
	(
		waited=0
		while kill -0 "$pid" 2>/dev/null; do
			if [ "$waited" -ge "$seconds" ]; then
				kill -TERM "$pid" 2>/dev/null
				sleep 2
				kill -KILL "$pid" 2>/dev/null
				exit 0
			fi
			sleep 1
			waited=$((waited + 1))
		done
	) >/dev/null 2>&1 &
	watchdog=$!
	wait "$pid" || status=$?
	kill "$watchdog" 2>/dev/null || true
	wait "$watchdog" 2>/dev/null || true
	return "$status"
}

# Runs commands in the background, at most <size> at a time. Bash 3.2 has no `wait -n`, so this waits for each full batch.
# Check pool_failed after the final pool_wait.
pool_pids=
pool_count=0
pool_failed=0
pool_start() { # <size> <command...>
	local size=$1
	shift
	"$@" &
	pool_pids="$pool_pids $!"
	pool_count=$((pool_count + 1))
	if [ "$pool_count" -ge "$size" ]; then pool_wait; fi
}

pool_wait() {
	local pid
	for pid in $pool_pids; do
		# shellcheck disable=SC2034 # read by the scripts that source this file
		wait "$pid" || pool_failed=1
	done
	pool_pids=
	pool_count=0
}

cpu_count() { getconf _NPROCESSORS_ONLN 2>/dev/null || printf '2'; }

# Maps the credential inputs to the environment rclone reads. Inputs win, otherwise the environment is left as it is.
export_s3_credentials() {
	if [ -n "${INPUT_S3_ACCESS_KEY_ID:-}" ]; then
		export AWS_ACCESS_KEY_ID="$INPUT_S3_ACCESS_KEY_ID"
		# A token in the environment belongs to the keys it came with, such as those of an earlier AWS step in the job.
		unset AWS_SESSION_TOKEN
	fi
	if [ -n "${INPUT_S3_SECRET_ACCESS_KEY:-}" ]; then export AWS_SECRET_ACCESS_KEY="$INPUT_S3_SECRET_ACCESS_KEY"; fi
	if [ -n "${INPUT_S3_SESSION_TOKEN:-}" ]; then export AWS_SESSION_TOKEN="$INPUT_S3_SESSION_TOKEN"; fi
	return 0
}

s3_provider() { printf '%s' "${INPUT_S3_PROVIDER:-$(detect_s3_provider "${INPUT_S3_ENDPOINT:-}")}"; }

# R2 has its own regions, so a region left in the environment by an earlier AWS step in the job isn't used there.
s3_region() {
	if [ -n "${INPUT_S3_REGION:-}" ]; then
		printf '%s' "$INPUT_S3_REGION"
	elif [ "$(s3_provider)" = "Cloudflare" ]; then
		printf 'auto'
	else
		printf '%s' "${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
	fi
}

# rclone's name for the store behind the endpoint.
detect_s3_provider() { # <endpoint>
	case "$1" in
	'') printf 'AWS' ;;
	*.r2.cloudflarestorage.com*) printf 'Cloudflare' ;;
	*) printf 'Other' ;;
	esac
}

# The bucket and key prefix to publish to.
s3_destination() {
	local prefix
	prefix=$(normalize_prefix "${INPUT_S3_PREFIX:-}")
	printf '%s%s' "$INPUT_S3_BUCKET" "${prefix:+/$prefix}"
}

# The prefix clients use for CREATE EXTENSION REPOSITORY.
repository_url() {
	local url=${INPUT_REPOSITORY_URL:-}
	if [ -z "$url" ]; then
		printf 's3://%s' "$(s3_destination)"
		return 0
	fi
	while [ "${url%/}" != "$url" ]; do url=${url%/}; done
	printf '%s' "$url"
}

# Runs the rclone from install-rclone.sh against the store in the inputs.
rclone_s3() { # <rclone arguments...>
	local endpoint=${INPUT_S3_ENDPOINT:-} region flags
	region=$(s3_region)
	flags=(--s3-provider "$(s3_provider)" --s3-env-auth --s3-no-check-bucket --stats=0 --config=/dev/null)
	if [ -n "$endpoint" ]; then flags+=(--s3-endpoint "$endpoint"); fi
	if [ -n "$region" ]; then flags+=(--s3-region "$region"); fi
	"$WORK_DIR/bin/rclone" "$@" "${flags[@]}"
}

# Downloads an object, and returns 1 if it doesn't exist. rclone reports a missing object as success and writes no file, so
# only its other failures are errors.
read_s3_object() { # <bucket and key> <local file>
	rm -f "$2"
	rclone_s3 copyto ":s3:$1" "$2" </dev/null || die "Couldn't read $1 from the bucket. Check the credentials, and that they can read and list its objects."
	[ -f "$2" ]
}
