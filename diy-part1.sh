#!/bin/bash
#
# Copyright (c) 2019-2020 P3TERX <https://p3terx.com>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#
# https://github.com/P3TERX/Actions-OpenWrt
# File name: diy-part1.sh
# Description: OpenWrt DIY script part 1 (Before Update feeds)
#

OPENCLASH_BRANCH=dev

# ============================================================
# cache_clone — 通用 GitHub 克隆 + 本地缓存回退
#
# 优先 git clone，失败时 fallback 到本地缓存。
# BUILD_CACHE_DIR 有值时启用缓存（device fork openwrt-device.conf）。
#
# 用法:
#   cache_clone <name> <url> <branch> <target> [<sparse_subdir>]
#
# 普通克隆:
#   cache_clone "luci-theme-argon" "https://..." "master" "package/..."
#
# sparse 克隆（monorepo 取子目录）:
#   cache_clone "luci-app-openclash" "https://..." "dev" "package/..." "luci-app-openclash"
# ============================================================
cache_clone() {
  local name="$1" url="$2" branch="$3" target="$4" sparse="${5:-}"
  local cache="${BUILD_CACHE_DIR:+"$BUILD_CACHE_DIR/$name"}"
  local ok=false

  rm -rf "$target"

  if [ -n "$sparse" ]; then
    local tmpdir="/tmp/cache-${name}"
    rm -rf "$tmpdir" && mkdir -p "$tmpdir"
    if git clone --depth 1 -b "$branch" --filter=blob:none --sparse \
         "$url" --no-checkout "$tmpdir" 2>/dev/null; then
      (cd "$tmpdir" && git sparse-checkout init --cone \
        && git sparse-checkout set "$sparse" \
        && git checkout)
      mv "${tmpdir}/${sparse}" "$target"
      rm -rf "$tmpdir"
      ok=true
    fi
  else
    if git clone --depth 1 -b "$branch" "$url" "$target" 2>/dev/null; then
      ok=true
    fi
  fi

  if $ok; then
    echo "✅ ${name}: cloned from GitHub"
    if [ -n "$BUILD_CACHE_DIR" ]; then
      mkdir -p "$(dirname "$cache")"
      rm -rf "$cache"
      cp -r "$target" "$cache"
      echo "✅ ${name}: cache updated"
    fi
  elif [ -n "$BUILD_CACHE_DIR" ] && [ -d "$cache" ]; then
    echo "⚠️ ${name}: GitHub clone failed, using local build-cache"
    cp -r "$cache" "$target"
  else
    echo "❌ ${name}: both GitHub clone and local cache failed"
    exit 1
  fi
}

# 1. luci-theme-argon（luci-app-argon-config 依赖的主题）
cache_clone "luci-theme-argon" \
  "https://github.com/jerrykuku/luci-theme-argon.git" \
  "master" "package/emortal/luci-theme-argon"

# 2. luci-app-argon-config
cache_clone "luci-app-argon-config" \
  "https://github.com/jerrykuku/luci-app-argon-config.git" \
  "master" "package/emortal/luci-app-argon-config"

# 3. luci-app-openclash
cache_clone "luci-app-openclash" \
  "https://github.com/vernesong/OpenClash.git" \
  "$OPENCLASH_BRANCH" "package/emortal/luci-app-openclash" \
  "luci-app-openclash"


# 5. zerotier — GitHub regenerated tarball hash (updated 2026-06-15)
#    Upstream now has e3b0c44... (empty hash), fix to actual tarball hash
sed -i 's|PKG_HASH:=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855|PKG_HASH:=2c607f573c6e38815433af289d364a689a203b18b51125f06c4472014d0657f0|' feeds/packages/net/zerotier/Makefile

# 5. OpenClash Ruby 4.0 + Psych YAML 兼容性修复
#    ImmortalWrt Ruby 4.0 的 Psych YAML 库需要显式 require stringio
#    否则 OpenClash 所有 Ruby YAML 解析脚本崩溃:
#    Load File Failed,【uninitialized constant Psych::StringIO】
OC_ROOT=package/emortal/luci-app-openclash/root
for script in \
  $OC_ROOT/etc/init.d/openclash \
  $OC_ROOT/usr/share/openclash/openclash_watchdog.sh \
  $OC_ROOT/usr/share/openclash/yml_change.sh \
  $OC_ROOT/usr/share/openclash/yml_groups_get.sh \
  $OC_ROOT/usr/share/openclash/yml_proxys_get.sh \
  $OC_ROOT/usr/share/openclash/yml_rules_change.sh; do
  if grep -q 'export RUBYOPT' "$script" 2>/dev/null; then
    echo "✅ openclash-psych-fix: already patched $script"
  else
    sed -i '1a export RUBYOPT="-rstringio"' "$script"
    echo "➕ openclash-psych-fix: patched $script"
  fi
done
