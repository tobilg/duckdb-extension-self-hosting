#!/usr/bin/env bash
# Reads every object back through the prefix clients use and compares the bytes, for all platforms. That catches a wrong
# repository-url and a CDN serving an older object, without running anything that was downloaded.

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

export_s3_credentials

bundle_dir="$WORK_DIR/bundle"
signed_dir="$bundle_dir/signed"
manifest="$bundle_dir/manifest.jsonl"
tmp_dir="$WORK_DIR/tmp/check"
repository=$(repository_url)
key_file_object=.well-known/duckdb-extension-repo.json
tab=$(printf '\t')
check_jobs=4
# A CDN can keep a 404 from before the upload: Cloudflare does for 3 minutes, on paths it caches. The limit is for the whole
# check, because a wrong repository-url would otherwise wait this long for every object.
retry_seconds=${REPOSITORY_RETRY_SECONDS:-240}
retry_interval=${REPOSITORY_RETRY_INTERVAL:-15}
retry_until=$(($(date +%s) + retry_seconds))

mkdir -p "$tmp_dir"
info "Checking what $repository serves"

fetch_url() { # <object> <local file>: prints the HTTP status
	local http_status encoding=identity
	# Wasm objects ask for Brotli, because a CDN may otherwise unpack them, which DuckDB-Wasm's browser would never see. The rest
	# is compared byte for byte, and a CDN may compress a JSON key file for a client that accepts that.
	case "$1" in
	*.wasm) encoding=br ;;
	esac
	# DuckDB doesn't follow redirects on plain HTTP, so neither does this.
	case "$repository" in
	http://*) http_status=$(curl -sS --connect-timeout 30 --max-time 600 --retry 3 -H "Accept-Encoding: $encoding" -o "$2" -w '%{http_code}' "$repository/$1") || http_status="no response" ;;
	*) http_status=$(curl -sSL --connect-timeout 30 --max-time 600 --retry 3 -H "Accept-Encoding: $encoding" -o "$2" -w '%{http_code}' "$repository/$1") || http_status="no response" ;;
	esac
	printf '%s' "$http_status"
}

fetch() { # <object> <local file>
	local http_status announced=false
	case "$repository" in
	s3://*)
		read_s3_object "${repository#s3://}/$1" "$2" || {
			error "$repository/$1 doesn't exist, although it has been uploaded. Check that 'repository-url' matches the bucket and 's3-prefix'."
			return 1
		}
		return 0
		;;
	esac
	http_status=$(fetch_url "$1" "$2")
	while [ "$http_status" = "404" ] && [ "$(date +%s)" -lt "$retry_until" ]; do
		if [ "$announced" = "false" ]; then
			info "  $1 answered with 404. A CDN can keep one from before the upload, so this tries again for up to $retry_seconds seconds."
			announced=true
		fi
		sleep "$retry_interval"
		http_status=$(fetch_url "$1" "$2")
	done
	case "$http_status" in
	200) ;;
	404)
		error "$repository/$1 answered with 404, although it has been uploaded. Check that 'repository-url' matches the bucket and 's3-prefix', and that the bucket is public. If they're right, a CDN may still have a 404 from before the upload: purge that path, or re-run this job later."
		return 1
		;;
	*)
		error "$repository/$1 answered with $http_status, although it has been uploaded. Check that 'repository-url' matches the bucket and 's3-prefix', and that the bucket is public."
		return 1
		;;
	esac
}

# Takes the unpacked binary too, because a CDN can serve either form of a Wasm object.
check_object() { # <index> <object> <sha256> <binary sha256>
	local file="$tmp_dir/$1" actual
	fetch "$2" "$file" || exit 1
	actual=$(sha256_of "$file")
	rm -f "$file"
	if [ "$actual" != "$3" ] && [ "$actual" != "$4" ]; then
		error "$repository/$2 serves a different build than the one just uploaded. Check that 'repository-url' matches the bucket and 's3-prefix', and whether a CDN is caching an older object."
		exit 1
	fi
	info "  $2"
}

check_key_file() {
	local file="$tmp_dir/key-file"
	fetch "$key_file_object" "$file" || exit 1
	if ! cmp -s "$file" "$signed_dir/$key_file_object"; then
		error "$repository/$key_file_object serves a different key file than the one just uploaded. Check whether a CDN is caching an older object."
		exit 1
	fi
	info "  $key_file_object"
}

jq -r '[.object, .sha256, .binary_sha256] | @tsv' "$manifest" >"$WORK_DIR/tmp/objects"
index=0
while IFS="$tab" read -r object digest binary_digest; do
	index=$((index + 1))
	pool_start "$check_jobs" check_object "$index" "$object" "$digest" "$binary_digest"
done <"$WORK_DIR/tmp/objects"
if [ -f "$signed_dir/$key_file_object" ]; then
	pool_start "$check_jobs" check_key_file
fi
pool_wait
[ "$pool_failed" = "0" ] || exit 1

info "The repository serves what was uploaded."
