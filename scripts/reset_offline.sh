#!/bin/bash

IMG_DIR=${IMG_DIR:-/tmp}
cd $IMG_DIR

DISK=${DISK:-sda}
ARCH=`uname -m`
RELEASE_NAME=${RELEASE_NAME:-$ARCH}

IMG_GZ=$RELEASE_NAME.img.gz
IMG_GZ_MD5=$RELEASE_NAME.img.gz.md5
IMG_MD5=$RELEASE_NAME.img.md5
IMG=$RELEASE_NAME.img

echo -e '\e[92m准备更新 '$ARCH' img 到 '$DISK'\e[0m'

echo -e '\e[92m开始检查 '$IMG_GZ'\e[0m'
[ ! -e $IMG_GZ ] && echo -e "\e[91m '$IMG_GZ' 不存在\e[0m" && exit 1
echo -e '\e[92m开始检查 '$IMG_GZ_MD5'\e[0m'
[ ! -e $IMG_GZ_MD5 ] && echo -e "\e[91m '$IMG_GZ_MD5' 不存在\e[0m" && exit 1

echo -e '\e[92m开始校验 '$IMG_GZ'\e[0m'
GZ_SUM="$(md5sum -c $IMG_GZ_MD5)"
if ! echo "$GZ_SUM" | grep 'OK' ; then
	echo -e "\e[91mMD5值匹配失败 $GZ_SUM\e[0m"
	exit 1
fi

echo -e '\e[92m开始检查 '$IMG_MD5'\e[0m'
[ ! -e $IMG_MD5 ] && echo -e "\e[91m '$IMG_MD5' 不存在\e[0m" && exit 1


echo -e '\e[92m开始清理 '$IMG'\e[0m'
[ -e $IMG ] && rm $IMG
echo -e '\e[92m开始解压 '$IMG_GZ'\e[0m'
gzip -d $IMG_GZ

echo -e '\e[92m开始校验 '$IMG'\e[0m'
IMG_SUM="$(md5sum -c $IMG_MD5)"
if ! echo "$IMG_SUM" | grep 'OK' ; then
	echo -e "\e[91mMD5值匹配失败 $IMG_SUM\e[0m"
	exit 1
fi

echo -e '\e[92m开始写入 '$IMG' 到 '$DISK'\e[0m'
dd if=$IMG of=/dev/$DISK
echo -e '\e[92m写入结束，重启\e[0m'
echo b > /proc/sysrq-trigger
