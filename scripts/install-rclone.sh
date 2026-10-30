#!/usr/bin/env bash
# Installs a pinned rclone into the work directory. The expected hashes are stored here rather than downloaded, so a
# compromised download location can't change what runs next to your storage credentials.

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RCLONE_VERSION=v1.75.2

case "$(runner_platform)" in
linux_amd64)
	asset=linux-amd64
	expected=349ac8fba6ff65d6247043f1750cdcb518ec5d500ef91463a10d37c0ccdf3702
	;;
linux_arm64)
	asset=linux-arm64
	expected=7e1e8d69654941b7b7df84ee74c5f7fb09cce7d5496947fb7bf16b55ff427d10
	;;
osx_amd64)
	asset=osx-amd64
	expected=574e1f31cf1c464e5fb0325cb66fcbdeaf1efa1802bd9b17f13c256fd74b6561
	;;
osx_arm64)
	asset=osx-arm64
	expected=610ab7d48615135dfc60b763858b11a426a0d3d1160c1bb76fb0ae6011b02edd
	;;
*) die "No rclone build is pinned for this runner ($(uname -s) $(uname -m))." ;;
esac

require_tool curl
require_tool unzip

name="rclone-$RCLONE_VERSION-$asset"
archive="$WORK_DIR/tmp/$name.zip"
curl -fsSL --connect-timeout 30 --max-time 300 --retry 3 -o "$archive" "https://github.com/rclone/rclone/releases/download/$RCLONE_VERSION/$name.zip"

actual=$(sha256_of "$archive")
[ "$actual" = "$expected" ] || die "The rclone download has an unexpected hash: $actual"

unzip -q -o "$archive" -d "$WORK_DIR/tmp"
mkdir -p "$WORK_DIR/bin"
mv "$WORK_DIR/tmp/$name/rclone" "$WORK_DIR/bin/rclone"
chmod +x "$WORK_DIR/bin/rclone"
rm -rf "$archive" "${WORK_DIR:?}/tmp/$name"

info "Installed $("$WORK_DIR/bin/rclone" version --check=false 2>/dev/null | sed -n 1p)"
