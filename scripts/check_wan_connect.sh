#!/bin/sh
# WAN 连通性检查（cron 每 5 分钟拉起一次）。
# 判定用 ping -c3 -W2：三个包、每个最多 2 秒，单包丢失不再触发重连。
# 连续 2 次检查（约 10 分钟）都失败才 ifdown/ifup wan，避免运营商偶发
# 丢包把 WAN 打断再重拨。原实现是 ping -c1 立即重连，并在一次调用里
# 连试 5 轮，一次抖动就会断网 30 秒以上。

LOG=/tmp/check_wan_connect.log
FAIL_FILE=/tmp/check_wan_fail_count
ALIYUN=223.5.5.5
DNSPOD=119.29.29.29
FAIL_LIMIT=2

DATE=$(date +%Y-%m-%d-%H:%M:%S)

ping_ok() {
	ping -c3 -W2 "$1" >/dev/null 2>&1
}

count_fail() {
	local count
	count=$(cat "$FAIL_FILE" 2>/dev/null || echo 0)
	case "$count" in
		''|*[!0-9]*) count=0 ;;
	esac
	count=$((count + 1))
	echo "$count" >"$FAIL_FILE"
	echo "$count"
}

recover_wan() {
	ifdown wan
	ifup wan
	rm -f "$FAIL_FILE"
}

PPPOE=$(/sbin/ifconfig 2>/dev/null | grep -c 'pppoe-wan')

if [ "$PPPOE" -ne 0 ]; then
	echo "$DATE check $ALIYUN start" >>$LOG
	if ping_ok "$ALIYUN"; then
		rm -f "$FAIL_FILE"
		echo "$DATE check ppp connect: OK" >>$LOG
		exit 0
	fi
	echo "$DATE check $DNSPOD start" >>$LOG
	if ping_ok "$DNSPOD"; then
		rm -f "$FAIL_FILE"
		echo "$DATE check ppp connect: OK" >>$LOG
		exit 0
	fi
	n=$(count_fail)
	if [ "$n" -ge "$FAIL_LIMIT" ]; then
		echo "$DATE $n consecutive failures, ppp restart" >>$LOG
		recover_wan
	else
		echo "$DATE check failed, skip restart ($n/$FAIL_LIMIT)" >>$LOG
	fi
	exit 0
fi

# 非 PPPoE（DHCP / 静态地址）：检查到网关的连通性
eth1=$(/sbin/ifconfig eth1 2>/dev/null | grep 'inet addr:' | cut -d: -f2 | awk '{ print $1}')
if [ -z "$eth1" ]; then
	echo "$DATE wan not connect" >>$LOG
	exit 0
fi
GATEWAY=$(ip route show default 2>/dev/null | head -1 | awk '{print $3}')
if [ -z "$GATEWAY" ]; then
	GATEWAY=$(echo "$eth1" | awk 'BEGIN{FS=OFS="."}{$NF=1;print}')
fi
echo "$DATE check $GATEWAY start" >>$LOG
if ping_ok "$GATEWAY"; then
	rm -f "$FAIL_FILE"
	echo "$DATE check wan connect: OK" >>$LOG
	exit 0
fi
n=$(count_fail)
if [ "$n" -ge "$FAIL_LIMIT" ]; then
	echo "$DATE $n consecutive failures, wan restart" >>$LOG
	recover_wan
else
	echo "$DATE check failed, skip restart ($n/$FAIL_LIMIT)" >>$LOG
fi
