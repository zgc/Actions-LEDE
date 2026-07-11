#!/bin/bash
set -euo pipefail

# The device config also contains build-host-only variables that may reference
# unset environment variables. Load it before enabling nounset behavior.
set +u
[ -f /etc/openwrt-device.conf ] && . /etc/openwrt-device.conf
set -u

IMG_DIR=${IMG_DIR:-/tmp}
DISK=${DISK:-sda}
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

cd "$IMG_DIR" || fail "无法进入镜像目录: $IMG_DIR"
[ -b "/dev/$DISK" ] || fail "不是块设备: /dev/$DISK"
[ -f "$IMG_GZ" ] || fail "镜像不存在: $IMG_GZ"
[ -f "$IMG_GZ_MD5" ] || fail "压缩镜像校验文件不存在: $IMG_GZ_MD5"
[ -f "$IMG_MD5" ] || fail "原始镜像校验文件不存在: $IMG_MD5"

echo -e "\e[92m校验压缩镜像: $IMG_GZ\e[0m"
md5sum -c -- "$IMG_GZ_MD5" || fail "压缩镜像校验失败"

rm -f -- "$IMG_TMP"
trap 'rm -f -- "$IMG_TMP"' EXIT
echo -e "\e[92m解压镜像: $IMG_GZ\e[0m"
gzip -dc -- "$IMG_GZ" > "$IMG_TMP" || fail "镜像解压失败"
mv -f -- "$IMG_TMP" "$IMG"

echo -e "\e[92m校验原始镜像: $IMG\e[0m"
md5sum -c -- "$IMG_MD5" || fail "原始镜像校验失败"

echo -e "\e[92m写入 $IMG 到 /dev/$DISK\e[0m"
dd if="$IMG" of="/dev/$DISK" conv=fsync status=progress || fail "写盘失败"
sync

# A successful write syscall does not prove that the target media contains the
# image. Compare exactly the image length before rebooting.
IMG_SIZE=$(wc -c < "$IMG")
echo -e "\e[92m读回校验 /dev/$DISK（${IMG_SIZE} bytes）\e[0m"
cmp -n "$IMG_SIZE" "$IMG" "/dev/$DISK" || fail "写盘后读回校验失败"

trap - EXIT
echo -e "\e[92m写入成功，重启\e[0m"
echo b > /proc/sysrq-trigger
