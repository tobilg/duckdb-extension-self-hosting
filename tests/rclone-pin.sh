#!/usr/bin/env bash
# Checks the rclone hashes in scripts/install-rclone.sh against rclone's own list. With a version, such as v1.76.0, moves the
# pin to that version first.

set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script="$root/scripts/install-rclone.sh"
new_version=${1:-}
version=${new_version:-$(sed -n 's/^RCLONE_VERSION=//p' "$script")}

sums=$(mktemp)
trap 'rm -f "$sums" "$sums.new"' EXIT
curl -fsSL --connect-timeout 30 --max-time 120 --retry 3 -o "$sums" "https://github.com/rclone/rclone/releases/download/$version/SHA256SUMS"

if [ -n "$new_version" ]; then
	awk -v version="$version" -v sums="$sums" '
		BEGIN { while ((getline line < sums) > 0) { split(line, parts, " "); hashes[parts[2]] = parts[1] } }
		/^RCLONE_VERSION=/ { print "RCLONE_VERSION=" version; next }
		/^\tasset=/ { asset = $0; sub(/.*=/, "", asset) }
		/^\texpected=/ { print "\texpected=" hashes["rclone-" version "-" asset ".zip"]; next }
		{ print }
	' "$script" >"$sums.new"
	cat "$sums.new" >"$script"
fi

status=0
for asset in linux-amd64 linux-arm64 osx-amd64 osx-arm64; do
	file="rclone-$version-$asset.zip"
	upstream=$(awk -v file="$file" '$2 == file { print $1 }' "$sums")
	pinned=$(awk -v asset="$asset" '/^\tasset=/ { current = $0; sub(/.*=/, "", current) } /^\texpected=/ && current == asset { value = $0; sub(/.*=/, "", value); print value }' "$script")
	if [ -n "$upstream" ] && [ "$upstream" = "$pinned" ]; then
		printf 'ok   %s\n' "$file"
	else
		printf 'FAIL %s: pinned %s, upstream %s\n' "$file" "${pinned:-nothing}" "${upstream:-nothing}"
		status=1
	fi
done
exit "$status"
