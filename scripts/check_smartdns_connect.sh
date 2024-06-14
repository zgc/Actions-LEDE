#!/bin/sh
DATE=$(date +%Y-%m-%d-%H:%M:%S)
tries=0
LOG=/tmp/check_smartdns_connect.log
ALIYUN=alidns.com
DNSPOD=dnspod.cn
SMARTDNS_PORT=$(cat /etc/config/smartdns | grep "option port" | cut -d: -f2 | awk '{ print $3}' | cut -d "'" -f 2)
SMARTDNS_ENABLED=$(cat /etc/config/smartdns | grep -m 1 "option enabled" | cut -d: -f2 | awk '{ print $3}' | cut -d "'" -f 2)
if [ ${SMARTDNS_ENABLED} -eq 1 ]; then
  while [ $tries -lt 5 ]; do
    echo $DATE check $ALIYUN start >>$LOG
    NSLOOKUP=$(nslookup -port=${SMARTDNS_PORT} $ALIYUN 127.0.0.1 2>/dev/null | grep -v grep | grep 'Name:' | wc -l)
    if [ ${NSLOOKUP} -ne 0 ]; then
      echo $DATE check smartdns connect: OK >>$LOG
      exit 0
    else
      echo $DATE check $DNSPOD start >>$LOG
      NSLOOKUP=$(nslookup -port=${SMARTDNS_PORT} $DNSPOD 127.0.0.1 2>/dev/null | grep -v grep | grep 'Name:' | wc -l)
      if [ ${NSLOOKUP} -ne 0 ]; then
        echo $DATE check smartdns connect: OK >>$LOG
        exit 0
      else
        let tries++
        echo $DATE tries: $tries, smartdns restart >>$LOG
        /etc/init.d/smartdns restart
        sleep 10
      fi
    fi
  done
else
  echo $DATE smartdns enabled: ${SMARTDNS_ENABLED} >>$LOG
fi
