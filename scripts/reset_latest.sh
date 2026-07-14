#!/bin/bash
set -euo pipefail

[ -f /etc/openwrt-device.conf ] && . /etc/openwrt-device.conf

IMG_DIR=${IMG_DIR:-/tmp}
DISK=${DISK:-sda}
GITHUB_REPO=${GITHUB_REPO:-zgc/Actions-LEDE}
RELEASE_NAME=${RELEASE_NAME:-$(uname -m)}
IMG_GZ="${RELEASE_NAME}.img.gz"
IMG_GZ_MD5="${RELEASE_NAME}.img.gz.md5"
IMG_MD5="${RELEASE_NAME}.img.md5"
IMG="${RELEASE_NAME}.img"
IMG_TMP="${IMG}.partial"

fail() {
	echo -e "\e[91m$*\e[0m" >&2
	exit 1
}

verify_written_image() {
	local img_size full_blocks tail_bytes source_md5 disk_md5

	img_size=$(wc -c < "$IMG")
	full_blocks=$((img_size / 1048576))
	tail_bytes=$((img_size % 1048576))
	echo -e "\e[92m读回校验 /dev/$DISK（${img_size} bytes）\e[0m"
	source_md5=$(md5sum "$IMG" | awk '{print $1}')
	disk_md5=$(
		{
			[ "$full_blocks" -eq 0 ] || dd if="/dev/$DISK" bs=1M count="$full_blocks" status=none
			[ "$tail_bytes" -eq 0 ] || dd if="/dev/$DISK" bs=1 skip="$((full_blocks * 1048576))" count="$tail_bytes" status=none
		} | md5sum | awk '{print $1}'
	)
	if [ "$source_md5" != "$disk_md5" ]; then
		echo -e "\e[91m写盘后读回校验失败: image=$source_md5 disk=$disk_md5\e[0m" >&2
		echo -e "\e[91m保留镜像且不重启；请保存以下块设备相关日志。\e[0m" >&2
		dmesg | grep -Ei 'nvme|I/O error|buffer I/O|blk_update|reset|timeout' | tail -n 120 >&2 || true
		return 1
	fi
}

github_api() {
	if [ -n "${GITHUB_OAUTH_TOKEN:-}" ]; then
		curl --fail --retry 5 --silent --show-error \
			--header "Authorization: Bearer $GITHUB_OAUTH_TOKEN" \
			--header "Accept: application/vnd.github+json" "$1"
	else
		curl --fail --retry 5 --silent --show-error \
			--header "Accept: application/vnd.github+json" "$1"
	fi
}

asset_id_by_name() {
	local wanted="$1" index name id
	for index in $(seq 0 50); do
		name=$(printf '%s' "$LATEST_RELEASE_JSON" | jsonfilter -e "@.assets[$index].name")
		[ -n "$name" ] || break
		if [ "$name" = "$wanted" ]; then
			id=$(printf '%s' "$LATEST_RELEASE_JSON" | jsonfilter -e "@.assets[$index].id")
			[ -n "$id" ] && printf '%s\n' "$id" && return 0
		fi
	done
	return 1
}

download_asset() {
	local asset_id="$1" output="$2"
	if [ -n "${GITHUB_OAUTH_TOKEN:-}" ]; then
		curl --fail --retry 5 --location --output "$output" \
			--header "Authorization: Bearer $GITHUB_OAUTH_TOKEN" \
			--header "Accept: application/octet-stream" \
			"https://api.github.com/repos/$GITHUB_REPO/releases/assets/$asset_id"
	else
		curl --fail --retry 5 --location --output "$output" \
			--header "Accept: application/octet-stream" \
			"https://api.github.com/repos/$GITHUB_REPO/releases/assets/$asset_id"
	fi
}

cd "$IMG_DIR" || fail "无法进入镜像目录: $IMG_DIR"
[ -b "/dev/$DISK" ] || fail "不是块设备: /dev/$DISK"

echo -e "\e[92m获取 $GITHUB_REPO 最新 release\e[0m"
LATEST_RELEASE_JSON=$(github_api "https://api.github.com/repos/$GITHUB_REPO/releases/latest") || fail "无法读取最新 release"
TAG_NAME=$(printf '%s' "$LATEST_RELEASE_JSON" | jsonfilter -e '@.tag_name')
[ -n "$TAG_NAME" ] || fail "latest release 缺少 tag_name"

IMG_GZ_ID=$(asset_id_by_name "$IMG_GZ") || fail "release 中缺少 $IMG_GZ"
IMG_GZ_MD5_ID=$(asset_id_by_name "$IMG_GZ_MD5") || fail "release 中缺少 $IMG_GZ_MD5"
IMG_MD5_ID=$(asset_id_by_name "$IMG_MD5") || fail "release 中缺少 $IMG_MD5"

echo -e "\e[92m下载 $TAG_NAME 的 $RELEASE_NAME 镜像\e[0m"
rm -f -- "$IMG_GZ" "$IMG_GZ_MD5" "$IMG_MD5" "$IMG_TMP"
download_asset "$IMG_GZ_ID" "$IMG_GZ"
download_asset "$IMG_GZ_MD5_ID" "$IMG_GZ_MD5"
download_asset "$IMG_MD5_ID" "$IMG_MD5"

echo -e "\e[92m校验压缩镜像: $IMG_GZ\e[0m"
md5sum -c -- "$IMG_GZ_MD5" || fail "压缩镜像校验失败"

trap 'rm -f -- "$IMG_TMP"' EXIT
echo -e "\e[92m解压镜像: $IMG_GZ\e[0m"
gzip -dc -- "$IMG_GZ" > "$IMG_TMP" || fail "镜像解压失败"
mv -f -- "$IMG_TMP" "$IMG"

echo -e "\e[92m校验原始镜像: $IMG\e[0m"
md5sum -c -- "$IMG_MD5" || fail "原始镜像校验失败"

echo -e "\e[92m写入 $IMG 到 /dev/$DISK\e[0m"
dd if="$IMG" of="/dev/$DISK" conv=fsync status=progress || fail "写盘失败"
sync
verify_written_image || fail "写盘后读回校验失败"

trap - EXIT
echo -e "\e[92m写入成功，重启\e[0m"
echo b > /proc/sysrq-trigger
