#!/usr/bin/env bash
# Sets the outputs and writes a job summary: what was signed, tested or uploaded, and in the end the SQL clients need.

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

bundle_dir="$WORK_DIR/bundle"
manifest="$bundle_dir/manifest.jsonl"
verified="$WORK_DIR/verified"
uploaded="$WORK_DIR/uploaded"
mode=${INPUT_MODE:-}

# Signing failed, or the signed tree never arrived, so there's nothing to report.
[ -s "$manifest" ] || exit 0

set_output_block files "$(jq -s -c '.' "$manifest")"

summary=${GITHUB_STEP_SUMMARY:-/dev/null}
fence='```'

print_table() {
	printf '| Extension | Platform | ABI | DuckDB | Version | Object |\n| --- | --- | --- | --- | --- | --- |\n'
	jq -s -r 'sort_by(.name, .duckdb_version, .platform, .channel) | .[] | "| \(.name) | \(.platform) | \(.abi) | \(.duckdb_version) | \(.extension_version) | `\(.object)` |"' "$manifest"
}

# The SQL pins every key, so that clients can follow a rotation to the reserve key without creating the repository again.
print_client_sql() { # <repository url>
	local keys_sql="" key_count=0 using name
	while [ -f "$bundle_dir/keys/public_$key_count.pem" ]; do
		keys_sql="$keys_sql${keys_sql:+, }'$(cat "$bundle_dir/keys/public_$key_count.pem")'"
		key_count=$((key_count + 1))
	done
	if [ "$key_count" = "1" ]; then using='USING PUBLIC KEY'; else using='USING PUBLIC KEYS'; fi

	printf '\n### Use it\n\nPin the key once per machine, then install and load by repository name:\n\n'
	printf '%ssql\n' "$fence"
	printf "SET allow_extension_repositories = 'allowed';\n"
	printf "CREATE EXTENSION REPOSITORY IF NOT EXISTS my_repo\n    WITH PREFIX '%s'\n    %s %s;\n" "$(sql_quote "$1")" "$using" "$keys_sql"
	while IFS= read -r name; do
		printf 'INSTALL "%s" FROM my_repo;\nLOAD "%s" FROM my_repo;\n' "$name" "$name"
	done <<EOF
$(jq -s -r '[.[].name] | unique | .[]' "$manifest")
EOF
	printf '%s\n' "$fence"
	# shellcheck disable=SC2016 # the backticks are Markdown
	case "$1" in
	s3://*) printf '\nThis prefix needs a `CREATE SECRET (TYPE s3, ...)` on each client for `INSTALL`.\n' ;;
	esac
	if [ "$(jq -s '[.[] | select(.kind == "wasm")] | length' "$manifest")" != "0" ]; then
		printf '\nWasm builds were published too. Browsers need CORS on the bucket, and see the README for the client setup.\n'
	fi
}

case "$mode" in
sign)
	{
		printf '## Signed DuckDB extensions\n\n'
		print_table
	} >>"$summary"
	;;
verify)
	{
		printf '## Tested DuckDB extensions\n\n'
		if [ "${SMOKE_TEST_OUTCOME:-}" = "failure" ]; then
			printf '> **The smoke test failed.** Nothing has been uploaded. See the log of this run.\n\n'
		fi
		if [ -s "$verified" ]; then
			printf '| Extension | DuckDB | Platform |\n| --- | --- | --- |\n'
			awk -F'\t' '{ printf "| %s | %s | %s |\n", $1, $2, $3 }' "$verified"
		else
			printf 'No build could be tested on this runner.\n'
		fi
	} >>"$summary"
	;;
publish)
	url=$(repository_url)
	set_output repository-url "$url"
	if [ -f "$uploaded" ]; then
		set_output_block uploaded-objects "$(jq -R . "$uploaded" | jq -s -c .)"
	fi
	{
		printf '## Published DuckDB extensions\n\n'
		if [ "${UPLOAD_OUTCOME:-}" = "failure" ]; then
			printf '> **The upload failed**, so this release is incomplete. Re-run this job.\n\n'
			if [ -s "$uploaded" ]; then
				printf 'Only these objects are live:\n\n'
				# shellcheck disable=SC2016 # the backticks are Markdown
				sed 's/.*/- `&`/' "$uploaded"
			else
				printf 'Nothing was uploaded.\n'
			fi
		else
			if [ "${CHECK_OUTCOME:-}" = "failure" ]; then
				printf '> **The repository check failed**, and these objects are already live. See the log of this run.\n\n'
			fi
			print_table
			print_client_sql "$url"
		fi
	} >>"$summary"
	;;
esac
