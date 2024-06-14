#!/bin/sh
DATE=$(date +%Y-%m-%d-%H:%M:%S)
tries=0
LOG=/tmp/check_wan_connect.log
PPPOE=$(/sbin/ifconfig 2>/dev/null | grep -v grep | grep 'pppoe-wan' | wc -l)
ALIYUN=223.5.5.5
DNSPOD=119.29.29.29
if [ ${PPPOE} -ne 0 ]; then
  while [ $tries -lt 5 ]; do
    echo $DATE check $ALIYUN start >>$LOG
    PING=$(ping -c1 $ALIYUN 2>/dev/null | grep -v grep | grep '64 bytes' | wc -l)
    if [ ${PING} -ne 0 ]; then
      echo $DATE check ppp connect: OK >>$LOG
      exit 0
    else
      echo $DATE check $DNSPOD start >>$LOG
      PING=$(ping -c1 $DNSPOD 2>/dev/null | grep -v grep | grep '64 bytes' | wc -l)
      if [ ${PING} -ne 0 ]; then
        echo $DATE check ppp connect: OK >>$LOG
        exit 0
      else
        let tries++
        echo $DATE tries: $tries, ppp restart >>$LOG
        ifdown wan | ifup wan
        sleep 10
      fi
    fi
  done
else
  while [ $tries -lt 5 ]; do
    eth1=$(/sbin/ifconfig eth1 2>/dev/null | grep 'inet addr:' | cut -d: -f2 | awk '{ print $1}')
    if [ -n ${eth1} ]; then
      GATEWAY=$(echo $eth1 | awk 'BEGIN{FS=OFS="."}{$NF=1;print}')
      PING=$(ping -c1 $GATEWAY 2>/dev/null | grep -v grep | grep '64 bytes' | wc -l)
      if [ ${PING} -ne 0 ]; then
        echo $DATE check wan connect: OK >>$LOG
        exit 0
      else
        let tries++
        echo $DATE tries: $tries, wan restart >>$LOG
        ifdown wan | ifup wan
        sleep 10
      fi
    else
      echo $DATE wan not connect >>$LOG
      exit 0
    fi
  done
fi
