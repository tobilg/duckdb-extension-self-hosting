#!/usr/bin/env bash
# Finds every extension binary, validates its footer, signs and verifies it, and builds the repository tree in
# $WORK_DIR/signed plus a manifest of what ended up there. The footer decides platform and versions, not the artifact
# name, so this works with any build system.

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
signed_dir="$WORK_DIR/signed"
tmp_dir="$WORK_DIR/tmp"
manifest="$WORK_DIR/manifest.jsonl"
seen="$WORK_DIR/seen"
key_file="$WORK_DIR/keys/signing_key.pem"
public_key_file="$WORK_DIR/keys/signing_key.pub"
upload_latest=${INPUT_UPLOAD_LATEST:-true}
upload_versioned=${INPUT_UPLOAD_VERSIONED:-true}
safe_word='^[A-Za-z0-9._-]+$'
safe_name='^[A-Za-z0-9_-]+$'
safe_platform='^[a-z0-9_]+$'

: >"$manifest"
: >"$seen"

[ -d "$SOURCE_DIR" ] || die "Source directory doesn't exist: $SOURCE_DIR"

if [ -n "${INPUT_EXTENSION_VERSION:-}" ] && [[ ! "$INPUT_EXTENSION_VERSION" =~ $safe_word ]]; then
	die "Input 'extension-version' contains characters that can't be used in a path: $INPUT_EXTENSION_VERSION"
fi
for version in $(split_list "${INPUT_DUCKDB_VERSION:-}"); do
	[[ "$version" =~ $safe_word ]] || die "Input 'duckdb-version' contains characters that can't be used in a path: $version"
done

# Puts the same file at a second object path without using the disk twice.
place() { # <source> <object path>
	mkdir -p "$(dirname "$signed_dir/$2")"
	ln -f "$1" "$signed_dir/$2" 2>/dev/null || cp -f "$1" "$signed_dir/$2"
}

record() { # <name> <platform> <kind> <abi> <duckdb version> <extension version> <channel> <object> <sha256> <encoding>
	jq -n -c --arg name "$1" --arg platform "$2" --arg kind "$3" --arg abi "$4" --arg duckdb_version "$5" \
		--arg extension_version "$6" --arg channel "$7" --arg object "$8" --arg sha256 "$9" --arg encoding "${10}" \
		'{name: $name, platform: $platform, kind: $kind, abi: $abi, duckdb_version: $duckdb_version,
		  extension_version: $extension_version, channel: $channel, object: $object, sha256: $sha256, encoding: $encoding}' \
		>>"$manifest"
}

process_binary() { # <file>
	local file=$1 base name kind size magic platform footer_version extension_version abi targets target
	base=$(basename "$file")
	case "$base" in
	*.duckdb_extension.wasm)
		name=${base%.duckdb_extension.wasm}
		kind=wasm
		;;
	*)
		name=${base%.duckdb_extension}
		kind=native
		;;
	esac
	[[ "$name" =~ $safe_name ]] || die "$file: the extension name can't be used in a path."

	if [ -n "${INPUT_EXTENSION_NAME:-}" ] && [ "$name" != "$INPUT_EXTENSION_NAME" ]; then
		info "Skipping $base: not '$INPUT_EXTENSION_NAME'."
		return 0
	fi

	size=$(file_size "$file")
	[ "$size" -ge 512 ] || die "$file: too small to be a DuckDB extension, which ends in a 512-byte footer."

	magic=$(footer_field "$file" "$size" 288)
	[ "$magic" = "4" ] || die "$file: the footer's magic value is invalid, so this isn't a DuckDB extension, or the footer was damaged. Running 'strip' on a binary does this."
	platform=$(footer_field "$file" "$size" 320)
	footer_version=$(footer_field "$file" "$size" 352)
	extension_version=$(footer_field "$file" "$size" 384)
	abi=$(footer_field "$file" "$size" 416)

	[[ "$platform" =~ $safe_platform ]] || die "$file: the platform in the footer isn't valid: '$platform'"
	[[ "$footer_version" =~ $safe_word ]] || die "$file: the DuckDB version in the footer isn't valid: '$footer_version'"
	[[ "$extension_version" =~ $safe_word ]] || die "$file: the extension version in the footer isn't valid: '$extension_version'"

	case "$platform" in
	wasm_*) [ "$kind" = "wasm" ] || die "$file: the footer says '$platform', but the file doesn't end in .duckdb_extension.wasm." ;;
	*) [ "$kind" = "native" ] || die "$file: the file ends in .duckdb_extension.wasm, but the footer says '$platform'." ;;
	esac

	if in_list "$platform" "${INPUT_EXCLUDE_PLATFORMS:-}"; then
		info "Skipping $base for $platform: excluded."
		return 0
	fi

	case "$abi" in
	'' | CPP | C_STRUCT_UNSTABLE)
		abi=${abi:-CPP}
		if [ -n "${INPUT_DUCKDB_VERSION:-}" ] && ! in_list "$footer_version" "$INPUT_DUCKDB_VERSION"; then
			die "$file: built for DuckDB '$footer_version', which isn't in 'duckdb-version' ($INPUT_DUCKDB_VERSION). $abi builds only load in the exact version they were built for."
		fi
		targets=$footer_version
		;;
	C_STRUCT)
		[ -n "${INPUT_DUCKDB_VERSION:-}" ] || die "$file: C_STRUCT builds record the C API version ($footer_version), not a DuckDB version. Set 'duckdb-version' to the DuckDB versions to publish to, such as 'v2.0.0'."
		targets=$INPUT_DUCKDB_VERSION
		;;
	*) die "$file: unknown ABI type in the footer: '$abi'" ;;
	esac

	if [ -n "${INPUT_EXTENSION_VERSION:-}" ]; then extension_version=$INPUT_EXTENSION_VERSION; fi

	local identity="$name $platform $footer_version"
	if grep -Fqx "$identity" "$seen"; then
		warn "Skipping $file: another binary of $name for $platform and $footer_version was already signed."
		return 0
	fi
	printf '%s\n' "$identity" >>"$seen"

	info "Signing $name for $platform ($abi, DuckDB $footer_version, extension $extension_version)"

	local unsigned="$tmp_dir/unsigned" hash="$tmp_dir/hash" signature="$tmp_dir/signature" signed="$tmp_dir/signed" packed="$tmp_dir/packed"
	head -c $((size - 256)) "$file" >"$unsigned"
	bash "$script_dir/compute-extension-hash.sh" "$unsigned" >"$hash"
	openssl pkeyutl -sign -in "$hash" -inkey "$key_file" -pkeyopt digest:sha256 -out "$signature"
	[ "$(file_size "$signature")" = "256" ] || die "$file: the signature isn't 256 bytes."
	openssl pkeyutl -verify -pubin -inkey "$public_key_file" -sigfile "$signature" -in "$hash" -pkeyopt digest:sha256 >/dev/null ||
		die "$file: the new signature doesn't verify."
	cat "$unsigned" "$signature" >"$signed"

	local digest encoding suffix
	digest=$(sha256_of "$signed")
	if [ "$kind" = "wasm" ]; then
		require_tool brotli "Wasm builds are served Brotli-compressed. Install it, or skip them with 'exclude-platforms'."
		brotli -f -q 11 -c "$signed" >"$packed"
		encoding=br
		suffix=.duckdb_extension.wasm
	else
		# -n leaves name and time out of the header, so a re-run produces the same bytes.
		gzip -n -c "$signed" >"$packed"
		encoding=
		suffix=.duckdb_extension.gz
	fi

	for target in $(split_list "$targets"); do
		if is_true "$upload_versioned"; then
			# DuckDB-Wasm has no VERSION clause in its load path, so its builds only get the latest path.
			if [ "$kind" = "native" ]; then
				local versioned_object="$name/$extension_version/$target/$platform/$name$suffix"
				place "$packed" "$versioned_object"
				record "$name" "$platform" "$kind" "$abi" "$target" "$extension_version" versioned "$versioned_object" "$digest" "$encoding"
			fi
		fi
		if is_true "$upload_latest"; then
			local latest_object="$target/$platform/$name$suffix"
			place "$packed" "$latest_object"
			record "$name" "$platform" "$kind" "$abi" "$target" "$extension_version" latest "$latest_object" "$digest" "$encoding"
		elif [ "$kind" = "wasm" ]; then
			warn "$name for $platform isn't published: Wasm builds only use the latest path, and 'upload-latest' is false."
		fi
	done

	rm -f "$unsigned" "$hash" "$signature" "$signed" "$packed"
}

binaries="$tmp_dir/binaries"
find "$SOURCE_DIR" -type f \( -name '*.duckdb_extension' -o -name '*.duckdb_extension.wasm' \) >"$tmp_dir/found"
LC_ALL=C sort "$tmp_dir/found" >"$binaries"

if [ ! -s "$binaries" ]; then
	die "No *.duckdb_extension or *.duckdb_extension.wasm files found in $SOURCE_DIR. Check that the build job ran first and that 'extension-name' or 'artifact-pattern' match its artifacts."
fi

while IFS= read -r binary; do
	process_binary "$binary"
done <"$binaries"

[ -s "$manifest" ] || die "Every binary in $SOURCE_DIR was filtered out by 'extension-name' or 'exclude-platforms'."

if is_true "${INPUT_PUBLISH_KEY_FILE:-true}"; then
	mkdir -p "$signed_dir/.well-known"
	index=0
	keys_json='[]'
	while [ -f "$WORK_DIR/keys/public_$index.pem" ]; do
		keys_json=$(printf '%s' "$keys_json" | jq -c --rawfile key "$WORK_DIR/keys/public_$index.pem" '. + [$key]')
		index=$((index + 1))
	done
	printf '%s' "$keys_json" | jq '{signature_keys: .}' >"$signed_dir/.well-known/duckdb-extension-repo.json"
fi

set_output signed-dir "$signed_dir"
info "Signed $(wc -l <"$seen" | tr -d '[:space:]') binaries."
