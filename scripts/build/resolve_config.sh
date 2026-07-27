#!/bin/bash
# 源码或 DIY 软件包变更后，解析并验证设备配置。
set -euo pipefail

OPENWRT_DIR=${1:?usage: resolve_config.sh <openwrt-dir> <config-file> <phase>}
CONFIG_FILE=${2:?usage: resolve_config.sh <openwrt-dir> <config-file> <phase>}
PHASE=${3:?usage: resolve_config.sh <openwrt-dir> <config-file> <phase>}

fail() {
	echo "❌ $*" >&2
	exit 1
}

cd "$OPENWRT_DIR" || fail "unable to enter OpenWrt directory: $OPENWRT_DIR"
rm -f tmp/.packageinfo tmp/.packagedeps tmp/.packageauxvars tmp/.packageusergroup \
	tmp/.config-*.in tmp/info/.files-packageinfo* tmp/info/.packageinfo-*
metadata_log=$(mktemp) || fail "unable to create package metadata log during $PHASE"
defconfig_log=""
trap 'rm -f "$metadata_log" "$defconfig_log"' EXIT
if ! make prepare-tmpinfo >"$metadata_log" 2>&1; then
	tail -n 80 "$metadata_log" >&2
	fail "package metadata refresh failed during $PHASE"
fi
test -s tmp/.packageinfo || fail "package metadata is empty during $PHASE"
defconfig_log=$(mktemp) || fail "unable to create defconfig log during $PHASE"
if ! make defconfig >"$defconfig_log" 2>&1; then
	grep -E 'recursive dependency detected!|:error:' "$defconfig_log" >&2 || true
	fail "defconfig failed during $PHASE"
fi
# OpenWrt Kconfig can report a recursive dependency yet exit successfully.
# Treat diagnostic output as a configuration failure instead of compiling from
# a partially resolved package graph.
if grep -Eq 'recursive dependency detected!|:error:' "$defconfig_log"; then
	grep -E 'recursive dependency detected!|:error:' "$defconfig_log" >&2 || true
	fail "defconfig reported Kconfig errors during $PHASE"
fi

[ -f "$CONFIG_FILE" ] || exit 0
missing_packages=""
while IFS= read -r package; do
	[ -z "$package" ] && continue
	grep -Fqx "CONFIG_PACKAGE_${package}=y" .config || missing_packages="$missing_packages $package"
done < <(sed -n 's/^CONFIG_PACKAGE_\([A-Za-z0-9_-]*\)=y$/\1/p' "$CONFIG_FILE")
[ -z "$missing_packages" ] || fail "requested packages missing after defconfig:$missing_packages"
echo "✅ Requested package selections verified"
