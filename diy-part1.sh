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

# 1. luci-theme-argon（luci-app-argon-config 依赖的主题）
rm -rf package/emortal/luci-theme-argon
git clone --depth 1 -b master https://github.com/jerrykuku/luci-theme-argon.git package/emortal/luci-theme-argon

# 2. luci-app-argon-config
rm -rf package/emortal/luci-app-argon-config
git clone --depth 1 -b master https://github.com/jerrykuku/luci-app-argon-config.git package/emortal/luci-app-argon-config

# 3. openclash（优先 git clone，GitHub 不通则 fallback 到本地缓存）
#    缓存仅为 GFW 容错，不阻碍版本更新
OPENCLASH_CACHE="$GITHUB_WORKSPACE/build-cache/luci-app-openclash"
rm -rf package/emortal/luci-app-openclash /tmp/openclash-tmp
mkdir -p /tmp/openclash-tmp
if git clone --depth 1 -b $OPENCLASH_BRANCH --filter=blob:none --sparse \
      https://github.com/vernesong/OpenClash.git --no-checkout /tmp/openclash-tmp 2>/dev/null; then
  echo "✅ openclash: cloned from GitHub (dev branch)"
  pushd /tmp/openclash-tmp >/dev/null
  git sparse-checkout init --cone
  git sparse-checkout set luci-app-openclash
  git checkout
  popd >/dev/null
  mv /tmp/openclash-tmp/luci-app-openclash package/emortal/luci-app-openclash
  rm -rf /tmp/openclash-tmp
  # 更新本地缓存，下次 GitHub 不通时使用
  mkdir -p "$(dirname "$OPENCLASH_CACHE")"
  rm -rf "$OPENCLASH_CACHE"
  cp -r package/emortal/luci-app-openclash "$OPENCLASH_CACHE"
  echo "✅ openclash: cache updated"
elif [ -d "$OPENCLASH_CACHE" ]; then
  echo "⚠️ openclash: GitHub clone failed, using local build-cache"
  cp -r "$OPENCLASH_CACHE" package/emortal/luci-app-openclash
else
  echo "❌ openclash: both GitHub clone and local cache failed"
  exit 1
fi


# 4. zerotier — GitHub regenerated tarball hash (updated 2026-06-15)
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
