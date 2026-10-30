#!/usr/bin/env bash
# Publishes real extensions to a local S3-compatible store and installs them with the real DuckDB CLI. Needs Docker and
# network access.

# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

export RUNS_DIR
RUNS_DIR=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/duckdb-publisher-e2e.XXXXXX")" && pwd -P)
trap 'bash "$TESTS_ROOT/tests/stop-s3.sh"; rm -rf "$RUNS_DIR"' EXIT
export TEST_HOME="$RUNS_DIR/runner-home"
mkdir -p "$TEST_HOME" "$RUNS_DIR/keys" "$RUNS_DIR/native" "$RUNS_DIR/stable" "$RUNS_DIR/wasm"

SETTINGS=$(bash "$TESTS_ROOT/tests/start-s3.sh" "$RUNS_DIR/s3") || exit 1
for line in $SETTINGS; do
	eval "$line"
done
CA="$RCLONE_CA_CERT"
SETUP_SQL="INSTALL httpfs; LOAD httpfs; SET GLOBAL ca_cert_file = '$CA';"

for key in one two; do
	openssl genrsa -out "$RUNS_DIR/keys/$key.pem" 2048 2>/dev/null
	openssl rsa -in "$RUNS_DIR/keys/$key.pem" -pubout -out "$RUNS_DIR/keys/$key.pub" 2>/dev/null
done
KEY_ONE=$(cat "$RUNS_DIR/keys/one.pem")
KEY_TWO=$(cat "$RUNS_DIR/keys/two.pem")
PUB_ONE=$(cat "$RUNS_DIR/keys/one.pub")

source "$TESTS_ROOT/scripts/lib.sh"
set +e
PLATFORM=$(runner_platform)
VERSION=v2.0.0
curl -fsS --compressed -o "$RUNS_DIR/native/rusty_quack.duckdb_extension" "https://community-extensions.duckdb.org/$VERSION/$PLATFORM/rusty_quack.duckdb_extension.gz" &&
	gunzip -c "$RUNS_DIR/native/rusty_quack.duckdb_extension" >"$RUNS_DIR/native/x" 2>/dev/null &&
	mv "$RUNS_DIR/native/x" "$RUNS_DIR/native/rusty_quack.duckdb_extension"
rm -f "$RUNS_DIR/native/x"
curl -fsS --compressed -o "$RUNS_DIR/stable/capi_quack.duckdb_extension" "https://community-extensions.duckdb.org/$VERSION/$PLATFORM/capi_quack.duckdb_extension.gz" &&
	gunzip -c "$RUNS_DIR/stable/capi_quack.duckdb_extension" >"$RUNS_DIR/stable/x" 2>/dev/null &&
	mv "$RUNS_DIR/stable/x" "$RUNS_DIR/stable/capi_quack.duckdb_extension"
rm -f "$RUNS_DIR/stable/x"
curl -fsS --compressed -o "$RUNS_DIR/wasm/capi_quack.duckdb_extension.wasm" "https://community-extensions.duckdb.org/$VERSION/wasm_eh/capi_quack.duckdb_extension.wasm"
EXTENSION_VERSION=$(tail -c 384 "$RUNS_DIR/native/rusty_quack.duckdb_extension" | dd bs=1 count=32 2>/dev/null | tr -d '\0')
LATEST="$VERSION/$PLATFORM/rusty_quack.duckdb_extension.gz"
VERSIONED="rusty_quack/$EXTENSION_VERSION/$VERSION/$PLATFORM/rusty_quack.duckdb_extension.gz"

printf 'platform %s, extension version %s\n\n' "$PLATFORM" "$EXTENSION_VERSION"

http_status() { curl -s --cacert "$CA" -o /dev/null -w '%{http_code}' "$1"; }
http_header() { curl -s --cacert "$CA" -I "$1" | tr -d '\r' | awk -v name="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]'):" 'tolower($1) == name { $1 = ""; sub(/^ /, ""); print }'; }

# The DuckDB CLI for this platform, as a client would have it.
cli_dir="$RUNS_DIR/cli"
mkdir -p "$cli_dir"
case "$PLATFORM" in
linux_amd64) cli_asset=duckdb-cli-linux-amd64 ;;
linux_arm64) cli_asset=duckdb-cli-linux-arm64 ;;
osx_amd64) cli_asset=duckdb-cli-osx-amd64 ;;
osx_arm64) cli_asset=duckdb-cli-osx-arm64 ;;
esac
curl -fsSL -o "$cli_dir/cli.tar.gz" "https://github.com/duckdb/duckdb/releases/download/$VERSION/$cli_asset.tar.gz" && tar -xzf "$cli_dir/cli.tar.gz" -C "$cli_dir"
DUCKDB=$(find "$cli_dir" -type f -name duckdb -perm -u+x -print)

client() { # <run name> <sql>
	local home="$RUNS_DIR/client-$1"
	mkdir -p "$home"
	CLIENT_LOG="$RUNS_DIR/client-$1.log"
	printf '%s\n' "$2" | env -u AI_AGENT HOME="$home" "$DUCKDB" -batch -bail -noheader -list >"$CLIENT_LOG" 2>&1
}

publish() { # <run name> <bucket> <signing key> [VAR=value...]
	local name=$1 bucket=$2 key=$3
	shift 3
	run_action "$name" INPUT_PATH="$RUNS_DIR/native" INPUT_SIGNING_KEY="$key" \
		INPUT_S3_BUCKET="$bucket" INPUT_S3_ENDPOINT="$S3_ENDPOINT" INPUT_S3_REGION=us-east-1 \
		INPUT_S3_ACCESS_KEY_ID="$S3_ACCESS_KEY_ID" INPUT_S3_SECRET_ACCESS_KEY="$S3_SECRET_ACCESS_KEY" \
		RCLONE_CA_CERT="$CA" INPUT_SMOKE_TEST_SETUP_SQL="$SETUP_SQL" "$@"
}

ok_or_log() { # <description> <status>
	if [ "$2" = "0" ]; then pass "$1"; else fail "$1" "$(tail -n 4 "$RUN_LOG" | cut -c1-300 | tr '\n' ' ')"; fi
}

echo '--- public bucket over https://'
PUBLIC="$S3_ENDPOINT/public-bucket"
publish public public-bucket "$KEY_ONE" INPUT_REPOSITORY_URL="$PUBLIC/"
ok_or_log 'publishes and passes the smoke test' $?
check_contains 'the smoke test ran' "$RUN_LOG" 'installed and loaded'
check_equal 'repository-url output has no trailing slash' "$PUBLIC" "$(output_value repository-url)"
check_equal 'latest path is readable without credentials' 200 "$(http_status "$PUBLIC/$LATEST")"
check_equal 'versioned path is readable without credentials' 200 "$(http_status "$PUBLIC/$VERSIONED")"
check_equal '.gz objects have no Content-Encoding' '' "$(http_header "$PUBLIC/$LATEST" Content-Encoding)"
curl -s --cacert "$CA" -o "$RUNS_DIR/keyfile.json" "$PUBLIC/.well-known/duckdb-extension-repo.json"
check_equal 'the key file is published' 1 "$(jq '.signature_keys | length' "$RUNS_DIR/keyfile.json")"
check_contains 'the summary has client SQL' "$RUN_SUMMARY" 'CREATE EXTENSION REPOSITORY IF NOT EXISTS my_repo'
check_contains 'the summary names the prefix' "$RUN_SUMMARY" "$PUBLIC"
ETAG_LATEST=$(http_header "$PUBLIC/$LATEST" ETag)
ETAG_VERSIONED=$(http_header "$PUBLIC/$VERSIONED" ETag)

if client pinned "$SETUP_SQL
SET allow_extension_repositories = 'allowed';
CREATE EXTENSION REPOSITORY my_repo WITH PREFIX '$PUBLIC' USING PUBLIC KEY '$PUB_ONE';
INSTALL rusty_quack FROM my_repo;
LOAD rusty_quack FROM my_repo;
SELECT name FROM rusty_quack(['Jane']);"; then
	pass 'a client with the key inline installs and loads it'
else
	fail 'a client with the key inline installs and loads it' "$(tail -n 3 "$CLIENT_LOG")"
fi
check_contains 'the extension runs' "$CLIENT_LOG" 'Jane'
if client keyfile "$SETUP_SQL
SET allow_extension_repositories = 'allowed';
CREATE EXTENSION REPOSITORY my_repo WITH PREFIX '$PUBLIC';
INSTALL rusty_quack FROM my_repo;
LOAD rusty_quack FROM my_repo;
SELECT name FROM rusty_quack(['Jane']);"; then
	pass 'a client using the key file installs and loads it'
else
	fail 'a client using the key file installs and loads it' "$(tail -n 3 "$CLIENT_LOG")"
fi
if client wrongkey "$SETUP_SQL
SET allow_extension_repositories = 'allowed';
CREATE EXTENSION REPOSITORY my_repo WITH PREFIX '$PUBLIC' USING PUBLIC KEY '$(cat "$RUNS_DIR/keys/two.pub")';
INSTALL rusty_quack FROM my_repo;"; then
	fail 'a client pinning another key is rejected'
else
	pass 'a client pinning another key is rejected'
fi
check_contains 'with a signature error' "$CLIENT_LOG" 'valid signature'

echo; echo '--- re-running a release'
publish rerun public-bucket "$KEY_ONE" INPUT_REPOSITORY_URL="$PUBLIC"
ok_or_log 'an identical re-run succeeds' $?
check_equal 'it leaves the latest object as it was' "$ETAG_LATEST" "$(http_header "$PUBLIC/$LATEST" ETag)"

echo; echo '--- versioned objects are immutable'
if publish refused public-bucket "$KEY_TWO" INPUT_REPOSITORY_URL="$PUBLIC"; then
	fail 'different bytes for a published version are refused'
else
	pass 'different bytes for a published version are refused'
fi
check_contains 'and the error says what to do' "$RUN_LOG" 'overwrite-versioned'
check_equal 'the versioned object is unchanged' "$ETAG_VERSIONED" "$(http_header "$PUBLIC/$VERSIONED" ETag)"
check_equal 'the latest object is unchanged too' "$ETAG_LATEST" "$(http_header "$PUBLIC/$LATEST" ETag)"
publish overwrite public-bucket "$KEY_TWO" INPUT_REPOSITORY_URL="$PUBLIC" INPUT_OVERWRITE_VERSIONED=true
ok_or_log 'overwrite-versioned allows it' $?
if [ "$ETAG_VERSIONED" != "$(http_header "$PUBLIC/$VERSIONED" ETag)" ]; then pass 'the versioned object changed'; else fail 'the versioned object changed'; fi
if [ "$ETAG_LATEST" != "$(http_header "$PUBLIC/$LATEST" ETag)" ]; then pass 'the latest object changed'; else fail 'the latest object changed'; fi

echo; echo '--- private bucket over s3://'
publish private private-bucket "$KEY_ONE" INPUT_S3_PREFIX=/some/prefix/
ok_or_log 'publishes and passes the smoke test through a secret' $?
check_contains 'the smoke test ran' "$RUN_LOG" 'installed and loaded'
check_contains 'the smoke test used s3://' "$RUN_LOG" 's3://private-bucket/some/prefix'
check_equal 'repository-url output is the s3:// prefix' 's3://private-bucket/some/prefix' "$(output_value repository-url)"
check_equal 'the object is not readable without credentials' 403 "$(http_status "$S3_ENDPOINT/private-bucket/some/prefix/$LATEST")"
check_contains 'the summary mentions the secret' "$RUN_SUMMARY" 'CREATE SECRET'
check_not_contains 'the log never shows the secret key' "$RUN_LOG" "$S3_SECRET_ACCESS_KEY"

echo; echo '--- credentials from the environment, as with OIDC'
run_action env INPUT_PATH="$RUNS_DIR/native" INPUT_SIGNING_KEY="$KEY_ONE" INPUT_S3_BUCKET=env-bucket INPUT_S3_ENDPOINT="$S3_ENDPOINT" \
	AWS_REGION=us-east-1 AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$S3_SECRET_ACCESS_KEY" \
	RCLONE_CA_CERT="$CA" INPUT_SMOKE_TEST_SETUP_SQL="$SETUP_SQL"
ok_or_log 'publishes with AWS_* variables only' $?
check_contains 'the smoke test ran' "$RUN_LOG" 'installed and loaded'

echo; echo '--- stable C API build'
run_action stable INPUT_PATH="$RUNS_DIR/stable" INPUT_SIGNING_KEY="$KEY_ONE" INPUT_S3_BUCKET=public-bucket INPUT_S3_ENDPOINT="$S3_ENDPOINT" INPUT_S3_REGION=us-east-1 \
	INPUT_S3_ACCESS_KEY_ID="$S3_ACCESS_KEY_ID" INPUT_S3_SECRET_ACCESS_KEY="$S3_SECRET_ACCESS_KEY" RCLONE_CA_CERT="$CA" \
	INPUT_REPOSITORY_URL="$PUBLIC" INPUT_DUCKDB_VERSION="$VERSION" INPUT_SMOKE_TEST_SETUP_SQL="$SETUP_SQL"
ok_or_log 'publishes a C_STRUCT build and passes the smoke test' $?
check_equal 'it lands in the DuckDB version directory' 200 "$(http_status "$PUBLIC/$VERSION/$PLATFORM/capi_quack.duckdb_extension.gz")"

echo; echo '--- key rotation'
ROTATE="$S3_ENDPOINT/rotate-bucket"
publish rotate_one rotate-bucket "$KEY_ONE" INPUT_REPOSITORY_URL="$ROTATE" INPUT_ADDITIONAL_PUBLIC_KEYS="$(cat "$RUNS_DIR/keys/two.pub")"
ok_or_log 'publishes with a reserve key' $?
curl -s --cacert "$CA" -o "$RUNS_DIR/rotate.json" "$ROTATE/.well-known/duckdb-extension-repo.json"
check_equal 'the key file lists both keys' 2 "$(jq '.signature_keys | length' "$RUNS_DIR/rotate.json")"
if client rotate "$SETUP_SQL
SET allow_extension_repositories = 'allowed';
CREATE EXTENSION REPOSITORY my_repo WITH PREFIX '$ROTATE';
INSTALL rusty_quack FROM my_repo;
LOAD rusty_quack FROM my_repo;"; then
	pass 'a client pins both keys from the key file'
else
	fail 'a client pins both keys from the key file' "$(tail -n 3 "$CLIENT_LOG")"
fi
publish rotate_two rotate-bucket "$KEY_TWO" INPUT_REPOSITORY_URL="$ROTATE" INPUT_OVERWRITE_VERSIONED=true INPUT_ADDITIONAL_PUBLIC_KEYS="$PUB_ONE"
ok_or_log 'publishes builds signed with the reserve key' $?
# The same client home as above, with the key file's two keys already pinned.
if client rotate "$SETUP_SQL
SET allow_extension_repositories = 'allowed';
FORCE INSTALL rusty_quack FROM my_repo;
LOAD rusty_quack FROM my_repo;
SELECT name FROM rusty_quack(['Jane']);"; then
	pass 'the same client upgrades without re-pinning'
else
	fail 'the same client upgrades without re-pinning' "$(tail -n 3 "$CLIENT_LOG")"
fi

echo; echo '--- Wasm'
WASM_BUCKET="$S3_ENDPOINT/wasm-bucket"
run_action wasm INPUT_PATH="$RUNS_DIR/wasm" INPUT_SIGNING_KEY="$KEY_ONE" INPUT_S3_BUCKET=wasm-bucket INPUT_S3_ENDPOINT="$S3_ENDPOINT" INPUT_S3_REGION=us-east-1 \
	INPUT_S3_ACCESS_KEY_ID="$S3_ACCESS_KEY_ID" INPUT_S3_SECRET_ACCESS_KEY="$S3_SECRET_ACCESS_KEY" RCLONE_CA_CERT="$CA" \
	INPUT_REPOSITORY_URL="$WASM_BUCKET" INPUT_DUCKDB_VERSION="$VERSION"
ok_or_log 'publishes a Wasm build' $?
check_contains 'the smoke test explains that it can not cover Wasm' "$RUN_LOG" 'Smoke test skipped'
WASM_URL="$WASM_BUCKET/$VERSION/wasm_eh/capi_quack.duckdb_extension.wasm"
check_equal 'the Wasm object is readable' 200 "$(http_status "$WASM_URL")"
check_equal 'it is served with Content-Encoding: br' br "$(http_header "$WASM_URL" Content-Encoding)"
check_equal 'it is served as application/wasm' application/wasm "$(http_header "$WASM_URL" Content-Type)"
check_contains 'the summary mentions CORS' "$RUN_SUMMARY" 'CORS'
curl -s --cacert "$CA" -o "$RUNS_DIR/wasm.br" "$WASM_URL"
brotli -d -c "$RUNS_DIR/wasm.br" >"$RUNS_DIR/wasm.bin"
check 'the stored bytes are Brotli and verify' verify_extension "$RUNS_DIR/wasm.bin" "$RUNS_DIR/keys/one.pub"

echo; echo '--- sign-only and failures'
run_action signonly INPUT_MODE=sign-only INPUT_PATH="$RUNS_DIR/native" INPUT_SIGNING_KEY="$KEY_ONE"
ok_or_log 'sign-only needs no bucket' $?
gunzip -c "$(output_value signed-dir)/$LATEST" >"$RUNS_DIR/signonly.bin"
check 'sign-only leaves a verifiable tree' verify_extension "$RUNS_DIR/signonly.bin" "$RUNS_DIR/keys/one.pub"
check_not_contains 'sign-only uploads nothing' "$RUN_LOG" 'Publishing to'
if run_action badcreds INPUT_PATH="$RUNS_DIR/native" INPUT_SIGNING_KEY="$KEY_ONE" INPUT_S3_BUCKET=env-bucket INPUT_S3_ENDPOINT="$S3_ENDPOINT" INPUT_S3_REGION=us-east-1 \
	INPUT_S3_ACCESS_KEY_ID=wrong INPUT_S3_SECRET_ACCESS_KEY=wrong RCLONE_CA_CERT="$CA" INPUT_SMOKE_TEST=false; then
	fail 'wrong credentials fail the run'
else
	pass 'wrong credentials fail the run'
fi
check_not 'and the key is still removed' test -e "$(output_value work-dir)/keys/signing_key.pem"

echo; echo '--- smoke test catches a repository clients can not use'
if run_action wrongurl INPUT_PATH="$RUNS_DIR/native" INPUT_SIGNING_KEY="$KEY_ONE" INPUT_S3_BUCKET=env-bucket INPUT_S3_ENDPOINT="$S3_ENDPOINT" INPUT_S3_REGION=us-east-1 \
	INPUT_S3_ACCESS_KEY_ID="$S3_ACCESS_KEY_ID" INPUT_S3_SECRET_ACCESS_KEY="$S3_SECRET_ACCESS_KEY" RCLONE_CA_CERT="$CA" \
	INPUT_REPOSITORY_URL="$S3_ENDPOINT/does-not-exist" INPUT_SMOKE_TEST_SETUP_SQL="$SETUP_SQL"; then
	fail 'a wrong repository-url fails the smoke test'
else
	pass 'a wrong repository-url fails the smoke test'
fi
check_contains 'and says the upload already happened' "$RUN_LOG" 'although it has been uploaded'

finish
