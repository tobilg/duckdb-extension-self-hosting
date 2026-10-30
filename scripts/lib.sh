#!/usr/bin/env bash
# Shared helpers, sourced by the other scripts.
#
# Everything here must run on bash 3.2, the stock bash on macOS: no associative arrays or mapfile, and no expansion of
# an array that may be empty. Never use `set -x`, and never read one end of a pipe partially under pipefail.

set -euo pipefail

error() { printf '::error::%s\n' "$*" >&2; }
warn() { printf '::warning::%s\n' "$*" >&2; }
notice() { printf '::notice::%s\n' "$*"; }
info() { printf '%s\n' "$*"; }
die() {
	error "$*"
	exit 1
}

set_output() { # <name> <value>
	[ -n "${GITHUB_OUTPUT:-}" ] || return 0
	printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT"
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

in_list() { # <word> <list>
	local item
	for item in $(split_list "$2"); do
		[ "$item" = "$1" ] && return 0
	done
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

# Maps the credential inputs to the environment rclone reads. Inputs win, otherwise the environment is left as it is.
export_s3_credentials() {
	if [ -n "${INPUT_S3_ACCESS_KEY_ID:-}" ]; then export AWS_ACCESS_KEY_ID="$INPUT_S3_ACCESS_KEY_ID"; fi
	if [ -n "${INPUT_S3_SECRET_ACCESS_KEY:-}" ]; then export AWS_SECRET_ACCESS_KEY="$INPUT_S3_SECRET_ACCESS_KEY"; fi
	if [ -n "${INPUT_S3_SESSION_TOKEN:-}" ]; then export AWS_SESSION_TOKEN="$INPUT_S3_SESSION_TOKEN"; fi
	return 0
}

s3_region() { printf '%s' "${INPUT_S3_REGION:-${AWS_REGION:-${AWS_DEFAULT_REGION:-}}}"; }

# rclone's name for the store behind the endpoint.
detect_s3_provider() { # <endpoint>
	case "$1" in
	'') printf 'AWS' ;;
	*.r2.cloudflarestorage.com*) printf 'Cloudflare' ;;
	*) printf 'Other' ;;
	esac
}
