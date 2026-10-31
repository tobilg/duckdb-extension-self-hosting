#!/usr/bin/env bash
# Uploads the signed tree: versioned paths, then the key file, then latest paths. That way a refused versioned upload
# leaves the key file and latest untouched, and a client that sees a new latest object can already fetch what it refers to.
# Before any of that it stops a release that would change the signing key, move latest back by accident or change a published
# version, because the signed tree alone can't show any of them.

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

export_s3_credentials

bundle_dir="$WORK_DIR/bundle"
signed_dir="$bundle_dir/signed"
manifest="$bundle_dir/manifest.jsonl"
tmp_dir="$WORK_DIR/tmp"
uploaded="$WORK_DIR/uploaded"
destination=$(s3_destination)
key_file_object=.well-known/duckdb-extension-repo.json
tab=$(printf '\t')
# Latest paths and the key file keep their names between releases, so caches must ask the bucket before reusing them. A
# versioned object only changes through 'overwrite-versioned', which shouldn't leave stale copies around for long.
latest_cache='no-cache'
versioned_cache='public, max-age=86400'
upload_jobs=4

: >"$uploaded"

info "Publishing to $destination (provider $(s3_provider))"

# Clients pin keys, so a key that isn't in the bucket's key file breaks every one of them on their next FORCE INSTALL.
check_key_file() {
	local remote="$tmp_dir/remote-key-file" listed signing_key allowed key dropped=0 own_keys="" index=0
	if ! read_s3_object "$destination/$key_file_object" "$remote"; then
		info "The bucket has no key file yet, so there's no earlier key to compare with."
		return 0
	fi
	allowed=${INPUT_ALLOW_KEY_CHANGE:-false}
	if ! listed=$(jq -r '.signature_keys[] | gsub("-----[A-Z ]+-----"; "") | gsub("\\s"; "")' "$remote" 2>/dev/null); then
		if ! is_true "$allowed"; then
			die "The key file in the bucket isn't valid, so the signing key can't be compared with it. Set 'allow-key-change: true' to replace it."
		fi
		warn "Replacing a key file in the bucket that isn't valid."
		return 0
	fi
	signing_key=$(compact_key "$bundle_dir/keys/public_0.pem")
	if ! grep -Fqx -- "$signing_key" <<<"$listed"; then
		if ! is_true "$allowed"; then
			die "The signing key ($(fingerprint_of "$bundle_dir/keys/public_0.pem")) isn't in the bucket's key file, so clients that pinned those keys would reject this release. Check that the job uses the right secret. If you're rotating keys, see the README, and set 'allow-key-change: true'."
		fi
		warn "The signing key ($(fingerprint_of "$bundle_dir/keys/public_0.pem")) isn't in the bucket's key file. Clients have to pin it before they can install this release."
	fi
	[ -f "$signed_dir/$key_file_object" ] || return 0
	while [ -f "$bundle_dir/keys/public_$index.pem" ]; do
		own_keys="$own_keys$(compact_key "$bundle_dir/keys/public_$index.pem")
"
		index=$((index + 1))
	done
	while IFS= read -r key; do
		if ! grep -Fqx -- "$key" <<<"$own_keys"; then dropped=$((dropped + 1)); fi
	done <<<"$listed"
	if [ "$dropped" != "0" ]; then
		warn "The new key file drops $dropped key(s) from the one in the bucket. New clients won't be able to install objects still signed with them. List them in 'additional-public-keys' until those objects are re-signed."
	fi
}

check_live_version() { # <index> <object> <kind> <name> <duckdb version> <platform> <new version>
	local existing="$tmp_dir/existing-$1" object=$2 kind=$3 name=$4 duckdb_version=$5 platform=$6 new_version=$7 size old_version
	[ -n "$new_version" ] || return 0
	read_s3_object "$destination/$object" "$existing.packed" || return 0
	if [ "$kind" = "wasm" ]; then
		if ! command -v brotli >/dev/null 2>&1; then
			warn "Can't compare $object with what's live, because brotli isn't installed."
			return 0
		fi
		if ! brotli -d -c "$existing.packed" >"$existing"; then
			warn "Can't compare $object with what's live, because it isn't valid Brotli."
			return 0
		fi
	elif ! gunzip -c "$existing.packed" >"$existing" 2>/dev/null; then
		warn "Can't compare $object with what's live, because it isn't valid gzip."
		return 0
	fi
	size=$(file_size "$existing")
	[ "$size" -ge 512 ] || return 0
	old_version=$(footer_field "$existing" "$size" 384)
	case "$(compare_versions "$new_version" "$old_version")" in
	lt) die "$name for $platform on DuckDB $duckdb_version: $new_version is older than $old_version, which clients get now. Set 'allow-downgrade: true' if that's what you want." ;;
	unknown)
		if [ "$new_version" != "$old_version" ]; then
			notice "$name for $platform on DuckDB $duckdb_version: can't tell whether $new_version is newer than $old_version, because they aren't both major.minor.patch versions."
		fi
		;;
	esac
}

# Re-running an older release, or two tags pushed out of order, would otherwise move clients back. The footer of what's live is
# the only reliable record of its version. This reads every platform, because they can be on different versions after a release
# that only some of them made, and a platform with no live object says nothing about the others.
check_downgrade() {
	if is_true "${INPUT_ALLOW_DOWNGRADE:-false}"; then return 0; fi
	local index=0 object kind name duckdb_version platform new_version
	jq -r 'select(.channel == "latest") | [.object, .kind, .name, .duckdb_version, .platform, .footer_extension_version] | @tsv' "$manifest" >"$tmp_dir/live-versions"
	while IFS="$tab" read -r object kind name duckdb_version platform new_version; do
		index=$((index + 1))
		pool_start "$upload_jobs" check_live_version "$index" "$object" "$kind" "$name" "$duckdb_version" "$platform" "$new_version"
	done <"$tmp_dir/live-versions"
	pool_wait
	[ "$pool_failed" = "0" ] || exit 1
	rm -f "$tmp_dir"/existing-*
}

check_versioned_object() { # <index> <object>
	local existing="$tmp_dir/existing-$1"
	read_s3_object "$destination/$2" "$existing" || return 0
	if ! cmp -s "$existing" "$signed_dir/$2"; then
		die "$2 already exists with different content. Nothing has been uploaded. Publish a new extension version, or set 'overwrite-versioned: true' to replace it."
	fi
}

# A refused release has to stop here. --immutable only refuses object by object, so by then its other platforms would already
# be live under that version, and could never change either. --immutable stays, for a release that gets there in between.
check_versioned_objects() {
	if is_true "${INPUT_OVERWRITE_VERSIONED:-false}"; then return 0; fi
	local index=0 object
	while IFS= read -r object; do
		index=$((index + 1))
		pool_start "$upload_jobs" check_versioned_object "$index" "$object"
	done <"$tmp_dir/versioned"
	pool_wait
	[ "$pool_failed" = "0" ] || exit 1
	rm -f "$tmp_dir"/existing-*
}

# --checksum compares content, not modification time: a re-run produces identical bytes and uploads nothing.
upload_latest_object() { # <object> <encoding>
	local object=$1 encoding=$2
	if [ "$encoding" = "br" ]; then
		rclone_s3 copyto "$signed_dir/$object" ":s3:$destination/$object" --checksum --header-upload "Cache-Control: $latest_cache" \
			--header-upload "Content-Encoding: br" --header-upload "Content-Type: application/wasm" ||
			die "Uploading $object failed."
	else
		rclone_s3 copyto "$signed_dir/$object" ":s3:$destination/$object" --checksum --header-upload "Cache-Control: $latest_cache" ||
			die "Uploading $object failed."
	fi
	printf '%s\n' "$object" >>"$uploaded"
	info "  $object"
}

upload_versioned_object() { # <object>
	local object=$1 directory file
	if is_true "${INPUT_OVERWRITE_VERSIONED:-false}"; then
		rclone_s3 copyto "$signed_dir/$object" ":s3:$destination/$object" --checksum --header-upload "Cache-Control: $versioned_cache" ||
			die "Uploading $object failed."
	else
		# copyto ignores --immutable, only the sync path of `rclone copy` enforces it.
		directory=$(dirname "$object")
		file=$(basename "$object")
		rclone_s3 copy "$signed_dir/$directory" ":s3:$destination/$directory" --checksum --immutable --include "/$file" --header-upload "Cache-Control: $versioned_cache" ||
			die "Uploading $object failed. If it already exists with different content, either publish a new extension version or set 'overwrite-versioned: true'. Rebuilding produces different bytes, so re-running a release with new builds hits this."
	fi
	printf '%s\n' "$object" >>"$uploaded"
	info "  $object"
}

check_key_file
check_downgrade
jq -r 'select(.channel == "versioned") | .object' "$manifest" >"$tmp_dir/versioned"
check_versioned_objects

while IFS= read -r object; do
	pool_start "$upload_jobs" upload_versioned_object "$object"
done <"$tmp_dir/versioned"
pool_wait
[ "$pool_failed" = "0" ] || exit 1

if [ -f "$signed_dir/$key_file_object" ]; then
	upload_latest_object "$key_file_object" ""
fi

jq -r 'select(.channel == "latest") | [.object, .encoding] | @tsv' "$manifest" >"$tmp_dir/latest"
while IFS="$tab" read -r object encoding; do
	pool_start "$upload_jobs" upload_latest_object "$object" "$encoding"
done <"$tmp_dir/latest"
pool_wait
[ "$pool_failed" = "0" ] || exit 1

info "Upload complete."
