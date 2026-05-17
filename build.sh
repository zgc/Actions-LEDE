#!/bin/bash

# 修复 Docker git 权限问题（必须在任何 git 命令之前）
export HOME=/root
git config --global --add safe.directory "*"

GITHUB_WORKSPACE=$(cd $(dirname $0);pwd)
RELEASE_DIR=${RELEASE_DIR:-$GITHUB_WORKSPACE/release}
DEVICE_NAME=$(grep "^CONFIG_TARGET.*DEVICE.*=y" config.seed | sed -r "s/CONFIG_TARGET_(.*)_DEVICE.*=y/\1/")
RELEASE_NAME=${RELEASE_NAME:-$DEVICE_NAME}
REPO_URL="https://github.com/immortalwrt/immortalwrt"
REPO_BRANCH="openwrt-18.06"
REPO_COMMIT=""
FEEDS_CONF="feeds.conf.default"
CONFIG_FILE="config.seed"
DIY_P1_SH="diy-part1.sh"
DIY_P2_SH="diy-part2.sh"


if [ ! -d openwrt/.git ]; then
  # Docker volume mount 的 dl/feeds 导致 rm 失败，先 umount
  umount openwrt/dl 2>/dev/null || true
  umount openwrt/feeds 2>/dev/null || true
  rm -rf openwrt
  git clone --depth 1 $REPO_URL -b $REPO_BRANCH openwrt
elif [ -z $REPO_COMMIT ]; then
  pushd openwrt
  rm -rf files package
  git pull origin $REPO_BRANCH || true
  git reset --hard HEAD
  popd
fi

if [ ! -z $REPO_COMMIT ]; then
  pushd openwrt
  rm -rf files package
  git pull origin $REPO_COMMIT || true
  git reset --hard HEAD
  popd
fi

[ -e $FEEDS_CONF ] && cp $FEEDS_CONF openwrt/feeds.conf.default
chmod +x $DIY_P1_SH

pushd openwrt
GITHUB_WORKSPACE=$GITHUB_WORKSPACE $GITHUB_WORKSPACE/$DIY_P1_SH
./scripts/feeds update -f -a
./scripts/feeds install -a

[ -e ../$CONFIG_FILE ] && cp ../$CONFIG_FILE .config
make defconfig

make package/luci-base/host/compile -j$(nproc) || make package/luci-base/host/compile -j1 V=s

# Pre-build Ruby host patch: apply BEFORE the main make starts
RUBY_MAKEFILE="$GITHUB_WORKSPACE/openwrt/build_dir/hostpkg/ruby-3.1.2/Makefile"
RUBY_MK="$GITHUB_WORKSPACE/openwrt/build_dir/hostpkg/ruby-3.1.2/uncommon.mk"
if [ -f "$RUBY_MAKEFILE" ]; then
  echo "🔧 Pre-patching Ruby 3.1 host build (system Ruby as BASERUBY)..."
  sed -i 's|BASERUBY = .*|BASERUBY = /usr/bin/ruby |' "$RUBY_MAKEFILE"
  sed -i '1191s|.*|\t\$(Q) echo "" > \$@|' "$RUBY_MK" 2>/dev/null || true
  echo "✅ Ruby host build patch applied before main build."
else
  echo "⏭️ Ruby source not yet extracted; will patch later."
fi

popd
chmod +x $DIY_P2_SH
cd openwrt
GITHUB_WORKSPACE=$GITHUB_WORKSPACE $GITHUB_WORKSPACE/$DIY_P2_SH

make defconfig

cd $GITHUB_WORKSPACE/openwrt
make download -j$(nproc) || make download -j1 V=s
find dl -not -path "dl/go-mod-cache/*" -size -1024c -exec rm -f {} \;
find dl -not -path "dl/go-mod-cache/*" -size 0 -exec rm -f {} \;
# Fix Ruby 3.1 bundled gems LoadError (optparse/fileutils/erb)
# Ruby 3.1 stdlib → bundled gems; OpenWrt --disable=gems breaks host build
# Fix: use system Ruby (Docker ruby 3.0) as BASERUBY
RUBY_MAKEFILE="$GITHUB_WORKSPACE/openwrt/build_dir/hostpkg/ruby-3.1.2/Makefile"
RUBY_MK="$GITHUB_WORKSPACE/openwrt/build_dir/hostpkg/ruby-3.1.2/uncommon.mk"
if [ -f "$RUBY_MAKEFILE" ]; then
  echo "🔧 Patching Ruby 3.1 host build (system Ruby as BASERUBY)..."
  sed -i 's|BASERUBY = .*|BASERUBY = /usr/bin/ruby |' "$RUBY_MAKEFILE"
  sed -i '1191s|.*|\\t$(Q) echo "" > $@|' "$RUBY_MK" 2>/dev/null || true
  echo "✅ Ruby host build patch applied."
else
  echo "⏭️ Ruby source not yet extracted; will skip patch."
fi
make -j4 || make -j2 V=s

cp -f .config ${GITHUB_WORKSPACE}/${CONFIG_FILE}

cd $GITHUB_WORKSPACE/openwrt/bin/targets/*/*
cp -f config.buildinfo ${GITHUB_WORKSPACE}/${CONFIG_FILE}
ls -A *.img.gz 2>/dev/null && cp -f *.img.gz ${GITHUB_WORKSPACE}/release/x86_64.img.gz
ls -A *.manifest 2>/dev/null && cp -f *.manifest ${GITHUB_WORKSPACE}/release/x86_64.manifest
cd ${GITHUB_WORKSPACE}/release
ls *.img.gz 2>/dev/null
