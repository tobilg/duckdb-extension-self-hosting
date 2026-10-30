#!/usr/bin/env bash
# Finds every extension binary, validates its footer, signs and verifies it, and builds the bundle that later jobs use: the
# repository tree in bundle/signed, a manifest of what's in it, and the public keys. The footer decides platform and
# versions, not the artifact name, so this works with any build system. Nothing here runs the binaries, because this is the
# one script that has the private key.

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
bundle_dir="$WORK_DIR/bundle"
signed_dir="$bundle_dir/signed"
manifest="$bundle_dir/manifest.jsonl"
tmp_dir="$WORK_DIR/tmp"
items_dir="$tmp_dir/items"
item_list="$tmp_dir/item-list"
seen="$tmp_dir/seen"
claimed="$tmp_dir/claimed"
matched_exclusions="$tmp_dir/matched-exclusions"
key_file="$WORK_DIR/keys/signing_key.pem"
public_key_file="$bundle_dir/keys/public_0.pem"
upload_latest=${INPUT_UPLOAD_LATEST:-true}
upload_versioned=${INPUT_UPLOAD_VERSIONED:-true}
# The first character rules out '.' and '..', which pass as path segments but aren't directories anyone can request.
safe_word='^[A-Za-z0-9][A-Za-z0-9._-]*$'
# DuckDB lowercases the name when it requests the file, and looks up C symbols named after it to load the extension.
safe_name='^[a-z_][a-z0-9_]*$'
safe_platform='^[a-z0-9_]+$'
safe_platform_pattern='^[a-z0-9_*?]+$'
bare_release='^[0-9]+\.'
item_count=0
wasm_without_path=0

trap 'rm -f "$key_file"' EXIT

mkdir -p "$signed_dir" "$items_dir"
: >"$manifest"
: >"$item_list"
: >"$seen"
: >"$claimed"
: >"$matched_exclusions"

[ -d "$SOURCE_DIR" ] || die "Source directory doesn't exist: $SOURCE_DIR"

if [ -n "${INPUT_EXTENSION_VERSION:-}" ] && [[ ! "$INPUT_EXTENSION_VERSION" =~ $safe_word ]]; then
	die "Input 'extension-version' contains characters that can't be used in a path: $INPUT_EXTENSION_VERSION"
fi
while IFS= read -r version; do
	[ -n "$version" ] || continue
	[[ "$version" =~ $safe_word ]] || die "Input 'duckdb-version' contains characters that can't be used in a path: $version"
	# Release builds of DuckDB request the tag with its 'v', so nothing would ever read this directory.
	if [[ "$version" =~ $bare_release ]]; then
		die "Input 'duckdb-version' has '$version', but DuckDB requests 'v$version'."
	fi
done <<EOF
$(split_list "${INPUT_DUCKDB_VERSION:-}")
EOF
while IFS= read -r pattern; do
	[ -n "$pattern" ] || continue
	[[ "$pattern" =~ $safe_platform_pattern ]] || die "Input 'exclude-platforms' has '$pattern', which can't match a platform. Platforms use lowercase letters, digits and underscores, such as wasm_mvp, and * and ? work as wildcards."
done <<EOF
$(split_list "${INPUT_EXCLUDE_PLATFORMS:-}")
EOF

# From here on no other process needs the key material in the environment.
bash "$script_dir/load-key.sh"
unset INPUT_SIGNING_KEY

# Puts the same file at a second object path without using the disk twice.
place() { # <source> <object path>
	mkdir -p "$(dirname "$signed_dir/$2")"
	ln -f "$1" "$signed_dir/$2" 2>/dev/null || cp -f "$1" "$signed_dir/$2"
}

record() { # <name> <platform> <kind> <abi> <duckdb version> <extension version> <footer extension version> <channel> <object> <sha256> <binary sha256> <encoding>
	jq -n -c --arg name "$1" --arg platform "$2" --arg kind "$3" --arg abi "$4" --arg duckdb_version "$5" \
		--arg extension_version "$6" --arg footer_extension_version "$7" --arg channel "$8" --arg object "$9" \
		--arg sha256 "${10}" --arg binary_sha256 "${11}" --arg encoding "${12}" \
		'{name: $name, platform: $platform, kind: $kind, abi: $abi, duckdb_version: $duckdb_version,
		  extension_version: $extension_version, footer_extension_version: $footer_extension_version, channel: $channel,
		  object: $object, sha256: $sha256, binary_sha256: $binary_sha256, encoding: $encoding}' \
		>>"$manifest"
}

is_excluded() { # <platform>
	local pattern excluded=1
	while IFS= read -r pattern; do
		[ -n "$pattern" ] || continue
		# shellcheck disable=SC2254 # the entry is meant to match as a wildcard
		case "$1" in
		$pattern)
			printf '%s\n' "$pattern" >>"$matched_exclusions"
			excluded=0
			;;
		esac
	done <<EOF
$(split_list "${INPUT_EXCLUDE_PLATFORMS:-}")
EOF
	return "$excluded"
}

# Signs one binary into a directory of its own. Compressing comes later, without the key on disk.
process_binary() { # <file>
	local file=$1 base name kind size magic platform footer_version footer_extension_version extension_version abi targets target
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

	# Before the name check, so that a file nobody asked to publish can't fail the run.
	if [ -n "${INPUT_EXTENSION_NAME:-}" ] && [ "$name" != "$INPUT_EXTENSION_NAME" ]; then
		info "Skipping $base: not '$INPUT_EXTENSION_NAME'."
		return 0
	fi

	[[ "$name" =~ $safe_name ]] || die "$file: DuckDB can't install an extension with this name. Use lowercase letters, digits and underscores, and don't start with a digit."

	size=$(file_size "$file")
	[ "$size" -ge 512 ] || die "$file: too small to be a DuckDB extension, which ends in a 512-byte footer."

	magic=$(footer_field "$file" "$size" 288)
	[ "$magic" = "4" ] || die "$file: the footer's magic value is invalid, so this isn't a DuckDB extension, or the footer was damaged. Running 'strip' on a binary does this."
	platform=$(footer_field "$file" "$size" 320)
	footer_version=$(footer_field "$file" "$size" 352)
	footer_extension_version=$(footer_field "$file" "$size" 384)
	abi=$(footer_field "$file" "$size" 416)

	[[ "$platform" =~ $safe_platform ]] || die "$file: the platform in the footer isn't valid: '$platform'"
	[[ "$footer_version" =~ $safe_word ]] || die "$file: the DuckDB version in the footer isn't valid: '$footer_version'"

	case "$platform" in
	wasm_*) [ "$kind" = "wasm" ] || die "$file: the footer says '$platform', but the file doesn't end in .duckdb_extension.wasm." ;;
	*) [ "$kind" = "native" ] || die "$file: the file ends in .duckdb_extension.wasm, but the footer says '$platform'." ;;
	esac

	if is_excluded "$platform"; then
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
		targets=$(split_list "$INPUT_DUCKDB_VERSION" | awk '!listed[$0]++')
		;;
	*) die "$file: unknown ABI type in the footer: '$abi'" ;;
	esac

	# The version only has to be a safe path segment where it becomes one, and 'extension-version' can stand in for it.
	extension_version=${INPUT_EXTENSION_VERSION:-$footer_extension_version}
	if is_true "$upload_versioned" && [ "$kind" = "native" ] && [[ ! "$extension_version" =~ $safe_word ]]; then
		die "$file: the extension version in the footer can't be used in a path: '$extension_version'. Set 'extension-version', or 'upload-versioned: false'."
	fi
	if [[ ! "$extension_version" =~ $safe_word ]]; then extension_version=; fi
	if [[ ! "$footer_extension_version" =~ $safe_word ]]; then footer_extension_version=; fi
	if [ -n "${INPUT_EXTENSION_VERSION:-}" ] && [ -n "$footer_extension_version" ] && [ "$INPUT_EXTENSION_VERSION" != "$footer_extension_version" ]; then
		warn "$file: 'extension-version' is '$INPUT_EXTENSION_VERSION', but the footer says '$footer_extension_version'. INSTALL ... VERSION finds it by the path, and duckdb_extensions() reports the footer's version."
	fi

	item_count=$((item_count + 1))
	local item="$items_dir/$item_count" unsigned_digest identity first
	mkdir -p "$item"
	head -c $((size - 256)) "$file" >"$item/unsigned"
	unsigned_digest=$(sha256_of "$item/unsigned")

	# The same build can be in a tree twice, but of two different builds the wrong one could win without anyone noticing.
	identity="$name $platform $footer_version"
	first=$(awk -F'|' -v id="$identity" '$1 == id { print $2 "|" $3; exit }' "$seen")
	if [ -n "$first" ]; then
		if [ "${first%%|*}" != "$unsigned_digest" ]; then
			die "$file: this is a different build of $name for $platform and $footer_version than ${first#*|}. Point 'path' or 'artifact-pattern' at only one of them."
		fi
		info "Skipping $file: the same build as ${first#*|}."
		rm -rf "$item"
		return 0
	fi
	printf '%s|%s|%s\n' "$identity" "$unsigned_digest" "$file" >>"$seen"

	# Builds with different footers can still share a path: C_STRUCT builds of two C API versions, for one DuckDB version.
	while IFS= read -r target; do
		if grep -Fqx "$name $platform $target" "$claimed"; then
			die "$file: another build of $name for $platform was already signed for DuckDB $target, and this one would replace it. Publish one build per platform and DuckDB version."
		fi
		printf '%s\n' "$name $platform $target" >>"$claimed"
	done <<EOF
$targets
EOF

	info "Signing $name for $platform ($abi, DuckDB $footer_version, extension ${extension_version:-without a version})"

	bash "$script_dir/compute-extension-hash.sh" "$item/unsigned" >"$item/hash"
	openssl pkeyutl -sign -in "$item/hash" -inkey "$key_file" -pkeyopt digest:sha256 -out "$item/signature"
	[ "$(file_size "$item/signature")" = "256" ] || die "$file: the signature isn't 256 bytes."
	openssl pkeyutl -verify -pubin -inkey "$public_key_file" -sigfile "$item/signature" -in "$item/hash" -pkeyopt digest:sha256 >/dev/null ||
		die "$file: the new signature doesn't verify."
	cat "$item/unsigned" "$item/signature" >"$item/signed"
	rm -f "$item/unsigned" "$item/hash" "$item/signature"

	printf '%s|%s|%s|%s|%s|%s|%s|%s\n' "$item" "$name" "$platform" "$kind" "$abi" "$footer_extension_version" "$extension_version" "$(printf '%s' "$targets" | tr '\n' ' ')" >>"$item_list"
}

compress_item() { # <item directory> <kind>
	if [ "$2" = "wasm" ]; then
		brotli -f -q 11 -c "$1/signed" >"$1/packed"
	else
		# -n leaves name and time out of the header, so a re-run produces the same bytes.
		gzip -n -c "$1/signed" >"$1/packed"
	fi
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

# Nothing needs the private key from here on, and compressing a large Wasm build can take minutes.
rm -f "$key_file"

while IFS= read -r pattern; do
	[ -n "$pattern" ] || continue
	if ! grep -Fqx -- "$pattern" "$matched_exclusions"; then
		warn "Input 'exclude-platforms' has '$pattern', which matched none of the binaries."
	fi
done <<EOF
$(split_list "${INPUT_EXCLUDE_PLATFORMS:-}")
EOF

if grep -q '|wasm|' "$item_list"; then
	require_tool brotli "Wasm builds are served Brotli-compressed. Install it, or skip them with 'exclude-platforms'."
fi

# Each item compresses on its own, because Brotli's top quality takes about a minute for a large Wasm build.
compress_jobs=$(cpu_count)
while IFS='|' read -r item _ _ kind _; do
	pool_start "$compress_jobs" compress_item "$item" "$kind"
done <"$item_list"
pool_wait
[ "$pool_failed" = "0" ] || die "Compressing the signed binaries failed."

while IFS='|' read -r item name platform kind abi footer_extension_version extension_version targets; do
	binary_digest=$(sha256_of "$item/signed")
	digest=$(sha256_of "$item/packed")
	if [ "$kind" = "wasm" ]; then
		encoding=br
		suffix=.duckdb_extension.wasm
	else
		encoding=
		suffix=.duckdb_extension.gz
	fi
	for target in $targets; do
		# DuckDB-Wasm has no VERSION clause in its load path, so its builds only get the latest path.
		if is_true "$upload_versioned" && [ "$kind" = "native" ]; then
			versioned_object="$name/$extension_version/$target/$platform/$name$suffix"
			place "$item/packed" "$versioned_object"
			record "$name" "$platform" "$kind" "$abi" "$target" "$extension_version" "$footer_extension_version" versioned "$versioned_object" "$digest" "$binary_digest" "$encoding"
		fi
		if is_true "$upload_latest"; then
			latest_object="$target/$platform/$name$suffix"
			place "$item/packed" "$latest_object"
			record "$name" "$platform" "$kind" "$abi" "$target" "$extension_version" "$footer_extension_version" latest "$latest_object" "$digest" "$binary_digest" "$encoding"
		elif [ "$kind" = "wasm" ]; then
			wasm_without_path=1
			warn "$name for $platform isn't published: Wasm builds only use the latest path, and 'upload-latest' is false."
		fi
	done
	rm -rf "$item"
done <"$item_list"

if [ ! -s "$manifest" ]; then
	if [ "$wasm_without_path" = "1" ]; then
		die "There is nothing to publish: only Wasm builds are left, and they need 'upload-latest', which is false."
	fi
	die "Every binary in $SOURCE_DIR was filtered out by 'extension-name' or 'exclude-platforms'."
fi

if is_true "${INPUT_PUBLISH_KEY_FILE:-true}"; then
	mkdir -p "$signed_dir/.well-known"
	index=0
	keys_json='[]'
	while [ -f "$bundle_dir/keys/public_$index.pem" ]; do
		keys_json=$(printf '%s' "$keys_json" | jq -c --rawfile key "$bundle_dir/keys/public_$index.pem" '. + [$key]')
		index=$((index + 1))
	done
	printf '%s' "$keys_json" | jq '{signature_keys: .}' >"$signed_dir/.well-known/duckdb-extension-repo.json"
fi

set_output signed-dir "$signed_dir"
set_output bundle-digest "$(bundle_digest "$bundle_dir")"
info "Signed $(wc -l <"$item_list" | tr -d '[:space:]') binaries."
