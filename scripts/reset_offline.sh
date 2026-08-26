#!/bin/bash
set -euo pipefail

# 设备配置还包含仅构建主机使用、可能引用未设置环境变量的字段。
# 因此必须在启用 nounset 前加载。
set +u
[ -f /etc/openwrt-device.conf ] && . /etc/openwrt-device.conf
set -u

# 远程执行时即使 SSH 断开收到 HUP/PIPE，也不能中断写盘/读回校验。
# 子进程在 exec 时会继承被忽略的信号，这是全设备通用的防护。
trap '' HUP PIPE

# 硬约束：刷写脚本禁止通过管道执行。sh reset_offline.sh 2>&1 | tail 这种
# 用法在 SSHD/远端进程被中断时会把 dd 一起打断，历史上已导致设备无法引导。
if [ -p /dev/stdout ] || [ -p /dev/stderr ]; then
	echo "❌ 禁止通过管道执行 reset_offline.sh" >&2
	echo "   正确用法: nohup sh /tmp/reset_offline.sh > /tmp/flash.log 2>&1 &" >&2
	exit 1
fi

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

verify_written_image() {
	local img_size full_blocks tail_bytes tail_blocks source_md5 disk_md5

	img_size=$(wc -c < "$IMG")
	full_blocks=$((img_size / 1048576))
	tail_bytes=$((img_size % 1048576))
	[ $((tail_bytes % 512)) -eq 0 ] || {
		echo -e "\e[91m镜像长度不是 512 字节对齐，拒绝读回校验\e[0m" >&2
		return 1
	}
	tail_blocks=$((tail_bytes / 512))
	echo -e "\e[92m读回校验 /dev/$DISK（${img_size} bytes）\e[0m"
	source_md5=$(md5sum "$IMG" | awk '{print $1}')
	disk_md5=$(
		{
			[ "$full_blocks" -eq 0 ] || dd if="/dev/$DISK" bs=1M count="$full_blocks" status=none
			# BusyBox dd 不接受大于 2 GiB 的字节偏移；剩余镜像尾部改用扇区寻址。
			[ "$tail_blocks" -eq 0 ] || dd if="/dev/$DISK" bs=512 skip="$((full_blocks * 2048))" count="$tail_blocks" status=none
		} | md5sum | awk '{print $1}'
	)
	if [ "$source_md5" != "$disk_md5" ]; then
		echo -e "\e[91m写盘后读回校验失败: image=$source_md5 disk=$disk_md5\e[0m" >&2
		echo -e "\e[91m保留镜像且不重启；请保存以下块设备相关日志。\e[0m" >&2
		dmesg | grep -Ei 'nvme|I/O error|buffer I/O|blk_update|reset|timeout' | tail -n 120 >&2 || true
		return 1
	fi
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

# 写入系统调用成功不代表目标介质已包含完整镜像；重启前必须按镜像长度精确比较。
verify_written_image || fail "写盘后读回校验失败"

trap - EXIT
echo -e "\e[92m写入成功，重启\e[0m"
echo b > /proc/sysrq-trigger
