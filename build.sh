#!/bin/bash
#
# Actions-LEDE：通用 OpenWrt/ImmortalWrt 构建脚本
# 基座：ImmortalWrt master
#
# 设备专用覆盖项：在同目录创建 openwrt-device.conf
# openwrt-device.conf 示例：
#   RELEASE_NAME=nuc8
#

# ============================================================
# 第一部分：Git 配置
# ============================================================

GITHUB_WORKSPACE=$(cd "$(dirname "$0")" && pwd)
cd "$GITHUB_WORKSPACE" || exit 1
# Docker bind mount 由宿主用户持有；仅在下方可复现性检查中局部声明安全目录。
# 固件必须可由已提交的源码树复现。设备仓库常含本地试验，直接从脏工作树构建将无法审计或复现。
if [ "${ALLOW_DIRTY_BUILD:-0}" != "1" ] && [ -n "$(git -c safe.directory="$GITHUB_WORKSPACE" -C "$GITHUB_WORKSPACE" status --porcelain)" ]; then
  echo "ERROR: refusing to build from a dirty work tree. Commit, stash, or set ALLOW_DIRTY_BUILD=1 intentionally."
  exit 1
fi
# 读取设备专用覆盖项
[ -f "$GITHUB_WORKSPACE/openwrt-device.conf" ] && source "$GITHUB_WORKSPACE/openwrt-device.conf"
# 软件包定制在 diy-part2.sh 中完成；保留设备的版本固定配置。
export ZEROTIER_VERSION

# ============================================================
# 第二部分：变量
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

# Docker 持久化构建缓存目录（staging_dir、build_dir、dl）。
# 将 Docker volume 挂载至此，可在容器间复用交叉编译工具链。
BUILD_CACHE_DIR=${BUILD_CACHE_DIR:-}

prepare_release_dir() {
  local stale_release

  if [ -e "$RELEASE_DIR" ] && [ ! -w "$RELEASE_DIR" ]; then
    stale_release="${RELEASE_DIR}.stale.$(date -u +%Y%m%dT%H%M%SZ)"
    echo "⚠️ Archiving non-writable release directory to $stale_release"
    mv "$RELEASE_DIR" "$stale_release" || {
      echo "❌ unable to archive non-writable release directory"
      exit 1
    }
  fi
  mkdir -p "$RELEASE_DIR" || { echo "❌ failed to create release directory"; exit 1; }
}

# ============================================================
# 第二部分之一：构建前置条件
# ============================================================

# ImmortalWrt 的 u-boot 前置检查需要 python3-setuptools。
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
# 第三部分：获取 OpenWrt 源码
# ============================================================

"$GITHUB_WORKSPACE/scripts/build/prepare_source.sh" \
  "$GITHUB_WORKSPACE" "$REPO_URL" "$REPO_BRANCH" "$REPO_COMMIT" "$BUILD_CACHE_DIR"

# ============================================================
# 第四部分：配置 feeds
# ============================================================

[ -e "$FEEDS_CONF" ] && cp "$FEEDS_CONF" openwrt/feeds.conf.default

pushd openwrt
# Docker volume 可能遗留由其他 UID 创建的 feeds。feeds 是上游忽略、可重建的
# 构建缓存；直接丢弃它，避免非 root 构建用户执行 chown 而必然失败。
workspace_uid=$(stat -c '%u' .)
workspace_gid=$(stat -c '%g' .)
if [ -d feeds ] && find feeds -xdev \( ! -uid "$workspace_uid" -o ! -gid "$workspace_gid" \) -print -quit 2>/dev/null | grep -q .; then
  echo "⚠️ Rebuilding feeds cache left by a different UID"
  rm -rf feeds || { echo "❌ unable to remove stale feeds cache"; exit 1; }
fi

# 恢复同一 UID 的持久化 feed 工作树，减少不必要的重新拉取。
for feed_dir in feeds/*/; do
  if [ -d "$feed_dir/.git" ]; then
    rm -f "$feed_dir/.git/index.lock"
    git -C "$feed_dir" checkout -- . 2>/dev/null
  fi
done

if ! GITHUB_WORKSPACE="$GITHUB_WORKSPACE" BUILD_CACHE_DIR="$BUILD_CACHE_DIR" "$GITHUB_WORKSPACE/$DIY_P1_SH"; then
  echo "❌ diy-part1.sh failed"
  exit 1
fi
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

# 当前上游 trafficshaper 的条件依赖会让未选中的包也进入递归 Kconfig。
# 仅移除 feeds 生成的链接，不修改上游源码；上游定义变更后自动不再排除。
exclude_unselected_broken_feed_packages() {
  local package package_file

  for package in trafficshaper freeradius3; do
    case "$package" in
      trafficshaper)
        package_file="feeds/packages/net/$package/Makefile"
        grep -q 'PACKAGE_nftables-json||PACKAGE_nftables-nojson' "$package_file" || continue
        ;;
      freeradius3)
        package_file="feeds/packages/net/$package/Config.in"
        grep -q '^[[:space:]]*depends on PACKAGE_freeradius3-common$' "$package_file" || continue
        ;;
    esac
    if grep -Eq "^CONFIG_PACKAGE_${package}(=y|=m)$" "$GITHUB_WORKSPACE/$CONFIG_FILE"; then
      echo "❌ $package is selected, but its current upstream Kconfig is recursive"
      return 1
    fi
    ./scripts/feeds uninstall "$package" || return 1
    echo "⚠️ Excluded unselected $package until its upstream Kconfig is fixed"
  done
}

exclude_unselected_broken_feed_packages || exit 1
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
# 第五部分：配置
# ============================================================

[ -e "$GITHUB_WORKSPACE/$CONFIG_FILE" ] && cp "$GITHUB_WORKSPACE/$CONFIG_FILE" .config
# 在 DIY 创建仓库自有软件包覆盖前，先验证 feed 软件包（含 SmartDNS 回退路径）。
"$GITHUB_WORKSPACE/scripts/build/resolve_config.sh" \
  "$GITHUB_WORKSPACE/openwrt" "$GITHUB_WORKSPACE/$CONFIG_FILE" "before diy-part2.sh"

popd

[ -e "$GITHUB_WORKSPACE/files" ] && cp -r "$GITHUB_WORKSPACE/files" openwrt/files
[ -e "$GITHUB_WORKSPACE/$CONFIG_FILE" ] && cp "$GITHUB_WORKSPACE/$CONFIG_FILE" openwrt/.config

pushd openwrt
if ! GITHUB_WORKSPACE="$GITHUB_WORKSPACE" "$GITHUB_WORKSPACE/$DIY_P2_SH"; then
  echo "❌ diy-part2.sh failed"
  exit 1
fi
# DIY 会新增软件包定义和设备 overlay，因此下载和编译前必须再次解析配置；
# 该步骤与 feed 验证刻意分离。
"$GITHUB_WORKSPACE/scripts/build/resolve_config.sh" \
  "$GITHUB_WORKSPACE/openwrt" "$GITHUB_WORKSPACE/$CONFIG_FILE" "after diy-part2.sh"

# ============================================================
# 第六部分：下载源码包
# ============================================================

make download -j8 || make download -j1 V=s || { echo "❌ make download failed"; exit 1; }
find dl -not -path "dl/go-mod-cache/*" -size -1024c -type f -exec rm -f {} \;

# ============================================================
# 第七部分：主编译
# ============================================================

# 清理设备声明的过期 rootfs 缓存，强制 prepare_rootfs 重新应用 files overlay。
# 路径列表由设备定义，不放入通用构建器。
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

has_corrupt_initial_gcc_objects() {
  find build_dir/toolchain-* -path '*/gcc-*-initial/gcc/*.o' -type f -size 0 -print -quit 2>/dev/null | grep -q .
}

rebuild_initial_gcc_without_ccache() {
  make toolchain/gcc/initial/clean V=s 2>/dev/null || true
  CCACHE_DISABLE=1 make -j"$(nproc)" toolchain/gcc/initial/compile V=s >> "$BUILD_LOG" 2>&1
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
  if has_corrupt_initial_gcc_objects; then
    echo "⚠️ Detected zero-byte initial GCC objects; rebuilding only toolchain/gcc/initial with ccache disabled."
    find build_dir/toolchain-* -path '*/gcc-*-initial/gcc/*.o' -type f -size 0 -print
    if ! rebuild_initial_gcc_without_ccache; then
      echo "❌ Initial GCC recovery failed"
      tail -n 200 "$BUILD_LOG" >&2
      preserve_build_log
      exit 1
    fi
  else
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
  fi
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
# 第八部分：保存配置并复制固件
# ============================================================


# 将展开后的 .config 保存为 config.buildinfo，绝不覆盖作为输入的 config.seed。
cp -f openwrt/.config config.buildinfo || { echo "❌ failed to save config.buildinfo"; exit 1; }
echo "✅ Saved expanded config to config.buildinfo"

prepare_release_dir
cp -f openwrt/.config "$RELEASE_DIR/config.buildinfo" || { echo "❌ failed to save release config.buildinfo"; exit 1; }

# 只解析唯一的固件输出目录，不能因文件系统遍历顺序让过期 target 目录被误用。
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
  if [ -f "$FIRMWARE_DIR/config.buildinfo" ]; then
    target_config="$FIRMWARE_DIR/config.buildinfo"
  else
    target_config="config.buildinfo"
    echo "⚠️ Target config.buildinfo is unavailable; using the expanded build config"
  fi
  cp -f "$target_config" "$RELEASE_DIR/${RELEASE_NAME}.target.config.buildinfo" || { echo "❌ failed to save target config.buildinfo"; exit 1; }
  # 优先查找 combined/EFI 固件镜像，其次才接受任意 .img.gz。
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

"$GITHUB_WORKSPACE/scripts/verify_firmware.sh" openwrt "$RELEASE_DIR" "$RELEASE_NAME"
ls -lh "$RELEASE_DIR/${RELEASE_NAME}.img.gz"
