#!/bin/bash
# 远程刷机安全封装：禁止在写盘期间中断 SSH/进程。
set -euo pipefail

if [ $# -lt 1 ]; then
	echo "Usage: $0 <device-ip> [release-dir] [release-name]"
	echo "Example: $0 192.168.60.1"
	exit 1
fi

IP=$1
ROOT=$(cd "$(dirname "$0")/.." && pwd)
RELEASE_DIR=${2:-"$ROOT/release"}
RELEASE_NAME=${3:-}

if [ -z "$RELEASE_NAME" ] && [ -f "$ROOT/openwrt-device.conf" ]; then
	RELEASE_NAME=$(sed -n 's/^RELEASE_NAME=\([A-Za-z0-9._-]*\)$/\1/p' "$ROOT/openwrt-device.conf" | tail -1)
fi
if [ -z "$RELEASE_NAME" ]; then
	echo "❌ cannot determine RELEASE_NAME; pass it as the third argument"
	exit 1
fi

SSH_OPTS="-F /dev/null -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15"
SCP_OPTS="-F /dev/null -o BatchMode=yes -o ConnectTimeout=10"
IMG_GZ="$RELEASE_NAME.img.gz"
IMG_GZ_MD5="$RELEASE_NAME.img.gz.md5"
IMG_MD5="$RELEASE_NAME.img.md5"
REMOTE_SCRIPT="$ROOT/scripts/reset_offline.sh"

if [ ! -f "$RELEASE_DIR/$IMG_GZ" ]; then
	echo "❌ $IMG_GZ not found; device may use NAND/sysupgrade format"
	echo "   B70 等设备请使用 LuCI sysupgrade，禁止整盘 raw 刷写"
	exit 1
fi

echo "== local checks =="
for f in "$IMG_GZ" "$IMG_GZ_MD5" "$IMG_MD5"; do
	[ -s "$RELEASE_DIR/$f" ] || { echo "❌ missing $f"; exit 1; }
done
(cd "$RELEASE_DIR" && md5sum -c "$IMG_GZ_MD5") || exit 1

echo "== upload to $IP:/tmp =="
scp $SCP_OPTS "$REMOTE_SCRIPT" "$RELEASE_DIR/$IMG_GZ" \
	"$RELEASE_DIR/$IMG_GZ_MD5" "$RELEASE_DIR/$IMG_MD5" \
	"root@$IP:/tmp/"

echo "== remote md5 check =="
ssh $SSH_OPTS "root@$IP" "cd /tmp && md5sum -c '$IMG_GZ_MD5'" || exit 1

echo "== start nohup flash (ssh exits immediately) =="
ssh $SSH_OPTS "root@$IP" \
	"rm -f /tmp/flash.log; nohup sh /tmp/reset_offline.sh > /tmp/flash.log 2>&1 & echo STARTED_PID=\$!"

echo "== polling /tmp/flash.log, do not interrupt =="
max_wait=1800
wait_sec=0
while [ "$wait_sec" -lt "$max_wait" ]; do
	if ! ping -c1 -W2 "$IP" >/dev/null 2>&1; then
		echo "device offline at $wait_sec s (reboot expected)"
		break
	fi
	if ssh $SSH_OPTS "root@$IP" \
		"grep -q '写入成功，重启' /tmp/flash.log 2>/dev/null" 2>/dev/null; then
		echo "flash success marker found"
		break
	fi
	sleep 10
	wait_sec=$((wait_sec+10))
done

echo "== waiting for reboot =="
for i in $(seq 1 30); do
	if ping -c1 -W2 "$IP" >/dev/null 2>&1 && \
		ssh $SSH_OPTS "root@$IP" true 2>/dev/null; then
		ssh $SSH_OPTS "root@$IP" \
			"head -3 /etc/openwrt_release; uptime; echo ---; apk list --installed 2>/dev/null | grep -E '^(frpc|luci-app-openclash|ruby-)' | head -6"
		exit 0
	fi
	sleep 10
done

echo "❌ device did not come back after reboot" >&2
exit 1
