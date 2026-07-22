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
cd "$GITHUB_WORKSPACE" || exit 1
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
REPO_COMMIT="${REPO_COMMIT:-}"
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

remove_declared_build_paths() {
  local paths="$1" path

  for path in $paths; do
    case "$path" in
      build_dir/*)
        case "$path" in *..*|*//* ) echo "❌ unsafe build cleanup path: $path"; return 1 ;; esac
        rm -rf -- $path
        ;;
      *) echo "❌ invalid build cleanup path: $path"; return 1 ;;
    esac
  done
}

# ============================================================
# Section 3: Clone/Pull OpenWrt
# ============================================================

chmod +x "$GITHUB_WORKSPACE/scripts/build/prepare_source.sh"
"$GITHUB_WORKSPACE/scripts/build/prepare_source.sh" \
  "$GITHUB_WORKSPACE" "$REPO_URL" "$REPO_BRANCH" "$REPO_COMMIT" "$BUILD_CACHE_DIR"

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
for feed_package in ${FEED_FORCE_PACKAGES:-}; do
  case "$feed_package" in
    ''|*[!A-Za-z0-9_.+-]*) echo "❌ invalid FEED_FORCE_PACKAGES entry: $feed_package"; exit 1 ;;
    *) ;;
  esac
  ./scripts/feeds install -f "$feed_package" || {
    echo "❌ forced feed package install failed: $feed_package"
    exit 1
  }
done

# ============================================================
# Section 5: Config
# ============================================================

[ -e "$GITHUB_WORKSPACE/$CONFIG_FILE" ] && cp "$GITHUB_WORKSPACE/$CONFIG_FILE" .config
# This pass validates feed packages, including the SmartDNS fallback, before DIY
# creates repository-owned package overrides.
chmod +x "$GITHUB_WORKSPACE/scripts/build/resolve_config.sh"
"$GITHUB_WORKSPACE/scripts/build/resolve_config.sh" \
  "$GITHUB_WORKSPACE/openwrt" "$GITHUB_WORKSPACE/$CONFIG_FILE" "before diy-part2.sh"

popd

[ -e "$GITHUB_WORKSPACE/files" ] && cp -r "$GITHUB_WORKSPACE/files" openwrt/files
[ -e "$GITHUB_WORKSPACE/$CONFIG_FILE" ] && cp "$GITHUB_WORKSPACE/$CONFIG_FILE" openwrt/.config
chmod +x "$DIY_P2_SH"

pushd openwrt
if ! GITHUB_WORKSPACE="$GITHUB_WORKSPACE" "$GITHUB_WORKSPACE/$DIY_P2_SH"; then
  echo "❌ diy-part2.sh failed"
  exit 1
fi
# DIY adds package definitions and the device overlay, so resolve again before
# downloading or compiling. This is intentionally separate from the feed pass.
"$GITHUB_WORKSPACE/scripts/build/resolve_config.sh" \
  "$GITHUB_WORKSPACE/openwrt" "$GITHUB_WORKSPACE/$CONFIG_FILE" "after diy-part2.sh"

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

# Clean device-declared stale rootfs caches to force prepare_rootfs to re-apply
# the files overlay.  The path list is kept out of the generic build runner.
remove_declared_build_paths "${OVERLAY_CACHE_CLEAN_PATHS:-}" || exit 1

echo "=== Stale squashfs/target-dir cleaned ==="

echo "=== Starting main build ==="

BUILD_LOG=$(mktemp)
trap 'rm -f "$BUILD_LOG"' EXIT
preserve_build_log() {
  cp "$BUILD_LOG" "$GITHUB_WORKSPACE/build-failure.log" && \
    echo "❌ Full build log saved to $GITHUB_WORKSPACE/build-failure.log"
}

run_main_build() {
  make -j$(nproc) V=s >> "$BUILD_LOG" 2>&1
}

printf '%s\n' '=== Main build (full log captured locally) ===' > "$BUILD_LOG"
if run_main_build; then
  BUILD_RC=0
  tail -n 40 "$BUILD_LOG"
else
  BUILD_RC=$?
  tail -n 200 "$BUILD_LOG" >&2
fi
if [ $BUILD_RC -ne 0 ]; then
  if grep -q 'Hash mismatch for file' "$BUILD_LOG"; then
    echo "❌ Source-cache checksum mismatch; skipping retry to preserve the failure evidence."
    preserve_build_log
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
  remove_declared_build_paths "${RETRY_CLEAN_PATHS:-}" || exit 1
  printf '%s\n' '=== Main build retry (full log appended locally) ===' >> "$BUILD_LOG"
  if run_main_build; then
    BUILD_RC=0
    tail -n 40 "$BUILD_LOG"
  else
    BUILD_RC=$?
    tail -n 200 "$BUILD_LOG" >&2
  fi
fi
popd

if [ $BUILD_RC -ne 0 ]; then
  preserve_build_log
  echo "❌ Build failed with exit code $BUILD_RC"
  echo "❌ Firmware copy SKIPPED — no valid build output"
  exit $BUILD_RC
fi

rm -f "$BUILD_LOG"
trap - EXIT

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

  else
    echo "❌ No manifest found in $FIRMWARE_DIR!"
    exit 1
  fi
else
  echo "❌ Firmware directory not found!"
  exit 1
fi

chmod +x "$GITHUB_WORKSPACE/scripts/verify_firmware.sh"
"$GITHUB_WORKSPACE/scripts/verify_firmware.sh" openwrt "$RELEASE_DIR" "$RELEASE_NAME"
ls -lh "$RELEASE_DIR/${RELEASE_NAME}.img.gz"
