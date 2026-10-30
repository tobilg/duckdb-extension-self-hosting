#!/usr/bin/env bash
# Uploads the signed tree: the key file first, then versioned paths, then latest paths. That way a client that sees a
# new latest object can already fetch everything it refers to, and a refused versioned upload leaves latest untouched.

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

export_s3_credentials

rclone="$WORK_DIR/bin/rclone"
signed_dir="$WORK_DIR/signed"
manifest="$WORK_DIR/manifest.jsonl"
endpoint=${INPUT_S3_ENDPOINT:-}
provider=${INPUT_S3_PROVIDER:-$(detect_s3_provider "$endpoint")}
region=$(s3_region)
if [ -z "$region" ] && [ "$provider" = "Cloudflare" ]; then region=auto; fi

prefix=$(normalize_prefix "${INPUT_S3_PREFIX:-}")
destination="$INPUT_S3_BUCKET"
if [ -n "$prefix" ]; then destination="$destination/$prefix"; fi

flags=(--s3-provider "$provider" --s3-env-auth --s3-no-check-bucket --stats=0 --config=/dev/null)
if [ -n "$endpoint" ]; then flags+=(--s3-endpoint "$endpoint"); fi
if [ -n "$region" ]; then flags+=(--s3-region "$region"); fi

info "Publishing to $destination (provider $provider)"

# --checksum compares content, not modification time: a re-run produces identical bytes and uploads nothing.
upload_latest_object() { # <object> <encoding>
	local object=$1 encoding=$2
	if [ "$encoding" = "br" ]; then
		"$rclone" copyto "$signed_dir/$object" ":s3:$destination/$object" "${flags[@]}" --checksum \
			--header-upload "Content-Encoding: br" --header-upload "Content-Type: application/wasm" ||
			die "Uploading $object failed."
	else
		"$rclone" copyto "$signed_dir/$object" ":s3:$destination/$object" "${flags[@]}" --checksum ||
			die "Uploading $object failed."
	fi
	info "  $object"
}

upload_versioned_object() { # <object>
	local object=$1 directory file
	if is_true "${INPUT_OVERWRITE_VERSIONED:-false}"; then
		"$rclone" copyto "$signed_dir/$object" ":s3:$destination/$object" "${flags[@]}" --checksum ||
			die "Uploading $object failed."
	else
		# copyto ignores --immutable, only the sync path of `rclone copy` enforces it.
		directory=$(dirname "$object")
		file=$(basename "$object")
		"$rclone" copy "$signed_dir/$directory" ":s3:$destination/$directory" "${flags[@]}" --checksum --immutable --include "/$file" ||
			die "Uploading $object failed. If it already exists with different content, either publish a new extension version or set 'overwrite-versioned: true'. Rebuilding produces different bytes, so re-running a release with new builds hits this."
	fi
	info "  $object"
}

key_file_object=.well-known/duckdb-extension-repo.json
if [ -f "$signed_dir/$key_file_object" ]; then
	upload_latest_object "$key_file_object" ""
fi

jq -r 'select(.channel == "versioned") | .object' "$manifest" >"$WORK_DIR/tmp/versioned"
while IFS= read -r object; do
	upload_versioned_object "$object"
done <"$WORK_DIR/tmp/versioned"

jq -r 'select(.channel == "latest") | [.object, .encoding] | @tsv' "$manifest" >"$WORK_DIR/tmp/latest"
while IFS="$(printf '\t')" read -r object encoding; do
	upload_latest_object "$object" "$encoding"
done <"$WORK_DIR/tmp/latest"

info "Upload complete."
