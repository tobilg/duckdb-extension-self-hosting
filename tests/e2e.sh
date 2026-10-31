#!/usr/bin/env bash
# Takes real extensions through the three jobs of a release: signs them, installs them with the real DuckDB CLI, publishes
# them to a local S3-compatible store, and installs them from there as a client would. Needs Docker and network access.

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
fetch_fixture community "$VERSION/$PLATFORM/rusty_quack.duckdb_extension" "$RUNS_DIR/native/rusty_quack.duckdb_extension" || exit 1
fetch_fixture community "$VERSION/$PLATFORM/capi_quack.duckdb_extension" "$RUNS_DIR/stable/capi_quack.duckdb_extension" || exit 1
fetch_fixture community "$VERSION/wasm_eh/capi_quack.duckdb_extension.wasm" "$RUNS_DIR/wasm/capi_quack.duckdb_extension.wasm" || exit 1
EXTENSION_VERSION=$(tail -c 384 "$RUNS_DIR/native/rusty_quack.duckdb_extension" | dd bs=1 count=32 2>/dev/null | tr -d '\0')
LATEST="$VERSION/$PLATFORM/rusty_quack.duckdb_extension.gz"
VERSIONED="rusty_quack/$EXTENSION_VERSION/$VERSION/$PLATFORM/rusty_quack.duckdb_extension.gz"

printf 'platform %s, extension version %s\n\n' "$PLATFORM" "$EXTENSION_VERSION"

http_status() { curl -s --cacert "$CA" -o /dev/null -w '%{http_code}' "$1"; }
http_header() { curl -s --cacert "$CA" -I "$1" | tr -d '\r' | awk -v name="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]'):" 'tolower($1) == name { $1 = ""; sub(/^ /, ""); print }'; }

# The DuckDB CLI for this platform, as a client would have it.
cli_dir="$RUNS_DIR/cli"
mkdir -p "$cli_dir"
curl -fsSL -o "$cli_dir/cli.tar.gz" "https://github.com/duckdb/duckdb/releases/download/$VERSION/$(cli_asset "$PLATFORM").tar.gz" && tar -xzf "$cli_dir/cli.tar.gz" -C "$cli_dir"
DUCKDB=$(find "$cli_dir" -type f -name duckdb -perm -u+x -print)

client() { # <run name> <sql>
	local home="$RUNS_DIR/client-$1"
	mkdir -p "$home"
	CLIENT_LOG="$RUNS_DIR/client-$1.log"
	printf '%s\n' "$2" | env -u AI_AGENT HOME="$home" "$DUCKDB" -batch -bail -noheader -list >"$CLIENT_LOG" 2>&1
}

# The sign job.
sign() { # <run name> <source dir> <signing key> [VAR=value...]
	local name=$1 source_dir=$2 key=$3
	shift 3
	run_action "$name" INPUT_MODE=sign INPUT_ALL_EXTENSIONS=true INPUT_PATH="$source_dir" INPUT_SIGNING_KEY="$key" "$@"
}

# The verify job, on the signed tree of the sign job before it.
verify() { # <run name> <bundle> [VAR=value...]
	local name=$1 bundle=$2
	shift 2
	run_action "$name" INPUT_MODE=verify TEST_BUNDLE="$bundle" "$@"
}

# The publish job.
upload_bundle() { # <run name> <bucket> <bundle> <digest> [VAR=value...]
	local name=$1 bucket=$2 bundle=$3 digest=$4
	shift 4
	run_action "$name" INPUT_MODE=publish TEST_BUNDLE="$bundle" INPUT_BUNDLE_DIGEST="$digest" \
		INPUT_S3_BUCKET="$bucket" INPUT_S3_ENDPOINT="$S3_ENDPOINT" INPUT_S3_REGION=us-east-1 \
		INPUT_S3_ACCESS_KEY_ID="$S3_ACCESS_KEY_ID" INPUT_S3_SECRET_ACCESS_KEY="$S3_SECRET_ACCESS_KEY" \
		RCLONE_CA_CERT="$CA" CURL_CA_BUNDLE="$CA" "$@"
}

# The sign and publish jobs in a row. The arguments go to both, which each take what they need.
publish() { # <run name> <bucket> <signing key> [VAR=value...]
	local name=$1 bucket=$2 key=$3
	shift 3
	sign "$name-sign" "$RUNS_DIR/native" "$key" "$@" || return 1
	upload_bundle "$name" "$bucket" "$(bundle_dir)" "$(output_value bundle-digest)" "$@"
}

ok_or_log() { # <description> <status>
	if [ "$2" = "0" ]; then pass "$1"; else fail "$1" "$(tail -n 4 "$RUN_LOG" | cut -c1-300 | tr '\n' ' ')"; fi
}

# A copy of the real extension that reports another version.
version_variant() { # <directory> <extension version>
	mkdir -p "$1"
	cp "$RUNS_DIR/native/rusty_quack.duckdb_extension" "$1/"
	set_footer_field "$1/rusty_quack.duckdb_extension" 384 "$2"
}

# The version in the footer of what a URL serves.
served_version() { # <url>
	curl -s --cacert "$CA" "$1" | gunzip -c 2>/dev/null >"$RUNS_DIR/served"
	tail -c 384 "$RUNS_DIR/served" | dd bs=1 count=32 2>/dev/null | tr -d '\0'
}

echo '--- the three jobs, on a public bucket over https://'
PUBLIC="$S3_ENDPOINT/public-bucket"
sign public_sign "$RUNS_DIR/native" "$KEY_ONE"
ok_or_log 'the sign job signs' $?
PUBLIC_BUNDLE=$(bundle_dir)
PUBLIC_DIGEST=$(output_value bundle-digest)
verify public_verify "$PUBLIC_BUNDLE"
ok_or_log 'the verify job installs and loads it with the real CLI' $?
check_contains 'the smoke test ran' "$RUN_LOG" 'installed and loaded'
check_contains 'its summary lists what was tested' "$RUN_SUMMARY" "| rusty_quack | $VERSION | $PLATFORM |"
upload_bundle public public-bucket "$PUBLIC_BUNDLE" "$PUBLIC_DIGEST" INPUT_REPOSITORY_URL="$PUBLIC/"
ok_or_log 'the publish job uploads it' $?
check_contains 'and reads it back through repository-url' "$RUN_LOG" 'serves what was uploaded'
check_equal 'repository-url output has no trailing slash' "$PUBLIC" "$(output_value repository-url)"
check_equal 'latest path is readable without credentials' 200 "$(http_status "$PUBLIC/$LATEST")"
check_equal 'versioned path is readable without credentials' 200 "$(http_status "$PUBLIC/$VERSIONED")"
check_equal '.gz objects have no Content-Encoding' '' "$(http_header "$PUBLIC/$LATEST" Content-Encoding)"
check_equal 'latest objects are revalidated by caches' no-cache "$(http_header "$PUBLIC/$LATEST" Cache-Control)"
check_equal 'versioned objects can be cached' 'public, max-age=86400' "$(http_header "$PUBLIC/$VERSIONED" Cache-Control)"
check_equal 'the key file is revalidated too' no-cache "$(http_header "$PUBLIC/.well-known/duckdb-extension-repo.json" Cache-Control)"
curl -s --cacert "$CA" -o "$RUNS_DIR/keyfile.json" "$PUBLIC/.well-known/duckdb-extension-repo.json"
check_equal 'the key file is published' 1 "$(jq '.signature_keys | length' "$RUNS_DIR/keyfile.json")"
check_contains 'the summary has client SQL' "$RUN_SUMMARY" 'CREATE EXTENSION REPOSITORY IF NOT EXISTS my_repo'
check_contains 'the summary names the prefix' "$RUN_SUMMARY" "$PUBLIC"
check_equal 'the fingerprint of the publish job is the signing key' "$(sed -n 's/^fingerprint=//p' "$RUNS_DIR/public_sign.output")" "$(output_value fingerprint)"
check_equal 'every object was uploaded' 3 "$(output_block uploaded-objects | jq 'length')"
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
check_contains 'and CREATE prints the fingerprint to compare' "$CLIENT_LOG" "$(output_value fingerprint)"
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
if publish refused public-bucket "$KEY_TWO" INPUT_REPOSITORY_URL="$PUBLIC" INPUT_ALLOW_KEY_CHANGE=true; then
	fail 'different bytes for a published version are refused'
else
	pass 'different bytes for a published version are refused'
fi
check_contains 'and the error says what to do' "$RUN_LOG" 'overwrite-versioned'
check_equal 'the versioned object is unchanged' "$ETAG_VERSIONED" "$(http_header "$PUBLIC/$VERSIONED" ETag)"
check_equal 'the latest object is unchanged too' "$ETAG_LATEST" "$(http_header "$PUBLIC/$LATEST" ETag)"
curl -s --cacert "$CA" -o "$RUNS_DIR/keyfile-refused.json" "$PUBLIC/.well-known/duckdb-extension-repo.json"
check 'and so is the key file' cmp "$RUNS_DIR/keyfile.json" "$RUNS_DIR/keyfile-refused.json"
publish overwrite public-bucket "$KEY_TWO" INPUT_REPOSITORY_URL="$PUBLIC" INPUT_OVERWRITE_VERSIONED=true INPUT_ALLOW_KEY_CHANGE=true
ok_or_log 'overwrite-versioned allows it' $?
if [ "$ETAG_VERSIONED" != "$(http_header "$PUBLIC/$VERSIONED" ETag)" ]; then pass 'the versioned object changed'; else fail 'the versioned object changed'; fi
if [ "$ETAG_LATEST" != "$(http_header "$PUBLIC/$LATEST" ETag)" ]; then pass 'the latest object changed'; else fail 'the latest object changed'; fi

echo; echo '--- a signing key that clients do not know'
V1="$RUNS_DIR/version-1"
V2="$RUNS_DIR/version-2"
version_variant "$V1" v1.0.0
version_variant "$V2" v2.0.0
WRONG="$PUBLIC/wrong-key"
publish wrong_first public-bucket "$KEY_ONE" INPUT_PATH="$V1" INPUT_S3_PREFIX=wrong-key INPUT_REPOSITORY_URL="$WRONG"
ok_or_log 'the first release goes out with one key' $?
if client wrong_key_client "$SETUP_SQL
SET allow_extension_repositories = 'allowed';
CREATE EXTENSION REPOSITORY my_repo WITH PREFIX '$WRONG' USING PUBLIC KEY '$PUB_ONE';
INSTALL rusty_quack FROM my_repo;
LOAD rusty_quack FROM my_repo;"; then pass 'and a client pins that key'; else fail 'and a client pins that key' "$(tail -n 3 "$CLIENT_LOG")"; fi
WRONG_ETAG=$(http_header "$WRONG/$LATEST" ETag)
if publish wrong_second public-bucket "$KEY_TWO" INPUT_PATH="$V2" INPUT_S3_PREFIX=wrong-key INPUT_REPOSITORY_URL="$WRONG"; then
	fail 'the next release with another key is refused'
else
	pass 'the next release with another key is refused'
fi
check_contains 'and the error says why' "$RUN_LOG" "isn't in the bucket's key file"
check_equal 'latest is unchanged' "$WRONG_ETAG" "$(http_header "$WRONG/$LATEST" ETag)"
if client wrong_key_client "$SETUP_SQL
SET allow_extension_repositories = 'allowed';
FORCE INSTALL rusty_quack FROM my_repo;
LOAD rusty_quack FROM my_repo;"; then pass 'so the client can still upgrade'; else fail 'so the client can still upgrade' "$(tail -n 3 "$CLIENT_LOG")"; fi

echo; echo '--- an older release after a newer one'
DOWN="$PUBLIC/downgrade"
publish down_new public-bucket "$KEY_ONE" INPUT_PATH="$V2" INPUT_S3_PREFIX=downgrade INPUT_REPOSITORY_URL="$DOWN"
ok_or_log 'the newer release goes out' $?
if publish down_old public-bucket "$KEY_ONE" INPUT_PATH="$V1" INPUT_S3_PREFIX=downgrade INPUT_REPOSITORY_URL="$DOWN"; then
	fail 'the older release is refused'
else
	pass 'the older release is refused'
fi
check_contains 'and the error says why' "$RUN_LOG" 'is older than v2.0.0'
check_equal 'latest still serves the newer one' v2.0.0 "$(served_version "$DOWN/$LATEST")"
publish down_allowed public-bucket "$KEY_ONE" INPUT_PATH="$V1" INPUT_S3_PREFIX=downgrade INPUT_REPOSITORY_URL="$DOWN" INPUT_ALLOW_DOWNGRADE=true
ok_or_log 'allow-downgrade lets it through' $?
check_equal 'and latest moves back' v1.0.0 "$(served_version "$DOWN/$LATEST")"

echo; echo '--- a build that does not load stops the release'
BROKEN="$RUNS_DIR/broken"
version_variant "$BROKEN" v1.1.0
head -c 65536 /dev/zero | dd of="$BROKEN/rusty_quack.duckdb_extension" bs=1 seek=0 conv=notrunc 2>/dev/null
sign broken_sign "$BROKEN" "$KEY_ONE"
ok_or_log 'it can be signed, because signing only looks at the footer' $?
if verify broken_verify "$(bundle_dir)"; then fail 'the verify job fails'; else pass 'the verify job fails'; fi
check_contains 'and the error says nothing has been uploaded' "$RUN_LOG" 'Nothing has been uploaded'
check_contains 'and holds the reason in the annotation' "$RUN_LOG" 'Error'
check_equal 'and it stays on one line' 1 "$(grep -c '^::error::' "$RUN_LOG")"
check_contains 'the summary calls it out' "$RUN_SUMMARY" 'The smoke test failed'

echo; echo '--- setup SQL in the verify job'
verify setup_no_semicolon "$PUBLIC_BUNDLE" INPUT_SMOKE_TEST_SETUP_SQL="SET threads = 1 -- no semicolon"
ok_or_log 'SQL without a semicolon works, also with a comment at the end' $?
if verify setup_bad "$PUBLIC_BUNDLE" INPUT_SMOKE_TEST_SETUP_SQL="this is not SQL"; then fail 'SQL that fails stops it'; else pass 'SQL that fails stops it'; fi

echo; echo '--- only the versioned path'
ONLY="$PUBLIC/versioned-only"
sign only_sign "$RUNS_DIR/native" "$KEY_ONE" INPUT_UPLOAD_LATEST=false
ok_or_log 'signs only the versioned path' $?
ONLY_BUNDLE=$(bundle_dir)
ONLY_DIGEST=$(output_value bundle-digest)
verify only_verify "$ONLY_BUNDLE"
ok_or_log 'the verify job installs it by version with the real CLI' $?
check_contains 'the smoke test ran' "$RUN_LOG" 'installed and loaded'
upload_bundle only public-bucket "$ONLY_BUNDLE" "$ONLY_DIGEST" INPUT_S3_PREFIX=versioned-only INPUT_REPOSITORY_URL="$ONLY"
ok_or_log 'publishes it' $?
check_equal 'latest stays empty' 404 "$(http_status "$ONLY/$LATEST")"
if client only_client "$SETUP_SQL
SET allow_extension_repositories = 'allowed';
CREATE EXTENSION REPOSITORY my_repo WITH PREFIX '$ONLY' USING PUBLIC KEY '$PUB_ONE';
INSTALL rusty_quack FROM my_repo VERSION '$EXTENSION_VERSION';
LOAD rusty_quack FROM my_repo;
SELECT name FROM rusty_quack(['Jane']);"; then pass 'a client installs it by version'; else fail 'a client installs it by version' "$(tail -n 3 "$CLIENT_LOG")"; fi

echo; echo '--- a signed tree that changed after the sign job'
sign tamper_sign "$RUNS_DIR/native" "$KEY_ONE"
TAMPERED="$RUNS_DIR/tampered"
cp -R "$(bundle_dir)" "$TAMPERED"
TAMPER_DIGEST=$(output_value bundle-digest)
printf 'x' >>"$TAMPERED/signed/$LATEST"
if upload_bundle tamper public-bucket "$TAMPERED" "$TAMPER_DIGEST" INPUT_S3_PREFIX=tampered INPUT_REPOSITORY_URL="$PUBLIC/tampered"; then
	fail 'the publish job refuses it'
else
	pass 'the publish job refuses it'
fi
check_contains 'and says why' "$RUN_LOG" "doesn't match 'bundle-digest'"
check_equal 'and uploads nothing' 404 "$(http_status "$PUBLIC/tampered/$LATEST")"

echo; echo '--- private bucket over s3://'
publish private private-bucket "$KEY_ONE" INPUT_S3_PREFIX=/some/prefix/
ok_or_log 'publishes and reads it back with the credentials' $?
check_contains 'the check used s3://' "$RUN_LOG" 'Checking what s3://private-bucket/some/prefix serves'
check_equal 'repository-url output is the s3:// prefix' 's3://private-bucket/some/prefix' "$(output_value repository-url)"
check_equal 'the object is not readable without credentials' 403 "$(http_status "$S3_ENDPOINT/private-bucket/some/prefix/$LATEST")"
check_contains 'the summary mentions the secret' "$RUN_SUMMARY" 'CREATE SECRET'
check_not_contains 'the log never shows the secret key' "$RUN_LOG" "$S3_SECRET_ACCESS_KEY"
if client private_client "$SETUP_SQL
CREATE SECRET private_bucket (TYPE s3, KEY_ID '$S3_ACCESS_KEY_ID', SECRET '$S3_SECRET_ACCESS_KEY', REGION 'us-east-1', ENDPOINT '${S3_ENDPOINT#https://}', URL_STYLE 'path');
SET allow_extension_repositories = 'allowed';
CREATE EXTENSION REPOSITORY my_repo WITH PREFIX 's3://private-bucket/some/prefix' USING PUBLIC KEY '$PUB_ONE';
INSTALL rusty_quack FROM my_repo;
LOAD rusty_quack FROM my_repo;
SELECT name FROM rusty_quack(['Jane']);"; then pass 'a client with a secret installs and loads it'; else fail 'a client with a secret installs and loads it' "$(tail -n 3 "$CLIENT_LOG")"; fi
publish private_explicit private-bucket "$KEY_ONE" INPUT_S3_PREFIX=explicit INPUT_REPOSITORY_URL=s3://private-bucket/explicit/
ok_or_log 'an explicit s3:// repository-url works too' $?
check_contains 'and is what gets checked' "$RUN_LOG" 'Checking what s3://private-bucket/explicit serves'

echo; echo '--- credentials from the environment'
sign env_sign "$RUNS_DIR/native" "$KEY_ONE"
ENV_BUNDLE=$(bundle_dir)
ENV_DIGEST=$(output_value bundle-digest)
run_action env INPUT_MODE=publish TEST_BUNDLE="$ENV_BUNDLE" INPUT_BUNDLE_DIGEST="$ENV_DIGEST" INPUT_S3_BUCKET=env-bucket INPUT_S3_ENDPOINT="$S3_ENDPOINT" \
	AWS_REGION=us-east-1 AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$S3_SECRET_ACCESS_KEY" RCLONE_CA_CERT="$CA"
ok_or_log 'publishes with AWS_* variables only' $?
check_contains 'the check ran' "$RUN_LOG" 'serves what was uploaded'

echo; echo '--- a role from GitHub OIDC'
# What configure-aws-credentials exports, in a job with the permission, and no credential inputs. Without s3-endpoint the
# provider is AWS, as on real AWS, and only the SDK's own override reaches the local store. The store accepts any session
# token, so this proves what the action sends, and not what IAM would make of it.
publish_with_role() { # <run name> [VAR=value...]
	local name=$1
	shift
	run_action "$name" INPUT_MODE=publish TEST_BUNDLE="$ENV_BUNDLE" INPUT_BUNDLE_DIGEST="$ENV_DIGEST" INPUT_S3_BUCKET=env-bucket INPUT_S3_PREFIX="$name" \
		AWS_ENDPOINT_URL_S3="$S3_ENDPOINT" AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$S3_SECRET_ACCESS_KEY" AWS_SESSION_TOKEN=session-from-oidc \
		AWS_REGION=us-east-1 AWS_DEFAULT_REGION=us-east-1 ACTIONS_ID_TOKEN_REQUEST_TOKEN=x ACTIONS_ID_TOKEN_REQUEST_URL=https://x.invalid RCLONE_CA_CERT="$CA" "$@"
}
publish_with_role oidc
ok_or_log 'publishes with only what the role leaves in the environment' $?
check_contains 'on the AWS provider' "$RUN_LOG" 'provider AWS'
check_contains 'and the check ran' "$RUN_LOG" 'serves what was uploaded'
check_not_contains 'the session token stays out of the log' "$RUN_LOG" 'session-from-oidc'
check_equal 'every object was uploaded' 3 "$(output_block uploaded-objects | jq 'length')"
publish_with_role oidc_dump RCLONE_DUMP=headers,auth RCLONE_LOG_LEVEL=DEBUG
ok_or_log 'publishes with rclone showing its requests' $?
check 'and sends the session token' grep -qi 'X-Amz-Security-Token: session-from-oidc' "$RUN_LOG"
check 'and signs for the region of the role' grep -q '/us-east-1/s3/aws4_request' "$RUN_LOG"
publish_with_role oidc_inputs INPUT_S3_ACCESS_KEY_ID="$S3_ACCESS_KEY_ID" INPUT_S3_SECRET_ACCESS_KEY="$S3_SECRET_ACCESS_KEY" \
	AWS_ACCESS_KEY_ID=stale AWS_SECRET_ACCESS_KEY=stale RCLONE_DUMP=headers,auth RCLONE_LOG_LEVEL=DEBUG
ok_or_log 'input keys win over a role left in the job' $?
check_not 'and do not send its session token' grep -qi 'X-Amz-Security-Token: session-from-oidc' "$RUN_LOG"

echo; echo '--- stable C API build'
STABLE_PREFIX=stable
sign stable_sign "$RUNS_DIR/stable" "$KEY_ONE" INPUT_DUCKDB_VERSION="$VERSION"
ok_or_log 'signs a C_STRUCT build' $?
STABLE_BUNDLE=$(bundle_dir)
STABLE_DIGEST=$(output_value bundle-digest)
verify stable_verify "$STABLE_BUNDLE"
ok_or_log 'the verify job installs and loads it' $?
upload_bundle stable public-bucket "$STABLE_BUNDLE" "$STABLE_DIGEST" INPUT_S3_PREFIX="$STABLE_PREFIX" INPUT_REPOSITORY_URL="$PUBLIC/$STABLE_PREFIX"
ok_or_log 'publishes it' $?
check_equal 'it lands in the DuckDB version directory' 200 "$(http_status "$PUBLIC/$STABLE_PREFIX/$VERSION/$PLATFORM/capi_quack.duckdb_extension.gz")"

echo; echo '--- key rotation'
ROTATE="$S3_ENDPOINT/rotate-bucket"
publish rotate_one rotate-bucket "$KEY_ONE" INPUT_REPOSITORY_URL="$ROTATE" INPUT_ADDITIONAL_PUBLIC_KEYS="$(cat "$RUNS_DIR/keys/two.pub")"
ok_or_log 'publishes with a reserve key' $?
# shellcheck disable=SC2016 # the backticks are Markdown
SUMMARY_SQL=$(sed -n '/^```sql$/,/^```$/p' "$RUN_SUMMARY" | sed '1d;$d')
if client summary "$SETUP_SQL
$SUMMARY_SQL
SELECT name FROM rusty_quack(['Jane']);"; then
	pass 'the SQL in the summary installs and loads it'
else
	fail 'the SQL in the summary installs and loads it' "$(tail -n 3 "$CLIENT_LOG")"
fi
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
ok_or_log 'publishes builds signed with the reserve key, which is in the key file' $?
check_not_contains 'without a warning about the key' "$RUN_LOG" "isn't in the bucket's key file"
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
if client summary "$SETUP_SQL
SET allow_extension_repositories = 'allowed';
FORCE INSTALL rusty_quack FROM my_repo;
LOAD rusty_quack FROM my_repo;
SELECT name FROM rusty_quack(['Jane']);"; then
	pass 'a client that used the SQL in the summary upgrades without re-pinning'
else
	fail 'a client that used the SQL in the summary upgrades without re-pinning' "$(tail -n 3 "$CLIENT_LOG")"
fi

echo; echo '--- Wasm'
WASM_BUCKET="$S3_ENDPOINT/wasm-bucket"
sign wasm_sign "$RUNS_DIR/wasm" "$KEY_ONE" INPUT_DUCKDB_VERSION="$VERSION"
ok_or_log 'signs a Wasm build' $?
WASM_BUNDLE=$(bundle_dir)
WASM_DIGEST=$(output_value bundle-digest)
verify wasm_verify "$WASM_BUNDLE"
ok_or_log 'the verify job passes' $?
check_contains 'and explains that it can not cover Wasm' "$RUN_LOG" 'Smoke test skipped'
upload_bundle wasm wasm-bucket "$WASM_BUNDLE" "$WASM_DIGEST" INPUT_REPOSITORY_URL="$WASM_BUCKET"
ok_or_log 'publishes a Wasm build' $?
check_contains 'the check accepts it' "$RUN_LOG" 'serves what was uploaded'
WASM_URL="$WASM_BUCKET/$VERSION/wasm_eh/capi_quack.duckdb_extension.wasm"
check_equal 'the Wasm object is readable' 200 "$(http_status "$WASM_URL")"
check_equal 'it is served with Content-Encoding: br' br "$(http_header "$WASM_URL" Content-Encoding)"
check_equal 'it is served as application/wasm' application/wasm "$(http_header "$WASM_URL" Content-Type)"
check_equal 'it is revalidated by caches' no-cache "$(http_header "$WASM_URL" Cache-Control)"
check_contains 'the summary mentions CORS' "$RUN_SUMMARY" 'CORS'
curl -s --cacert "$CA" -o "$RUNS_DIR/wasm.br" "$WASM_URL"
brotli -d -c "$RUNS_DIR/wasm.br" >"$RUNS_DIR/wasm.bin"
check 'the stored bytes are Brotli and verify' verify_extension "$RUNS_DIR/wasm.bin" "$RUNS_DIR/keys/one.pub"
upload_bundle wasm_rerun wasm-bucket "$WASM_BUNDLE" "$WASM_DIGEST" INPUT_REPOSITORY_URL="$WASM_BUCKET"
ok_or_log 'a re-run compares with what is live through Brotli' $?

echo; echo '--- signing alone, and failures'
run_action signonly INPUT_MODE=sign INPUT_ALL_EXTENSIONS=true INPUT_PATH="$RUNS_DIR/native" INPUT_SIGNING_KEY="$KEY_ONE"
ok_or_log 'the sign job needs no bucket' $?
gunzip -c "$(output_value signed-dir)/$LATEST" >"$RUNS_DIR/signonly.bin"
check 'and leaves a verifiable tree' verify_extension "$RUNS_DIR/signonly.bin" "$RUNS_DIR/keys/one.pub"
check_not_contains 'and uploads nothing' "$RUN_LOG" 'Publishing to'
check_not 'and removes the key' test -e "$(output_value work-dir)/keys/signing_key.pem"
BAD_DIGEST=$(output_value bundle-digest)
BAD_BUNDLE=$(bundle_dir)
if run_action badcreds INPUT_MODE=publish TEST_BUNDLE="$BAD_BUNDLE" INPUT_BUNDLE_DIGEST="$BAD_DIGEST" INPUT_S3_BUCKET=env-bucket INPUT_S3_ENDPOINT="$S3_ENDPOINT" INPUT_S3_REGION=us-east-1 \
	INPUT_S3_ACCESS_KEY_ID=wrong INPUT_S3_SECRET_ACCESS_KEY=wrong RCLONE_CA_CERT="$CA" INPUT_CHECK_REPOSITORY=false; then
	fail 'wrong credentials fail the run'
else
	pass 'wrong credentials fail the run'
fi
check_contains 'with a hint' "$RUN_LOG" 'Check the credentials'

echo; echo '--- the repository check catches a repository clients can not use'
if publish wrongurl env-bucket "$KEY_ONE" INPUT_REPOSITORY_URL="$S3_ENDPOINT/does-not-exist"; then
	fail 'a wrong repository-url fails the check'
else
	pass 'a wrong repository-url fails the check'
fi
check_contains 'and says the upload already happened' "$RUN_LOG" 'although it has been uploaded'
check_contains 'the summary still records the publish' "$RUN_SUMMARY" '## Published DuckDB extensions'
check_contains 'and that the check failed' "$RUN_SUMMARY" 'repository check failed'
check_equal 'the repository-url output is still set' "$S3_ENDPOINT/does-not-exist" "$(output_value repository-url)"

echo; echo '--- the repository check catches a repository that serves another build'
OTHER_BUILD="$RUNS_DIR/other-build"
version_variant "$OTHER_BUILD" "$EXTENSION_VERSION"
# A byte in an unused field of the footer: still a valid extension, with other bytes.
SIZE=$(wc -c <"$OTHER_BUILD/rusty_quack.duckdb_extension" | tr -d '[:space:]')
printf 'x' | dd of="$OTHER_BUILD/rusty_quack.duckdb_extension" bs=1 seek=$((SIZE - 512)) conv=notrunc 2>/dev/null
# The upload goes to a prefix, while the URL's root still serves the build from the rotation test, with the same key.
if publish stale rotate-bucket "$KEY_TWO" INPUT_PATH="$OTHER_BUILD" INPUT_S3_PREFIX=staging INPUT_REPOSITORY_URL="$ROTATE"; then
	fail 'an older build at repository-url fails the check'
else
	pass 'an older build at repository-url fails the check'
fi
check_contains 'and says that it is another build' "$RUN_LOG" 'different build'
publish fresh rotate-bucket "$KEY_TWO" INPUT_PATH="$OTHER_BUILD" INPUT_S3_PREFIX=staging INPUT_REPOSITORY_URL="$ROTATE/staging"
ok_or_log 'the same build passes at the right URL' $?
check_contains 'the check ran' "$RUN_LOG" 'serves what was uploaded'

finish
