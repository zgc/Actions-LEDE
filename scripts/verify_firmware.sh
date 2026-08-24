#!/bin/bash
# 发布前验证由 build.sh 生成的固件。
set -euo pipefail

OPENWRT_DIR=${1:?usage: verify_firmware.sh <openwrt-dir> <release-dir> <release-name>}
RELEASE_DIR=${2:?usage: verify_firmware.sh <openwrt-dir> <release-dir> <release-name>}
RELEASE_NAME=${3:?usage: verify_firmware.sh <openwrt-dir> <release-dir> <release-name>}
FIRMWARE_EXT=${FIRMWARE_EXT:-img.gz}
FIRMWARE="$RELEASE_DIR/$RELEASE_NAME.$FIRMWARE_EXT"

fail() {
	echo "❌ $*" >&2
	exit 1
}

CLEANUP_DIRS=()

cleanup() {
	local directory
	for directory in "${CLEANUP_DIRS[@]}"; do
		rm -rf "$directory"
	done
}

trap cleanup EXIT

verify_manifest() {
	local check_dir package missing_packages=""

	check_dir=$(mktemp -d) || fail "failed to create manifest check directory"
	CLEANUP_DIRS+=("$check_dir")
	awk '/^Package: / { print $2 }' "$OPENWRT_DIR/tmp/.packageinfo" | sort -u > "$check_dir/buildable"
	sed -n 's/^CONFIG_PACKAGE_\([A-Za-z0-9_-]*\)=y$/\1/p' "$OPENWRT_DIR/.config" | sort -u > "$check_dir/selected"
	awk -F ' - ' 'NF >= 2 { print $1 }' "$RELEASE_DIR/$RELEASE_NAME.manifest" | sort -u > "$check_dir/manifest"
	test -s "$check_dir/buildable" || fail "package metadata is unavailable for manifest validation"
	test -s "$check_dir/selected" || fail "selected package list is empty"
	test -s "$check_dir/manifest" || fail "firmware manifest is empty"

	while IFS= read -r package; do
		[ -z "$package" ] && continue
		if ! grep -Fqx "$package" "$check_dir/manifest" &&
			! grep -Eq "^${package}([0-9]+([.-][0-9]+)*|-[0-9]+)$" "$check_dir/manifest"; then
			missing_packages="$missing_packages $package"
		fi
	done < <(comm -12 "$check_dir/selected" "$check_dir/buildable")

	[ -z "$missing_packages" ] || fail "firmware manifest is missing selected packages:$missing_packages"
	echo "✅ firmware manifest contains every selected package"
}

verify_squashfs() {
	local image="$FIRMWARE" verify_dir image_raw image_rootfs squashfs_offset luci_asset
    verify_dir=$(mktemp -d) || fail "failed to create image verification directory"
    CLEANUP_DIRS+=("$verify_dir")

	if [ "$FIRMWARE_EXT" = "img.gz" ]; then
		gzip -t "$image" || fail "firmware gzip integrity check failed"
		image_raw="$verify_dir/$RELEASE_NAME.img"
		gzip -dc "$image" > "$image_raw" || fail "failed to decompress firmware image for SquashFS verification"
	else
		image_raw="$verify_dir/$RELEASE_NAME.$FIRMWARE_EXT"
		cp -f "$image" "$image_raw" || fail "failed to copy firmware image for SquashFS verification"
	fi
	image_rootfs="$verify_dir/rootfs"
	squashfs_offset=$(LC_ALL=C grep -abo -m 1 'hsqs' "$image_raw" | cut -d: -f1 || true)
	[ -n "$squashfs_offset" ] || fail "unable to locate SquashFS in firmware image"
	echo "🔍 Fully extracting SquashFS at offset $squashfs_offset"
	unsquashfs -offset "$squashfs_offset" -excludes -d "$image_rootfs" "$image_raw" dev >/dev/null || fail "firmware SquashFS extraction failed"
	for luci_asset in luci.js ui.js; do
		[ -s "$image_rootfs/www/luci-static/resources/$luci_asset" ] || fail "verified SquashFS is missing LuCI asset: $luci_asset"
	done
	echo "✅ firmware SquashFS fully extracted and LuCI assets verified"
}

[ -d "$OPENWRT_DIR" ] || fail "OpenWrt directory is missing: $OPENWRT_DIR"
[ -s "$RELEASE_DIR/$RELEASE_NAME.manifest" ] || fail "release manifest is missing"
[ -s "$FIRMWARE" ] || fail "release image is missing"

verify_manifest
verify_squashfs

(
	cd "$RELEASE_DIR"
	checksum_tmp=$(mktemp ".${RELEASE_NAME}.md5.XXXXXX")
	trap 'rm -f "$checksum_tmp"' EXIT
	md5sum "$RELEASE_NAME.$FIRMWARE_EXT" > "$checksum_tmp"
	mv -f "$checksum_tmp" "$RELEASE_NAME.$FIRMWARE_EXT.md5"
	if [ "$FIRMWARE_EXT" = "img.gz" ]; then
		gzip -dc "$RELEASE_NAME.$FIRMWARE_EXT" | md5sum | sed "s/-/$RELEASE_NAME.img/" > "$checksum_tmp"
		mv -f "$checksum_tmp" "$RELEASE_NAME.img.md5"
	fi
)
