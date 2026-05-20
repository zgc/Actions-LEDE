#!/bin/bash

# 修复 Docker git 权限问题（必须在任何 git 命令之前）
export HOME=/root
git config --global --add safe.directory "*"

GITHUB_WORKSPACE=$(cd $(dirname $0);pwd)
RELEASE_DIR=${RELEASE_DIR:-$GITHUB_WORKSPACE/release}
DEVICE_NAME=$(grep "^CONFIG_TARGET.*DEVICE.*=y" config.seed | sed -r "s/CONFIG_TARGET_(.*)_DEVICE.*=y/\1/")
# Fallback: if DEVICE_NAME is empty, derive from firmware filename itself
RELEASE_NAME=${RELEASE_NAME:-${DEVICE_NAME:-firmware}}
REPO_URL="https://github.com/immortalwrt/immortalwrt"
REPO_BRANCH="openwrt-18.06-k5.4"
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
# Fix: patch the source tarball BEFORE make starts (same strategy as GCC)
RUBY_TARBALL="$GITHUB_WORKSPACE/openwrt/dl/ruby-3.1.2.tar.xz"
if [ -f "$RUBY_TARBALL" ]; then
  echo "🔧 Patching Ruby 3.1 source tarball (system Ruby as BASERUBY)..."
  RUBY_TMP=$(mktemp -d)
  tar xJf "$RUBY_TARBALL" -C "$RUBY_TMP" 2>/dev/null

  # 1. Remove --disable[-=]gems from Ruby internal tool scripts (host-compile uses them)
  find "$RUBY_TMP/ruby-3.1.2/tool" -name '*.rb' -exec sed -i 's/--disable[-=]gems//g' {} +

  # 2. Remove file2lastrev.rb references from uncommon.mk if present
  sed -i '/file2lastrev\.rb/!b;N;d' "$RUBY_TMP/ruby-3.1.2/uncommon.mk" 2>/dev/null || true

  # 3. Patch BASERUBY in configure-generated Makefile template (Makefile.in)
  if [ -f "$RUBY_TMP/ruby-3.1.2/Makefile.in" ]; then
    sed -i 's|BASERUBY = .*|BASERUBY = /usr/bin/ruby |' "$RUBY_TMP/ruby-3.1.2/Makefile.in"
  fi

  # Repack the tarball (overwrite in-place)
  tar cJf "$RUBY_TARBALL" -C "$RUBY_TMP" ruby-3.1.2 2>/dev/null
  rm -rf "$RUBY_TMP"
  echo "✅ Ruby 3.1 source tarball patched."
else
  echo "⏭️ Ruby tarball not yet downloaded; skipping patch."
fi

# Also patch any previously extracted Ruby build (incremental builds)
RUBY_BUILD="$GITHUB_WORKSPACE/openwrt/build_dir/hostpkg/ruby-3.1.2"
if [ -d "$RUBY_BUILD/tool" ]; then
  find "$RUBY_BUILD/tool" -name '*.rb' -exec sed -i 's/--disable[-=]gems//g' {} +
  if [ -f "$RUBY_BUILD/Makefile" ]; then
    sed -i 's|BASERUBY = .*|BASERUBY = /usr/bin/ruby |' "$RUBY_BUILD/Makefile"
  fi
fi
# Set GOPROXY for Go modules (fix frp build failure)
export GOPROXY=https://goproxy.cn,https://goproxy.io,direct
export GONOSUMCHECK=*
export GOSUMDB=off

# Fix GCC 8.4.0 libiberty compilation errors (missing headers in newer GCC host)
# Patch the source archive BEFORE make starts so it's baked in
GCC_TARBALL="$GITHUB_WORKSPACE/openwrt/dl/gcc-8.4.0.tar.xz"
if [ -f "$GCC_TARBALL" ]; then
  echo "🔧 Patching GCC 8.4.0 libiberty headers in tarball..."
  TMPDIR=$(mktemp -d)
  tar xJf "$GCC_TARBALL" -C "$TMPDIR" 2>/dev/null
  FIBHEAP="$TMPDIR/gcc-8.4.0/libiberty/fibheap.c"
  REGEX="$TMPDIR/gcc-8.4.0/libiberty/regex.c"
  if [ -f "$FIBHEAP" ] && ! grep -q '#include <limits.h>' "$FIBHEAP"; then
    sed -i '/#include "fibheap\.h"/a #include <limits.h>\n#include <string.h>' "$FIBHEAP"
    echo "✅ fibheap.c patched"
  fi
  if [ -f "$REGEX" ] && ! grep -q '#include <stdlib.h>' "$REGEX"; then
    sed -i '/#include <string\.h>/a #include <stdlib.h>' "$REGEX"
    echo "✅ regex.c patched"
  fi
  tar cJf "$GCC_TARBALL" -C "$TMPDIR" gcc-8.4.0 2>/dev/null
  rm -rf "$TMPDIR"
  echo "✅ GCC 8.4.0 tarball patched."
else
  echo "⏭️ GCC tarball not yet downloaded; skipping patch."
fi

make -j4 || make -j2 V=s

cp -f .config ${GITHUB_WORKSPACE}/${CONFIG_FILE}

# Return to workspace root for firmware copy (we're currently in openwrt/ subdir)
# NOTE: Use GITHUB_WORKSPACE instead of dirname $0 — in Docker sh -c mode, $0 is "bash" not the script path
export GITHUB_WORKSPACE="${GITHUB_WORKSPACE:-$(cd "$(dirname "$0")" 2>/dev/null && pwd || echo ".")}"
cd "$GITHUB_WORKSPACE"

mkdir -p "$RELEASE_DIR"

# Find the deepest firmware output directory under bin/targets
FIRMWARE_DIR=$(find openwrt/bin/targets -type d -name "64" 2>/dev/null | head -1)
if [ -z "$FIRMWARE_DIR" ]; then
  FIRMWARE_DIR=$(find openwrt/bin/targets -mindepth 2 -maxdepth 4 -type d 2>/dev/null | grep -v packages | head -1)
fi
echo "📦 Firmware directory: $FIRMWARE_DIR"

if [ -d "$FIRMWARE_DIR" ]; then
  cp -f "$FIRMWARE_DIR"/config.buildinfo "$RELEASE_DIR/" 2>/dev/null || true
  # Find the combined/EFI firmware image (preferred) or any .img.gz
  FIRMWARE_FILE=$(find "$FIRMWARE_DIR" -maxdepth 1 -name "*combined*img.gz" -type f 2>/dev/null | head -1)
  if [ -z "$FIRMWARE_FILE" ]; then
    FIRMWARE_FILE=$(find "$FIRMWARE_DIR" -maxdepth 1 -name "*img.gz" -type f 2>/dev/null | head -1)
  fi
  if [ -n "$FIRMWARE_FILE" ] && [ -f "$FIRMWARE_FILE" ]; then
    cp -f "$FIRMWARE_FILE" "$RELEASE_DIR/$RELEASE_NAME.img.gz"
    echo "✅ Firmware copied: $(basename "$FIRMWARE_FILE")"
  else
    echo "❌ No .img.gz found in $FIRMWARE_DIR!"
  fi
  MANIFEST=$(find "$FIRMWARE_DIR" -maxdepth 1 -name "*.manifest" -type f 2>/dev/null | head -1)
  if [ -n "$MANIFEST" ] && [ -f "$MANIFEST" ]; then
    cp -f "$MANIFEST" "$RELEASE_DIR/$RELEASE_NAME.manifest"
  fi
else
  echo "❌ Firmware directory not found!"
fi

cd "$RELEASE_DIR" || exit 1
# Use actual filename for md5 — handle case where RELEASE_NAME is empty and file has original name
IMG_FILE=$(ls -1 *.img.gz 2>/dev/null | head -1)
if [ -n "$IMG_FILE" ]; then
  BASE=$(basename "$IMG_FILE" .img.gz)
  md5sum "$IMG_FILE" > "${BASE}.img.gz.md5" 2>/dev/null || true
  gzip -dc "$IMG_FILE" | md5sum | sed "s/-/${BASE}.img/" > "${BASE}.img.md5" 2>/dev/null || true
fi
ls -lh *.img.gz 2>/dev/null
cd "$GITHUB_WORKSPACE"
