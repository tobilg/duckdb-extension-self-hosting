#!/usr/bin/env bash
# Sets the outputs and writes a job summary with the SQL clients need.

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

manifest="$WORK_DIR/manifest.jsonl"
public_key=$(cat "$WORK_DIR/keys/signing_key.pub")
mode=${INPUT_MODE:-publish}

set_output_block files "$(jq -s -c '.' "$manifest")"

repository_url=
if [ "$mode" = "publish" ]; then
	repository_url=${INPUT_REPOSITORY_URL:-}
	if [ -n "$repository_url" ]; then
		while [ "${repository_url%/}" != "$repository_url" ]; do repository_url=${repository_url%/}; done
	else
		prefix=$(normalize_prefix "${INPUT_S3_PREFIX:-}")
		repository_url="s3://$INPUT_S3_BUCKET"
		if [ -n "$prefix" ]; then repository_url="$repository_url/$prefix"; fi
	fi
fi
set_output repository-url "$repository_url"

summary=${GITHUB_STEP_SUMMARY:-/dev/null}
first_name=$(jq -s -r '.[0].name' "$manifest")
fence='```'

{
	if [ "$mode" = "publish" ]; then
		printf '## Published DuckDB extensions\n\n'
	else
		printf '## Signed DuckDB extensions\n\n'
	fi
	printf '| Extension | Platform | ABI | DuckDB | Version | Object |\n| --- | --- | --- | --- | --- | --- |\n'
	jq -s -r 'sort_by(.name, .duckdb_version, .platform, .channel) | .[] | "| \(.name) | \(.platform) | \(.abi) | \(.duckdb_version) | \(.extension_version) | `\(.object)` |"' "$manifest"

	if [ "$mode" = "publish" ]; then
		printf '\n### Use it\n\nPin the key once per machine, then install and load by repository name:\n\n'
		printf '%ssql\n' "$fence"
		printf "SET allow_extension_repositories = 'allowed';\n"
		printf "CREATE EXTENSION REPOSITORY IF NOT EXISTS my_repo\n    WITH PREFIX '%s'\n    USING PUBLIC KEY '%s';\n" "$repository_url" "$public_key"
		printf 'INSTALL %s FROM my_repo;\nLOAD %s FROM my_repo;\n' "$first_name" "$first_name"
		printf '%s\n' "$fence"
		# shellcheck disable=SC2016 # the backticks are Markdown
		case "$repository_url" in
		s3://*) printf '\nThis prefix needs a `CREATE SECRET (TYPE s3, ...)` on each client for `INSTALL`.\n' ;;
		esac
		if [ "$(jq -s '[.[] | select(.kind == "wasm")] | length' "$manifest")" != "0" ]; then
			printf '\nWasm builds were published too. Browsers need CORS on the bucket, and see the README for the client setup.\n'
		fi
	fi
} >>"$summary"
