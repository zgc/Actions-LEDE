#!/bin/sh
DATE=$(date +%Y-%m-%d-%H:%M:%S)
tries=0
LOG=/tmp/check_openclash_connect.log
YOUTUBE=youtube.com
GITHUB=github.com
OPENCLASH_DNS_PORT=$(cat /etc/config/openclash | grep "option dns_port" | cut -d: -f2 | awk '{ print $3}' | cut -d "'" -f 2)
OPENCLASH_ENABLE=$(cat /etc/config/openclash | grep -m 1 "option enable" | cut -d: -f2 | awk '{ print $3}' | cut -d "'" -f 2)
if [ ${OPENCLASH_ENABLE} -eq 1 ]; then
  while [ $tries -lt 5 ]; do
    echo $DATE check $GITHUB start >>$LOG
    NSLOOKUP=$(nslookup -port=${OPENCLASH_DNS_PORT} $GITHUB 127.0.0.1 2>/dev/null | grep -v grep | grep 'Name:' | wc -l)
    if [ ${NSLOOKUP} -ne 0 ]; then
      echo $DATE check openclash connect: OK >>$LOG
      exit 0
    else
      echo $DATE check $YOUTUBE start >>$LOG
      NSLOOKUP=$(nslookup -port=${OPENCLASH_DNS_PORT} $YOUTUBE 127.0.0.1 2>/dev/null | grep -v grep | grep 'Name:' | wc -l)
      if [ ${NSLOOKUP} -ne 0 ]; then
        echo $DATE check openclash connect: OK >>$LOG
        exit 0
      else
        let tries++
        echo $DATE tries: $tries, openclash restart >>$LOG
        /etc/init.d/openclash restart
        sleep 10
      fi
    fi
  done
else
  echo $DATE openclash enable: ${OPENCLASH_ENABLED} >>$LOG
fi
