#!/usr/bin/env bash
# Proves that the signed builds install and load before anything is uploaded: downloads the DuckDB CLI matching each
# version, pins the key in a throwaway home, and runs INSTALL and LOAD by repository name with the signed tree as a local
# repository. Only the runner's own platform can be tested, so run this on every type of runner you can. This runs the
# extension's native code, which is why setup.sh keeps this mode away from every secret.

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

manifest="$WORK_DIR/bundle/manifest.jsonl"
signed_dir="$WORK_DIR/bundle/signed"
public_key=$(cat "$WORK_DIR/bundle/keys/public_0.pem")
verified="$WORK_DIR/verified"
timeout_seconds=${SMOKE_TEST_TIMEOUT:-300}
platform=$(runner_platform)

: >"$verified"

if [ -z "$platform" ]; then
	notice "Smoke test skipped: DuckDB publishes no CLI for this runner."
	exit 0
fi

# Each extension and DuckDB version once: the latest path if it was published, otherwise the versioned one.
jq -s -r --arg platform "$platform" '
	map(select(.platform == $platform and .kind == "native"))
	| group_by([.name, .duckdb_version])
	| map((map(select(.channel == "latest")) | first) // first)
	| .[] | [.name, .duckdb_version, .channel, .extension_version] | @tsv
' "$manifest" >"$WORK_DIR/tmp/smoke"

if [ ! -s "$WORK_DIR/tmp/smoke" ]; then
	notice "Smoke test skipped: no build for this runner's platform ($platform)."
	exit 0
fi

cli=$(cli_asset "$platform")

# Prints the path of the CLI for a version. Returns 2 if that version has no release, as with builds of a commit, and 1
# if the CLI couldn't be fetched, which says nothing about the extension but means it can't be tested.
fetch_cli() { # <version>
	local version=$1 dir="$WORK_DIR/cli/$1" http_status
	if [ ! -x "$dir/duckdb" ]; then
		mkdir -p "$dir"
		# No --fail, because that hides the status. --retry still covers temporary failures. There's no hash to check this
		# download against, so it can't be allowed to leave HTTPS.
		http_status=$(curl -sSL --proto '=https' --proto-redir '=https' --connect-timeout 30 --max-time 600 --retry 3 -o "$dir/cli.tar.gz" -w '%{http_code}' \
			"https://github.com/duckdb/duckdb/releases/download/$version/$cli.tar.gz") || http_status="no response"
		case "$http_status" in
		200) ;;
		404) return 2 ;;
		*)
			error "Couldn't download the DuckDB CLI for $version ($http_status), so the smoke test can't run. Nothing has been uploaded, and re-running is safe."
			return 1
			;;
		esac
		if ! tar -xzf "$dir/cli.tar.gz" -C "$dir"; then
			error "Couldn't unpack the DuckDB CLI for $version, so the smoke test can't run. Nothing has been uploaded, and re-running is safe."
			return 1
		fi
		rm -f "$dir/cli.tar.gz"
		if [ ! -x "$dir/duckdb" ]; then
			local found
			found=$(find "$dir" -type f -name duckdb -perm -u+x -print)
			if [ -z "$found" ]; then
				error "The DuckDB CLI archive for $version has no duckdb binary, so the smoke test can't run. Nothing has been uploaded, and re-running is safe."
				return 1
			fi
			mv "$found" "$dir/duckdb"
		fi
	fi
	printf '%s' "$dir/duckdb"
}

# Keeps variables of this job out of the extension's environment. This isn't a sandbox: native code running as this user can
# reach anything else this user can, so what really protects your secrets is that this job has none.
cli_env=(env -i "PATH=$PATH")
for variable in TMPDIR HTTP_PROXY HTTPS_PROXY NO_PROXY ALL_PROXY http_proxy https_proxy no_proxy all_proxy \
	HTTP_PROXY_USERNAME HTTP_PROXY_PASSWORD http_proxy_username http_proxy_password SSL_CERT_FILE SSL_CERT_DIR; do
	if [ -n "${!variable:-}" ]; then cli_env+=("$variable=${!variable}"); fi
done

# The semicolon on a line of its own also ends SQL that stops without one, or with a comment.
setup_sql=
if [ -n "${INPUT_SMOKE_TEST_SETUP_SQL:-}" ]; then
	setup_sql="$INPUT_SMOKE_TEST_SETUP_SQL
;"
fi

failed=0
tested=0
while IFS="$(printf '\t')" read -r name version channel extension_version; do
	fetch_status=0
	duckdb_cli=$(fetch_cli "$version") || fetch_status=$?
	case "$fetch_status" in
	0) tested=$((tested + 1)) ;;
	2)
		notice "Smoke test skipped for $name on $version: no DuckDB CLI release exists for that version."
		continue
		;;
	*)
		failed=1
		continue
		;;
	esac

	version_clause=
	if [ "$channel" = "versioned" ]; then version_clause=" VERSION '$(sql_quote "$extension_version")'"; fi

	home_dir=$(mktemp -d "$WORK_DIR/tmp/home.XXXXXX")
	sql_file="$home_dir/smoke.sql"
	cat >"$sql_file" <<EOF
${setup_sql}
SET allow_extension_repositories = 'allowed';
CREATE EXTENSION REPOSITORY smoke_repo WITH PREFIX '$(sql_quote "$signed_dir")' USING PUBLIC KEY '$public_key';
INSTALL "$name" FROM smoke_repo$version_clause;
LOAD "$name" FROM smoke_repo;
SELECT 'smoke-test-loaded:' || loaded FROM duckdb_extensions() WHERE extension_name = '$name';
EOF

	info "Smoke test: $name on DuckDB $version"
	cli_status=0
	output=$(run_with_timeout "$timeout_seconds" "$sql_file" "${cli_env[@]}" HOME="$home_dir" "$duckdb_cli" -batch -bail -noheader -list 2>&1) || cli_status=$?
	case "$cli_status" in
	0)
		if [[ "$output" != *smoke-test-loaded:true* ]]; then
			error "$name on DuckDB $version: LOAD ran, but the extension isn't listed as loaded. Nothing has been uploaded. Output: $output"
			failed=1
		else
			info "  installed and loaded"
			printf '%s\t%s\t%s\n' "$name" "$version" "$platform" >>"$verified"
		fi
		;;
	137 | 143)
		error "$name on DuckDB $version: the smoke test timed out after $timeout_seconds seconds, so it was stopped. Nothing has been uploaded. Output: $output"
		failed=1
		;;
	*)
		error "$name on DuckDB $version failed the smoke test. Nothing has been uploaded. Output: $output"
		failed=1
		;;
	esac
	rm -rf "$home_dir"
done <"$WORK_DIR/tmp/smoke"

[ "$failed" = "0" ] || exit 1
[ "$tested" != "0" ] || warn "The smoke test didn't test anything: no published DuckDB version has a CLI release, so these builds are unverified."
