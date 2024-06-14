#!/bin/bash

GITHUB_WORKSPACE=$(cd $(dirname $0);pwd)
RELEASE_DIR=${RELEASE_DIR:-$GITHUB_WORKSPACE/release}
DEVICE_NAME=$(grep '^CONFIG_TARGET.*DEVICE.*=y' config.seed | sed -r 's/CONFIG_TARGET_(.*)_DEVICE.*=y/\1/')
RELEASE_NAME=${RELEASE_NAME:-$DEVICE_NAME}
REPO_URL="https://github.com/coolsnowwolf/lede"
REPO_BRANCH="master"
FEEDS_CONF="feeds.conf.default"
CONFIG_FILE="config.seed"
DIY_P1_SH="diy-part1.sh"
DIY_P2_SH="diy-part2.sh"


if [ ! -e openwrt ]; then
  git clone --depth 1 $REPO_URL -b $REPO_BRANCH openwrt
else
  pushd openwrt
  rm -rf files package
  git pull origin $REPO_BRANCH
  git reset --hard origin/$REPO_BRANCH
  popd
fi

[ -e $FEEDS_CONF ] && cp $FEEDS_CONF openwrt/feeds.conf.default
chmod +x $DIY_P1_SH

pushd openwrt
GITHUB_WORKSPACE=$GITHUB_WORKSPACE $GITHUB_WORKSPACE/$DIY_P1_SH
./scripts/feeds update -f -a
./scripts/feeds install -a
popd

[ -e files ] && cp -r files openwrt/files
[ -e $CONFIG_FILE ] && cp $CONFIG_FILE openwrt/.config
chmod +x $DIY_P2_SH

pushd openwrt
GITHUB_WORKSPACE=$GITHUB_WORKSPACE $GITHUB_WORKSPACE/$DIY_P2_SH
make defconfig
make download -j8
make -j$(nproc) || make -j1 || make -j1 V=s
popd

mkdir -p $RELEASE_DIR
pushd openwrt/bin/targets/*/*
cp config.buildinfo $RELEASE_DIR
cp $(ls -1 ./*img.gz | head -1) $RELEASE_DIR/$RELEASE_NAME.img.gz
popd

pushd $RELEASE_DIR
md5sum $RELEASE_NAME.img.gz > $RELEASE_NAME.img.gz.md5
gzip -dc $RELEASE_NAME.img.gz | md5sum | sed "s/-/$RELEASE_NAME.img/" > $RELEASE_NAME.img.md5
popd
