#!/bin/bash
# Resolve and verify a device config after a source or DIY package change.
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
make prepare-tmpinfo || fail "package metadata refresh failed during $PHASE"
test -s tmp/.packageinfo || fail "package metadata is empty during $PHASE"
make defconfig || fail "defconfig failed during $PHASE"

[ -f "$CONFIG_FILE" ] || exit 0
missing_packages=""
while IFS= read -r package; do
	[ -z "$package" ] && continue
	grep -Fqx "CONFIG_PACKAGE_${package}=y" .config || missing_packages="$missing_packages $package"
done < <(sed -n 's/^CONFIG_PACKAGE_\([A-Za-z0-9_-]*\)=y$/\1/p' "$CONFIG_FILE")
[ -z "$missing_packages" ] || fail "requested packages missing after defconfig:$missing_packages"
echo "✅ Requested package selections verified"
