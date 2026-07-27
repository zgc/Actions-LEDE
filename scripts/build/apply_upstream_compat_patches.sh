#!/bin/bash
# Apply pinned compatibility patches only until their upstream equivalents land.
set -euo pipefail

WORKSPACE=${1:?usage: apply_upstream_compat_patches.sh <workspace> <openwrt-dir>}
OPENWRT_DIR=${2:?usage: apply_upstream_compat_patches.sh <workspace> <openwrt-dir>}
FEED_ROOT="$OPENWRT_DIR/feeds/packages"
PATCH_FILE="$WORKSPACE/patches/openwrt-packages/trafficshaper-avoid-recursive-kconfig.patch"
TRAFFICSHAPER_MAKEFILE="$FEED_ROOT/net/trafficshaper/Makefile"
FREERADIUS_PATCH_FILE="$WORKSPACE/patches/openwrt-packages/freeradius3-avoid-recursive-kconfig.patch"
FREERADIUS_CONFIG="$FEED_ROOT/net/freeradius3/Config.in"
GCC_PATCH_FILE="$WORKSPACE/patches/immortalwrt/gcc-initial-disable-ccache.patch"
GCC_INITIAL_MAKEFILE="$OPENWRT_DIR/toolchain/gcc/initial/Makefile"

[ -f "$GCC_INITIAL_MAKEFILE" ] || {
	echo "❌ initial GCC compatibility check: Makefile not found"
	exit 1
}

if grep -q 'CCACHE_DISABLE=1 \$(GCC_MAKE)' "$GCC_INITIAL_MAKEFILE"; then
	echo "✅ initial GCC bootstrap already bypasses ccache"
else
	patch --batch --dry-run -d "$OPENWRT_DIR" -p1 < "$GCC_PATCH_FILE" >/dev/null || {
		echo "❌ initial GCC ccache safety patch no longer matches upstream"
		exit 1
	}
	patch --batch -d "$OPENWRT_DIR" -p1 < "$GCC_PATCH_FILE"
	echo "✅ applied initial GCC ccache safety patch"
fi

[ -f "$TRAFFICSHAPER_MAKEFILE" ] || {
	echo "❌ trafficshaper compatibility check: Makefile not found"
	exit 1
}

if grep -q '^define Package/trafficshaper-iptables$' "$TRAFFICSHAPER_MAKEFILE"; then
	echo "✅ trafficshaper recursive-Kconfig fix already present upstream"
else
	patch --batch --dry-run -d "$FEED_ROOT" -p1 < "$PATCH_FILE" >/dev/null || {
		echo "❌ trafficshaper compatibility patch no longer matches upstream"
		exit 1
	}
	patch --batch -d "$FEED_ROOT" -p1 < "$PATCH_FILE"
	echo "✅ applied trafficshaper recursive-Kconfig compatibility patch"
fi

[ -f "$FREERADIUS_CONFIG" ] || {
	echo "❌ FreeRADIUS compatibility check: Config.in not found"
	exit 1
}

if ! grep -q '^\s*depends on PACKAGE_freeradius3-common$' "$FREERADIUS_CONFIG"; then
	echo "✅ FreeRADIUS recursive-Kconfig fix already present upstream"
else
	patch --batch --dry-run -d "$FEED_ROOT" -p1 < "$FREERADIUS_PATCH_FILE" >/dev/null || {
		echo "❌ FreeRADIUS recursive-Kconfig compatibility patch no longer matches upstream"
		exit 1
	}
	patch --batch -d "$FEED_ROOT" -p1 < "$FREERADIUS_PATCH_FILE"
	echo "✅ applied FreeRADIUS recursive-Kconfig compatibility patch"
fi
