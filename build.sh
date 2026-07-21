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

GITHUB_WORKSPACE=$(cd "$(dirname "$0")" && pwd)
# Docker bind mounts are owned by the host user while the builder runs as root.
# Configure the concrete workspace before the reproducibility Git check below.
git config --global --add safe.directory "$GITHUB_WORKSPACE"
# A firmware must be reproducible from a committed source tree.  Device
# repositories frequently contain local experiments, and building from one
# makes the resulting image impossible to audit or reproduce.
if [ "${ALLOW_DIRTY_BUILD:-0}" != "1" ] && [ -n "$(git -C "$GITHUB_WORKSPACE" status --porcelain)" ]; then
  echo "ERROR: refusing to build from a dirty work tree. Commit, stash, or set ALLOW_DIRTY_BUILD=1 intentionally."
  exit 1
fi
# Source device-specific overrides
[ -f "$GITHUB_WORKSPACE/openwrt-device.conf" ] && source "$GITHUB_WORKSPACE/openwrt-device.conf"
# Package customization runs in diy-part2.sh; retain device-declared inputs.
export ZEROTIER_VERSION SERIAL_BUILD_TARGETS

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
export OPENWRT_REF="$REPO_BRANCH"
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

[ -e "$FEEDS_CONF" ] && cp "$FEEDS_CONF" openwrt/feeds.conf.default
chmod +x "$DIY_P1_SH"

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

if ! GITHUB_WORKSPACE="$GITHUB_WORKSPACE" BUILD_CACHE_DIR="$BUILD_CACHE_DIR" "$GITHUB_WORKSPACE/$DIY_P1_SH"; then
  echo "❌ diy-part1.sh failed"
  exit 1
fi
git config --global http.version HTTP/1.1
feeds_updated=0
for attempt in 1 2 3; do
  if ./scripts/feeds update -f -a; then
    feeds_updated=1
    break
  fi
  echo "⚠️ feeds update failed (attempt $attempt/3), retrying..."
  sleep $((attempt * 3))
done
[ "$feeds_updated" -eq 1 ] || { echo "❌ feeds update failed after 3 attempts"; exit 1; }
./scripts/feeds install -a || { echo "❌ feeds install failed"; exit 1; }

# ============================================================
# Section 5: Config
# ============================================================

refresh_package_metadata() {
  # Only regenerate Kconfig package metadata. Do not remove build outputs or downloads.
  rm -f tmp/.packageinfo tmp/.packagedeps tmp/.packageauxvars tmp/.packageusergroup \
    tmp/.config-*.in tmp/info/.files-packageinfo* tmp/info/.packageinfo-*
  make prepare-tmpinfo || { echo "❌ package metadata refresh failed"; exit 1; }
  test -s tmp/.packageinfo || { echo "❌ package metadata is empty"; exit 1; }
}

verify_config_packages() {
  local package missing_packages=""
  [ -f "$GITHUB_WORKSPACE/$CONFIG_FILE" ] || return 0
  while IFS= read -r package; do
    [ -z "$package" ] && continue
    grep -Fqx "CONFIG_PACKAGE_${package}=y" .config || missing_packages="$missing_packages $package"
  done < <(sed -n 's/^CONFIG_PACKAGE_\([A-Za-z0-9_-]*\)=y$/\1/p' "$GITHUB_WORKSPACE/$CONFIG_FILE")
  if [ -n "$missing_packages" ]; then
    echo "❌ Requested packages missing after defconfig:$missing_packages"
    exit 1
  fi
  echo "✅ Requested package selections verified"
}

[ -e "$GITHUB_WORKSPACE/$CONFIG_FILE" ] && cp "$GITHUB_WORKSPACE/$CONFIG_FILE" .config
refresh_package_metadata
make defconfig || { echo "❌ defconfig failed"; exit 1; }
verify_config_packages

popd

[ -e "$GITHUB_WORKSPACE/files" ] && cp -r "$GITHUB_WORKSPACE/files" openwrt/files
[ -e "$GITHUB_WORKSPACE/$CONFIG_FILE" ] && cp "$GITHUB_WORKSPACE/$CONFIG_FILE" openwrt/.config
chmod +x "$DIY_P2_SH"

pushd openwrt
if ! GITHUB_WORKSPACE="$GITHUB_WORKSPACE" "$GITHUB_WORKSPACE/$DIY_P2_SH"; then
  echo "❌ diy-part2.sh failed"
  exit 1
fi
refresh_package_metadata
make defconfig || { echo "❌ defconfig (post diy) failed"; exit 1; }
verify_config_packages

# ============================================================
# Section 6: Package Fixes
# ============================================================

# Set Go module resolution policy for selected serial package builds.
export GOPROXY=https://goproxy.cn,https://goproxy.io,direct
export GONOSUMCHECK=*
export GOSUMDB=off


# ============================================================
# Section 8: Download
# ============================================================

# Drop caches when the kernel permits it. Docker commonly mounts this sysctl
# read-only, so suppress that expected host-policy failure.
sync
if { echo 3 > /proc/sys/vm/drop_caches; } 2>/dev/null; then
  echo "✅ dropped filesystem caches"
else
  echo "ℹ️ cache drop skipped (not permitted by container runtime)"
fi

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

# FRP is pre-compiled below to avoid Go's parallel-build race.  Its package
# build needs target libgcc, which only exists after the target toolchain is
# installed; a warm cache used to hide this ordering dependency.
echo "=== Building and installing target toolchain ==="
make toolchain/install -j$(nproc) V=s || { echo "❌ toolchain/install failed"; exit 1; }
echo "✅ target toolchain installed"

# ============================================================
# Section 9: Go Packages Pre-compile
# ============================================================

# Pre-compile python3 host tooling (needed by meson for apk/host build)
# A selected serial package can trigger apk/host, which needs python3 host via meson.
# feeds install symlinks: feeds/packages/lang/python/python3 -> package/feeds/packages/python3
if ls package/feeds/packages/python3/Makefile 2>/dev/null; then
  echo "=== Pre-compiling python3 host tooling (for meson/apk) ==="
  make package/feeds/packages/python3/host/compile -j1 V=s || { echo "❌ python3 host build failed"; exit 1; }
  # Symlink python3 from hostpkg→host so meson cross-file can find it
  if [ -f staging_dir/hostpkg/bin/python3 ]; then
    ln -sf ../../hostpkg/bin/python3 staging_dir/host/bin/python3
    echo "✅ symlinked hostpkg/bin/python3 → host/bin/python3"
  fi
  echo "✅ python3 host build done"
fi

# Selected packages may have shared-cache races under the parallel main build.
# Devices declare their build targets in openwrt-device.conf; the runner only
# validates and serializes those declared targets.
echo "=== Pre-compiling selected packages with -j1 ==="
for build_target in ${SERIAL_BUILD_TARGETS:-}; do
  case "$build_target" in
    package/*) ;;
    *) echo "❌ invalid SERIAL_BUILD_TARGETS entry: $build_target"; exit 1 ;;
  esac
  if [ ! -f "$build_target/Makefile" ]; then
    echo "❌ selected build target is unavailable: $build_target"
    exit 1
  fi
  echo "Pre-compiling $build_target with -j1..."
  if ! make "$build_target/compile" -j1 V=s; then
    echo "WARNING: $build_target failed, retrying..."
    make "$build_target/compile" -j1 V=s || { echo "❌ $build_target failed after retry"; exit 1; }
  fi
done
echo "=== Selected package pre-compilation done ==="

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

# Free memory before main build when the container runtime permits it.
sync
if { echo 3 > /proc/sys/vm/drop_caches; } 2>/dev/null; then
  echo "✅ dropped filesystem caches before main build"
else
  echo "ℹ️ cache drop skipped before main build (not permitted by container runtime)"
fi

echo "=== Starting main build ==="

BUILD_LOG=$(mktemp)
trap 'rm -f "$BUILD_LOG"' EXIT
set -o pipefail
make -j$(nproc) V=s 2>&1 | tee "$BUILD_LOG"
BUILD_RC=${PIPESTATUS[0]}
if [ $BUILD_RC -ne 0 ]; then
  if grep -q 'Hash mismatch for file' "$BUILD_LOG"; then
    echo "❌ Source-cache checksum mismatch; skipping retry to preserve the failure evidence."
    exit $BUILD_RC
  fi
  echo "⚠️ First attempt failed, cleaning kernel build dir and retrying..."
  echo "=== target/linux/clean ==="
  make target/linux/clean V=s 2>/dev/null || true
  for clean_target in ${RETRY_CLEAN_TARGETS:-}; do
    case "$clean_target" in
      package/*/clean) make "$clean_target" V=s 2>/dev/null || true ;;
      *) echo "❌ invalid RETRY_CLEAN_TARGETS entry: $clean_target"; exit 1 ;;
    esac
  done
  for clean_path in ${RETRY_CLEAN_PATHS:-}; do
    case "$clean_path" in
      build_dir/*) rm -rf -- $clean_path ;;
      *) echo "❌ invalid RETRY_CLEAN_PATHS entry: $clean_path"; exit 1 ;;
    esac
  done
  make -j$(nproc) V=s
  BUILD_RC=$?
fi
rm -f "$BUILD_LOG"
trap - EXIT
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
cp -f openwrt/.config config.buildinfo || { echo "❌ failed to save config.buildinfo"; exit 1; }
echo "✅ Saved expanded config to config.buildinfo"

mkdir -p "$RELEASE_DIR" || { echo "❌ failed to create release directory"; exit 1; }
cp -f openwrt/.config "$RELEASE_DIR/config.buildinfo" || { echo "❌ failed to save release config.buildinfo"; exit 1; }

# Resolve exactly one firmware output directory. Never let a stale target
# directory silently win because filesystem traversal happened to list it first.
mapfile -t firmware_dirs < <(find openwrt/bin/targets -type d -name "64" 2>/dev/null)
if [ "${#firmware_dirs[@]}" -ne 1 ]; then
  mapfile -t firmware_dirs < <(find openwrt/bin/targets -mindepth 2 -maxdepth 4 -type d 2>/dev/null | grep -v '/packages$')
fi
if [ "${#firmware_dirs[@]}" -ne 1 ]; then
  echo "❌ expected exactly one firmware directory, found ${#firmware_dirs[@]}"
  printf '  %s\n' "${firmware_dirs[@]}"
  exit 1
fi
FIRMWARE_DIR="${firmware_dirs[0]}"
echo "📦 Firmware directory: $FIRMWARE_DIR"

if [ -d "$FIRMWARE_DIR" ]; then
  cp -f "$FIRMWARE_DIR"/config.buildinfo "$RELEASE_DIR/${RELEASE_NAME}.target.config.buildinfo" || { echo "❌ missing target config.buildinfo"; exit 1; }
  # Find the combined/EFI firmware image (preferred) or any .img.gz
  mapfile -t firmware_files < <(find "$FIRMWARE_DIR" -maxdepth 1 -name "*combined*img.gz" -type f 2>/dev/null)
  if [ "${#firmware_files[@]}" -eq 0 ]; then
    mapfile -t firmware_files < <(find "$FIRMWARE_DIR" -maxdepth 1 -name "*img.gz" -type f 2>/dev/null)
  fi
  if [ "${#firmware_files[@]}" -ne 1 ]; then
    echo "❌ expected exactly one firmware image, found ${#firmware_files[@]}"
    printf '  %s\n' "${firmware_files[@]}"
    exit 1
  fi
  FIRMWARE_FILE="${firmware_files[0]}"
  if [ -f "$FIRMWARE_FILE" ]; then
    cp -f "$FIRMWARE_FILE" "$RELEASE_DIR/$RELEASE_NAME.img.gz" || { echo "❌ failed to copy firmware image"; exit 1; }
    echo "✅ Firmware: $(basename "$FIRMWARE_FILE")"
  else
    echo "❌ No .img.gz found in $FIRMWARE_DIR!"
    exit 1
  fi
  mapfile -t manifests < <(find "$FIRMWARE_DIR" -maxdepth 1 -name "*.manifest" -type f 2>/dev/null)
  if [ "${#manifests[@]}" -ne 1 ]; then
    echo "❌ expected exactly one firmware manifest, found ${#manifests[@]}"
    printf '  %s\n' "${manifests[@]}"
    exit 1
  fi
  MANIFEST="${manifests[0]}"
  if [ -f "$MANIFEST" ]; then
    cp -f "$MANIFEST" "$RELEASE_DIR/$RELEASE_NAME.manifest" || { echo "❌ failed to copy manifest"; exit 1; }

	    # Validate every selected package that has a concrete package definition.
	    # Some CONFIG_PACKAGE symbols are feature toggles (for example,
	    # dnsmasq_full_dhcpv6), so derive package names from .packageinfo rather
	    # than treating every selected symbol as a manifest package name.
	    manifest_check_dir=$(mktemp -d) || { echo "❌ failed to create manifest check directory"; exit 1; }
	    awk '/^Package: / { print $2 }' "$GITHUB_WORKSPACE/openwrt/tmp/.packageinfo" | sort -u > "$manifest_check_dir/buildable" && test -s "$manifest_check_dir/buildable" || { rm -rf "$manifest_check_dir"; echo "❌ package metadata is unavailable for manifest validation"; exit 1; }
	    sed -n 's/^CONFIG_PACKAGE_\([A-Za-z0-9_-]*\)=y$/\1/p' "$GITHUB_WORKSPACE/openwrt/.config" | sort -u > "$manifest_check_dir/selected" && test -s "$manifest_check_dir/selected" || { rm -rf "$manifest_check_dir"; echo "❌ selected package list is empty"; exit 1; }
	    awk -F ' - ' 'NF >= 2 { print $1 }' "$MANIFEST" | sort -u > "$manifest_check_dir/manifest" && test -s "$manifest_check_dir/manifest" || { rm -rf "$manifest_check_dir"; echo "❌ firmware manifest is empty"; exit 1; }
	    missing_packages=""
	    while IFS= read -r package; do
	      [ -z "$package" ] && continue
	      # ImmortalWrt appends ABI suffixes (for example libopenssl3 and
	      # libsqlite3-0). Accept only the exact package or that numeric ABI form.
	      if ! grep -Fqx "$package" "$manifest_check_dir/manifest" && ! grep -Eq "^${package}([0-9]+([.-][0-9]+)*|-[0-9]+)$" "$manifest_check_dir/manifest"; then
	        missing_packages="$missing_packages $package"
	      fi
	    done < <(comm -12 "$manifest_check_dir/selected" "$manifest_check_dir/buildable")
	    rm -rf "$manifest_check_dir"
	    if [ -n "$missing_packages" ]; then
	      echo "❌ firmware manifest is missing selected packages:$missing_packages"
	      exit 1
	    fi
	    echo "✅ firmware manifest contains every selected package"
  else
    echo "❌ No manifest found in $FIRMWARE_DIR!"
    exit 1
  fi
else
  echo "❌ Firmware directory not found!"
  exit 1
fi

cd "$RELEASE_DIR" || exit 1
IMG_FILE="${RELEASE_NAME}.img.gz"
if [ -f "$IMG_FILE" ]; then
  BASE=$(basename "$IMG_FILE" .img.gz)
	  gzip -t "$IMG_FILE" || { echo "❌ firmware gzip integrity check failed"; exit 1; }

	  # A gzip checksum only proves the image bytes are intact. Fully extract the
	  # embedded SquashFS before publishing so a corrupt compressed block cannot
	  # become a bootable-but-broken LuCI image.
	  image_verify_dir=$(mktemp -d) || { echo "❌ failed to create image verification directory"; exit 1; }
	  image_raw="$image_verify_dir/${BASE}.img"
	  image_rootfs="$image_verify_dir/rootfs"
	  cleanup_image_verify() { rm -rf "$image_verify_dir"; }
	  if ! gzip -dc "$IMG_FILE" > "$image_raw"; then
	    cleanup_image_verify
	    echo "❌ failed to decompress firmware image for SquashFS verification"
	    exit 1
	  fi
	  squashfs_offset=$(LC_ALL=C grep -abo -m 1 'hsqs' "$image_raw" | cut -d: -f1 || true)
	  if [ -z "$squashfs_offset" ]; then
	    cleanup_image_verify
	    echo "❌ unable to locate SquashFS in firmware image"
	    exit 1
	  fi
	  echo "🔍 Fully extracting SquashFS at offset $squashfs_offset"
	  if ! unsquashfs -offset "$squashfs_offset" -excludes -d "$image_rootfs" "$image_raw" dev >/dev/null; then
	    cleanup_image_verify
	    echo "❌ firmware SquashFS extraction failed"
	    exit 1
	  fi
	  for luci_asset in luci.js ui.js; do
	    [ -s "$image_rootfs/www/luci-static/resources/$luci_asset" ] || {
	      cleanup_image_verify
	      echo "❌ verified SquashFS is missing LuCI asset: $luci_asset"
	      exit 1
	    }
	  done
	  cleanup_image_verify
	  echo "✅ firmware SquashFS fully extracted and LuCI assets verified"

	  md5sum "$IMG_FILE" > "${BASE}.img.gz.md5" || { echo "❌ failed to create compressed firmware MD5"; exit 1; }
	  gzip -dc "$IMG_FILE" | md5sum | sed "s/-/${BASE}.img/" > "${BASE}.img.md5" || { echo "❌ failed to create uncompressed firmware MD5"; exit 1; }
else
  echo "❌ release image $IMG_FILE is missing"
  exit 1
fi
ls -lh "$IMG_FILE"
cd "$GITHUB_WORKSPACE"
