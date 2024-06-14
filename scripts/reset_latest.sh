#!/bin/bash

IMG_DIR=${IMG_DIR:-/tmp}
cd $IMG_DIR

DISK=${DISK:-sda}
GITHUB_REPO="zgc/Actions-LEDE"
ARCH=`uname -m`

get_latest_release() {
	curl --retry 5 --header "Accept: application/vnd.github+json" --silent "https://api.github.com/repos/$1/releases/latest"
}

get_latest_assets() {
  curl --retry 5 -LJO -H 'Accept: application/octet-stream' "https://api.github.com/repos/$1/releases/assets/$2"
}

echo -e '\e[92m开始获取 '$GITHUB_REPO' latest版本\e[0m'
LATEST_RELEASE_JSON=`get_latest_release $GITHUB_REPO`

TAG_NAME=$(echo $LATEST_RELEASE_JSON | jsonfilter -e  @.tag_name)
IMG_GZ=$(echo $LATEST_RELEASE_JSON | jsonfilter -e  @.assets[1].name)
IMG_GZ_ID=$(echo $LATEST_RELEASE_JSON | jsonfilter -e  @.assets[1].id)
IMG_GZ_MD5=$(echo $LATEST_RELEASE_JSON | jsonfilter -e  @.assets[2].name)
IMG_GZ_MD5_ID=$(echo $LATEST_RELEASE_JSON | jsonfilter -e  @.assets[2].id)
IMG_MD5=$(echo $LATEST_RELEASE_JSON | jsonfilter -e  @.assets[3].name)
IMG_MD5_ID=$(echo $LATEST_RELEASE_JSON | jsonfilter -e  @.assets[3].id)
IMG=$(echo $LATEST_RELEASE_JSON | jsonfilter -e  @.assets[1].name | sed 's/\.[^.]*$//')

echo -e '\e[92m准备更新 '$TAG_NAME $ARCH' 到 '$DISK'\e[0m'

echo -e '\e[92m开始清理 '$IMG_GZ'\e[0m'
[ -e $IMG_GZ ] && rm $IMG_GZ
echo -e '\e[92m开始下载 '$IMG_GZ'\e[0m'
get_latest_assets $GITHUB_REPO $IMG_GZ_ID
echo -e '\e[92m开始清理 '$IMG_GZ_MD5'\e[0m'
[ -e $IMG_GZ_MD5 ] && rm $IMG_GZ_MD5
echo -e '\e[92m开始下载 '$IMG_GZ_MD5'\e[0m'
get_latest_assets $GITHUB_REPO $IMG_GZ_MD5_ID

echo -e '\e[92m开始校验 '$IMG_GZ'\e[0m'
GZ_SUM="$(md5sum -c "$IMG_GZ_MD5")"
if ! echo "$GZ_SUM" | grep 'OK' ; then
	echo -e "\e[91mMD5值匹配失败 $GZ_SUM\e[0m"
	exit 1
fi

echo -e '\e[92m开始清理 '$IMG_MD5'\e[0m'
[ -e $IMG_MD5 ] && rm $IMG_MD5
echo -e '\e[92m开始下载 '$IMG_MD5'\e[0m'
get_latest_assets $GITHUB_REPO $IMG_MD5_ID

echo -e '\e[92m开始清理 '$IMG'\e[0m'
[ -e $IMG ] && rm $IMG
echo -e '\e[92m开始解压 '$IMG_GZ'\e[0m'
gzip -d $IMG_GZ

echo -e '\e[92m开始校验 '$IMG'\e[0m'
IMG_SUM="$(md5sum -c "$IMG_MD5")"
if ! echo "$IMG_SUM" | grep 'OK' ; then
	echo -e "\e[91mMD5值匹配失败 $IMG_SUM\e[0m"
	exit 1
fi

echo -e '\e[92m开始写入 '$IMG' 到 '$DISK'\e[0m'
dd if=$IMG of=/dev/$DISK
echo -e '\e[92m写入结束，重启\e[0m'
echo b > /proc/sysrq-trigger
