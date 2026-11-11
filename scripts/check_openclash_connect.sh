#!/bin/sh

DATE=$(date +%Y-%m-%d-%H:%M:%S)
LOG=/tmp/check_openclash_connect.log
FAIL_FILE=/tmp/check_openclash_fail_count
RECOVER_MARK=/tmp/check_openclash_recover_tried
YOUTUBE=youtube.com
GITHUB=github.com
OPENCLASH_DNS_PORT=$(uci -q get openclash.config.dns_port)
OPENCLASH_ENABLE=$(uci -q get openclash.config.enable)

# 开机首启失败自愈：WAN/订阅未就绪时 OpenClash 会 start_fail 并把 enable 置 0。
# 只认本次开机日志里的 Core Start Failed，避免和手动停用冲突；每次开机只试一次。
if [ "$OPENCLASH_ENABLE" != "1" ] && [ ! -e "$RECOVER_MARK" ] && grep -q "Core Start Failed" /tmp/openclash_start.log 2>/dev/null; then
  if ip route 2>/dev/null | grep -q '^default' && nslookup baidu.com 127.0.0.1 >/dev/null 2>&1; then
    echo "$DATE openclash boot start failed, WAN ready, re-enable and start" >>$LOG
    touch "$RECOVER_MARK"
    uci -q set openclash.config.enable=1
    uci -q commit openclash
    /etc/init.d/openclash start
    exit 0
  fi
  echo "$DATE openclash boot start failed, waiting for WAN" >>$LOG
  exit 0
fi

if [ "$OPENCLASH_ENABLE" = "1" ]; then
  check_dns() {
    nslookup -port="$OPENCLASH_DNS_PORT" "$1" 127.0.0.1 2>/dev/null | grep -q 'Name:'
  }

  echo "$DATE check $GITHUB start" >>$LOG
  if check_dns "$GITHUB" || check_dns "$YOUTUBE"; then
    rm -f "$FAIL_FILE"
    echo "$DATE check openclash connect: OK" >>$LOG
    exit 0
  fi

  COUNT=$(cat "$FAIL_FILE" 2>/dev/null || echo 0)
  COUNT=$((COUNT + 1))
  echo "$COUNT" > "$FAIL_FILE"
  if [ "$COUNT" -ge 3 ]; then
    echo "$DATE 3 consecutive failures, openclash restart" >>$LOG
    /etc/init.d/openclash restart
    rm -f "$FAIL_FILE"
  else
    echo "$DATE check failed, skip restart ($COUNT/3)" >>$LOG
  fi
else
  echo "$DATE openclash disable, skip" >>$LOG
fi
