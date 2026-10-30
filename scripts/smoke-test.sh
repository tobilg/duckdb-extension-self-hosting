#!/usr/bin/env bash
# Proves that what was just published installs: downloads the DuckDB CLI matching each published version, pins the key
# in a throwaway home, and runs INSTALL and LOAD by repository name. Only the runner's own platform can be tested.

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

export_s3_credentials

manifest="$WORK_DIR/manifest.jsonl"
public_key=$(cat "$WORK_DIR/keys/signing_key.pub")
prefix=$(normalize_prefix "${INPUT_S3_PREFIX:-}")
platform=$(runner_platform)

if [ -z "$platform" ]; then
	notice "Smoke test skipped: DuckDB publishes no CLI for this runner."
	exit 0
fi

repository_url=${INPUT_REPOSITORY_URL:-}
secret_sql=
if [ -n "$repository_url" ]; then
	while [ "${repository_url%/}" != "$repository_url" ]; do repository_url=${repository_url%/}; done
else
	if [ -z "${AWS_ACCESS_KEY_ID:-}" ] || [ -z "${AWS_SECRET_ACCESS_KEY:-}" ]; then
		notice "Smoke test skipped: set 'repository-url' or provide credentials, so that DuckDB can read the bucket."
		exit 0
	fi
	repository_url="s3://$INPUT_S3_BUCKET"
	if [ -n "$prefix" ]; then repository_url="$repository_url/$prefix"; fi

	secret_sql="CREATE SECRET smoke_test (TYPE s3, KEY_ID '$(sql_quote "$AWS_ACCESS_KEY_ID")', SECRET '$(sql_quote "$AWS_SECRET_ACCESS_KEY")'"
	if [ -n "${AWS_SESSION_TOKEN:-}" ]; then secret_sql="$secret_sql, SESSION_TOKEN '$(sql_quote "$AWS_SESSION_TOKEN")'"; fi
	if [ -n "$(s3_region)" ]; then secret_sql="$secret_sql, REGION '$(sql_quote "$(s3_region)")'"; fi
	case "${INPUT_S3_ENDPOINT:-}" in
	'') ;;
	http://*) secret_sql="$secret_sql, ENDPOINT '$(sql_quote "${INPUT_S3_ENDPOINT#http://}")', URL_STYLE 'path', USE_SSL false" ;;
	*) secret_sql="$secret_sql, ENDPOINT '$(sql_quote "${INPUT_S3_ENDPOINT#https://}")', URL_STYLE 'path'" ;;
	esac
	secret_sql="$secret_sql, SCOPE 's3://$(sql_quote "$INPUT_S3_BUCKET")');"
fi

# Each extension and DuckDB version once: the latest path if it was published, otherwise the versioned one.
jq -s -r --arg platform "$platform" '
	map(select(.platform == $platform and .kind == "native"))
	| group_by([.name, .duckdb_version])
	| map((map(select(.channel == "latest")) | first) // first)
	| .[] | [.name, .duckdb_version, .channel, .extension_version] | @tsv
' "$manifest" >"$WORK_DIR/tmp/smoke"

if [ ! -s "$WORK_DIR/tmp/smoke" ]; then
	notice "Smoke test skipped: nothing was published for this runner's platform ($platform)."
	exit 0
fi

case "$platform" in
linux_amd64) cli=duckdb-cli-linux-amd64 ;;
linux_arm64) cli=duckdb-cli-linux-arm64 ;;
osx_amd64) cli=duckdb-cli-osx-amd64 ;;
osx_arm64) cli=duckdb-cli-osx-arm64 ;;
esac

require_tool curl

# Prints the path of the CLI for a version. Fails if that version has no release, as with builds of a commit.
fetch_cli() { # <version>
	local version=$1 dir="$WORK_DIR/cli/$1"
	if [ ! -x "$dir/duckdb" ]; then
		mkdir -p "$dir"
		curl -fsSL --retry 3 -o "$dir/cli.tar.gz" "https://github.com/duckdb/duckdb/releases/download/$version/$cli.tar.gz" || return 1
		tar -xzf "$dir/cli.tar.gz" -C "$dir" || return 1
		rm -f "$dir/cli.tar.gz"
		if [ ! -x "$dir/duckdb" ]; then
			local found
			found=$(find "$dir" -type f -name duckdb -perm -u+x -print)
			[ -n "$found" ] || return 1
			mv "$found" "$dir/duckdb"
		fi
	fi
	printf '%s' "$dir/duckdb"
}

failed=0
while IFS="$(printf '\t')" read -r name version channel extension_version; do
	if ! duckdb_cli=$(fetch_cli "$version"); then
		notice "Smoke test skipped for $name on $version: no DuckDB CLI release exists for that version."
		continue
	fi

	version_clause=
	if [ "$channel" = "versioned" ]; then version_clause=" VERSION '$(sql_quote "$extension_version")'"; fi

	home_dir=$(mktemp -d "$WORK_DIR/tmp/home.XXXXXX")
	sql_file="$home_dir/smoke.sql"
	(
		umask 077
		cat >"$sql_file" <<EOF
${INPUT_SMOKE_TEST_SETUP_SQL:-}
${secret_sql}
SET allow_extension_repositories = 'allowed';
CREATE EXTENSION REPOSITORY smoke_repo WITH PREFIX '$(sql_quote "$repository_url")' USING PUBLIC KEY '$public_key';
INSTALL $name FROM smoke_repo$version_clause;
LOAD $name FROM smoke_repo;
SELECT 'smoke-test-loaded:' || loaded FROM duckdb_extensions() WHERE extension_name = '$name';
EOF
	)

	info "Smoke test: $name on DuckDB $version from $repository_url"
	# The SQL goes in through stdin: it may hold credentials, which must not show up in the process list.
	if output=$(env -u AI_AGENT HOME="$home_dir" "$duckdb_cli" -batch -bail -noheader -list <"$sql_file" 2>&1); then
		case "$output" in
		*smoke-test-loaded:true*) info "  installed and loaded" ;;
		*)
			error "$name on DuckDB $version: LOAD ran, but the extension isn't listed as loaded. Output: $output"
			failed=1
			;;
		esac
	else
		error "$name on DuckDB $version failed the smoke test, although it has been uploaded. Output: $output"
		failed=1
	fi
	rm -rf "$home_dir"
done <"$WORK_DIR/tmp/smoke"

[ "$failed" = "0" ] || exit 1
