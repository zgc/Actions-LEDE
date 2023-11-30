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

rm -rf package/lean/luci-app-argon-config
git clone --depth 1 -b 18.06 https://github.com/jerrykuku/luci-app-argon-config.git package/lean/luci-app-argon-config

rm -rf package/lean/luci-app-filebrowser
svn co https://github.com/immortalwrt/luci/branches/openwrt-18.06/applications/luci-app-filebrowser package/lean/luci-app-filebrowser
sed -i "s/..\/..\/luci.mk/\$(TOPDIR)\/feeds\/luci\/luci.mk/g" package/lean/luci-app-filebrowser/Makefile
rm -rf package/lean/filebrowser
svn co https://github.com/immortalwrt/packages/branches/openwrt-18.06/utils/filebrowser package/lean/filebrowser
sed -i "s/..\/..\/lang\/golang\/golang-package.mk/\$(TOPDIR)\/feeds\/packages\/lang\/golang\/golang-package.mk/g" package/lean/filebrowser/Makefile

rm -rf package/lean/luci-app-openclash
OPENCLASH_BRANCH=dev
svn co https://github.com/vernesong/OpenClash/branches/$OPENCLASH_BRANCH/luci-app-openclash package/lean/luci-app-openclash

rm -rf package/lean/luci-app-smartdns
svn co https://github.com/immortalwrt/luci/branches/openwrt-18.06/applications/luci-app-smartdns package/lean/luci-app-smartdns
sed -i "s/..\/..\/luci.mk/\$(TOPDIR)\/feeds\/luci\/luci.mk/g" package/lean/luci-app-smartdns/Makefile

rm -rf package/lean/luci-app-adguardhome
git clone --depth 1 -b beta https://github.com/rufengsuixing/luci-app-adguardhome.git package/lean/luci-app-adguardhome
sed -i "s/\$(TOPDIR)\/luci.mk/\$(TOPDIR)\/feeds\/luci\/luci.mk/g" package/lean/luci-app-adguardhome/Makefile
