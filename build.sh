#!/bin/bash
#
# Actions-LEDE — Generic OpenWrt/ImmortalWrt Build Script
# Base: ImmortalWrt master
#
# Device-specific overrides: create openwrt-device.conf in the same directory
# Example openwrt-device.conf:
#   RELEASE_NAME=nuc8
#

# ============================================================
# Section 1: Git Configuration
# ============================================================

GITHUB_WORKSPACE=$(cd $(dirname $0);pwd)
# Source device-specific overrides
[ -f "$GITHUB_WORKSPACE/openwrt-device.conf" ] && source "$GITHUB_WORKSPACE/openwrt-device.conf"

# Fix: Docker container git detects root-owned repo, refuses operations
git config --global --add safe.directory '*'
# Fix: Docker image now has git compiled against OpenSSL (not GnuTLS)
# TLS workarounds no longer needed — keep postBuffer as safety net
git config --global http.postBuffer 524288000

# ============================================================
# Section 2: Variables
# ============================================================

RELEASE_DIR=${RELEASE_DIR:-$GITHUB_WORKSPACE/release}
DEVICE_NAME=$(grep '^CONFIG_TARGET.*DEVICE.*=y' config.seed | sed -r 's/CONFIG_TARGET_(.*)_DEVICE.*=y/\1/')
RELEASE_NAME=${RELEASE_NAME:-${DEVICE_NAME:-firmware}}
REPO_URL="https://github.com/immortalwrt/immortalwrt"
REPO_BRANCH="${REPO_BRANCH:-master}"
REPO_COMMIT=""
FEEDS_CONF="feeds.conf.default"
CONFIG_FILE="config.seed"
DIY_P1_SH="diy-part1.sh"
DIY_P2_SH="diy-part2.sh"

# Build cache directory for Docker volume persistence (staging_dir, build_dir, dl)
# Mount a Docker volume here to reuse cross-compiler toolchain between container runs
BUILD_CACHE_DIR=${BUILD_CACHE_DIR:-}

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
# Section 2.2: Build Cache Functions
# ============================================================

save_build_caches() {
  [ -z "$BUILD_CACHE_DIR" ] && return 0
  local src="${1:-openwrt}"
  for dir in dl staging_dir build_dir; do
    if [ -d "$src/$dir" ] && [ ! -L "$src/$dir" ]; then
      mkdir -p "$BUILD_CACHE_DIR"
      rm -rf "$BUILD_CACHE_DIR/$dir"
      mv "$src/$dir" "$BUILD_CACHE_DIR/$dir"
      echo "✅ Saved $dir to build cache"
    fi
  done
}

restore_build_caches() {
  [ -z "$BUILD_CACHE_DIR" ] && return 0
  local tgt="${1:-openwrt}"
  # 2-step: cache → /tmp → target (target dir doesn't exist at restore time)
  for dir in dl staging_dir build_dir; do
    [ -d "$BUILD_CACHE_DIR/$dir" ] && mv "$BUILD_CACHE_DIR/$dir" "/tmp/$dir-cache"
  done
  for dir in dl staging_dir build_dir; do
    [ -d "/tmp/$dir-cache" ] && mv "/tmp/$dir-cache" "$tgt/$dir" && echo "✅ Restored $dir from build cache"
  done
}

# ============================================================
# Section 3: Clone/Pull OpenWrt
# ============================================================

if [ ! -e openwrt ] || [ ! -d openwrt/.git ]; then
  # No valid git clone — need fresh clone
  # Build cache: saves cross-compiler toolchain (~10 min), dl (~5 min), build_dir (~5 min)
  # Save existing caches before wiping (Docker volume persistence)
  [ -d openwrt ] && save_build_caches

  rm -rf openwrt
  # GnuTLS intermittent TLS error workaround: HTTP/1.1 + retry loop
  git config --global http.version HTTP/1.1
  for _ in 1 2 3; do
    rm -rf openwrt
    git clone --depth 1 $REPO_URL -b $REPO_BRANCH openwrt && break
    echo "⚠️ git clone failed, retrying..."
    sleep 3
  done
  if [ ! -f openwrt/Makefile ]; then
    echo "❌ git clone failed after 3 attempts"
    exit 1
  fi

  restore_build_caches
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

if ! GITHUB_WORKSPACE=$GITHUB_WORKSPACE BUILD_CACHE_DIR=$BUILD_CACHE_DIR $GITHUB_WORKSPACE/$DIY_P1_SH; then
  echo "❌ diy-part1.sh failed"
  exit 1
fi
./scripts/feeds update -f -a
./scripts/feeds install -a

# Remove feeds symlinks that conflict with custom (emortal) packages
# Ensures custom versions under package/emortal/ always win cleanly
for pkg_dir in package/emortal/*/; do
  pkg_name="$(basename "$pkg_dir")"
  # Only target symlinks (feeds install artifacts)
  find package/feeds -maxdepth 3 -type l -name "$pkg_name" 2>/dev/null | while read -r link; do
    rm -f "$link"
    echo "✅ Removed conflicting feeds symlink: $link"
  done
done

# ============================================================
# Section 5: Config
# ============================================================

[ -e $GITHUB_WORKSPACE/$CONFIG_FILE ] && cp $GITHUB_WORKSPACE/$CONFIG_FILE .config
make defconfig || { echo "❌ defconfig failed"; exit 1; }

popd

[ -e $GITHUB_WORKSPACE/files ] && cp -r $GITHUB_WORKSPACE/files openwrt/files
[ -e $GITHUB_WORKSPACE/$CONFIG_FILE ] && cp $GITHUB_WORKSPACE/$CONFIG_FILE openwrt/.config
chmod +x $DIY_P2_SH

pushd openwrt
GITHUB_WORKSPACE=$GITHUB_WORKSPACE $GITHUB_WORKSPACE/$DIY_P2_SH
make defconfig || { echo "❌ defconfig (post diy) failed"; exit 1; }

# Prevent false-positive full rebuild due to defconfig timestamp change.
# make defconfig updates .config mtime, which makes all existing .built stamps
# appear stale. The solution: touch existing .built to match .config so make only
# compiles genuinely new packages (like smartdns) that have no .built yet.
# Docker overlay2 filesystem rounds down sub-second timestamps, so
# `touch -r .config` makes .built ~1s OLDER than .config → full rebuild.
# Fix: set timestamps to .config epoch + 2 seconds to ensure .built > .config.
CONFIG_TS=$(stat -c%Y .config)
NEW_TS=$((CONFIG_TS + 2))
# Sync all existing .built stamps to .config + 2s so make skips stale packages.
find build_dir/target-*/ -name .built -exec touch -d @$NEW_TS {} \; 2>/dev/null || true
find build_dir/hostpkg/ -name .built -exec touch -d @$NEW_TS {} \; 2>/dev/null || true
# Sync _installed stamps EXCEPT smartdns/luci-app-smartdns (must be rebuilt).
find staging_dir/target-*/stamp/ -name ".*_installed" ! -name "*.smartdns*" ! -name "*.luci-app-smartdns*" -exec touch -d @$NEW_TS {} \; 2>/dev/null || true
find staging_dir/hostpkg/stamp/ -name ".*_installed" ! -name "*.smartdns*" ! -name "*.luci-app-smartdns*" -exec touch -d @$NEW_TS {} \; 2>/dev/null || true
# CLEAN smartdns stamps from build_dir so make recompiles from scratch
# (built from incomplete 6th-build artifacts, install always fails).
rm -f build_dir/target-*/smartdns-*/.built
rm -f build_dir/target-*/luci-app-smartdns-*/.built
rm -f staging_dir/target-*/stamp/.smartdns_installed
rm -f staging_dir/target-*/stamp/.luci-app-smartdns_installed
unset CONFIG_TS NEW_TS

# ============================================================
# Section 6: Package Fixes
# ============================================================

# Set GOPROXY for Go modules (fix frp build)
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

# Fix gnutls 3.8.10 stdbool.h cross-compilation error (gnulib detects ac_cv_header_stdbool_h=yes
# but its replacement module still undef's HAVE_STDBOOL_H because it checks C99 compiler capabilities)
# Patch config.h after configure to force HAVE_STDBOOL_H=1.
GNUTLS_FEED=feeds/packages/libs/gnutls
if [ -f "$GNUTLS_FEED/Makefile" ]; then
  if ! grep -q 'HAVE_STDBOOL_H' "$GNUTLS_FEED/Makefile"; then
    sed -i '/^define Build\/InstallDev/i define Build/Configure\n\t$$(call Build/Configure/Default)\n\t$$(SED) "s|/\\* #undef HAVE_STDBOOL_H \\*/|#define HAVE_STDBOOL_H 1|" $$(PKG_BUILD_DIR)/config.h\nendef\n' "$GNUTLS_FEED/Makefile"
    if grep -q 'HAVE_STDBOOL_H' "$GNUTLS_FEED/Makefile"; then
      echo "✅ gnutls: HAVE_STDBOOL_H fix applied (config.h patch after configure)"
    else
      echo "⚠️ gnutls: fix not applied (sed pattern changed, manual fix needed)"
    fi
  else
    echo "✅ gnutls: HAVE_STDBOOL_H fix already applied"
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
# Section 7: Build Performance Optimizations
# ============================================================

# Disable Python3 host PGO (saves ~8 min per build)
# Host Python3 is only a build tool — PGO provides zero benefit to firmware quality
PY3_FEED=feeds/packages/lang/python/python3
if [ -f "$PY3_FEED/Makefile" ]; then
  if grep -q -- '--enable-optimizations' "$PY3_FEED/Makefile"; then
    sed -i 's/--enable-optimizations/--disable-optimizations/' "$PY3_FEED/Makefile"
    echo "✅ python3 host: PGO disabled (--enable-optimizations → --disable-optimizations)"
  else
    echo "✅ python3 host: PGO already disabled"
  fi
fi

# ============================================================
# Section 8: Download
# ============================================================

# Drop caches to free memory before compilation (prevents OOM in Docker)
sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true

make download -j8 || make download -j1 V=s || { echo "❌ make download failed"; exit 1; }
find dl -not -path "dl/go-mod-cache/*" -size -1024c -type f -exec rm -f {} \;
find dl -not -path "dl/go-mod-cache/*" -size 0 -type f -exec rm -f {} \;

# Build and install host tools (sed, autoconf, automake, m4, libtool, etc.)
# Required before any host package compile — make download only downloads, doesn't build
#
# util-linux uses meson which requires python3 at staging_dir/host/bin/python3.
# Symlink system python3 there temporarily; proper feeds python3 host compile
# happens in the Go/packages section later (overwrites this symlink).
mkdir -p staging_dir/host/bin
if ! [ -f staging_dir/host/bin/python3 ]; then
  ln -sf "$(which python3)" staging_dir/host/bin/python3
  echo "✅ symlinked system python3 → staging_dir/host/bin/python3"
fi
echo "=== Building and installing host tools ==="
make tools/install -j$(nproc) V=s || { echo "❌ tools/install failed"; exit 1; }
echo "✅ host tools installed"

# ============================================================
# Section 9: Go Packages Pre-compile
# ============================================================

# Pre-compile python3 host tooling (needed by meson for apk/host build)
# Without this, frp pre-compile can trigger apk/host which needs python3 host via meson.
# feeds install symlinks: feeds/packages/lang/python/python3 -> package/feeds/packages/python3
if ls package/feeds/packages/python3/Makefile 2>/dev/null; then
  echo "=== Pre-compiling python3 host tooling (for meson/apk) ==="
  make package/feeds/packages/python3/host/compile -j1 V=s
  # Symlink python3 from hostpkg→host so meson cross-file can find it
  if [ -f staging_dir/hostpkg/bin/python3 ]; then
    ln -sf ../../hostpkg/bin/python3 staging_dir/host/bin/python3
    echo "✅ symlinked hostpkg/bin/python3 → host/bin/python3"
  fi
  echo "✅ python3 host build done"
fi

# Go packages (frp) have intermittent parallel build
# race conditions with -j16 due to shared Go module cache.
# Pre-compile them with -j1 so the main -j16 build skips them.
echo "=== Pre-compiling Go packages with -j1 ==="
for go_pkg in frp; do
  # Only pre-compile packages actually needed (check if any =y entry references this package)
  if ! grep '=y' .config 2>/dev/null | grep -qi "$go_pkg"; then
    echo "Skipping $go_pkg (not enabled in .config)"
    continue
  fi
  if [ -d "package/feeds/packages/$go_pkg" ]; then
    echo "Pre-compiling $go_pkg with -j1..."
    make "package/feeds/packages/$go_pkg/compile" -j1 V=s
    if [ $? -ne 0 ]; then
      echo "WARNING: $go_pkg failed, retrying..."
      make "package/feeds/packages/$go_pkg/compile" -j1 V=s
    fi
  fi
done
echo "=== Go packages pre-compilation done ==="

# ============================================================
# Section 10: Main Build
# ============================================================

# Clean stale squashfs and target-dir caches to force prepare_rootfs
# to re-apply the files/ overlay. Without this, -j parallel builds
# may skip target-dir-% (which calls prepare_rootfs) and use a cached
# squashfs that lacks custom files.
rm -f build_dir/target-x86_64_musl/linux-x86_64/root.squashfs
rm -rf build_dir/target-x86_64_musl/linux-x86_64/target-dir-*

echo "=== Stale squashfs/target-dir cleaned ==="

# Free memory before main build to prevent OOM
sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true

echo "=== Memory caches dropped, starting main build ==="

make -j$(nproc) V=s
BUILD_RC=$?
if [ $BUILD_RC -ne 0 ]; then
  echo "⚠️ First attempt failed, cleaning kernel build dir and retrying..."
  echo "=== target/linux/clean ==="
  make target/linux/clean V=s 2>/dev/null || true
  rm -rf build_dir/target-x86_64_musl/linux-x86_64/linux-*
  # Also clean packages that are known to have transient ZFS parallel-build races
  for pkg in intel-microcode linux-atm; do
    make package/firmware/$pkg/clean V=s 2>/dev/null || true
    make package/kernel/$pkg/clean V=s 2>/dev/null || true
  done
  make -j$(nproc) V=s
  BUILD_RC=$?
fi
popd

if [ $BUILD_RC -ne 0 ]; then
  echo "❌ Build failed with exit code $BUILD_RC"
  echo "❌ Firmware copy SKIPPED — no valid build output"
  exit $BUILD_RC
fi

# ============================================================
# Section 11: Save Config & Copy Firmware
# ============================================================


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
