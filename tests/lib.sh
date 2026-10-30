#!/usr/bin/env bash
# Helpers for the test suites. Stays compatible with bash 3.2, like the scripts it tests.

set -uo pipefail

TESTS_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tests_run=0
tests_failed=0

pass() {
	tests_run=$((tests_run + 1))
	printf 'ok   %s\n' "$1"
}

fail() {
	tests_run=$((tests_run + 1))
	tests_failed=$((tests_failed + 1))
	printf 'FAIL %s\n' "$1"
	if [ -n "${2:-}" ]; then printf '     %s\n' "$2"; fi
}

check() { # <description> <command...>
	local description=$1
	shift
	if "$@" >/dev/null 2>&1; then pass "$description"; else fail "$description" "command failed: $*"; fi
}

check_not() { # <description> <command...>
	local description=$1
	shift
	if "$@" >/dev/null 2>&1; then fail "$description" "command succeeded: $*"; else pass "$description"; fi
}

check_equal() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$2', got '$3'"; fi
}

check_contains() { # <description> <file> <text>
	if grep -Fq -- "$3" "$2"; then
		pass "$1"
	else
		fail "$1" "'$3' not found in: $(tail -n 3 "$2" | cut -c1-240 | tr '\n' ' ')"
	fi
}

check_not_contains() { # <description> <file> <text>
	if grep -Fq -- "$3" "$2"; then fail "$1" "'$3' found in $2"; else pass "$1"; fi
}

finish() {
	printf '\n%d checks, %d failed\n' "$tests_run" "$tests_failed"
	[ "$tests_failed" = "0" ]
}

# Runs the action with a clean environment, so nothing leaks in from the caller's shell. Sets RUN_LOG, RUN_OUTPUT and
# RUN_SUMMARY, and returns the action's exit status.
run_action() { # <run name> [VAR=value...]
	local name=$1
	shift
	RUN_LOG="$RUNS_DIR/$name.log"
	RUN_OUTPUT="$RUNS_DIR/$name.output"
	RUN_SUMMARY="$RUNS_DIR/$name.summary"
	: >"$RUN_OUTPUT"
	: >"$RUN_SUMMARY"
	env -i PATH="$PATH" HOME="${TEST_HOME:-$HOME}" TMPDIR="$RUNS_DIR" RUNNER_TEMP="$RUNS_DIR" \
		RUN_OUTPUT_FILE="$RUN_OUTPUT" RUN_SUMMARY_FILE="$RUN_SUMMARY" "$@" \
		"${BASH:-bash}" "$TESTS_ROOT/tests/run-action.sh" >"$RUN_LOG" 2>&1
}

output_value() { # <name>
	sed -n "s/^$1=//p" "$RUN_OUTPUT" | sed -n 1p
}

# Writes a file with the structure of a built extension: payload, 256 bytes of metadata, 256 zero bytes of signature.
make_extension() { # <file> <platform> <duckdb version> <extension version> <abi> <payload bytes>
	local file=$1 platform=$2 version=$3 extension_version=$4 abi=$5 payload=$6
	mkdir -p "$(dirname "$file")"
	head -c "$payload" /dev/urandom >"$file"
	head -c 96 /dev/zero >>"$file"
	local field
	for field in "$abi" "$extension_version" "$version" "$platform" "4"; do
		printf '%s' "$field" >>"$file"
		head -c $((32 - ${#field})) /dev/zero >>"$file"
	done
	head -c 256 /dev/zero >>"$file"
}

# The hash DuckDB signs, computed independently of the vendored script.
independent_hash() { # <file with the signature removed> <output>
	local dir
	dir=$(mktemp -d "$RUNS_DIR/hash.XXXXXX")
	(
		cd "$dir" || exit 1
		split -b 1048576 "$1" chunk_
		for chunk in chunk_*; do openssl dgst -binary -sha256 "$chunk" >>digests; done
		openssl dgst -binary -sha256 digests >"$2"
	)
	rm -rf "$dir"
}

# Verifies a signed extension the way DuckDB does.
verify_extension() { # <signed file> <public key>
	local dir size
	dir=$(mktemp -d "$RUNS_DIR/verify.XXXXXX")
	size=$(wc -c <"$1" | tr -d '[:space:]')
	head -c $((size - 256)) "$1" >"$dir/unsigned"
	tail -c 256 "$1" >"$dir/signature"
	independent_hash "$dir/unsigned" "$dir/hash"
	openssl pkeyutl -verify -pubin -inkey "$2" -sigfile "$dir/signature" -in "$dir/hash" -pkeyopt digest:sha256 >/dev/null 2>&1
	local result=$?
	rm -rf "$dir"
	return "$result"
}

sha256_file() { # <file>
	local line
	if command -v sha256sum >/dev/null 2>&1; then line=$(sha256sum "$1"); else line=$(shasum -a 256 "$1"); fi
	printf '%s' "${line%% *}"
}
