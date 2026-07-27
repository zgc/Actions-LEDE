#!/bin/bash
# Apply pinned compatibility patches only until their upstream equivalents land.
set -euo pipefail

WORKSPACE=${1:?usage: apply_upstream_compat_patches.sh <workspace> <openwrt-dir>}
OPENWRT_DIR=${2:?usage: apply_upstream_compat_patches.sh <workspace> <openwrt-dir>}
FEED_ROOT="$OPENWRT_DIR/feeds/packages"
PATCH_FILE="$WORKSPACE/patches/openwrt-packages/trafficshaper-avoid-recursive-kconfig.patch"
TRAFFICSHAPER_MAKEFILE="$FEED_ROOT/net/trafficshaper/Makefile"

[ -f "$TRAFFICSHAPER_MAKEFILE" ] || {
	echo "❌ trafficshaper compatibility check: Makefile not found"
	exit 1
}

if grep -q '^define Package/trafficshaper-iptables$' "$TRAFFICSHAPER_MAKEFILE"; then
	echo "✅ trafficshaper recursive-Kconfig fix already present upstream"
	exit 0
fi

patch --batch --dry-run -d "$FEED_ROOT" -p1 < "$PATCH_FILE" >/dev/null || {
	echo "❌ trafficshaper compatibility patch no longer matches upstream"
	exit 1
}
patch --batch -d "$FEED_ROOT" -p1 < "$PATCH_FILE"
echo "✅ applied trafficshaper recursive-Kconfig compatibility patch"
