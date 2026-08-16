#!/bin/sh

DATE=$(date +%Y-%m-%d-%H:%M:%S)
tries=0
LOG=/tmp/check_openclash_connect.log
YOUTUBE=youtube.com
GITHUB=github.com
OPENCLASH_DNS_PORT=$(cat /etc/config/openclash | grep "option dns_port" | cut -d: -f2 | awk '{ print $3}' | cut -d "'" -f 2)
OPENCLASH_ENABLE=$(cat /etc/config/openclash | grep -m 1 "option enable" | cut -d: -f2 | awk '{ print $3}' | cut -d "'" -f 2)

if [ "${OPENCLASH_ENABLE}" = "1" ]; then
  FAIL_FILE=/tmp/check_openclash_fail_count
  check_dns() {
    nslookup -port="${OPENCLASH_DNS_PORT}" "$1" 127.0.0.1 2>/dev/null | grep -q 'Name:'
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
