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

# 3. openclash（完整克隆后提取）
rm -rf package/emortal/luci-app-openclash /tmp/openclash-tmp
git clone --depth 1 -b $OPENCLASH_BRANCH https://github.com/vernesong/OpenClash.git /tmp/openclash-tmp
mv /tmp/openclash-tmp/luci-app-openclash package/emortal/luci-app-openclash
rm -rf /tmp/openclash-tmp

# 4. ZeroTier 1.14.2
# 4.1 zerotier 包（coolsnowwolf/packages 特定 commit）
rm -rf package/emortal/zerotier /tmp/coolsnowwolf-pkg
git clone https://github.com/coolsnowwolf/packages.git /tmp/coolsnowwolf-pkg
cd /tmp/coolsnowwolf-pkg
git checkout 01e5467f06d049a1e15637ae86306602c89e8a4c
cd $GITHUB_WORKSPACE
mv /tmp/coolsnowwolf-pkg/net/zerotier package/emortal/zerotier
rm -rf /tmp/coolsnowwolf-pkg

# 4.2 luci-app-zerotier（coolsnowwolf/luci master 分支）
rm -rf package/emortal/luci-app-zerotier /tmp/coolsnowwolf-luci
git clone --depth 1 https://github.com/coolsnowwolf/luci.git /tmp/coolsnowwolf-luci
mv /tmp/coolsnowwolf-luci/applications/luci-app-zerotier package/emortal/luci-app-zerotier
rm -rf /tmp/coolsnowwolf-luci

# 5. adguardhome
rm -rf package/emortal/luci-app-adguardhome
git clone --depth 1 -b beta https://github.com/rufengsuixing/luci-app-adguardhome.git package/emortal/luci-app-adguardhome
sed -i "s/\$(TOPDIR)\/luci.mk/\$(TOPDIR)\/feeds\/luci\/luci.mk/g" package/emortal/luci-app-adguardhome/Makefile
