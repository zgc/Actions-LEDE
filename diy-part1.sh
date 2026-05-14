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

LUCI_BRANCH=18.06
OPENCLASH_BRANCH=dev

# 1. luci-theme-argon（luci-app-argon-config 依赖的主题）
rm -rf package/emortal/luci-theme-argon
git clone --depth 1 -b $LUCI_BRANCH https://github.com/jerrykuku/luci-theme-argon.git package/emortal/luci-theme-argon

# 2. luci-app-argon-config
rm -rf package/emortal/luci-app-argon-config
git clone --depth 1 -b $LUCI_BRANCH https://github.com/jerrykuku/luci-app-argon-config.git package/emortal/luci-app-argon-config

# 3. openclash（sparse checkout 省空间）
rm -rf package/emortal/luci-app-openclash /tmp/openclash-tmp
mkdir -p /tmp/openclash-tmp
git clone --depth 1 -b $OPENCLASH_BRANCH --filter=blob:none --sparse https://github.com/vernesong/OpenClash.git --no-checkout /tmp/openclash-tmp
pushd /tmp/openclash-tmp
git sparse-checkout init --cone
git sparse-checkout set luci-app-openclash
git checkout
popd
mv /tmp/openclash-tmp/luci-app-openclash package/emortal/luci-app-openclash
rm -rf /tmp/openclash-tmp

# 4. ZeroTier 1.14.2
# 4.1 zerotier 包（coolsnowwolf/packages 特定 commit，sparse checkout 省空间）
rm -rf package/emortal/zerotier /tmp/coolsnowwolf-pkg
mkdir -p /tmp/coolsnowwolf-pkg
git clone --filter=blob:none --sparse https://github.com/coolsnowwolf/packages.git --no-checkout /tmp/coolsnowwolf-pkg
cd /tmp/coolsnowwolf-pkg
git checkout 01e5467f06d049a1e15637ae86306602c89e8a4c
git sparse-checkout init --cone
git sparse-checkout set net/zerotier
git checkout 01e5467f06d049a1e15637ae86306602c89e8a4c
cd $GITHUB_WORKSPACE/openwrt
mv /tmp/coolsnowwolf-pkg/net/zerotier package/emortal/zerotier
rm -rf /tmp/coolsnowwolf-pkg

# 4.2 coolsnowwolf/luci packages（master 分支，Lua/CBI 全部兼容）
# 替换 ImmortalWrt feeds 版本：diskman frpc ksmbd netdata smartdns ttyd vlmcsd turboacc zerotier
cd $GITHUB_WORKSPACE/openwrt
rm -rf /tmp/cw-luci
mkdir -p /tmp/cw-luci
# 增大 http buffer，减少 GnuTLS 握手失败概率
git config --global http.postBuffer 524288000
# 重试 5 次，指数退避（Docker 内 GnuTLS 握手不稳定）
_cw_ok=0
for _attempt in 1 2 3 4 5; do
  echo "[cw-luci] attempt $_attempt/5 ..."
  if git clone --depth 1 -b master --filter=blob:none --no-checkout https://github.com/coolsnowwolf/luci.git /tmp/cw-luci 2>&1; then
    _cw_ok=1; break
  fi
  rm -rf /tmp/cw-luci; mkdir -p /tmp/cw-luci
  _wait=$((10 * _attempt))
  echo "[cw-luci] failed, waiting ${_wait}s ..."
  sleep $_wait
done
if [ $_cw_ok -eq 0 ]; then
  echo "[cw-luci] git clone failed 5 times, falling back to archive API ..."
  rm -rf /tmp/cw-luci; mkdir -p /tmp/cw-luci
  curl -sL --retry 3 --retry-delay 10 https://github.com/coolsnowwolf/luci/archive/master.tar.gz | tar xz --strip-components=1 -C /tmp/cw-luci 2>&1
  if [ ! -f /tmp/cw-luci/applications/luci-app-turboacc/Makefile ]; then
    echo "[cw-luci] ERROR: archive API fallback also failed, keeping feeds versions"
  fi
fi
cd /tmp/cw-luci 2>/dev/null && {
# 其余 7 个包: 使用最新 master（仍有 luasrc/，Lua/CBI 兼容）
git checkout origin/master -- \
  applications/luci-app-turboacc/ \
  applications/luci-app-diskman/ \
  applications/luci-app-frpc/ \
  applications/luci-app-ksmbd/ \
  applications/luci-app-netdata/ \
  applications/luci-app-smartdns/ \
  applications/luci-app-ttyd/ \
  applications/luci-app-vlmcsd/ 2>/dev/null
}
# zerotier: 使用最后一个 Lua/CBI 版本 (c79d23bf46)，origin/master 已迁移到 JS
# GitHub 不支持 fetch 任意 SHA，用 archive API 单独下载
# 如果 curl 失败（Docker 内 TLS 问题），不在这里创建空目录
# 让 for 循环的 Makefile 检测来决定是否用 feeds 版本
cd /tmp
rm -rf cw-luci-zerotier
curl -sL https://github.com/coolsnowwolf/luci/archive/c79d23bf46.tar.gz | tar xz
cw_dir=$(ls -d coolsnowwolf-luci-* 2>/dev/null | head -1)
if [ -d "$cw_dir/applications/luci-app-zerotier" ] && [ -f "$cw_dir/applications/luci-app-zerotier/Makefile" ]; then
  mkdir -p /tmp/cw-luci/applications/luci-app-zerotier
  cp -a $cw_dir/applications/luci-app-zerotier/* /tmp/cw-luci/applications/luci-app-zerotier/
  echo "OK: zerotier LuCI from coolsnowwolf c79d23bf46"
else
  echo "WARN: zerotier LuCI not available from coolsnowwolf, feeds version will be used"
fi
rm -rf $cw_dir
cd $GITHUB_WORKSPACE/openwrt
for pkg in luci-app-zerotier luci-app-turboacc luci-app-diskman luci-app-frpc luci-app-ksmbd luci-app-netdata luci-app-smartdns luci-app-ttyd luci-app-vlmcsd; do
  # 只在源目录有 Makefile 时才替换（避免 mkdir -p 创建空目录导致误判）
  if [ -f /tmp/cw-luci/applications/$pkg/Makefile ]; then
    rm -rf package/emortal/$pkg
    mv /tmp/cw-luci/applications/$pkg package/emortal/$pkg
    # 修复 Makefile include 路径（单引号防止 shell 展开 $(TOPDIR)）
    sed -i 's|../../luci.mk|$(TOPDIR)/feeds/luci/luci.mk|g' package/emortal/$pkg/Makefile
  else
    echo "WARN: $pkg not found in coolsnowwolf/luci (no Makefile), keeping feeds version"
    # 清理可能存在的空目录，让 feeds 版本接管
    if [ -d package/emortal/$pkg ] && [ ! -f package/emortal/$pkg/Makefile ]; then
      rm -rf package/emortal/$pkg
      echo "  Removed empty package/emortal/$pkg, feeds version will be used"
    fi
  fi
done
rm -rf /tmp/cw-luci
# 删除 coolsnowwolf 的 zerotier init.d（与 emortal zerotier START=90 冲突）
rm -f package/emortal/luci-app-zerotier/root/etc/init.d/zerotier
rm -rf package/emortal/luci-app-zerotier/root/etc/zerotier
# 保留: uci-defaults（ucitrack + firewall）、zerotier.start/stop（NAT 规则）、Lua 文件、翻译

# 5. adguardhome
rm -rf package/emortal/luci-app-adguardhome
git clone --depth 1 -b beta https://github.com/rufengsuixing/luci-app-adguardhome.git package/emortal/luci-app-adguardhome
sed -i "s/\$(TOPDIR)\/luci.mk/\$(TOPDIR)\/feeds\/luci\/luci.mk/g" package/emortal/luci-app-adguardhome/Makefile
