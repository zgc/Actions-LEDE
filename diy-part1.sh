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

# 4. adguardhome（beta 分支，luci-app-adguardhome）
rm -rf package/emortal/luci-app-adguardhome
git clone --depth 1 -b beta https://github.com/rufengsuixing/luci-app-adguardhome.git package/emortal/luci-app-adguardhome
sed -i "s/\$(TOPDIR)\/luci.mk/\$(TOPDIR)\/feeds\/luci\/luci.mk/g" package/emortal/luci-app-adguardhome/Makefile
