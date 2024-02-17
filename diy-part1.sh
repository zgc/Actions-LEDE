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

# Uncomment a feed source
#sed -i 's/^#\(.*helloworld\)/\1/' feeds.conf.default

# Add a feed source
#echo 'src-git helloworld https://github.com/fw876/helloworld' >>feeds.conf.default
#echo 'src-git passwall https://github.com/xiaorouji/openwrt-passwall' >>feeds.conf.default

IMMORTALWRT_BRANCH=openwrt-18.06
OPENCLASH_BRANCH=dev

rm -rf package/lean/luci-app-argon-config
git clone --depth 1 -b 18.06 https://github.com/jerrykuku/luci-app-argon-config.git package/lean/luci-app-argon-config

rm -rf package/lean/luci-app-filebrowser
mkdir -p package/lean/luci-app-filebrowser
pushd package/lean/luci-app-filebrowser
git init
git remote add -f origin https://github.com/immortalwrt/luci.git
git config core.sparsecheckout true
echo "applications/luci-app-filebrowser" >> .git/info/sparse-checkout
git pull --depth 1 origin $IMMORTALWRT_BRANCH
sed -i "s/..\/..\/luci.mk/\$(TOPDIR)\/feeds\/luci\/luci.mk/g" Makefile
popd
rm -rf package/lean/filebrowser
mkdir -p package/lean/filebrowser
pushd package/lean/filebrowser
git init
git remote add -f origin https://github.com/immortalwrt/packages.git
git config core.sparsecheckout true
echo "utils/filebrowser" >> .git/info/sparse-checkout
git pull --depth 1 origin $IMMORTALWRT_BRANCH
sed -i "s/..\/..\/lang\/golang\/golang-package.mk/\$(TOPDIR)\/feeds\/packages\/lang\/golang\/golang-package.mk/g" Makefile
popd

rm -rf package/lean/luci-app-openclash
mkdir -p package/lean/luci-app-openclash
pushd package/lean/luci-app-openclash
git init
git remote add -f origin https://github.com/vernesong/OpenClash.git
git config core.sparsecheckout true
echo "luci-app-openclash" >> .git/info/sparse-checkout
git pull --depth 1 origin $OPENCLASH_BRANCH
popd

rm -rf package/lean/luci-app-smartdns
mkdir -p package/lean/luci-app-smartdns
pushd package/lean/luci-app-smartdns
git init
git remote add -f origin https://github.com/immortalwrt/luci.git
git config core.sparsecheckout true
echo "applications/luci-app-smartdns" >> .git/info/sparse-checkout
git pull --depth 1 origin $IMMORTALWRT_BRANCH
sed -i "s/..\/..\/luci.mk/\$(TOPDIR)\/feeds\/luci\/luci.mk/g" Makefile
popd

rm -rf package/lean/luci-app-adguardhome
git clone --depth 1 -b beta https://github.com/rufengsuixing/luci-app-adguardhome.git package/lean/luci-app-adguardhome
sed -i "s/\$(TOPDIR)\/luci.mk/\$(TOPDIR)\/feeds\/luci\/luci.mk/g" package/lean/luci-app-adguardhome/Makefile
