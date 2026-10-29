#!/bin/sh
# smartdns 连通性检查（cron 每 5 分钟拉起一次）。
# 判定分两类，避免上游 DNS 抖动时误重启服务：
#   - pidof 为空：硬故障，立即拉起
#   - 进程在但 alidns/dnspod 都不解析：连续 3 次（约 15 分钟）才重启
# 2026-10-28/29 四台 05:00 断档的起因是这里的 restart 走到了 smartdns 的
# restart_crond()，而它用 /etc/init.d/cron restart 把 crond 连同这条任务一起
# 杀掉。该函数已在 diy-part2.sh 里改成 crontab 重载。

LOG=/tmp/check_smartdns_connect.log
FAIL_FILE=/tmp/check_smartdns_fail_count
ALIYUN=alidns.com
DNSPOD=dnspod.cn
SMARTDNS_PORT=$(cat /etc/config/smartdns | grep "option port" | cut -d: -f2 | awk '{ print $3}' | cut -d "'" -f 2)
SMARTDNS_ENABLED=$(cat /etc/config/smartdns | grep -m 1 "option enabled" | cut -d: -f2 | awk '{ print $3}' | cut -d "'" -f 2)

DATE=$(date +%Y-%m-%d-%H:%M:%S)

if [ "${SMARTDNS_ENABLED}" != "1" ]; then
	echo "$DATE smartdns disable, skip" >>$LOG
	exit 0
fi

probe() {
	nslookup -port="${SMARTDNS_PORT}" "$1" 127.0.0.1 2>/dev/null | grep -c 'Name:'
}

echo "$DATE check $ALIYUN start" >>$LOG
if [ "$(probe "$ALIYUN")" -ne 0 ]; then
	rm -f "$FAIL_FILE"
	echo "$DATE check smartdns connect: OK" >>$LOG
	exit 0
fi

echo "$DATE check $DNSPOD start" >>$LOG
if [ "$(probe "$DNSPOD")" -ne 0 ]; then
	rm -f "$FAIL_FILE"
	echo "$DATE check smartdns connect: OK" >>$LOG
	exit 0
fi

# 进程不在是硬故障，立即拉起
if [ -z "$(pidof smartdns)" ]; then
	echo "$DATE smartdns process missing, restart" >>$LOG
	/etc/init.d/smartdns restart
	exit 0
fi

# 进程在但解析失败，可能是上游抖动：连续 3 次才重启
COUNT=$(cat "$FAIL_FILE" 2>/dev/null || echo 0)
case "$COUNT" in
	''|*[!0-9]*) COUNT=0 ;;
esac
COUNT=$((COUNT + 1))
echo "$COUNT" >"$FAIL_FILE"
if [ "$COUNT" -ge 3 ]; then
	echo "$DATE 3 consecutive failures, smartdns restart" >>$LOG
	/etc/init.d/smartdns restart
	rm -f "$FAIL_FILE"
else
	echo "$DATE check failed, skip restart ($COUNT/3)" >>$LOG
fi
