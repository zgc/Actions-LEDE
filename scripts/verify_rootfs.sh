#!/bin/sh
set -eu

ROOTFS=${ROOTFS:-/rom}
LUCIDIR="$ROOTFS/www/luci-static/resources"

fail() {
	echo "rootfs integrity check failed: $*" >&2
	exit 1
}

[ -d "$ROOTFS" ] || fail "rootfs mount is unavailable: $ROOTFS"
[ -r "$LUCIDIR/luci.js" ] || fail "missing LuCI asset: luci.js"
[ -r "$LUCIDIR/ui.js" ] || fail "missing LuCI asset: ui.js"

echo "Verifying every regular file under $ROOTFS"
find "$ROOTFS" -xdev -type f -exec sha256sum {} \; >/dev/null || fail "unable to read all rootfs files"

kernel_log=$(dmesg) || fail "unable to read kernel log"
if printf '%s\n' "$kernel_log" | grep -Eqi 'SQUASHFS error|xz decompression failed|Unable to read page'; then
	fail "kernel reported a SquashFS read or decompression error"
fi

echo "rootfs integrity check passed"
