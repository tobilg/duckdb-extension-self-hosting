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

mkdir -p "$tmp_dir"
info "Checking what $repository serves"

fetch() { # <object> <local file>
	local http_status encoding=identity
	case "$repository" in
	s3://*)
		read_s3_object "${repository#s3://}/$1" "$2" || {
			error "$repository/$1 doesn't exist, although it has been uploaded. Check that 'repository-url' matches the bucket and 's3-prefix'."
			return 1
		}
		return 0
		;;
	esac
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
	if [ "$http_status" != "200" ]; then
		error "$repository/$1 answered with $http_status, although it has been uploaded. Check that 'repository-url' matches the bucket and 's3-prefix', and that the bucket is public."
		return 1
	fi
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
