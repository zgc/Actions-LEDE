#!/bin/bash
#
# Actions-LEDE — Generic OpenWrt/ImmortalWrt Build Script
# Base: ImmortalWrt 18.06-k5.4
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
REPO_BRANCH="openwrt-18.06-k5.4"
REPO_COMMIT=""
FEEDS_CONF="feeds.conf.default"
CONFIG_FILE="config.seed"
DIY_P1_SH="diy-part1.sh"
DIY_P2_SH="diy-part2.sh"

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
# Section 6: Package Replacement & Fixes
# ============================================================

# Ensure zerotier LuCI is enabled after defconfig
sed -i 's/# CONFIG_PACKAGE_luci-app-zerotier is not set/CONFIG_PACKAGE_luci-app-zerotier=y/' .config
sed -i 's/CONFIG_PACKAGE_luci-app-zerotier=m/CONFIG_PACKAGE_luci-app-zerotier=y/' .config

# Replace feeds packages with coolsnowwolf/emortal versions
# Only delete feeds version if emortal has a Makefile (graceful fallback)
if [ -f package/emortal/luci-app-turboacc/Makefile ]; then
  rm -rf feeds/luci/applications/luci-app-turboacc
fi
for pkg in luci-app-diskman luci-app-frpc luci-app-ksmbd luci-app-netdata luci-app-smartdns luci-app-ttyd luci-app-vlmcsd luci-app-zerotier; do
  if [ -f package/emortal/$pkg/Makefile ]; then
    rm -rf feeds/luci/applications/$pkg
  fi
done

# Fix: feeds zerotier init.d conflicts with emortal daemon (START=99 vs START=90)
# Only delete the conflicting init.d file, keep zerotier.start/stop (NAT rules), uci-defaults, etc.
rm -f feeds/luci/applications/luci-app-zerotier/root/etc/init.d/zerotier
rm -f package/emortal/luci-app-zerotier/root/etc/init.d/zerotier
rm -rf package/emortal/luci-app-zerotier/root/etc/zerotier

# Fix: defconfig may downgrade/remove turboacc sub-options
sed -i 's/# CONFIG_PACKAGE_TURBOACC_INCLUDE_OFFLOADING is not set/CONFIG_PACKAGE_TURBOACC_INCLUDE_OFFLOADING=y/' .config
sed -i 's/# CONFIG_PACKAGE_TURBOACC_INCLUDE_BBR_CCA is not set/CONFIG_PACKAGE_TURBOACC_INCLUDE_BBR_CCA=y/' .config
sed -i 's/# CONFIG_PACKAGE_TURBOACC_INCLUDE_PDNSD is not set/CONFIG_PACKAGE_TURBOACC_INCLUDE_PDNSD=y/' .config

# Fix: turboacc fullcone NAT — fw3 bool parser only accepts '1'/'true'/'yes'
# "High Performing Mode" sets value '2' which fw3 treats as false → fullcone rules never written
if [ -f package/emortal/luci-app-turboacc/root/etc/init.d/turboacc ]; then
  sed -i 's|uci set firewall.@defaults[0].fullcone="${fullcone_nat}"|[ "${fullcone_nat}" != "0" ] \&\& uci set firewall.@defaults[0].fullcone="1" || uci set firewall.@defaults[0].fullcone="0"|g' package/emortal/luci-app-turboacc/root/etc/init.d/turboacc
fi

# Force rebuild luci-app-zerotier: stale build dir has old stamp files
rm -rf build_dir/target-*/luci-app-zerotier

# ============================================================
# Section 7: Ruby 3.1 Fix (conditional — only if Ruby in config)
# ============================================================

# Set GOPROXY for Go modules (fix frp build failure)
export GOPROXY=https://goproxy.cn,https://goproxy.io,direct
export GONOSUMCHECK=*
export GOSUMDB=off

RUBY_TARBALL="$GITHUB_WORKSPACE/openwrt/dl/ruby-3.1.2.tar.xz"
RUBY_MAKEFILE="$GITHUB_WORKSPACE/openwrt/feeds/packages/lang/ruby/Makefile"
RUBY_URL="https://cache.ruby-lang.org/pub/ruby/3.1/ruby-3.1.2.tar.xz"

if [ -f "$RUBY_MAKEFILE" ]; then
  # Clean stale Ruby build artifacts from prior failed builds
  RUBY_BUILD_DIR="$GITHUB_WORKSPACE/openwrt/build_dir/hostpkg/ruby-3.1.2"
  if [ -d "$RUBY_BUILD_DIR" ]; then
    echo "🧹 Removing stale Ruby build dir..."
    rm -rf "$RUBY_BUILD_DIR"
  fi
  rm -f "$GITHUB_WORKSPACE/openwrt/staging_dir/hostpkg/bin/ruby" 2>/dev/null

  echo "🔧 Pre-patching Ruby 3.1: download + patch + update PKG_HASH..."
  mkdir -p "$GITHUB_WORKSPACE/openwrt/dl"
  curl -fsSL "$RUBY_URL" -o "$RUBY_TARBALL" 2>/dev/null || wget -q "$RUBY_URL" -O "$RUBY_TARBALL"
  if [ -f "$RUBY_TARBALL" ]; then
    RUBY_TMP=$(mktemp -d)
    tar xJf "$RUBY_TARBALL" -C "$RUBY_TMP" 2>/dev/null
    RUBY_SRC="$RUBY_TMP/ruby-3.1.2"
    # Patch generic_erb.rb: re-exec with system Ruby if erb not available
    # System Ruby 3.0 has erb/optparse/fileutils as default gems.
    # Handles chicken-and-egg: BASERUBY --disable=gems can't load erb,
    # but we need erb to generate id.h before miniruby is built.
    if [ -f "$RUBY_SRC/tool/generic_erb.rb" ]; then
      {
        head -1 "$RUBY_SRC/tool/generic_erb.rb"
        cat <<'ERB_PATCH'
begin
  require "erb"
rescue LoadError
  exec "/usr/bin/ruby", File.expand_path(__FILE__), *ARGV
end
ERB_PATCH
        tail -n +2 "$RUBY_SRC/tool/generic_erb.rb" | grep -v '^require "erb"$'
      } > "$RUBY_SRC/tool/generic_erb.rb.tmp"
      mv "$RUBY_SRC/tool/generic_erb.rb.tmp" "$RUBY_SRC/tool/generic_erb.rb"
    fi
    # Remove file2lastrev.rb references from uncommon.mk (bypasses optparse/fileutils)
    sed -i '/file2lastrev\.rb/!b;N;d' "$RUBY_SRC/uncommon.mk" 2>/dev/null || true
    # Set BASERUBY to system Ruby in Makefile.in
    if [ -f "$RUBY_SRC/Makefile.in" ]; then
      sed -i 's|BASERUBY = .*|BASERUBY = /usr/bin/ruby |' "$RUBY_SRC/Makefile.in"
    fi
    # Repack and update hash
    tar cJf "$RUBY_TARBALL" -C "$RUBY_TMP" ruby-3.1.2 2>/dev/null
    rm -rf "$RUBY_TMP"
    NEW_HASH=$(sha256sum "$RUBY_TARBALL" | awk '{print $1}')
    sed -i "s/^PKG_HASH:=.*/PKG_HASH:=$NEW_HASH/" "$RUBY_MAKEFILE"
    echo "✅ Ruby 3.1 pre-patched. PKG_HASH=$NEW_HASH"
  else
    echo "⚠️ Ruby download failed; make download will handle it"
  fi
  # Force BASERUBY to system Ruby via HOST_CONFIGURE_ARGS
  if ! command -v /usr/bin/ruby &>/dev/null; then
    echo "⚠️ /usr/bin/ruby not found; installing ruby..."
    apt-get update -qq && apt-get install -y -qq ruby 2>/dev/null || true
  fi
  if command -v /usr/bin/ruby &>/dev/null; then
    if ! grep -q 'with-baseruby' "$RUBY_MAKEFILE"; then
      sed -i '/^CONFIGURE_ARGS += /i HOST_CONFIGURE_ARGS += --with-baseruby=/usr/bin/ruby' "$RUBY_MAKEFILE"
      echo "✅ Added --with-baseruby=/usr/bin/ruby"
    fi
  else
    echo "⚠️ Could not install Ruby; BASERUBY may fail on bundled gems"
  fi
fi

# ============================================================
# Section 8: GCC 8.4.0 Fix (conditional — only if tarball exists)
# ============================================================

GCC_TARBALL="$GITHUB_WORKSPACE/openwrt/dl/gcc-8.4.0.tar.xz"
if [ -f "$GCC_TARBALL" ]; then
  echo "🔧 Patching GCC 8.4.0 libiberty headers..."
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
fi

# ============================================================
# Section 9: Download
# ============================================================

# Drop caches to free memory before compilation (prevents OOM in Docker)
sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true

make download -j8 || make download -j1 V=s
find dl -not -path "dl/go-mod-cache/*" -size -1024c -exec rm -f {} \;
find dl -not -path "dl/go-mod-cache/*" -size 0 -exec rm -f {} \;

# Also patch any previously extracted Ruby build (incremental builds)
RUBY_BUILD="$GITHUB_WORKSPACE/openwrt/build_dir/hostpkg/ruby-3.1.2"
if [ -d "$RUBY_BUILD/tool" ]; then
  if [ -f "$RUBY_BUILD/tool/generic_erb.rb" ]; then
    if ! grep -q 'rescue LoadError' "$RUBY_BUILD/tool/generic_erb.rb"; then
      {
        head -1 "$RUBY_BUILD/tool/generic_erb.rb"
        cat <<'ERB_PATCH'
begin
  require "erb"
rescue LoadError
  exec "/usr/bin/ruby", File.expand_path(__FILE__), *ARGV
end
ERB_PATCH
        tail -n +2 "$RUBY_BUILD/tool/generic_erb.rb" | grep -v '^require "erb"$'
      } > "$RUBY_BUILD/tool/generic_erb.rb.tmp"
      mv "$RUBY_BUILD/tool/generic_erb.rb.tmp" "$RUBY_BUILD/tool/generic_erb.rb"
    fi
  fi
  sed -i '/file2lastrev\.rb/!b;N;d' "$RUBY_BUILD/uncommon.mk" 2>/dev/null || true
  if [ -f "$RUBY_BUILD/Makefile" ]; then
    sed -i 's|BASERUBY = .*|BASERUBY = /usr/bin/ruby |' "$RUBY_BUILD/Makefile"
  fi
fi

# ============================================================
# Section 10: vlmcsd GCC 13 Fix
# ============================================================

# $(notdir $(CC)) breaks when CC="ccache gcc" (contains spaces)
make package/feeds/packages/vlmcsd/prepare 2>/dev/null || true
VLMCSD_GNUMAKE=$(ls build_dir/target-*/vlmcsd-*/src/GNUmakefile 2>/dev/null | head -1)
if [ -n "$VLMCSD_GNUMAKE" ]; then
  sed -i 's/notdir $(CC)/lastword $(subst ccache, ,$(CC))/g' "$VLMCSD_GNUMAKE"
fi

# ============================================================
# Section 11: Go Packages Pre-compile
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
# Section 12: Main Build
# ============================================================

make -j$(nproc) || make -j1 || make -j1 V=s
popd

# ============================================================
# Section 13: Save Config & Copy Firmware
# ============================================================

cp -f openwrt/.config ${GITHUB_WORKSPACE}/${CONFIG_FILE}

# Return to workspace root
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
