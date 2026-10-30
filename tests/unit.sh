#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2012,SC2119,SC2120 # lib_call's code is expanded by the inner bash, ls shows the file modes, and check_refused passes arguments to functions
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
openssl genpkey -algorithm RSA-PSS -pkeyopt rsa_keygen_bits:2048 -out "$K/pss.pem" 2>/dev/null
openssl pkey -in "$K/pss.pem" -pubout -out "$K/pss.pub" 2>/dev/null
KEY=$(cat "$K/key.pem")

sign_only() { # <run name> <source dir> [VAR=value...]
	local name=$1 source_dir=$2
	shift 2
	run_action "$name" INPUT_MODE=sign INPUT_ALL_EXTENSIONS=true INPUT_SIGNING_KEY="$KEY" INPUT_PATH="$source_dir" "$@"
}

# Runs one script of the action with a clean environment, without the steps that action.yml runs after it. Has no
# RUNNER_TEMP, so a test can run scripts of different modes on one work directory.
run_step() { # <script> [VAR=value...]
	local script=$1
	shift
	env -i PATH="$PATH" HOME="$HOME" TMPDIR="$RUNS_DIR" GITHUB_OUTPUT="$RUN_OUTPUT" GITHUB_STEP_SUMMARY="$RUN_SUMMARY" "$@" \
		"${BASH:-bash}" "$TESTS_ROOT/scripts/$script" >>"$RUN_LOG" 2>&1
}

new_step_run() { # <name>
	RUN_LOG="$RUNS_DIR/$1.log"
	RUN_OUTPUT="$RUNS_DIR/$1.output"
	RUN_SUMMARY="$RUNS_DIR/$1.summary"
	: >"$RUN_LOG"
	: >"$RUN_OUTPUT"
	: >"$RUN_SUMMARY"
}

lib_call() { # <shell code, with lib.sh sourced> [argument...]
	local code=$1
	shift
	"${BASH:-bash}" -c 'source "$1"; shift; '"$code" _ "$TESTS_ROOT/scripts/lib.sh" "$@"
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
FILES=$(output_block files)
check_equal 'the files output lists both paths' 2 "$(printf '%s' "$FILES" | jq 'length')"
check_equal 'the files output has the ABI' CPP "$(printf '%s' "$FILES" | jq -r '.[0].abi')"
check_equal 'sha256 is the hash of the object' "$FIRST_HASH" "$(printf '%s' "$FILES" | jq -r '.[0].sha256')"
check_equal 'binary_sha256 is the hash of the binary inside it' "$(sha256_file "$RUNS_DIR/signed.bin")" "$(printf '%s' "$FILES" | jq -r '.[0].binary_sha256')"
check_contains 'the summary lists what was signed' "$RUN_SUMMARY" '## Signed DuckDB extensions'
check_not_contains 'the log never shows the private key' "$RUN_LOG" 'PRIVATE KEY'
WORK=$(output_value work-dir)
check_not 'the private key is removed afterwards' test -e "$WORK/keys/signing_key.pem"
check 'the signed tree stays for later steps' test -f "$LATEST"
check_not 'intermediate files are removed' test -e "$WORK/tmp"
check_not 'the build artifacts are removed' test -e "$WORK/artifacts"
check_equal 'the bundle digest is a SHA-256' 64 "$(output_value bundle-digest | tr -d '\n' | wc -c | tr -d '[:space:]')"
check_equal 'the bundle digest describes the tree' "$(output_value bundle-digest)" "$(lib_call 'bundle_digest "$1"' "$(bundle_dir)")"

BASIC_DIGEST=$(output_value bundle-digest)
sign_only rerun "$SRC"
check_equal 'a re-run produces identical bytes' "$FIRST_HASH" "$(sha256_file "$(output_value signed-dir)/v2.0.0/linux_amd64/demo.duckdb_extension.gz")"
check_equal 'and the same digest, so a later job can be re-run too' "$BASIC_DIGEST" "$(output_value bundle-digest)"

echo; echo '--- several binaries in one run'
MANY="$RUNS_DIR/many"
make_extension "$MANY/a/alpha.duckdb_extension" linux_amd64 v2.0.0 v1.0.0 CPP 300000
make_extension "$MANY/b/alpha.duckdb_extension" osx_arm64 v2.0.0 v1.0.0 CPP 300000
make_extension "$MANY/c/beta.duckdb_extension" linux_amd64 v2.0.0 v3.0.0 CPP 200000
sign_only many "$MANY"
SIGNED=$(output_value signed-dir)
# Each must hold its own binary: the objects are hard links, so a shared scratch file would overwrite the earlier ones.
same_payload() { # <object> <source binary>
	gunzip -c "$1" >"$RUNS_DIR/unpacked"
	local size
	size=$(wc -c <"$2" | tr -d '[:space:]')
	head -c $((size - 256)) "$RUNS_DIR/unpacked" >"$RUNS_DIR/unpacked.head"
	head -c $((size - 256)) "$2" >"$RUNS_DIR/source.head"
	cmp -s "$RUNS_DIR/unpacked.head" "$RUNS_DIR/source.head"
}
check 'the first binary keeps its own bytes' same_payload "$SIGNED/v2.0.0/linux_amd64/alpha.duckdb_extension.gz" "$MANY/a/alpha.duckdb_extension"
check 'the second binary keeps its own bytes' same_payload "$SIGNED/v2.0.0/osx_arm64/alpha.duckdb_extension.gz" "$MANY/b/alpha.duckdb_extension"
check 'the third binary keeps its own bytes' same_payload "$SIGNED/v2.0.0/linux_amd64/beta.duckdb_extension.gz" "$MANY/c/beta.duckdb_extension"
check 'the versioned object holds the same binary' same_payload "$SIGNED/beta/v3.0.0/v2.0.0/linux_amd64/beta.duckdb_extension.gz" "$MANY/c/beta.duckdb_extension"
check_equal 'the manifest lists all of them' 6 "$(jq -s 'length' "$(bundle_dir)/manifest.jsonl")"
check_contains 'says how many binaries it signed' "$RUN_LOG" 'Signed 3 binaries'

echo; echo '--- key file'
sign_only keyfile "$SRC" INPUT_ADDITIONAL_PUBLIC_KEYS="$(cat "$K/reserve.pub")"
KEYFILE="$(output_value signed-dir)/.well-known/duckdb-extension-repo.json"
check_equal 'lists the signing key and the reserve key' 2 "$(jq '.signature_keys | length' "$KEYFILE")"
jq -j '.signature_keys[0]' "$KEYFILE" >"$RUNS_DIR/first.pub"
check 'the signing key comes first' cmp "$RUNS_DIR/first.pub" "$K/key.pub"
sign_only nokeyfile "$SRC" INPUT_PUBLISH_KEY_FILE=false
check_not 'can leave the key file out' test -e "$(output_value signed-dir)/.well-known/duckdb-extension-repo.json"
check_refused 'rejects a 4096-bit reserve key' '2048-bit' sign_only badreserve "$SRC" INPUT_ADDITIONAL_PUBLIC_KEYS="$(cat "$K/big.pub")"
check_refused 'rejects a reserve key that is not PEM' 'holds no PEM public key' sign_only badreserve2 "$SRC" INPUT_ADDITIONAL_PUBLIC_KEYS="nonsense"
check_refused 'rejects an RSA-PSS reserve key' 'must be an RSA key' sign_only pssreserve "$SRC" INPUT_ADDITIONAL_PUBLIC_KEYS="$(cat "$K/pss.pub")"
RESERVE_ONE_LINE=$(awk '{printf "%s\\n", $0}' "$K/reserve.pub")
if sign_only literal_reserve "$SRC" INPUT_ADDITIONAL_PUBLIC_KEYS="$RESERVE_ONE_LINE"; then pass 'accepts a reserve key with literal \n'; else fail 'accepts a reserve key with literal \n' "$(tail -n 1 "$RUN_LOG")"; fi
check_equal 'and lists it' 2 "$(jq '.signature_keys | length' "$(output_value signed-dir)/.well-known/duckdb-extension-repo.json")"

echo; echo '--- signing key'
SINGLE_LINE=$(awk '{printf "%s\\n", $0}' "$K/key.pem")
if run_action literal INPUT_MODE=sign INPUT_ALL_EXTENSIONS=true INPUT_SIGNING_KEY="$SINGLE_LINE" INPUT_PATH="$SRC"; then pass 'accepts a key with literal \n'; else fail 'accepts a key with literal \n'; fi
check_refused 'rejects an empty key, and explains why that happens' 'fork' run_action empty INPUT_MODE=sign INPUT_ALL_EXTENSIONS=true INPUT_SIGNING_KEY="" INPUT_PATH="$SRC"
check_refused 'rejects a 4096-bit key' '2048-bit' run_action big INPUT_MODE=sign INPUT_ALL_EXTENSIONS=true INPUT_SIGNING_KEY="$(cat "$K/big.pem")" INPUT_PATH="$SRC"
check_not_contains 'does not print a rejected key' "$RUN_LOG" 'PRIVATE KEY'
check_not 'and removes it' test -e "$(output_value work-dir)/keys/signing_key.pem"
check_refused 'rejects an EC key' 'must be an RSA key' run_action ec INPUT_MODE=sign INPUT_ALL_EXTENSIONS=true INPUT_SIGNING_KEY="$(cat "$K/ec.pem")" INPUT_PATH="$SRC"
check_refused 'rejects an RSA-PSS key, which DuckDB would reject' 'must be an RSA key' run_action pss INPUT_MODE=sign INPUT_ALL_EXTENSIONS=true INPUT_SIGNING_KEY="$(cat "$K/pss.pem")" INPUT_PATH="$SRC"
check_refused 'rejects garbage' 'not a readable PEM private key' run_action garbage INPUT_MODE=sign INPUT_ALL_EXTENSIONS=true INPUT_SIGNING_KEY="not a key" INPUT_PATH="$SRC"

echo; echo '--- handling the private key'
new_step_run keyfile_mode
run_step setup.sh INPUT_MODE=sign INPUT_ALL_EXTENSIONS=true INPUT_PATH="$SRC" HAS_SIGNING_KEY=true
WORK=$(output_value work-dir)
check_equal 'the work directory is private' drwx------ "$(ls -ld "$WORK" | cut -c1-10)"
check_not 'setup does not write the private key, so it is not on disk during the artifact download' test -e "$WORK/keys/signing_key.pem"
run_step load-key.sh WORK_DIR="$WORK" INPUT_SIGNING_KEY="$KEY"
check_equal 'the key file is private' -rw------- "$(ls -l "$WORK/keys/signing_key.pem" | cut -c1-10)"
run_step cleanup.sh WORK_DIR="$WORK"
check_not 'cleanup removes a key that sign.sh left behind' test -e "$WORK/keys/signing_key.pem"
new_step_run key_failure
run_step setup.sh INPUT_MODE=sign INPUT_ALL_EXTENSIONS=true INPUT_PATH="$SRC" HAS_SIGNING_KEY=true
WORK=$(output_value work-dir)
make_extension "$RUNS_DIR/bad-for-key/x.duckdb_extension" linux_amd64 v2.0.0 v1 WEIRD 2000
run_step sign.sh WORK_DIR="$WORK" SOURCE_DIR="$RUNS_DIR/bad-for-key" INPUT_SIGNING_KEY="$KEY"
check_contains 'a signing failure stops the step' "$RUN_LOG" 'unknown ABI'
check 'and sign.sh had written the key' test -d "$WORK/keys"
check_not 'but removed it again, without help from cleanup.sh' test -e "$WORK/keys/signing_key.pem"
# Signs with the wrong key, to see whether the check after signing notices.
mkdir -p "$RUNS_DIR/wrong-signer"
cat >"$RUNS_DIR/wrong-signer/openssl" <<EOF
#!/bin/sh
real=\$(PATH="$PATH" command -v openssl)
if [ "\$1" = "pkeyutl" ] && [ "\$2" = "-sign" ]; then
	exec "\$real" pkeyutl -sign -in "\$4" -inkey "$K/reserve.pem" -pkeyopt digest:sha256 -out "\${10}"
fi
exec "\$real" "\$@"
EOF
chmod +x "$RUNS_DIR/wrong-signer/openssl"
new_step_run self_check
run_step setup.sh INPUT_MODE=sign INPUT_ALL_EXTENSIONS=true INPUT_PATH="$SRC" HAS_SIGNING_KEY=true
WORK=$(output_value work-dir)
if run_step sign.sh WORK_DIR="$WORK" SOURCE_DIR="$SRC" INPUT_SIGNING_KEY="$KEY" PATH="$RUNS_DIR/wrong-signer:$PATH"; then
	fail 'refuses a signature that does not verify against the public key'
else
	pass 'refuses a signature that does not verify against the public key'
fi
check_contains 'and says so' "$RUN_LOG" "new signature doesn't verify"
# Compressing can take minutes, and needs neither the key file nor the key in the environment.
mkdir -p "$RUNS_DIR/spy-gzip"
cat >"$RUNS_DIR/spy-gzip/gzip" <<EOF
#!/bin/sh
real=\$(PATH="$PATH" command -v gzip)
if [ -e "\$KEY_FILE_TO_WATCH" ]; then echo 'key file on disk' >>"$RUNS_DIR/spy-gzip/seen"; fi
env | grep -q '^INPUT_SIGNING_KEY=' && echo 'key in the environment' >>"$RUNS_DIR/spy-gzip/seen"
exec "\$real" "\$@"
EOF
chmod +x "$RUNS_DIR/spy-gzip/gzip"
: >"$RUNS_DIR/spy-gzip/seen"
new_step_run key_during_compress
run_step setup.sh INPUT_MODE=sign INPUT_ALL_EXTENSIONS=true INPUT_PATH="$SRC" HAS_SIGNING_KEY=true
WORK=$(output_value work-dir)
run_step sign.sh WORK_DIR="$WORK" SOURCE_DIR="$SRC" INPUT_SIGNING_KEY="$KEY" KEY_FILE_TO_WATCH="$WORK/keys/signing_key.pem" PATH="$RUNS_DIR/spy-gzip:$PATH"
check 'the signing step compressed something' test -f "$WORK/bundle/signed/v2.0.0/linux_amd64/demo.duckdb_extension.gz"
check_not_contains 'the key file is gone before compressing starts' "$RUNS_DIR/spy-gzip/seen" 'key file on disk'
check_not_contains 'and the key is not in the environment of the tools' "$RUNS_DIR/spy-gzip/seen" 'key in the environment'
# The redirect creates the output file either way, so without this check an empty object would get published.
mkdir -p "$RUNS_DIR/failing-gzip"
printf '#!/bin/sh\nexit 1\n' >"$RUNS_DIR/failing-gzip/gzip"
chmod +x "$RUNS_DIR/failing-gzip/gzip"
new_step_run compress_failure
run_step setup.sh INPUT_MODE=sign INPUT_ALL_EXTENSIONS=true INPUT_PATH="$SRC" HAS_SIGNING_KEY=true
WORK=$(output_value work-dir)
if run_step sign.sh WORK_DIR="$WORK" SOURCE_DIR="$SRC" INPUT_SIGNING_KEY="$KEY" PATH="$RUNS_DIR/failing-gzip:$PATH"; then
	fail 'a failed compression fails the step'
else
	pass 'a failed compression fails the step'
fi
check_contains 'and says so' "$RUN_LOG" 'Compressing the signed binaries failed'
check_not 'and leaves nothing to publish' test -e "$WORK/bundle/signed/v2.0.0"

echo; echo '--- footer validation'
BAD="$RUNS_DIR/bad"
make_extension "$BAD/magic/x.duckdb_extension" linux_amd64 v2.0.0 v1 CPP 2000
set_footer_field "$BAD/magic/x.duckdb_extension" 288 9
check_refused 'rejects a damaged footer, and mentions strip' 'strip' sign_only magic "$BAD/magic"
make_extension "$BAD/small/x.duckdb_extension" linux_amd64 v2.0.0 v1 CPP 1
head -c 100 "$BAD/small/x.duckdb_extension" >"$BAD/small/y.duckdb_extension"
rm "$BAD/small/x.duckdb_extension"
check_refused 'rejects a file smaller than the footer' 'too small' sign_only small "$BAD/small"
make_extension "$BAD/traversal/x.duckdb_extension" '../evil' v2.0.0 v1 CPP 2000
check_refused 'rejects a platform that escapes the path' 'platform in the footer' sign_only traversal "$BAD/traversal"
make_extension "$BAD/version/x.duckdb_extension" linux_amd64 '../../evil' v1 CPP 2000
check_refused 'rejects a DuckDB version that escapes the path' 'DuckDB version in the footer' sign_only version "$BAD/version"
make_extension "$BAD/extversion/x.duckdb_extension" linux_amd64 v2.0.0 '../evil' CPP 2000
check_refused 'rejects an extension version that escapes the path' "can't be used in a path" sign_only extversion "$BAD/extversion"
make_extension "$BAD/dots/x.duckdb_extension" linux_amd64 '..' v1 CPP 2000
check_refused "rejects a DuckDB version of '..'" 'DuckDB version in the footer' sign_only dots "$BAD/dots"
check_not "writes nothing outside the signed tree for '..'" test -e "$(output_value work-dir)/bundle/linux_amd64"
make_extension "$BAD/dot/x.duckdb_extension" linux_amd64 '.' v1 CPP 2000
check_refused "rejects a DuckDB version of '.'" 'DuckDB version in the footer' sign_only dot "$BAD/dot"
make_extension "$BAD/extdots/x.duckdb_extension" linux_amd64 v2.0.0 '..' CPP 2000
check_refused "rejects an extension version of '..'" "can't be used in a path" sign_only extdots "$BAD/extdots"
make_extension "$BAD/hyphen/my-ext.duckdb_extension" linux_amd64 v2.0.0 v1 CPP 2000
check_refused 'rejects a name with a hyphen, and explains which names work' 'lowercase letters' sign_only hyphen "$BAD/hyphen"
make_extension "$BAD/upper/MyExt.duckdb_extension" linux_amd64 v2.0.0 v1 CPP 2000
check_refused 'rejects a name with uppercase letters' 'lowercase letters' sign_only upper "$BAD/upper"
make_extension "$BAD/digit/3dthing.duckdb_extension" linux_amd64 v2.0.0 v1 CPP 2000
check_refused 'rejects a name that starts with a digit' 'lowercase letters' sign_only digit "$BAD/digit"
make_extension "$BAD/abi/x.duckdb_extension" linux_amd64 v2.0.0 v1 WEIRD 2000
check_refused 'rejects an unknown ABI' 'unknown ABI' sign_only abi "$BAD/abi"
make_extension "$BAD/kind/x.duckdb_extension" wasm_eh v2.0.0 v1 CPP 2000
check_refused 'rejects a Wasm footer on a native file name' "doesn't end in .duckdb_extension.wasm" sign_only kind "$BAD/kind"
make_extension "$BAD/kind2/x.duckdb_extension.wasm" linux_amd64 v2.0.0 v1 CPP 2000
check_refused 'rejects a native footer on a Wasm file name' 'ends in .duckdb_extension.wasm' sign_only kind2 "$BAD/kind2"
mkdir -p "$BAD/empty"
check_refused 'fails when there is nothing to sign' 'files found' sign_only empty "$BAD/empty"

echo; echo '--- versions'
V="$RUNS_DIR/versions"
make_extension "$V/cstruct/stable.duckdb_extension" linux_amd64 v1.2.0 abc123 C_STRUCT 2000
check_refused 'C_STRUCT needs duckdb-version' 'C API version' sign_only cstruct_none "$V/cstruct"
sign_only cstruct "$V/cstruct" INPUT_DUCKDB_VERSION="v2.0.0, v2.0.1"
SIGNED=$(output_value signed-dir)
check 'C_STRUCT goes into the first listed version' test -f "$SIGNED/v2.0.0/linux_amd64/stable.duckdb_extension.gz"
check 'C_STRUCT goes into the second listed version' test -f "$SIGNED/v2.0.1/linux_amd64/stable.duckdb_extension.gz"
check 'C_STRUCT gets versioned paths per DuckDB version' test -f "$SIGNED/stable/abc123/v2.0.1/linux_amd64/stable.duckdb_extension.gz"
check_not 'C_STRUCT does not use the C API version as a directory' test -e "$SIGNED/v1.2.0"
make_extension "$V/cpp/demo.duckdb_extension" linux_amd64 v2.0.0 v1 CPP 2000
check_refused 'a CPP build rejects a different duckdb-version' 'exact version' sign_only cpp_mismatch "$V/cpp" INPUT_DUCKDB_VERSION=v2.1.0
sign_only cpp_match "$V/cpp" INPUT_DUCKDB_VERSION=v2.0.0
check 'a CPP build accepts its own duckdb-version' test -f "$(output_value signed-dir)/v2.0.0/linux_amd64/demo.duckdb_extension.gz"
make_extension "$V/unstable/demo.duckdb_extension" linux_amd64 v2.0.0 v1 C_STRUCT_UNSTABLE 2000
check_refused 'a C_STRUCT_UNSTABLE build rejects a different duckdb-version' 'exact version' sign_only unstable_mismatch "$V/unstable" INPUT_DUCKDB_VERSION=v2.1.0
sign_only override "$V/cpp" INPUT_EXTENSION_VERSION=v9.9.9
check 'extension-version overrides the footer in the path' test -f "$(output_value signed-dir)/demo/v9.9.9/v2.0.0/linux_amd64/demo.duckdb_extension.gz"
check_contains 'and warns that the footer says something else' "$RUN_LOG" "the footer says 'v1'"
sign_only override_same "$V/cpp" INPUT_EXTENSION_VERSION=v1
check_not_contains 'but not if they agree' "$RUN_LOG" 'the footer says'
check_refused 'rejects an unsafe extension-version' "can't be used in a path" sign_only override_bad "$V/cpp" INPUT_EXTENSION_VERSION=../evil
check_refused 'rejects an unsafe duckdb-version' "can't be used in a path" sign_only version_bad "$V/cstruct" INPUT_DUCKDB_VERSION=../evil
check_refused "rejects an extension-version of '..'" "can't be used in a path" sign_only override_dots "$V/cpp" INPUT_EXTENSION_VERSION=..
check_refused "rejects a duckdb-version of '..'" "can't be used in a path" sign_only version_dots "$V/cstruct" INPUT_DUCKDB_VERSION=..
check_refused 'rejects a duckdb-version without its v, and says which directory DuckDB requests' "'v2.0.1'" sign_only version_bare "$V/cstruct" INPUT_DUCKDB_VERSION="v2.0.0, 2.0.1"
sign_only version_commit "$V/cstruct" INPUT_DUCKDB_VERSION=d54cbbe3df
check 'accepts the commit directory of a dev build' test -f "$(output_value signed-dir)/d54cbbe3df/linux_amd64/stable.duckdb_extension.gz"
sign_only version_twice "$V/cstruct" INPUT_DUCKDB_VERSION="v2.0.0, v2.0.0"
check_equal 'a version listed twice is published once' 2 "$(output_block files | jq 'length')"
make_extension "$V/capi/a/stable.duckdb_extension" linux_amd64 v1.2.0 abc123 C_STRUCT 2000
make_extension "$V/capi/b/stable.duckdb_extension" linux_amd64 v1.3.0 abc123 C_STRUCT 2000
check_refused 'refuses two builds that would land on one path' 'would replace' sign_only capi_collision "$V/capi" INPUT_DUCKDB_VERSION=v2.0.0
# A footer's version doesn't have to be usable where it isn't part of a path, and the input can replace one that isn't.
make_extension "$V/noversion/demo.duckdb_extension" linux_amd64 v2.0.0 '' CPP 2000
check_refused 'a footer without a version needs extension-version for the versioned path' "Set 'extension-version'" sign_only noversion "$V/noversion"
if sign_only noversion_input "$V/noversion" INPUT_EXTENSION_VERSION=v1.0.0; then pass 'extension-version stands in for a footer without a version'; else fail 'extension-version stands in for a footer without a version' "$(tail -n 1 "$RUN_LOG")"; fi
check 'and is used in the path' test -f "$(output_value signed-dir)/demo/v1.0.0/v2.0.0/linux_amd64/demo.duckdb_extension.gz"
if sign_only noversion_latest "$V/noversion" INPUT_UPLOAD_VERSIONED=false; then pass 'a footer without a version is fine without the versioned path'; else fail 'a footer without a version is fine without the versioned path' "$(tail -n 1 "$RUN_LOG")"; fi

echo; echo '--- selecting binaries'
M="$RUNS_DIR/multi"
make_extension "$M/a/one.duckdb_extension" linux_amd64 v2.0.0 v1 CPP 2000
make_extension "$M/b/one.duckdb_extension" osx_arm64 v2.0.0 v1 CPP 2000
make_extension "$M/c/two.duckdb_extension" linux_amd64 v2.0.0 v1 CPP 2000
sign_only multi "$M"
SIGNED=$(output_value signed-dir)
check 'publishes every platform from one run' test -f "$SIGNED/v2.0.0/osx_arm64/one.duckdb_extension.gz"
check 'all-extensions publishes every extension' test -f "$SIGNED/v2.0.0/linux_amd64/two.duckdb_extension.gz"
check_refused 'a build tree can not be signed without saying what to sign' 'all-extensions' run_action noname INPUT_MODE=sign INPUT_SIGNING_KEY="$KEY" INPUT_PATH="$M"
check_refused 'nor can a glob of artifacts' 'all-extensions' run_action nonamepattern INPUT_MODE=sign INPUT_SIGNING_KEY="$KEY" INPUT_ARTIFACT_PATTERN='*'
run_action named INPUT_MODE=sign INPUT_SIGNING_KEY="$KEY" INPUT_PATH="$M" INPUT_EXTENSION_NAME=one
SIGNED=$(output_value signed-dir)
check 'extension-name keeps the named extension' test -f "$SIGNED/v2.0.0/linux_amd64/one.duckdb_extension.gz"
check_not 'extension-name skips other extensions' test -e "$SIGNED/v2.0.0/linux_amd64/two.duckdb_extension.gz"
sign_only filtered "$M" INPUT_EXTENSION_NAME=one INPUT_EXCLUDE_PLATFORMS="osx_arm64,linux_arm64"
check_not 'exclude-platforms skips a platform' test -e "$(output_value signed-dir)/v2.0.0/osx_arm64"
check_contains 'and warns about an entry that matched nothing' "$RUN_LOG" "'linux_arm64', which matched none"
check_not_contains 'but not about one that did' "$RUN_LOG" "'osx_arm64', which matched none"
sign_only filtered_glob "$M" INPUT_EXCLUDE_PLATFORMS='osx_*'
check_not 'exclude-platforms takes a wildcard' test -e "$(output_value signed-dir)/v2.0.0/osx_arm64"
check 'that leaves the other platforms' test -f "$(output_value signed-dir)/v2.0.0/linux_amd64/one.duckdb_extension.gz"
check_not_contains 'and does not warn' "$RUN_LOG" 'matched none'
# A file in the current directory must not turn the wildcard into its own name.
mkdir -p "$RUNS_DIR/glob-cwd"
: >"$RUNS_DIR/glob-cwd/osx_decoy"
(cd "$RUNS_DIR/glob-cwd" && sign_only filtered_cwd "$M" INPUT_EXCLUDE_PLATFORMS='osx_*')
check_not 'the wildcard does not expand against the current directory' test -e "$(output_value signed-dir)/v2.0.0/osx_arm64"
check_refused 'a platform name that can not exist fails, instead of publishing what it meant to skip' "can't match a platform" sign_only filtered_typo "$M" INPUT_EXCLUDE_PLATFORMS='wasm-eh'
check_refused 'fails if every binary is filtered out' 'filtered out' sign_only filtered_all "$M" INPUT_EXTENSION_NAME=nope
make_extension "$M/unrelated/foo.bar.duckdb_extension" linux_amd64 v2.0.0 v1 CPP 2000
sign_only unrelated "$M" INPUT_EXTENSION_NAME=one
check 'an unusable name is fine when it is not being published' test -f "$(output_value signed-dir)/v2.0.0/linux_amd64/one.duckdb_extension.gz"
rm -rf "$M/unrelated"
cp "$M/a/one.duckdb_extension" "$RUNS_DIR/one.copy"
mkdir -p "$M/d"
cp "$RUNS_DIR/one.copy" "$M/d/one.duckdb_extension"
if sign_only duplicate "$M"; then pass 'the same build twice is fine'; else fail 'the same build twice is fine' "$(tail -n 1 "$RUN_LOG")"; fi
check_contains 'and is only signed once' "$RUN_LOG" 'the same build as'
# A signed copy of the same build differs only in the signature slot.
head -c 2256 "$RUNS_DIR/one.copy" >"$M/d/one.duckdb_extension"
head -c 256 /dev/urandom >>"$M/d/one.duckdb_extension"
if sign_only duplicate_signed "$M"; then pass 'a copy that differs only in its signature counts as the same build'; else fail 'a copy that differs only in its signature counts as the same build' "$(tail -n 1 "$RUN_LOG")"; fi
make_extension "$M/d/one.duckdb_extension" linux_amd64 v2.0.0 v1 CPP 2000
check_refused 'two different builds on one path fail, because the wrong one could win' 'different build' sign_only duplicate_other "$M"
rm -rf "$M/d"
sign_only latest_only "$M" INPUT_UPLOAD_VERSIONED=false
check_not 'upload-versioned false skips the versioned path' test -e "$(output_value signed-dir)/one"
sign_only versioned_only "$M" INPUT_UPLOAD_LATEST=false
check_not 'upload-latest false skips the latest path' test -e "$(output_value signed-dir)/v2.0.0"
check_refused 'refuses when both paths are off' 'nothing to publish' sign_only neither "$M" INPUT_UPLOAD_LATEST=false INPUT_UPLOAD_VERSIONED=false

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
	check_equal 'Wasm records its encoding' br "$(output_block files | jq -r '.[0].encoding')"
	check_refused 'Wasm-only without the latest path says that is the reason' "they need 'upload-latest'" sign_only wasm_nolatest "$W" INPUT_UPLOAD_LATEST=false
	# A Wasm build has no versioned path, so a footer version it can't use there doesn't matter.
	make_extension "$W/noversion/demo.duckdb_extension.wasm" wasm_eh v2.0.0 '' CPP 2000
	if sign_only wasm_noversion "$W/noversion"; then pass 'a Wasm footer without a version is fine'; else fail 'a Wasm footer without a version is fine' "$(tail -n 1 "$RUN_LOG")"; fi
else
	printf 'skip Wasm: brotli is not installed\n'
fi

echo; echo '--- inputs'
check_refused 'needs a mode' "'mode' is required" run_action nomode INPUT_SIGNING_KEY="$KEY" INPUT_PATH="$SRC"
check_refused 'rejects an unknown mode' "got 'nope'" run_action badmode INPUT_MODE=nope INPUT_SIGNING_KEY="$KEY" INPUT_PATH="$SRC"
check_refused "rejects the old mode 'sign-only'" "got 'sign-only'" run_action oldmode INPUT_MODE=sign-only INPUT_SIGNING_KEY="$KEY" INPUT_PATH="$SRC"
check_refused 'rejects a non-boolean' "'check-repository' must be" run_action badbool INPUT_MODE=sign INPUT_CHECK_REPOSITORY=yes INPUT_SIGNING_KEY="$KEY" INPUT_PATH="$SRC"
check_refused 'needs to know what to sign' "Set 'extension-name'" run_action nosource INPUT_MODE=sign INPUT_SIGNING_KEY="$KEY"
check_refused 'rejects a missing path' 'not a directory' run_action nopath INPUT_MODE=sign INPUT_ALL_EXTENSIONS=true INPUT_SIGNING_KEY="$KEY" INPUT_PATH="$RUNS_DIR/nope"
check_refused 'refuses Windows runners' 'Windows' run_action windows RUNNER_OS=Windows INPUT_MODE=sign INPUT_SIGNING_KEY="$KEY" INPUT_PATH="$SRC"
check_equal 'detects R2' Cloudflare "$(lib_call 'detect_s3_provider "$1"' https://abc.r2.cloudflarestorage.com)"
check_equal 'defaults to AWS without an endpoint' AWS "$(lib_call 'detect_s3_provider "$1"' '')"
check_equal 'uses Other for any other endpoint' Other "$(lib_call 'detect_s3_provider "$1"' https://minio.example.com)"
publish_setup() { # <run name> [VAR=value...]
	local name=$1
	shift
	run_action "$name" INPUT_MODE=publish INPUT_S3_BUCKET=bucket INPUT_BUNDLE_DIGEST=abc "$@"
}
publish_step() { run_step setup.sh INPUT_MODE=publish INPUT_S3_BUCKET=bucket INPUT_BUNDLE_DIGEST=abc "$@"; }
check_refused 'publish needs a bucket' "'s3-bucket' is required" run_action nobucket INPUT_MODE=publish INPUT_BUNDLE_DIGEST=abc INPUT_S3_ACCESS_KEY_ID=a INPUT_S3_SECRET_ACCESS_KEY=b
check_refused 'publish needs the digest of the sign job' "'bundle-digest' is required" run_action nodigest INPUT_MODE=publish INPUT_S3_BUCKET=bucket INPUT_S3_ACCESS_KEY_ID=a INPUT_S3_SECRET_ACCESS_KEY=b
check_refused 'publish does not take the signing key' "Don't pass 'signing-key'" publish_setup publish_key INPUT_SIGNING_KEY="$KEY" INPUT_S3_ACCESS_KEY_ID=a INPUT_S3_SECRET_ACCESS_KEY=b
check_refused 'a repository-url with a line break fails' 'contains whitespace' publish_setup newline_url INPUT_REPOSITORY_URL="$(printf 'https://x\nfingerprint=forged')" INPUT_S3_ACCESS_KEY_ID=a INPUT_S3_SECRET_ACCESS_KEY=b
check_refused 'no credentials fail before anything else happens' 'No S3 credentials' publish_setup nocreds
check_not_contains 'and before rclone is downloaded' "$RUN_LOG" 'Installed rclone'
check_not_contains 'and do not bring up OIDC in a job that does not use it' "$RUN_LOG" 'configure-aws-credentials'
check_refused 'a job that can request an OIDC token but assumed no role is told what to add' 'configure-aws-credentials' publish_setup oidc_no_role ACTIONS_ID_TOKEN_REQUEST_TOKEN=x ACTIONS_ID_TOKEN_REQUEST_URL=https://x.invalid
check_refused 'a key without a secret fails' 'Set both' publish_setup creds_id INPUT_S3_ACCESS_KEY_ID=a AWS_SECRET_ACCESS_KEY=fromenv
check_refused 'a secret without a key fails' 'Set both' publish_setup creds_secret INPUT_S3_SECRET_ACCESS_KEY=b AWS_ACCESS_KEY_ID=fromenv
check_refused 'a session token without a key fails' "'s3-session-token' only works" publish_setup creds_token INPUT_S3_SESSION_TOKEN=c AWS_ACCESS_KEY_ID=x AWS_SECRET_ACCESS_KEY=y
new_step_run creds_ok
check 'credentials from the environment are enough' publish_step AWS_ACCESS_KEY_ID=x AWS_SECRET_ACCESS_KEY=y
check 'so is a role to assume' publish_step AWS_WEB_IDENTITY_TOKEN_FILE=/x
check 'and a self-hosted runner can have an instance role' publish_step RUNNER_ENVIRONMENT=self-hosted
check_not 'which a GitHub-hosted runner can not' publish_step RUNNER_ENVIRONMENT=github-hosted
check 'publish accepts a job with a role from OIDC' publish_step ACTIONS_ID_TOKEN_REQUEST_TOKEN=x ACTIONS_ID_TOKEN_REQUEST_URL=https://x.invalid AWS_ACCESS_KEY_ID=x AWS_SECRET_ACCESS_KEY=y AWS_SESSION_TOKEN=z AWS_REGION=us-east-1
check 'and static keys in a job that also has the permission' publish_step ACTIONS_ID_TOKEN_REQUEST_TOKEN=x HAS_S3_ACCESS_KEY_ID=true HAS_S3_SECRET_ACCESS_KEY=true
check 'and an instance role on a self-hosted runner that also has it' publish_step ACTIONS_ID_TOKEN_REQUEST_TOKEN=x RUNNER_ENVIRONMENT=self-hosted
check 'signing does not mind the permission, because it runs no native code' run_step setup.sh INPUT_MODE=sign INPUT_ALL_EXTENSIONS=true INPUT_PATH="$SRC" HAS_SIGNING_KEY=true ACTIONS_ID_TOKEN_REQUEST_TOKEN=x

echo; echo '--- jobs stay apart'
check_refused 'verify does not take the signing key' "Don't pass 'signing-key'" run_action verify_key INPUT_MODE=verify INPUT_SIGNING_KEY="$KEY"
check_refused 'verify does not take S3 credentials' "Don't pass S3 credentials" run_action verify_creds INPUT_MODE=verify INPUT_S3_SECRET_ACCESS_KEY=b
for variable in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_ROLE_ARN AWS_WEB_IDENTITY_TOKEN_FILE AWS_PROFILE AWS_SHARED_CREDENTIALS_FILE; do
	check_refused "verify refuses $variable in the job" "$variable in its environment" run_action "verify_$variable" INPUT_MODE=verify "$variable=do-not-print"
	check_not_contains 'and does not print its value' "$RUN_LOG" 'do-not-print'
done
for variable in ACTIONS_ID_TOKEN_REQUEST_TOKEN ACTIONS_ID_TOKEN_REQUEST_URL; do
	check_refused "verify refuses a job that can request an OIDC token, seen through $variable" "'id-token: write'" run_action "verify_$variable" INPUT_MODE=verify "$variable=do-not-print"
	check_not_contains 'and does not print its value' "$RUN_LOG" 'do-not-print'
done
# One job has one RUNNER_TEMP.
SHARED_TEMP="$RUNS_DIR/shared-temp"
mkdir -p "$SHARED_TEMP"
sign_only shared_sign "$SRC" RUNNER_TEMP="$SHARED_TEMP"
SHARED_BUNDLE=$(bundle_dir)
check_refused 'verify refuses to run in the job that signed' 'ran in one job' run_action shared_verify INPUT_MODE=verify TEST_BUNDLE="$SHARED_BUNDLE" RUNNER_TEMP="$SHARED_TEMP"
SHARED_TEMP="$RUNS_DIR/shared-temp-2"
mkdir -p "$SHARED_TEMP"
# The stand-in curl says the CLI has no release, because only the mark that this mode ran matters here.
mkdir -p "$RUNS_DIR/no-cli-release"
printf '#!/bin/sh\nprintf 404\n' >"$RUNS_DIR/no-cli-release/curl"
chmod +x "$RUNS_DIR/no-cli-release/curl"
run_action shared_verify2 INPUT_MODE=verify TEST_BUNDLE="$SHARED_BUNDLE" RUNNER_TEMP="$SHARED_TEMP" PATH="$RUNS_DIR/no-cli-release:$PATH"
check_refused 'signing refuses to run in a job that ran verify' 'ran in one job' sign_only shared_sign2 "$SRC" RUNNER_TEMP="$SHARED_TEMP"
check_refused 'and so does publishing' 'ran in one job' publish_setup shared_publish RUNNER_TEMP="$SHARED_TEMP" INPUT_S3_ACCESS_KEY_ID=a INPUT_S3_SECRET_ACCESS_KEY=b

echo; echo '--- the signed tree between jobs'
sign_only bundle "$SRC"
BUNDLE=$(bundle_dir)
BUNDLE_DIGEST=$(output_value bundle-digest)
new_step_run bundle_ok
WORK="$RUNS_DIR/bundle-work"
mkdir -p "$WORK"
cp -R "$BUNDLE" "$WORK/bundle"
check 'check-bundle accepts the tree with its digest' run_step check-bundle.sh WORK_DIR="$WORK" INPUT_BUNDLE_DIGEST="$BUNDLE_DIGEST"
check_contains 'and reports the signed tree' "$RUN_OUTPUT" "signed-dir=$WORK/bundle/signed"
check_contains 'and the fingerprint' "$RUN_OUTPUT" 'fingerprint=sha256:'
printf 'x' >>"$WORK/bundle/signed/v2.0.0/linux_amd64/demo.duckdb_extension.gz"
new_step_run bundle_object
check_not 'a changed object is refused' run_step check-bundle.sh WORK_DIR="$WORK" INPUT_BUNDLE_DIGEST="$BUNDLE_DIGEST"
check_contains 'with an explanation' "$RUN_LOG" "doesn't match 'bundle-digest'"
rm -rf "$WORK/bundle"
cp -R "$BUNDLE" "$WORK/bundle"
printf '%s' 'extra' >"$WORK/bundle/keys/public_1.pem"
new_step_run bundle_key
check_not 'an added key is refused, because it would land in the key file' run_step check-bundle.sh WORK_DIR="$WORK" INPUT_BUNDLE_DIGEST="$BUNDLE_DIGEST"
rm -rf "$WORK/bundle"
cp -R "$BUNDLE" "$WORK/bundle"
printf '{}\n' >>"$WORK/bundle/manifest.jsonl"
new_step_run bundle_manifest
check_not 'a changed manifest is refused' run_step check-bundle.sh WORK_DIR="$WORK" INPUT_BUNDLE_DIGEST="$BUNDLE_DIGEST"
rm -rf "$WORK/bundle"
mkdir -p "$WORK/bundle"
new_step_run bundle_missing
check_not 'a missing tree is refused' run_step check-bundle.sh WORK_DIR="$WORK"
check_contains 'with a hint' "$RUN_LOG" "'signed-artifact'"
rm -rf "$WORK"

echo; echo '--- helpers'
check_equal 'an annotation stays on one line' 'a%0Ab' "$(lib_call 'error "$1" 2>&1 | sed "s/^::error:://"' "$(printf 'a\nb')")"
check_equal 'text in an annotation can not start a command' '1' "$(lib_call 'warn "$1" 2>&1 | wc -l | tr -d " "' "$(printf 'x\n::error::injected')")"
check_equal 'an annotation encodes percent signs first' '100%25%0D' "$(lib_call 'notice "$1" | sed "s/^::notice:://"' "$(printf '100%%\r')")"
OUT="$RUNS_DIR/output-test"
: >"$OUT"
lib_call 'GITHUB_OUTPUT="$1" set_output plain value; GITHUB_OUTPUT="$1" set_output repository-url "$2"' "$OUT" "$(printf 'https://x\nfingerprint=forged')"
check_contains 'set_output writes a plain value' "$OUT" 'plain=value'
check_contains 'a value with a line break uses the block form' "$OUT" 'repository-url<<EOF_'
check_equal 'so that it can not set another output' 1 "$(grep -c '^fingerprint=forged$' "$OUT" | tr -d ' ')"
check_equal 'a quote in SQL is doubled' "it''s" "$(lib_call 'sql_quote "$1"' "it's")"
check_equal 'every quote is doubled' "'' ''" "$(lib_call 'sql_quote "$1"' "' '")"
check_equal 'a prefix loses its slashes' 'some/prefix' "$(lib_call 'normalize_prefix "$1"' '//some/prefix//')"
check_equal 'in_list finds a word' yes "$(lib_call 'if in_list "$1" "$2"; then echo yes; else echo no; fi' v2.0.0 'v1.0.0, v2.0.0')"
check_equal 'in_list does not match part of a word' no "$(lib_call 'if in_list "$1" "$2"; then echo yes; else echo no; fi' v2.0 'v1.0.0, v2.0.0')"
check_equal 'in_list does not expand wildcards' no "$(cd "$RUNS_DIR/glob-cwd" && lib_call 'if in_list "$1" "$2"; then echo yes; else echo no; fi' osx_decoy 'osx_*')"
check_equal 'the CLI asset of a platform' duckdb-cli-linux-arm64 "$(lib_call 'cli_asset "$1"' linux_arm64)"
versions() { lib_call 'compare_versions "$1" "$2"' "$1" "$2"; }
check_equal 'an older version' lt "$(versions v1.2.3 v1.2.4)"
check_equal 'a newer version' gt "$(versions v2.0.0 v1.9.9)"
check_equal 'the same version' eq "$(versions v1.2.3 1.2.3)"
check_equal 'versions compare as numbers, not text' lt "$(versions v1.9.0 v1.10.0)"
check_equal 'a suffix does not make a version older' eq "$(versions v1.2.3-5-gabc v1.2.3)"
check_equal 'leading zeros are not octal' gt "$(versions v1.09.0 v1.8.0)"
check_equal 'a commit hash can not be compared' unknown "$(versions e249224 v1.2.3)"
check_equal 'in either position' unknown "$(versions v1.2.3 e249224)"
repository() { env -i PATH="$PATH" "$@" "${BASH:-bash}" -c 'source "$1"; repository_url' _ "$TESTS_ROOT/scripts/lib.sh"; }
check_equal 'repository-url wins, without its slash' https://x.example "$(repository INPUT_REPOSITORY_URL=https://x.example/ INPUT_S3_BUCKET=b)"
check_equal 'otherwise it is the bucket' s3://b "$(repository INPUT_S3_BUCKET=b)"
check_equal 'and its prefix' s3://b/p/q "$(repository INPUT_S3_BUCKET=b INPUT_S3_PREFIX=/p/q/)"
# Runs a command that outlives the timeout, in a command substitution like the smoke test does.
TIMEOUT_START=$(date +%s)
TIMEOUT_STATUS=0
TIMEOUT_OUTPUT=$(lib_call 'run_with_timeout 1 /dev/null sh -c "echo started; exec sleep 30"') || TIMEOUT_STATUS=$?
TIMEOUT_TOOK=$(($(date +%s) - TIMEOUT_START))
check_equal 'run_with_timeout stops a command' 143 "$TIMEOUT_STATUS"
check_equal 'and returns its output' started "$TIMEOUT_OUTPUT"
if [ "$TIMEOUT_TOOK" -lt 10 ]; then pass 'without waiting for it'; else fail 'without waiting for it' "took $TIMEOUT_TOOK seconds"; fi
printf 'from the file\n' >"$RUNS_DIR/stdin"
check_equal 'run_with_timeout passes the input file' 'from the file' "$(lib_call 'run_with_timeout 5 "$1" cat' "$RUNS_DIR/stdin")"
check_equal 'and the exit status' 3 "$(lib_call 'run_with_timeout 5 /dev/null sh -c "exit 3" || echo $?')"
check_equal 'the pool runs everything' 5 "$(lib_call 'for i in 1 2 3 4 5; do pool_start 2 sh -c "echo x" ; done; pool_wait' | wc -l | tr -d ' ')"
check_equal 'the pool notices a failure' 1 "$(lib_call 'pool_start 2 sh -c "exit 1"; pool_start 2 true; pool_start 2 true; pool_wait; echo $pool_failed')"
check_equal 'and is fine without one' 0 "$(lib_call 'pool_start 2 true; pool_wait; echo $pool_failed')"

echo; echo '--- credentials and region'
# Prints what rclone would see, after the mapping from inputs to the environment. Takes VAR=value pairs.
s3_settings() {
	env -i PATH="$PATH" "$@" bash -c 'source "$1"; export_s3_credentials; printf "%s|%s|%s" "${AWS_ACCESS_KEY_ID:-}" "${AWS_SESSION_TOKEN:-}" "$(s3_region)"' _ "$TESTS_ROOT/scripts/lib.sh"
}
R2=https://abc.r2.cloudflarestorage.com
check_equal 'an input key ignores a token left in the environment' 'r2key||auto' "$(s3_settings AWS_SESSION_TOKEN=stale INPUT_S3_ACCESS_KEY_ID=r2key INPUT_S3_ENDPOINT="$R2")"
check_equal 'an input token is used' 'r2key|mine|auto' "$(s3_settings AWS_SESSION_TOKEN=stale INPUT_S3_ACCESS_KEY_ID=r2key INPUT_S3_SESSION_TOKEN=mine INPUT_S3_ENDPOINT="$R2")"
check_equal 'keys and token from the environment stay together' 'envkey|envtoken|' "$(s3_settings AWS_ACCESS_KEY_ID=envkey AWS_SESSION_TOKEN=envtoken)"
check_equal 'R2 ignores a region left in the environment' 'r2key||auto' "$(s3_settings AWS_REGION=eu-central-1 INPUT_S3_ACCESS_KEY_ID=r2key INPUT_S3_ENDPOINT="$R2")"
check_equal 'an input region wins on R2' 'r2key||weur' "$(s3_settings AWS_REGION=eu-central-1 INPUT_S3_ACCESS_KEY_ID=r2key INPUT_S3_ENDPOINT="$R2" INPUT_S3_REGION=weur)"
check_equal 'other stores use the region in the environment' '||eu-central-1' "$(s3_settings AWS_REGION=eu-central-1 INPUT_S3_ENDPOINT=https://minio.example.com)"

echo; echo '--- smoke test, with a stand-in CLI and curl'
PLATFORM=$(bash -c 'source "$1"; runner_platform' _ "$TESTS_ROOT/scripts/lib.sh")
# Stands in for the DuckDB CLI: records what it was given, and then does what the given line says.
stand_in_cli() { # <work dir> <version> [shell code]
	mkdir -p "$1/cli/$2"
	cat >"$1/cli/$2/duckdb" <<EOF
#!/bin/sh
env >"$RUNS_DIR/cli.env"
cat >"$RUNS_DIR/cli.sql"
${3:-echo 'smoke-test-loaded:true'}
EOF
	chmod +x "$1/cli/$2/duckdb"
}
S="$RUNS_DIR/smoke"
make_extension "$S/src/demo.duckdb_extension" "$PLATFORM" v2.0.0 v1 CPP 2000
new_step_run smoke
run_step setup.sh INPUT_MODE=sign INPUT_ALL_EXTENSIONS=true INPUT_PATH="$S/src" HAS_SIGNING_KEY=true
WORK=$(output_value work-dir)
run_step sign.sh WORK_DIR="$WORK" SOURCE_DIR="$S/src" INPUT_SIGNING_KEY="$KEY" INPUT_ADDITIONAL_PUBLIC_KEYS="$(cat "$K/reserve.pub")"
stand_in_cli "$WORK" v2.0.0
smoke() { run_step smoke-test.sh WORK_DIR="$WORK" "$@"; }
if smoke OTHER_SECRET=theother HTTP_PROXY=http://proxy.example; then
	pass 'passes when the extension installs and loads'
else
	fail 'passes when the extension installs and loads' "$(tail -n 2 "$RUN_LOG")"
fi
check_contains 'says it installed and loaded' "$RUN_LOG" 'installed and loaded'
check_contains 'uses the signed tree as a local repository, so that nothing has to be uploaded first' "$RUNS_DIR/cli.sql" "WITH PREFIX '$WORK/bundle/signed'"
check_contains 'pins the signing key' "$RUNS_DIR/cli.sql" "$(sed -n 2p "$WORK/bundle/keys/public_0.pem")"
check_not_contains 'creates no secret' "$RUNS_DIR/cli.sql" 'CREATE SECRET'
check_not_contains 'the CLI does not see other variables of the job' "$RUNS_DIR/cli.env" 'theother'
check_not_contains 'the CLI does not learn the work directory' "$RUNS_DIR/cli.env" 'WORK_DIR'
check_contains 'the CLI gets the proxy' "$RUNS_DIR/cli.env" 'HTTP_PROXY=http://proxy.example'
check_contains 'the smoke test quotes the name' "$RUNS_DIR/cli.sql" 'INSTALL "demo" FROM smoke_repo'
smoke INPUT_SMOKE_TEST_SETUP_SQL='SET threads = 1 -- no semicolon'
check_contains 'setup SQL comes first' "$RUNS_DIR/cli.sql" 'SET threads = 1 -- no semicolon'
check_equal 'and is ended, whatever it ends with' ';' "$(sed -n 2p "$RUNS_DIR/cli.sql")"
smoke
check_equal 'no setup SQL means no extra statement' '' "$(sed -n 1p "$RUNS_DIR/cli.sql")"

: >"$RUN_LOG"
stand_in_cli "$WORK" v2.0.0 "echo 'first line of output'; echo 'Binder Error: the real reason' >&2; exit 1"
if smoke; then fail 'fails when the CLI fails'; else pass 'fails when the CLI fails'; fi
check_contains 'says that nothing has been uploaded' "$RUN_LOG" 'Nothing has been uploaded'
check_contains 'and the annotation holds the whole error, not only its first line' "$RUN_LOG" 'first line of output%0ABinder Error: the real reason'
: >"$RUN_LOG"
stand_in_cli "$WORK" v2.0.0 "echo 'smoke-test-loaded:false'"
if smoke; then fail 'fails when the extension is not listed as loaded'; else pass 'fails when the extension is not listed as loaded'; fi
check_contains 'and says so' "$RUN_LOG" "isn't listed as loaded"
: >"$RUN_LOG"
stand_in_cli "$WORK" v2.0.0 "exec sleep 30"
TIMEOUT_START=$(date +%s)
if smoke SMOKE_TEST_TIMEOUT=1; then fail 'stops a CLI that hangs'; else pass 'stops a CLI that hangs'; fi
if [ "$(($(date +%s) - TIMEOUT_START))" -lt 15 ]; then pass 'without waiting for it'; else fail 'without waiting for it'; fi
check_contains 'and says it timed out' "$RUN_LOG" 'timed out after 1 seconds'

new_step_run smoke_versioned
run_step setup.sh INPUT_MODE=sign INPUT_ALL_EXTENSIONS=true INPUT_PATH="$S/src" HAS_SIGNING_KEY=true
VERSIONED_WORK=$(output_value work-dir)
run_step sign.sh WORK_DIR="$VERSIONED_WORK" SOURCE_DIR="$S/src" INPUT_SIGNING_KEY="$KEY" INPUT_UPLOAD_LATEST=false
stand_in_cli "$VERSIONED_WORK" v2.0.0
run_step smoke-test.sh WORK_DIR="$VERSIONED_WORK"
check_contains 'a versioned-only build is installed by version' "$RUNS_DIR/cli.sql" "INSTALL \"demo\" FROM smoke_repo VERSION 'v1'"

new_step_run smoke_other_platform
make_extension "$S/other-platform/demo.duckdb_extension" freebsd_amd64 v2.0.0 v1 CPP 2000
run_step setup.sh INPUT_MODE=sign INPUT_ALL_EXTENSIONS=true INPUT_PATH="$S/other-platform" HAS_SIGNING_KEY=true
OTHER_WORK=$(output_value work-dir)
run_step sign.sh WORK_DIR="$OTHER_WORK" SOURCE_DIR="$S/other-platform" INPUT_SIGNING_KEY="$KEY"
if run_step smoke-test.sh WORK_DIR="$OTHER_WORK"; then pass 'a runner without a build to test passes'; else fail 'a runner without a build to test passes'; fi
check_contains 'and says it skipped' "$RUN_LOG" 'Smoke test skipped'

rm -rf "$WORK/cli"
mkdir -p "$S/no-network" "$S/no-release"
printf '#!/bin/sh\necho "curl: (7) Failed to connect" >&2\nprintf 000\nexit 7\n' >"$S/no-network/curl"
printf '#!/bin/sh\nprintf 404\n' >"$S/no-release/curl"
chmod +x "$S/no-network/curl" "$S/no-release/curl"
new_step_run smoke_network
if smoke PATH="$S/no-network:$PATH"; then
	fail 'a failed CLI download fails the smoke test'
else
	pass 'a failed CLI download fails the smoke test'
fi
check_contains 'and says that nothing has been uploaded' "$RUN_LOG" 'Nothing has been uploaded'
new_step_run smoke_norelease
if smoke PATH="$S/no-release:$PATH"; then
	pass 'a version without a CLI release does not fail the smoke test'
else
	fail 'a version without a CLI release does not fail the smoke test' "$(tail -n 2 "$RUN_LOG")"
fi
check_contains 'but warns that nothing was tested' "$RUN_LOG" "didn't test anything"

echo; echo '--- uploading, with a stand-in rclone'
# Keeps a bucket in a directory, and logs each call. Behaves like the real one where it matters: a missing object isn't an
# error when reading it, and `copy --immutable` refuses to change an object.
install_stand_in_rclone() { # <work dir>
	mkdir -p "$1/bin"
	cat >"$1/bin/rclone" <<'EOF'
#!/bin/sh
command=$1 source=$2 destination=$3
shift 3
printf '%s %s %s %s\n' "$command" "$source" "$destination" "$*" >>"$FAKE_RCLONE_LOG"
local_path() { printf '%s/%s' "$FAKE_BUCKET" "${1#:s3:}"; }
case "$command" in
copyto)
	case "$source" in
	:s3:*)
		if [ -n "${FAKE_RCLONE_READ_ERROR:-}" ]; then
			echo 'AccessDenied' >&2
			exit 1
		fi
		if [ -f "$(local_path "$source")" ]; then cp "$(local_path "$source")" "$destination"; fi
		exit 0
		;;
	esac
	case "$destination" in
	*"${FAKE_RCLONE_FAIL:-no such object}"*)
		echo 'upload failed' >&2
		exit 1
		;;
	esac
	mkdir -p "$(dirname "$(local_path "$destination")")"
	cp "$source" "$(local_path "$destination")"
	;;
copy)
	file=
	immutable=
	while [ $# -gt 0 ]; do
		case "$1" in
		--include)
			file=${2#/}
			shift
			;;
		--immutable) immutable=1 ;;
		esac
		shift
	done
	target="$(local_path "$destination")/$file"
	case "$target" in
	*"${FAKE_RCLONE_FAIL:-no such object}"*)
		echo 'upload failed' >&2
		exit 1
		;;
	esac
	if [ -n "$immutable" ] && [ -f "$target" ] && ! cmp -s "$source/$file" "$target"; then
		echo 'immutable file modified' >&2
		exit 6
	fi
	mkdir -p "$(dirname "$target")"
	cp "$source/$file" "$target"
	;;
esac
EOF
	chmod +x "$1/bin/rclone"
}
# A work directory holding a signed tree, as after the download in a publish job.
signed_work() { # <run name> <source dir> <key pem> [VAR=value...]
	local name=$1 source_dir=$2 key=$3
	shift 3
	new_step_run "$name"
	run_step setup.sh INPUT_MODE=sign INPUT_ALL_EXTENSIONS=true INPUT_PATH="$source_dir" HAS_SIGNING_KEY=true
	WORK=$(output_value work-dir)
	run_step sign.sh WORK_DIR="$WORK" SOURCE_DIR="$source_dir" INPUT_SIGNING_KEY="$(cat "$key")" "$@"
	install_stand_in_rclone "$WORK"
	mkdir -p "$WORK/tmp"
}
upload() { run_step upload.sh WORK_DIR="$WORK" INPUT_S3_BUCKET=bucket FAKE_BUCKET="$BUCKET" FAKE_RCLONE_LOG="$RCLONE_LOG" "$@"; }
check_repository() { run_step check-repository.sh WORK_DIR="$WORK" INPUT_S3_BUCKET=bucket FAKE_BUCKET="$BUCKET" FAKE_RCLONE_LOG="$RCLONE_LOG" "$@"; }
new_bucket() {
	BUCKET="$RUNS_DIR/bucket-$1"
	RCLONE_LOG="$RUNS_DIR/rclone-$1.log"
	rm -rf "$BUCKET"
	mkdir -p "$BUCKET/bucket"
	: >"$RCLONE_LOG"
}
# The line of the first upload to a path.
upload_line() { grep -n -- " :s3:bucket/$1" "$RCLONE_LOG" | grep -v '^[0-9]*:copyto :s3:' | sed -n 1p | cut -d: -f1; }

U="$RUNS_DIR/upload"
make_extension "$U/v1/a/demo.duckdb_extension" linux_amd64 v2.0.0 v1.0.0 CPP 3000
make_extension "$U/v1/b/demo.duckdb_extension" osx_arm64 v2.0.0 v1.0.0 CPP 3000
make_extension "$U/v2/a/demo.duckdb_extension" linux_amd64 v2.0.0 v2.0.0 CPP 3000
make_extension "$U/v2/b/demo.duckdb_extension" osx_arm64 v2.0.0 v2.0.0 CPP 3000
new_bucket order
signed_work upload_order "$U/v1" "$K/key.pem"
if upload; then pass 'uploads a release'; else fail 'uploads a release' "$(tail -n 2 "$RUN_LOG")"; fi
check 'the latest object arrives' test -f "$BUCKET/bucket/v2.0.0/linux_amd64/demo.duckdb_extension.gz"
check 'the versioned object arrives' test -f "$BUCKET/bucket/demo/v1.0.0/v2.0.0/osx_arm64/demo.duckdb_extension.gz"
check 'the key file arrives' test -f "$BUCKET/bucket/.well-known/duckdb-extension-repo.json"
VERSIONED_LINE=$(upload_line demo/v1.0.0)
KEY_FILE_LINE=$(upload_line .well-known/duckdb-extension-repo.json)
LATEST_LINE=$(upload_line v2.0.0/)
if [ -n "$VERSIONED_LINE" ] && [ "$VERSIONED_LINE" -lt "$KEY_FILE_LINE" ]; then pass 'versioned objects go before the key file'; else fail 'versioned objects go before the key file' "lines $VERSIONED_LINE and $KEY_FILE_LINE"; fi
if [ -n "$KEY_FILE_LINE" ] && [ "$KEY_FILE_LINE" -lt "$LATEST_LINE" ]; then pass 'the key file goes before the latest objects'; else fail 'the key file goes before the latest objects' "lines $KEY_FILE_LINE and $LATEST_LINE"; fi
check_contains 'latest objects are revalidated by caches' "$RCLONE_LOG" 'v2.0.0/linux_amd64/demo.duckdb_extension.gz --checksum --header-upload Cache-Control: no-cache'
check_contains 'versioned objects can be cached' "$RCLONE_LOG" 'Cache-Control: public, max-age=86400'
check_contains 'versioned objects are immutable' "$RCLONE_LOG" '--immutable'
check_contains 'the key file is revalidated too' "$RCLONE_LOG" 'duckdb-extension-repo.json --checksum --header-upload Cache-Control: no-cache'
check_equal 'it records all five objects' 5 "$(wc -l <"$WORK/uploaded" | tr -d ' ')"
check_contains 'says it finished' "$RUN_LOG" 'Upload complete'

check_refused_upload() { # <description> <text> <VAR=value...>
	local description=$1 text=$2
	shift 2
	: >"$RUN_LOG"
	check_refused "$description" "$text" upload "$@"
}

echo; echo '--- the signing key against the bucket'
new_bucket key
signed_work key_first "$U/v1" "$K/key.pem"
upload
BEFORE=$(sha256_file "$BUCKET/bucket/.well-known/duckdb-extension-repo.json")
signed_work key_other "$U/v2" "$K/reserve.pem"
: >"$RCLONE_LOG"
check_refused_upload 'a signing key the bucket does not list is refused' "isn't in the bucket's key file"
check_contains 'and names the option for a rotation' "$RUN_LOG" "allow-key-change"
check_contains 'and the fingerprint' "$RUN_LOG" 'sha256:'
check_equal 'nothing was uploaded' 0 "$(grep -vc '^copyto :s3:' "$RCLONE_LOG")"
check_equal 'and the key file is unchanged' "$BEFORE" "$(sha256_file "$BUCKET/bucket/.well-known/duckdb-extension-repo.json")"
: >"$RUN_LOG"
if upload INPUT_ALLOW_KEY_CHANGE=true; then pass 'allow-key-change lets a rotation through'; else fail 'allow-key-change lets a rotation through' "$(tail -n 2 "$RUN_LOG")"; fi
check_contains 'with a warning' "$RUN_LOG" 'Clients have to pin it'
check_contains 'and another that it drops the old key' "$RUN_LOG" 'drops 1 key(s)'
new_bucket key_reserve
signed_work key_reserve_first "$U/v1" "$K/key.pem" INPUT_ADDITIONAL_PUBLIC_KEYS="$(cat "$K/reserve.pub")"
upload
signed_work key_reserve_second "$U/v2" "$K/reserve.pem" INPUT_ADDITIONAL_PUBLIC_KEYS="$(cat "$K/key.pub")"
: >"$RUN_LOG"
if upload; then pass 'a reserve key from the key file needs no flag'; else fail 'a reserve key from the key file needs no flag' "$(tail -n 2 "$RUN_LOG")"; fi
check_not_contains 'nor a warning' "$RUN_LOG" '::warning'
new_bucket key_compact
mkdir -p "$BUCKET/bucket/.well-known"
jq -n --arg key "$(sed '/-----/d' "$K/key.pub" | tr -d '\n')" '{signature_keys: [$key]}' >"$BUCKET/bucket/.well-known/duckdb-extension-repo.json"
signed_work key_compact "$U/v1" "$K/key.pem"
: >"$RUN_LOG"
if upload; then pass 'a key file with compact keys counts too, which DuckDB also accepts'; else fail 'a key file with compact keys counts too, which DuckDB also accepts' "$(tail -n 2 "$RUN_LOG")"; fi
new_bucket key_broken
mkdir -p "$BUCKET/bucket/.well-known"
printf 'not json' >"$BUCKET/bucket/.well-known/duckdb-extension-repo.json"
signed_work key_broken "$U/v1" "$K/key.pem"
check_refused_upload 'a broken key file in the bucket is refused' "isn't valid"
: >"$RUN_LOG"
if upload INPUT_ALLOW_KEY_CHANGE=true; then pass 'but allow-key-change can replace it'; else fail 'but allow-key-change can replace it' "$(tail -n 2 "$RUN_LOG")"; fi
new_bucket key_error
signed_work key_error "$U/v1" "$K/key.pem"
check_refused_upload 'a key file that can not be read stops the upload' "Couldn't read" FAKE_RCLONE_READ_ERROR=1
check_equal 'before anything was uploaded' 0 "$(find "$BUCKET/bucket" -type f | wc -l | tr -d ' ')"
new_bucket key_nofile
signed_work key_nofile_first "$U/v1" "$K/key.pem" INPUT_PUBLISH_KEY_FILE=false
upload
check_not 'publish-key-file false uploads no key file' test -e "$BUCKET/bucket/.well-known/duckdb-extension-repo.json"

echo; echo '--- the version against the bucket'
new_bucket downgrade
signed_work down_new "$U/v2" "$K/key.pem"
upload
LIVE=$(sha256_file "$BUCKET/bucket/v2.0.0/linux_amd64/demo.duckdb_extension.gz")
signed_work down_old "$U/v1" "$K/key.pem"
check_refused_upload 'an older version on the latest path is refused' 'is older than v2.0.0'
check_contains 'and names the option' "$RUN_LOG" 'allow-downgrade'
check_equal 'latest is unchanged' "$LIVE" "$(sha256_file "$BUCKET/bucket/v2.0.0/linux_amd64/demo.duckdb_extension.gz")"
check_not 'and nothing else was uploaded' test -e "$BUCKET/bucket/demo/v1.0.0"
: >"$RUN_LOG"
if upload INPUT_ALLOW_DOWNGRADE=true; then pass 'allow-downgrade lets it through'; else fail 'allow-downgrade lets it through' "$(tail -n 2 "$RUN_LOG")"; fi
check_not 'and moves latest back' test "$LIVE" = "$(sha256_file "$BUCKET/bucket/v2.0.0/linux_amd64/demo.duckdb_extension.gz")"
new_bucket upgrade
signed_work up_old "$U/v1" "$K/key.pem"
upload
signed_work up_new "$U/v2" "$K/key.pem"
: >"$RUN_LOG"
if upload; then pass 'a newer version goes through'; else fail 'a newer version goes through' "$(tail -n 2 "$RUN_LOG")"; fi
new_bucket hash_version
make_extension "$U/hash1/demo.duckdb_extension" linux_amd64 v2.0.0 e249224 CPP 3000
make_extension "$U/hash2/demo.duckdb_extension" linux_amd64 v2.0.0 abcdef0 CPP 3000
signed_work hash_one "$U/hash1" "$K/key.pem"
upload
signed_work hash_two "$U/hash2" "$K/key.pem"
: >"$RUN_LOG"
if upload; then pass 'commit versions can not be compared, so they go through'; else fail 'commit versions can not be compared, so they go through' "$(tail -n 2 "$RUN_LOG")"; fi
check_contains 'with a notice' "$RUN_LOG" "can't tell whether"
new_bucket not_gzip
mkdir -p "$BUCKET/bucket/v2.0.0/linux_amd64"
printf 'not gzip' >"$BUCKET/bucket/v2.0.0/linux_amd64/demo.duckdb_extension.gz"
signed_work not_gzip "$U/v1" "$K/key.pem"
: >"$RUN_LOG"
if upload; then pass 'a live object that can not be read does not block the release'; else fail 'a live object that can not be read does not block the release' "$(tail -n 2 "$RUN_LOG")"; fi
check_contains 'but is reported' "$RUN_LOG" "isn't valid gzip"

echo; echo '--- a failed upload'
new_bucket partial
signed_work partial_ok "$U/v1" "$K/key.pem"
if upload FAKE_RCLONE_FAIL=:s3:bucket/v2.0.0/linux_amd64; then fail 'a failed latest upload fails the step'; else pass 'a failed latest upload fails the step'; fi
check_contains 'and names the object' "$RUN_LOG" 'Uploading v2.0.0/linux_amd64/demo.duckdb_extension.gz failed'
check_contains 'what was uploaded is recorded' "$WORK/uploaded" 'demo/v1.0.0/v2.0.0/linux_amd64/demo.duckdb_extension.gz'
check_not 'what failed is not' grep -qx 'v2.0.0/linux_amd64/demo.duckdb_extension.gz' "$WORK/uploaded"
run_step summary.sh WORK_DIR="$WORK" INPUT_S3_BUCKET=bucket INPUT_MODE=publish UPLOAD_OUTCOME=failure
check_contains 'the summary says the upload failed' "$RUN_SUMMARY" 'The upload failed'
check_contains 'and lists what is live' "$RUN_SUMMARY" '`demo/v1.0.0/v2.0.0/linux_amd64/demo.duckdb_extension.gz`'
check_not_contains 'and shows no SQL for a release that is incomplete' "$RUN_SUMMARY" 'CREATE EXTENSION REPOSITORY'
check_contains 'the output has what is live' "$RUN_OUTPUT" 'uploaded-objects<<EOF_'
check_contains 'and all files' "$RUN_OUTPUT" 'files<<EOF_'
new_bucket partial_versioned
signed_work partial_versioned "$U/v1" "$K/key.pem"
: >"$RUN_LOG"
if upload FAKE_RCLONE_FAIL=demo/v1.0.0/v2.0.0/linux_amd64; then fail 'a failed versioned upload fails the step'; else pass 'a failed versioned upload fails the step'; fi
check_not 'and leaves the key file alone' test -e "$BUCKET/bucket/.well-known/duckdb-extension-repo.json"
check_not 'and latest' test -e "$BUCKET/bucket/v2.0.0"
new_bucket immutable
signed_work immutable_one "$U/v1" "$K/key.pem"
upload
make_extension "$U/rebuilt/a/demo.duckdb_extension" linux_amd64 v2.0.0 v1.0.0 CPP 3000
signed_work immutable_two "$U/rebuilt" "$K/key.pem"
check_refused_upload 'different bytes for a published version are refused' 'overwrite-versioned'
: >"$RUN_LOG"
if upload INPUT_OVERWRITE_VERSIONED=true; then pass 'overwrite-versioned allows it'; else fail 'overwrite-versioned allows it' "$(tail -n 2 "$RUN_LOG")"; fi

echo; echo '--- checking what the repository serves, with a stand-in rclone'
new_bucket check
signed_work check_ok "$U/v1" "$K/key.pem"
upload
: >"$RUN_LOG"
if check_repository; then pass 'passes when every object matches'; else fail 'passes when every object matches' "$(tail -n 2 "$RUN_LOG")"; fi
check_contains 'and checks another platform than the runner' "$RUN_LOG" 'v2.0.0/osx_arm64/demo.duckdb_extension.gz'
check_contains 'and the key file' "$RUN_LOG" '.well-known/duckdb-extension-repo.json'
check_contains 'and says so' "$RUN_LOG" 'serves what was uploaded'
cp "$BUCKET/bucket/v2.0.0/osx_arm64/demo.duckdb_extension.gz" "$RUNS_DIR/saved.gz"
printf 'stale' >"$BUCKET/bucket/v2.0.0/osx_arm64/demo.duckdb_extension.gz"
: >"$RUN_LOG"
check_refused 'a stale object on another platform fails' 'different build' check_repository
check_contains 'and names it' "$RUN_LOG" 'v2.0.0/osx_arm64/demo.duckdb_extension.gz'
rm "$BUCKET/bucket/v2.0.0/osx_arm64/demo.duckdb_extension.gz"
: >"$RUN_LOG"
check_refused 'a missing object fails' "doesn't exist" check_repository
cp "$RUNS_DIR/saved.gz" "$BUCKET/bucket/v2.0.0/osx_arm64/demo.duckdb_extension.gz"
printf '{"signature_keys":[]}' >"$BUCKET/bucket/.well-known/duckdb-extension-repo.json"
: >"$RUN_LOG"
check_refused 'a stale key file fails' 'different key file' check_repository
new_bucket check_prefix
mkdir -p "$BUCKET/bucket"
: >"$RUN_LOG"
check_refused 'a repository-url pointing elsewhere fails' "doesn't exist" check_repository INPUT_REPOSITORY_URL=s3://bucket/elsewhere

echo; echo '--- summary'
new_step_run summary
run_step setup.sh INPUT_MODE=sign INPUT_ALL_EXTENSIONS=true INPUT_PATH="$S/src" HAS_SIGNING_KEY=true
WORK=$(output_value work-dir)
run_step sign.sh WORK_DIR="$WORK" SOURCE_DIR="$S/src" INPUT_SIGNING_KEY="$KEY" INPUT_ADDITIONAL_PUBLIC_KEYS="$(cat "$K/reserve.pub")"
summary() { run_step summary.sh WORK_DIR="$WORK" INPUT_S3_BUCKET=bucket INPUT_MODE=publish INPUT_REPOSITORY_URL=https://example.invalid "$@"; }
: >"$RUN_SUMMARY"
summary
check_contains 'the SQL pins every key' "$RUN_SUMMARY" 'USING PUBLIC KEYS'
RESERVE_LINE=$(sed -n 2p "$K/reserve.pub")
check_contains 'including the reserve key' "$RUN_SUMMARY" "$RESERVE_LINE"
check_contains 'the SQL in the summary quotes the name' "$RUN_SUMMARY" 'INSTALL "demo" FROM my_repo'
check_not_contains 'a passed check is not mentioned' "$RUN_SUMMARY" 'check failed'
: >"$RUN_SUMMARY"
summary CHECK_OUTCOME=failure
check_contains 'a failed repository check is called out' "$RUN_SUMMARY" 'repository check failed'
rm -f "$WORK/bundle/keys/public_1.pem"
: >"$RUN_SUMMARY"
summary
check_contains 'one key uses the singular form' "$RUN_SUMMARY" 'USING PUBLIC KEY '
: >"$RUN_SUMMARY"
summary INPUT_REPOSITORY_URL="https://it's.invalid"
check_contains 'a quote in the prefix stays valid SQL' "$RUN_SUMMARY" "https://it''s.invalid"
: >"$RUN_SUMMARY"
summary INPUT_REPOSITORY_URL=
check_contains 'without a public prefix, the SQL uses the bucket' "$RUN_SUMMARY" "WITH PREFIX 's3://bucket'"
check_contains 'and mentions the secret it needs' "$RUN_SUMMARY" 'CREATE SECRET'
: >"$RUN_SUMMARY"
run_step summary.sh WORK_DIR="$WORK" INPUT_MODE=sign
check_contains 'mode sign lists what was signed' "$RUN_SUMMARY" '## Signed DuckDB extensions'
check_not_contains 'but has no SQL, because nothing is live' "$RUN_SUMMARY" 'CREATE EXTENSION REPOSITORY'
: >"$RUN_SUMMARY"
printf 'demo\tv2.0.0\tlinux_amd64\n' >"$WORK/verified"
run_step summary.sh WORK_DIR="$WORK" INPUT_MODE=verify SMOKE_TEST_OUTCOME=success
check_contains 'mode verify lists what was tested' "$RUN_SUMMARY" '| demo | v2.0.0 | linux_amd64 |'
: >"$RUN_SUMMARY"
run_step summary.sh WORK_DIR="$WORK" INPUT_MODE=verify SMOKE_TEST_OUTCOME=failure
check_contains 'and calls out a failure' "$RUN_SUMMARY" 'The smoke test failed'
new_step_run summary_empty
mkdir -p "$RUNS_DIR/empty-work/bundle"
check 'without a signed tree, there is nothing to report and no failure' run_step summary.sh WORK_DIR="$RUNS_DIR/empty-work" INPUT_MODE=sign
sign_only summary_many "$MANY"
MANY_WORK=$(output_value work-dir)
new_step_run summary_many_step
run_step summary.sh WORK_DIR="$MANY_WORK" INPUT_S3_BUCKET=bucket INPUT_MODE=publish
check_contains 'the SQL covers the first extension' "$RUN_SUMMARY" 'INSTALL "alpha" FROM my_repo'
check_contains 'and the others' "$RUN_SUMMARY" 'LOAD "beta" FROM my_repo'

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
	if [ "$script" = "scripts/sign.sh" ]; then used="$used $(grep -oE 'INPUT_[A-Z0-9_]+' "$TESTS_ROOT/scripts/load-key.sh" | sort -u)"; fi
	if grep -q 'export_s3_credentials' "$TESTS_ROOT/$script"; then used="$used INPUT_S3_ACCESS_KEY_ID INPUT_S3_SECRET_ACCESS_KEY INPUT_S3_SESSION_TOKEN"; fi
	if grep -q 'rclone_s3\|read_s3_object\|s3_region\|s3_provider' "$TESTS_ROOT/$script"; then used="$used INPUT_S3_REGION INPUT_S3_PROVIDER INPUT_S3_ENDPOINT"; fi
	if grep -q 's3_destination\|repository_url' "$TESTS_ROOT/$script"; then used="$used INPUT_S3_BUCKET INPUT_S3_PREFIX"; fi
	if grep -q 'repository_url' "$TESTS_ROOT/$script"; then used="$used INPUT_REPOSITORY_URL"; fi
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
	artifact-pattern | signed-artifact) grep -q "inputs.$input" "$TESTS_ROOT/action.yml" || unused="$unused $input" ;;
	*) grep -q "INPUT_$upper:" "$TESTS_ROOT/action.yml" || unused="$unused $input" ;;
	esac
done <"$RUNS_DIR/declared"
check_equal 'every declared input is used' '' "$unused"
check_equal 'action.yml pins third-party actions by commit' 0 "$(grep -E '^\s+uses: ' "$TESTS_ROOT/action.yml" | grep -cvE '@[0-9a-f]{40}( |$)')"
ACTION_SCRIPTS=$(grep -oE 'scripts/[a-z-]+\.sh' "$TESTS_ROOT/action.yml" | sed 's#scripts/##' | tr '\n' ' ')
RUNNER_SCRIPTS=$(grep -oE '[a-z-]+\.sh' "$TESTS_ROOT/tests/run-action.sh" | grep -vE '^(unit|run-action)\.sh$' | tr '\n' ' ')
check_equal 'tests/run-action.sh runs the same scripts in the same order as action.yml' "$ACTION_SCRIPTS" "$RUNNER_SCRIPTS"
# The condition of the step that runs a script, on its own line in action.yml.
step_condition() { # <script>
	awk -v script="scripts/$1" '
		/^    - name:/ { condition = "" }
		/^      if:/ { condition = $0; sub(/^      if: */, "", condition) }
		index($0, script) { print condition; exit }
	' "$TESTS_ROOT/action.yml"
}
check_equal 'setup always runs' '' "$(step_condition setup.sh)"
check_equal 'signing only runs in mode sign' "inputs.mode == 'sign'" "$(step_condition sign.sh)"
check_equal 'the signed tree is checked in the later jobs' "inputs.mode != 'sign'" "$(step_condition check-bundle.sh)"
check_equal 'the smoke test only runs in mode verify' "inputs.mode == 'verify'" "$(step_condition smoke-test.sh)"
check_equal 'rclone is only installed in mode publish' "inputs.mode == 'publish'" "$(step_condition install-rclone.sh)"
check_equal 'uploading only runs in mode publish' "inputs.mode == 'publish'" "$(step_condition upload.sh)"
check_equal 'the repository check runs unless turned off, also with an empty input' "inputs.mode == 'publish' && inputs.check-repository != 'false'" "$(step_condition check-repository.sh)"
check_equal 'the summary also runs after a failure' "\${{ !cancelled() && steps.setup.outcome == 'success' }}" "$(step_condition summary.sh)"
check_equal 'cleanup always runs, also after a failure' 'always()' "$(step_condition cleanup.sh)"
# The key material must only pass through the step that signs.
check_equal 'one step gets the signing key' 1 "$(grep -c 'inputs.signing-key }}' "$TESTS_ROOT/action.yml" | tr -d ' ')"
check_contains 'and it is the one that signs' "$RUNS_DIR/wiring" 'scripts/sign.sh'
check_equal 'that step comes after the artifact download' \
	"$(awk '/Download build artifacts/ { print "download" } /INPUT_SIGNING_KEY:/ { print "key" }' "$TESTS_ROOT/action.yml" | tr '\n' ' ')" 'download key '
check_equal 'the step that runs native code has no credentials' '' "$(sed -n 's/^scripts\/smoke-test.sh //p' "$RUNS_DIR/wiring" | tr ' ' '\n' | grep -E 'S3_|SIGNING' | tr '\n' ' ')"
check_contains 'the signed tree keeps its hidden directory' "$TESTS_ROOT/action.yml" 'include-hidden-files: true'

echo
echo '--- repository'
check_not 'no script turns on command tracing' grep -nE '^\s*set -[a-z]*x|set -o xtrace' "$TESTS_ROOT"/scripts/*.sh
check_equal 'no script in the action runs the extension outside the smoke test' 'scripts/smoke-test.sh' "$(grep -lE 'duckdb_cli' "$TESTS_ROOT"/scripts/*.sh | sed "s#$TESTS_ROOT/##")"
check_contains 'the signing key can not be committed by accident' "$TESTS_ROOT/.gitignore" '*.pem'
check_contains 'the wasm test dependencies are locked' "$TESTS_ROOT/tests/wasm/run.sh" 'npm ci'
check 'and the lockfile exists' test -f "$TESTS_ROOT/tests/wasm/package-lock.json"
check_not_contains 'and is not ignored' "$TESTS_ROOT/tests/wasm/.gitignore" 'package-lock.json'
OIDC_EXAMPLE="$TESTS_ROOT/examples/release-aws-oidc.yml"
# Which part of a workflow grants the permission: the name of a job, or "workflow" for all of them.
id_token_grants() { # <workflow>
	awk '
		/^jobs:/ { in_jobs = 1; next }
		in_jobs && /^  [a-z_-]+:$/ { job = $1; sub(":", "", job) }
		/^ *id-token: write/ { print (in_jobs ? job : "workflow") }
	' "$1" | tr '\n' ' '
}
check_equal 'the OIDC example only grants id-token to the publish job' 'publish ' "$(id_token_grants "$OIDC_EXAMPLE")"
check_contains 'and takes every permission from the verify job' "$OIDC_EXAMPLE" 'permissions: {}'
check_not_contains 'and has no storage keys' "$OIDC_EXAMPLE" 's3-access-key-id'
check_not_contains 'and no endpoint' "$OIDC_EXAMPLE" 's3-endpoint'
check_equal 'the role check only grants id-token to the publish job' 'publish ' "$(id_token_grants "$TESTS_ROOT/.github/workflows/aws-oidc-check.yml")"
AWS_ACTION_PIN=$(grep -oE 'aws-actions/configure-aws-credentials@[0-9a-f]{40}' "$OIDC_EXAMPLE" | sort -u)
check 'the OIDC example pins the AWS action by commit' test -n "$AWS_ACTION_PIN"
check_equal 'and the README pins the same commit' "$AWS_ACTION_PIN" "$(grep -oE 'aws-actions/configure-aws-credentials@[0-9a-f]{40}' "$TESTS_ROOT/README.md" | sort -u)"
for example in "$TESTS_ROOT/examples/release.yml" "$OIDC_EXAMPLE" "$TESTS_ROOT/README.md"; do
	name=$(basename "$example")
	check_contains "$name sets a concurrency group for publishing" "$example" 'cancel-in-progress: false'
	check_contains "$name sets a timeout" "$example" 'timeout-minutes:'
	check_contains "$name passes the digest to the publish job" "$example" 'bundle-digest: ${{ needs.sign.outputs.bundle-digest }}'
	check_contains "$name lists the reserve key" "$example" 'additional-public-keys:'
	check_not_contains "$name does not point at a tag" "$example" 'self-hosting@v1'
done
finish
