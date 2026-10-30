#!/usr/bin/env bash
# Tests everything that needs no network, no storage and no DuckDB. Run it with the bash under test: CI uses /bin/bash on
# macOS, which is 3.2.

# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

export RUNS_DIR
RUNS_DIR=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/duckdb-publisher-unit.XXXXXX")" && pwd -P)
trap 'rm -rf "$RUNS_DIR"' EXIT
K="$RUNS_DIR/keys"
mkdir -p "$K"

printf 'bash %s\n\n' "$BASH_VERSION"

openssl genrsa -out "$K/key.pem" 2048 2>/dev/null
openssl rsa -in "$K/key.pem" -pubout -out "$K/key.pub" 2>/dev/null
openssl genrsa -out "$K/reserve.pem" 2048 2>/dev/null
openssl rsa -in "$K/reserve.pem" -pubout -out "$K/reserve.pub" 2>/dev/null
openssl genrsa -out "$K/big.pem" 4096 2>/dev/null
openssl rsa -in "$K/big.pem" -pubout -out "$K/big.pub" 2>/dev/null
openssl ecparam -name prime256v1 -genkey -noout -out "$K/ec.pem" 2>/dev/null
KEY=$(cat "$K/key.pem")

sign_only() { # <run name> <source dir> [VAR=value...]
	local name=$1 source_dir=$2
	shift 2
	run_action "$name" INPUT_MODE=sign-only INPUT_SIGNING_KEY="$KEY" INPUT_PATH="$source_dir" "$@"
}

echo '--- signing'
SRC="$RUNS_DIR/src1"
make_extension "$SRC/nested/deep/demo.duckdb_extension" linux_amd64 v2.0.0 v1.2.3 CPP 2500000
if sign_only basic "$SRC"; then pass 'signs a CPP build found in a nested directory'; else fail 'signs a CPP build found in a nested directory' "$(tail -n 2 "$RUN_LOG")"; fi
SIGNED=$(output_value signed-dir)
LATEST="$SIGNED/v2.0.0/linux_amd64/demo.duckdb_extension.gz"
VERSIONED="$SIGNED/demo/v1.2.3/v2.0.0/linux_amd64/demo.duckdb_extension.gz"
check 'writes the latest path' test -f "$LATEST"
check 'writes the versioned path' test -f "$VERSIONED"
gunzip -c "$LATEST" >"$RUNS_DIR/signed.bin"
check 'the signature verifies against an independently computed hash' verify_extension "$RUNS_DIR/signed.bin" "$K/key.pub"
check_not 'the signature does not verify against another key' verify_extension "$RUNS_DIR/signed.bin" "$K/reserve.pub"
ORIGINAL_SIZE=$(wc -c <"$SRC/nested/deep/demo.duckdb_extension" | tr -d '[:space:]')
check_equal 'the file keeps its size' "$ORIGINAL_SIZE" "$(wc -c <"$RUNS_DIR/signed.bin" | tr -d '[:space:]')"
head -c $((ORIGINAL_SIZE - 256)) "$SRC/nested/deep/demo.duckdb_extension" >"$RUNS_DIR/a"
head -c $((ORIGINAL_SIZE - 256)) "$RUNS_DIR/signed.bin" >"$RUNS_DIR/b"
check 'only the last 256 bytes change' cmp "$RUNS_DIR/a" "$RUNS_DIR/b"
head -c $((ORIGINAL_SIZE - 256)) "$RUNS_DIR/signed.bin" >"$RUNS_DIR/unsigned"
independent_hash "$RUNS_DIR/unsigned" "$RUNS_DIR/independent.hash"
bash "$TESTS_ROOT/scripts/compute-extension-hash.sh" "$RUNS_DIR/unsigned" >"$RUNS_DIR/vendored.hash"
check 'the vendored hash script matches an independent computation' cmp "$RUNS_DIR/independent.hash" "$RUNS_DIR/vendored.hash"
check_not 'that hash differs from a plain SHA-256' test "$(openssl dgst -sha256 -binary "$RUNS_DIR/unsigned" | od -An -tx1 | tr -d ' \n')" = "$(od -An -tx1 "$RUNS_DIR/vendored.hash" | tr -d ' \n')"
check_equal 'reports the fingerprint in the format DuckDB uses' "sha256:$(openssl pkey -pubin -in "$K/key.pub" -outform DER | openssl dgst -sha256 | awk '{print $NF}')" "$(output_value fingerprint)"
FIRST_HASH=$(sha256_file "$LATEST")
FILES=$(sed -n '/^files<</,/^EOF_/p' "$RUN_OUTPUT" | sed -n 2p)
check_equal 'the files output lists both paths' 2 "$(printf '%s' "$FILES" | jq 'length')"
check_equal 'the files output has the ABI' CPP "$(printf '%s' "$FILES" | jq -r '.[0].abi')"
check_contains 'the summary shows client SQL' "$RUN_SUMMARY" '## Signed DuckDB extensions'
check_not_contains 'the log never shows the private key' "$RUN_LOG" 'PRIVATE KEY'
WORK=$(output_value work-dir)
check_not 'the private key is removed afterwards' test -e "$WORK/keys/signing_key.pem"
check 'the signed tree stays for later steps' test -f "$LATEST"
check_not 'intermediate files are removed' test -e "$WORK/tmp"

sign_only rerun "$SRC"
check_equal 'a re-run produces identical bytes' "$FIRST_HASH" "$(sha256_file "$(output_value signed-dir)/v2.0.0/linux_amd64/demo.duckdb_extension.gz")"

echo; echo '--- key file'
sign_only keyfile "$SRC" INPUT_ADDITIONAL_PUBLIC_KEYS="$(cat "$K/reserve.pub")"
KEYFILE="$(output_value signed-dir)/.well-known/duckdb-extension-repo.json"
check_equal 'lists the signing key and the reserve key' 2 "$(jq '.signature_keys | length' "$KEYFILE")"
jq -j '.signature_keys[0]' "$KEYFILE" >"$RUNS_DIR/first.pub"
check 'the signing key comes first' cmp "$RUNS_DIR/first.pub" "$K/key.pub"
sign_only nokeyfile "$SRC" INPUT_PUBLISH_KEY_FILE=false
check_not 'can leave the key file out' test -e "$(output_value signed-dir)/.well-known/duckdb-extension-repo.json"
check_not 'rejects a 4096-bit reserve key' sign_only badreserve "$SRC" INPUT_ADDITIONAL_PUBLIC_KEYS="$(cat "$K/big.pub")"
check_not 'rejects a reserve key that is not PEM' sign_only badreserve2 "$SRC" INPUT_ADDITIONAL_PUBLIC_KEYS="nonsense"

echo; echo '--- signing key'
SINGLE_LINE=$(awk '{printf "%s\\n", $0}' "$K/key.pem")
if run_action literal INPUT_MODE=sign-only INPUT_SIGNING_KEY="$SINGLE_LINE" INPUT_PATH="$SRC"; then pass 'accepts a key with literal \n'; else fail 'accepts a key with literal \n'; fi
check_not 'rejects an empty key' run_action empty INPUT_MODE=sign-only INPUT_SIGNING_KEY="" INPUT_PATH="$SRC"
check_contains 'explains an empty key' "$RUN_LOG" 'fork'
check_not 'rejects a 4096-bit key' run_action big INPUT_MODE=sign-only INPUT_SIGNING_KEY="$(cat "$K/big.pem")" INPUT_PATH="$SRC"
check_contains 'explains the key size' "$RUN_LOG" '2048-bit'
check_not_contains 'does not print a rejected key' "$RUN_LOG" 'PRIVATE KEY'
check_not 'rejects an EC key' run_action ec INPUT_MODE=sign-only INPUT_SIGNING_KEY="$(cat "$K/ec.pem")" INPUT_PATH="$SRC"
check_not 'rejects garbage' run_action garbage INPUT_MODE=sign-only INPUT_SIGNING_KEY="not a key" INPUT_PATH="$SRC"

echo; echo '--- footer validation'
BAD="$RUNS_DIR/bad"
make_extension "$BAD/magic/x.duckdb_extension" linux_amd64 v2.0.0 v1 CPP 2000
SIZE=$(wc -c <"$BAD/magic/x.duckdb_extension" | tr -d '[:space:]')
printf '9' | dd of="$BAD/magic/x.duckdb_extension" bs=1 seek=$((SIZE - 288)) conv=notrunc 2>/dev/null
check_not 'rejects a damaged footer' sign_only magic "$BAD/magic"
check_contains 'mentions strip for a damaged footer' "$RUN_LOG" 'strip'
make_extension "$BAD/small/x.duckdb_extension" linux_amd64 v2.0.0 v1 CPP 1
head -c 100 "$BAD/small/x.duckdb_extension" >"$BAD/small/y.duckdb_extension"
rm "$BAD/small/x.duckdb_extension"
check_not 'rejects a file smaller than the footer' sign_only small "$BAD/small"
make_extension "$BAD/traversal/x.duckdb_extension" '../evil' v2.0.0 v1 CPP 2000
check_not 'rejects a platform that escapes the path' sign_only traversal "$BAD/traversal"
make_extension "$BAD/version/x.duckdb_extension" linux_amd64 '../../evil' v1 CPP 2000
check_not 'rejects a DuckDB version that escapes the path' sign_only version "$BAD/version"
make_extension "$BAD/extversion/x.duckdb_extension" linux_amd64 v2.0.0 '../evil' CPP 2000
check_not 'rejects an extension version that escapes the path' sign_only extversion "$BAD/extversion"
make_extension "$BAD/abi/x.duckdb_extension" linux_amd64 v2.0.0 v1 WEIRD 2000
check_not 'rejects an unknown ABI' sign_only abi "$BAD/abi"
make_extension "$BAD/kind/x.duckdb_extension" wasm_eh v2.0.0 v1 CPP 2000
check_not 'rejects a Wasm footer on a native file name' sign_only kind "$BAD/kind"
make_extension "$BAD/kind2/x.duckdb_extension.wasm" linux_amd64 v2.0.0 v1 CPP 2000
check_not 'rejects a native footer on a Wasm file name' sign_only kind2 "$BAD/kind2"
mkdir -p "$BAD/empty"
check_not 'fails when there is nothing to sign' sign_only empty "$BAD/empty"
check_contains 'explains that nothing was found' "$RUN_LOG" 'found'

echo; echo '--- versions'
V="$RUNS_DIR/versions"
make_extension "$V/cstruct/stable.duckdb_extension" linux_amd64 v1.2.0 abc123 C_STRUCT 2000
check_not 'C_STRUCT needs duckdb-version' sign_only cstruct_none "$V/cstruct"
check_contains 'explains why' "$RUN_LOG" 'C API version'
sign_only cstruct "$V/cstruct" INPUT_DUCKDB_VERSION="v2.0.0, v2.0.1"
SIGNED=$(output_value signed-dir)
check 'C_STRUCT goes into the first listed version' test -f "$SIGNED/v2.0.0/linux_amd64/stable.duckdb_extension.gz"
check 'C_STRUCT goes into the second listed version' test -f "$SIGNED/v2.0.1/linux_amd64/stable.duckdb_extension.gz"
check 'C_STRUCT gets versioned paths per DuckDB version' test -f "$SIGNED/stable/abc123/v2.0.1/linux_amd64/stable.duckdb_extension.gz"
check_not 'C_STRUCT does not use the C API version as a directory' test -e "$SIGNED/v1.2.0"
make_extension "$V/cpp/demo.duckdb_extension" linux_amd64 v2.0.0 v1 CPP 2000
check_not 'a CPP build rejects a different duckdb-version' sign_only cpp_mismatch "$V/cpp" INPUT_DUCKDB_VERSION=v2.1.0
sign_only cpp_match "$V/cpp" INPUT_DUCKDB_VERSION=v2.0.0
check 'a CPP build accepts its own duckdb-version' test -f "$(output_value signed-dir)/v2.0.0/linux_amd64/demo.duckdb_extension.gz"
make_extension "$V/unstable/demo.duckdb_extension" linux_amd64 v2.0.0 v1 C_STRUCT_UNSTABLE 2000
check_not 'a C_STRUCT_UNSTABLE build rejects a different duckdb-version' sign_only unstable_mismatch "$V/unstable" INPUT_DUCKDB_VERSION=v2.1.0
sign_only override "$V/cpp" INPUT_EXTENSION_VERSION=v9.9.9
check 'extension-version overrides the footer in the path' test -f "$(output_value signed-dir)/demo/v9.9.9/v2.0.0/linux_amd64/demo.duckdb_extension.gz"
check_not 'rejects an unsafe extension-version' sign_only override_bad "$V/cpp" INPUT_EXTENSION_VERSION=../evil
check_not 'rejects an unsafe duckdb-version' sign_only version_bad "$V/cstruct" INPUT_DUCKDB_VERSION=../evil

echo; echo '--- selecting binaries'
M="$RUNS_DIR/multi"
make_extension "$M/a/one.duckdb_extension" linux_amd64 v2.0.0 v1 CPP 2000
make_extension "$M/b/one.duckdb_extension" osx_arm64 v2.0.0 v1 CPP 2000
make_extension "$M/c/two.duckdb_extension" linux_amd64 v2.0.0 v1 CPP 2000
sign_only multi "$M"
SIGNED=$(output_value signed-dir)
check 'publishes every platform from one run' test -f "$SIGNED/v2.0.0/osx_arm64/one.duckdb_extension.gz"
check 'publishes every extension by default' test -f "$SIGNED/v2.0.0/linux_amd64/two.duckdb_extension.gz"
sign_only filtered "$M" INPUT_EXTENSION_NAME=one INPUT_EXCLUDE_PLATFORMS="osx_arm64,osx_amd64"
SIGNED=$(output_value signed-dir)
check 'extension-name keeps the named extension' test -f "$SIGNED/v2.0.0/linux_amd64/one.duckdb_extension.gz"
check_not 'extension-name skips other extensions' test -e "$SIGNED/v2.0.0/linux_amd64/two.duckdb_extension.gz"
check_not 'exclude-platforms skips a platform' test -e "$SIGNED/v2.0.0/osx_arm64"
check_not 'fails if every binary is filtered out' sign_only filtered_all "$M" INPUT_EXTENSION_NAME=nope
check_contains 'explains the filter' "$RUN_LOG" 'filtered out'
make_extension "$M/d/one.duckdb_extension" linux_amd64 v2.0.0 v1 CPP 2000
sign_only duplicate "$M"
check_contains 'warns about a duplicate binary' "$RUN_LOG" 'already signed'
rm -rf "$M/d"
sign_only latest_only "$M" INPUT_UPLOAD_VERSIONED=false
check_not 'upload-versioned false skips the versioned path' test -e "$(output_value signed-dir)/one"
sign_only versioned_only "$M" INPUT_UPLOAD_LATEST=false
check_not 'upload-latest false skips the latest path' test -e "$(output_value signed-dir)/v2.0.0"
check_not 'refuses when both paths are off' sign_only neither "$M" INPUT_UPLOAD_LATEST=false INPUT_UPLOAD_VERSIONED=false

echo; echo '--- Wasm'
if command -v brotli >/dev/null 2>&1; then
	W="$RUNS_DIR/wasm"
	make_extension "$W/demo.duckdb_extension.wasm" wasm_eh v2.0.0 v1 CPP 200000
	sign_only wasm "$W"
	SIGNED=$(output_value signed-dir)
	WASM="$SIGNED/v2.0.0/wasm_eh/demo.duckdb_extension.wasm"
	check 'Wasm uses the .wasm path' test -f "$WASM"
	check_not 'Wasm has no versioned path' test -e "$SIGNED/demo"
	brotli -d -c "$WASM" >"$RUNS_DIR/wasm.bin"
	check 'Wasm is Brotli-compressed and verifies' verify_extension "$RUNS_DIR/wasm.bin" "$K/key.pub"
	FILES=$(sed -n '/^files<</,/^EOF_/p' "$RUN_OUTPUT" | sed -n 2p)
	check_equal 'Wasm records its encoding' br "$(printf '%s' "$FILES" | jq -r '.[0].encoding')"
else
	printf 'skip Wasm: brotli is not installed\n'
fi

echo; echo '--- inputs'
check_not 'rejects an unknown mode' run_action badmode INPUT_MODE=nope INPUT_SIGNING_KEY="$KEY" INPUT_PATH="$SRC"
check_not 'rejects a non-boolean' run_action badbool INPUT_MODE=sign-only INPUT_SMOKE_TEST=yes INPUT_SIGNING_KEY="$KEY" INPUT_PATH="$SRC"
check_not 'publish needs a bucket' run_action nobucket INPUT_SIGNING_KEY="$KEY" INPUT_PATH="$SRC"
check_not 'needs to know what to sign' run_action nosource INPUT_MODE=sign-only INPUT_SIGNING_KEY="$KEY"
check_not 'rejects a missing path' run_action nopath INPUT_MODE=sign-only INPUT_SIGNING_KEY="$KEY" INPUT_PATH="$RUNS_DIR/nope"
check_not 'refuses Windows runners' run_action windows RUNNER_OS=Windows INPUT_MODE=sign-only INPUT_SIGNING_KEY="$KEY" INPUT_PATH="$SRC"
check_contains 'says Windows is not supported' "$RUN_LOG" 'Windows'
provider_for() { # <endpoint>
	# shellcheck disable=SC2016 # expanded by the inner bash
	bash -c 'source "$1"; detect_s3_provider "$2"' _ "$TESTS_ROOT/scripts/lib.sh" "$1"
}
check_equal 'detects R2' Cloudflare "$(provider_for https://abc.r2.cloudflarestorage.com)"
check_equal 'defaults to AWS without an endpoint' AWS "$(provider_for '')"
check_equal 'uses Other for any other endpoint' Other "$(provider_for https://minio.example.com)"

echo; echo '--- action.yml wiring'
# Each script must get every INPUT_* it reads from its own step in action.yml.
awk '
	/^ *- name:/ { inputs = "" }
	/^ *INPUT_[A-Z0-9_]+:/ { name = $1; sub(":", "", name); inputs = inputs " " name }
	/scripts\/[a-z-]+\.sh/ { match($0, /scripts\/[a-z-]+\.sh/); print substr($0, RSTART, RLENGTH) inputs }
' "$TESTS_ROOT/action.yml" >"$RUNS_DIR/wiring"
check_equal 'every step of action.yml runs a script that exists' 0 "$(while read -r script _; do [ -f "$TESTS_ROOT/$script" ] || echo "$script"; done <"$RUNS_DIR/wiring" | wc -l | tr -d '[:space:]')"
while read -r script mapped; do
	used=$(grep -oE 'INPUT_[A-Z0-9_]+' "$TESTS_ROOT/$script" | sort -u)
	if grep -q 'export_s3_credentials' "$TESTS_ROOT/$script"; then used="$used INPUT_S3_ACCESS_KEY_ID INPUT_S3_SECRET_ACCESS_KEY INPUT_S3_SESSION_TOKEN"; fi
	if grep -q 's3_region' "$TESTS_ROOT/$script"; then used="$used INPUT_S3_REGION"; fi
	missing=
	for name in $used; do
		case " $mapped " in *" $name "*) ;; *) missing="$missing $name" ;; esac
	done
	check_equal "$script gets every input it reads" '' "$missing"
done <"$RUNS_DIR/wiring"
# Every input declared in action.yml must reach a script, or it silently does nothing.
awk '/^inputs:/ { on = 1; next } /^outputs:/ { on = 0 } on && /^  [a-z0-9-]+:$/ { name = $1; sub(":", "", name); print name }' "$TESTS_ROOT/action.yml" >"$RUNS_DIR/declared"
unused=
while read -r input; do
	upper=$(printf '%s' "$input" | tr 'a-z-' 'A-Z_')
	case "$input" in
	artifact-pattern) grep -q 'inputs.artifact-pattern' "$TESTS_ROOT/action.yml" || unused="$unused $input" ;;
	*) grep -q "INPUT_$upper:" "$TESTS_ROOT/action.yml" || unused="$unused $input" ;;
	esac
done <"$RUNS_DIR/declared"
check_equal 'every declared input is used' '' "$unused"
check_equal 'action.yml pins third-party actions by commit' 0 "$(grep -E '^\s+uses: ' "$TESTS_ROOT/action.yml" | grep -cvE '@[0-9a-f]{40}( |$)')"

echo
echo '--- style'
check_not 'no script turns on command tracing' grep -nE '^\s*set -[a-z]*x|set -o xtrace' "$TESTS_ROOT"/scripts/*.sh
finish
