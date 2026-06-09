#!/bin/bash
#
# Actions-LEDE — Generic OpenWrt/ImmortalWrt Build Script
# Base: ImmortalWrt master
#
# Device-specific overrides: create device.conf in the same directory
# Example device.conf:
#   RELEASE_NAME=nuc8
#

# ============================================================
# Section 1: Git Configuration
# ============================================================

GITHUB_WORKSPACE=$(cd $(dirname $0);pwd)
# Source device-specific overrides
[ -f "$GITHUB_WORKSPACE/device.conf" ] && source "$GITHUB_WORKSPACE/device.conf"

# Fix: Docker container git detects root-owned repo, refuses operations
git config --global --add safe.directory '*'
# Fix: git compiled against GnuTLS has unstable TLS 1.3 handshakes with GitHub
# Force TLS 1.2 + HTTP/1.1 to avoid GnuTLS TLS 1.3 issues
# Also increase postBuffer to reduce round-trips
# NOTE: do NOT remove libcurl3-gnutls — Ubuntu 22.04's git depends on it
git config --global http.sslVersion tlsv1.2
git config --global http.version HTTP/1.1
git config --global http.postBuffer 524288000

# ============================================================
# Section 2: Variables
# ============================================================

RELEASE_DIR=${RELEASE_DIR:-$GITHUB_WORKSPACE/release}
DEVICE_NAME=$(grep '^CONFIG_TARGET.*DEVICE.*=y' config.seed | sed -r 's/CONFIG_TARGET_(.*)_DEVICE.*=y/\1/')
RELEASE_NAME=${RELEASE_NAME:-${DEVICE_NAME:-firmware}}
REPO_URL="https://github.com/immortalwrt/immortalwrt"
REPO_BRANCH="master"
REPO_COMMIT=""
FEEDS_CONF="feeds.conf.default"
CONFIG_FILE="config.seed"
DIY_P1_SH="diy-part1.sh"
DIY_P2_SH="diy-part2.sh"

# ============================================================
# Section 2.1: Build Prerequisites
# ============================================================

# python3-setuptools is required by ImmortalWrt's u-boot prereq check
if ! python3 -c "import setuptools" 2>/dev/null; then
  echo "⚠️ python3-setuptools missing, installing..."
  apt-get update -qq && apt-get install -y -qq python3-setuptools > /dev/null 2>&1
  echo "✅ python3-setuptools installed"
fi

# ============================================================
# Section 3: Clone/Pull OpenWrt
# ============================================================

if [ ! -e openwrt ]; then
  git clone --depth 1 $REPO_URL -b $REPO_BRANCH openwrt
elif [ -z $REPO_COMMIT ]; then
  pushd openwrt
  rm -rf files package
  git pull origin $REPO_BRANCH
  git reset --hard origin/$REPO_BRANCH
  popd
fi

if [ ! -z $REPO_COMMIT ]; then
  pushd openwrt
  rm -rf files package
  git pull origin $REPO_COMMIT
  git reset --hard $REPO_COMMIT
  popd
fi

# ============================================================
# Section 4: Feeds Setup
# ============================================================

[ -e $FEEDS_CONF ] && cp $FEEDS_CONF openwrt/feeds.conf.default
chmod +x $DIY_P1_SH

pushd openwrt
# Restore feeds files deleted by previous builds (Docker volume mount persistence)
for feed_dir in feeds/*/; do
  if [ -d "$feed_dir/.git" ]; then
    rm -f "$feed_dir/.git/index.lock"
    git -C "$feed_dir" checkout -- . 2>/dev/null
  fi
done
# Fix: Docker root ownership on feeds
chown -R $(stat -c '%u:%g' .) feeds/ 2>/dev/null || true

GITHUB_WORKSPACE=$GITHUB_WORKSPACE $GITHUB_WORKSPACE/$DIY_P1_SH
./scripts/feeds update -f -a
./scripts/feeds install -a

# ============================================================
# Section 5: Config
# ============================================================

[ -e ../$CONFIG_FILE ] && cp ../$CONFIG_FILE .config
make defconfig

# LuCI 25.12 removed luci-base/host/compile (po2lmo no longer needed)
# echo "编译 luci-base 生成 po2lmo..."
# make package/luci-base/host/compile -j$(nproc) || make package/luci-base/host/compile -j1 V=s

popd

[ -e files ] && cp -r files openwrt/files
[ -e $CONFIG_FILE ] && cp $CONFIG_FILE openwrt/.config
chmod +x $DIY_P2_SH

pushd openwrt
GITHUB_WORKSPACE=$GITHUB_WORKSPACE $GITHUB_WORKSPACE/$DIY_P2_SH
make defconfig

# ============================================================
# Section 6: Package Fixes
# ============================================================

# Set GOPROXY for Go modules (fix frp/adguardhome build)
export GOPROXY=https://goproxy.cn,https://goproxy.io,direct
export GONOSUMCHECK=*
export GOSUMDB=off

# Fix netdata build: disable cloud/ACLK to remove protobuf dependency
# Root cause: netdata's #define error(args...) macro conflicts with abseil-cpp headers
# (protobuf 29.5 -> abseil-cpp). --disable-cloud removes the protobuf dependency entirely.
NETDATA_FEED=feeds/packages/admin/netdata
if [ -f "$NETDATA_FEED/Makefile" ]; then
  if grep -q '\-\-disable-cloud' "$NETDATA_FEED/Makefile"; then
    echo "✅ netdata: --disable-cloud already present"
  else
    sed -i 's/\t--disable-ml$/\t--disable-ml \\\n\t--disable-cloud/' "$NETDATA_FEED/Makefile"
    if grep -q '\-\-disable-cloud' "$NETDATA_FEED/Makefile"; then
      echo "✅ netdata: --disable-cloud added (removes protobuf dependency)"
    else
      echo "⚠️ netdata: --disable-cloud not added (--disable-ml pattern changed, manual fix needed)"
    fi
  fi
fi

# Ensure zerotier LuCI is enabled after defconfig
sed -i 's/# CONFIG_PACKAGE_luci-app-zerotier is not set/CONFIG_PACKAGE_luci-app-zerotier=y/' .config
sed -i 's/CONFIG_PACKAGE_luci-app-zerotier=m/CONFIG_PACKAGE_luci-app-zerotier=y/' .config

# Bump zerotier to 1.16.2 (feeds has older, 1.16.2 supports moon natively)
ZT_FEED=feeds/packages/net/zerotier
ZT_VER_TARGET="1.16.2"
if [ -f $ZT_FEED/Makefile ]; then
  ZT_VER_CURRENT=$(grep '^PKG_VERSION:=' "$ZT_FEED/Makefile" | head -1 | cut -d= -f2)
  if [ "$ZT_VER_CURRENT" != "$ZT_VER_TARGET" ]; then
    sed -i "s/^PKG_VERSION:=$ZT_VER_CURRENT/PKG_VERSION:=$ZT_VER_TARGET/" $ZT_FEED/Makefile
    # Download and compute correct hash for target version
    ZT_HASH=$(curl -sL "https://codeload.github.com/zerotier/ZeroTierOne/tar.gz/$ZT_VER_TARGET" | sha256sum | awk '{print $1}')
    if [ -n "$ZT_HASH" ] && [ ${#ZT_HASH} -eq 64 ]; then
      sed -i "s/^PKG_HASH:=.*/PKG_HASH:=$ZT_HASH/" $ZT_FEED/Makefile
      echo "✅ zerotier bumped $ZT_VER_CURRENT → $ZT_VER_TARGET (hash: ${ZT_HASH:0:12}...)"
    else
      echo "⚠️ zerotier hash compute failed, reverting version"
      sed -i "s/^PKG_VERSION:=$ZT_VER_TARGET/PKG_VERSION:=$ZT_VER_CURRENT/" $ZT_FEED/Makefile
    fi
  else
    echo "✅ zerotier already at $ZT_VER_TARGET"
  fi
  # Enable config_path for persistent zerotier data (identity, moon, networks)
  ZT_CONF=$ZT_FEED/files/etc/config/zerotier
  if [ -f "$ZT_CONF" ]; then
    sed -i "s/#option config_path '.*'/option config_path '\/etc\/zerotier'/" "$ZT_CONF"
    echo "✅ zerotier config_path enabled for data persistence"
  fi
fi


# ============================================================
# Section 7: Download
# ============================================================

# Drop caches to free memory before compilation (prevents OOM in Docker)
sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true

make download -j8 || make download -j1 V=s
find dl -not -path "dl/go-mod-cache/*" -size -1024c -type f -exec rm -f {} \;
find dl -not -path "dl/go-mod-cache/*" -size 0 -type f -exec rm -f {} \;

# ============================================================
# Section 8: vlmcsd GCC 13 Fix
# ============================================================

# $(notdir $(CC)) breaks when CC="ccache gcc" (contains spaces)
make package/feeds/packages/vlmcsd/prepare 2>/dev/null || true
VLMCSD_GNUMAKE=$(ls build_dir/target-*/vlmcsd-*/src/GNUmakefile 2>/dev/null | head -1)
if [ -n "$VLMCSD_GNUMAKE" ]; then
  sed -i 's/notdir $(CC)/lastword $(subst ccache, ,$(CC))/g' "$VLMCSD_GNUMAKE"
fi

# ============================================================
# Section 9: Go Packages Pre-compile
# ============================================================

# Go packages (frp, adguardhome, filebrowser) have intermittent parallel build
# race conditions with -j16 due to shared Go module cache.
# Pre-compile them with -j1 so the main -j16 build skips them.
echo "=== Pre-compiling Go packages with -j1 ==="
for go_pkg in frp adguardhome filebrowser; do
  if [ -d "package/feeds/packages/$go_pkg" ]; then
    echo "Pre-compiling $go_pkg with -j1..."
    make "package/feeds/packages/$go_pkg/compile" -j1 V=s 2>&1 | tail -5
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
      echo "WARNING: $go_pkg failed, retrying..."
      make "package/feeds/packages/$go_pkg/compile" -j1 V=s 2>&1 | tail -5
    fi
  fi
done
echo "=== Go packages pre-compilation done ==="

# ============================================================
# Section 10: Main Build
# ============================================================

make -j$(nproc) || make -j1 || make -j1 V=s
popd

# ============================================================
# Section 11: Save Config & Copy Firmware
# ============================================================

# Return to workspace root FIRST
export GITHUB_WORKSPACE="${GITHUB_WORKSPACE:-$(cd "$(dirname "$0")" 2>/dev/null && pwd || echo ".")}"
cd "$GITHUB_WORKSPACE"

# Save expanded .config as config.buildinfo (NEVER overwrite config.seed — it's our input!)
cp -f openwrt/.config config.buildinfo
echo "✅ Saved expanded config to config.buildinfo"

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
    echo "✅ Firmware: $(basename "$FIRMWARE_FILE")"
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
IMG_FILE=$(ls -1 *.img.gz 2>/dev/null | head -1)
if [ -n "$IMG_FILE" ]; then
  BASE=$(basename "$IMG_FILE" .img.gz)
  md5sum "$IMG_FILE" > "${BASE}.img.gz.md5" 2>/dev/null || true
  gzip -dc "$IMG_FILE" | md5sum | sed "s/-/${BASE}.img/" > "${BASE}.img.md5" 2>/dev/null || true
fi
ls -lh *.img.gz 2>/dev/null
cd "$GITHUB_WORKSPACE"
