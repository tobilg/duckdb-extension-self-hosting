#!/usr/bin/env bash
# Signs real Wasm extensions with the action's scripts, serves them like a public bucket and loads them in DuckDB-Wasm.
#
# The pinned DuckDB-Wasm package is a dev build of the v2.0.0 commit, so it looks in a directory named after the commit
# and expects that name in the footer of CPP builds. The footer of the CPP fixture is rewritten to match. C_STRUCT
# builds don't record a DuckDB version. Move to the v2.0.0 directory once a stable DuckDB-Wasm 2.0 exists.

# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

VERSION_DIR=d54cbbe3df
PAGE_PORT=${WASM_TEST_PAGE_PORT:-19100}
REPOSITORY_PORT=${WASM_TEST_REPOSITORY_PORT:-19101}
HERE="$TESTS_ROOT/tests/wasm"
PLATFORM_DIR="$VERSION_DIR/wasm_eh"

export RUNS_DIR
RUNS_DIR=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/duckdb-publisher-wasm.XXXXXX")" && pwd -P)
SERVER=
trap '[ -n "$SERVER" ] && kill "$SERVER" 2>/dev/null; rm -rf "$RUNS_DIR"' EXIT
export TEST_HOME="$RUNS_DIR/home"
mkdir -p "$TEST_HOME" "$RUNS_DIR/keys" "$RUNS_DIR/source" "$RUNS_DIR/page"
REPOSITORY="$RUNS_DIR/repository"

if [ ! -d "$HERE/node_modules/@duckdb/duckdb-wasm" ]; then
	(cd "$HERE" && npm install --no-audit --no-fund --silent --no-package-lock) || exit 1
fi

for key in one two; do
	openssl genrsa -out "$RUNS_DIR/keys/$key.pem" 2048 2>/dev/null
	openssl rsa -in "$RUNS_DIR/keys/$key.pem" -pubout -out "$RUNS_DIR/keys/$key.pub" 2>/dev/null
done

curl -fsS --compressed -o "$RUNS_DIR/source/capi_quack.duckdb_extension.wasm" https://community-extensions.duckdb.org/v2.0.0/wasm_eh/capi_quack.duckdb_extension.wasm || exit 1
curl -fsS --compressed -o "$RUNS_DIR/source/inet.duckdb_extension.wasm" https://extensions.duckdb.org/v2.0.0/wasm_eh/inet.duckdb_extension.wasm || exit 1

# Rewrites the DuckDB version in the footer of the CPP build, 352 bytes from the end.
INET="$RUNS_DIR/source/inet.duckdb_extension.wasm"
SIZE=$(wc -c <"$INET" | tr -d '[:space:]')
{
	printf '%s' "$VERSION_DIR"
	head -c $((32 - ${#VERSION_DIR})) /dev/zero
} | dd of="$INET" bs=1 seek=$((SIZE - 352)) conv=notrunc 2>/dev/null

sign_into() { # <route> <key>
	if ! run_action "sign-$1" INPUT_MODE=sign-only INPUT_PATH="$RUNS_DIR/source" INPUT_SIGNING_KEY="$(cat "$RUNS_DIR/keys/$2.pem")" INPUT_DUCKDB_VERSION="$VERSION_DIR"; then
		echo "signing for $1 failed:"
		cat "$RUN_LOG"
		exit 1
	fi
	mkdir -p "$REPOSITORY/$1"
	cp -R "$(output_value signed-dir)/." "$REPOSITORY/$1/"
}
sign_into good one
sign_into nocors one
sign_into rotated two

mkdir -p "$REPOSITORY/plain/$PLATFORM_DIR" "$REPOSITORY/tamper/$PLATFORM_DIR"
CAPI="$PLATFORM_DIR/capi_quack.duckdb_extension.wasm"
brotli -d -c "$REPOSITORY/good/$CAPI" >"$REPOSITORY/plain/$CAPI"
cp "$REPOSITORY/plain/$CAPI" "$RUNS_DIR/tampered"
printf 'X' | dd of="$RUNS_DIR/tampered" bs=1 seek=100 conv=notrunc 2>/dev/null
brotli -f -c "$RUNS_DIR/tampered" >"$REPOSITORY/tamper/$CAPI"

printf '<!doctype html><html><head><meta charset="utf-8"><title>test</title></head><body><script src="/page.js"></script></body></html>\n' >"$RUNS_DIR/page/index.html"
"$HERE/node_modules/.bin/esbuild" "$HERE/page.js" --bundle --format=iife --outfile="$RUNS_DIR/page/page.js" --log-level=warning \
	--alias:@duckdb/duckdb-wasm="$HERE/node_modules/@duckdb/duckdb-wasm/dist/duckdb-browser.mjs" || exit 1

: >"$RUNS_DIR/requests.log"
node "$HERE/server.cjs" "$RUNS_DIR/page" "$HERE/node_modules/@duckdb/duckdb-wasm/dist" "$REPOSITORY" "$PAGE_PORT" "$REPOSITORY_PORT" "$RUNS_DIR/requests.log" &
SERVER=$!
attempts=0
until curl -s -o /dev/null "http://127.0.0.1:$PAGE_PORT/" && curl -s -o /dev/null "http://127.0.0.1:$REPOSITORY_PORT/"; do
	attempts=$((attempts + 1))
	if [ "$attempts" -gt 100 ]; then
		echo "the test servers did not start"
		exit 1
	fi
	perl -e 'select(undef, undef, undef, 0.1)'
done

NODE_PATH="$HERE/node_modules" node "$HERE/driver.cjs" "$PAGE_PORT" "$REPOSITORY_PORT" "$RUNS_DIR/keys/one.pub" "$RUNS_DIR/keys/two.pub" "$VERSION_DIR" "$RUNS_DIR/requests.log"
