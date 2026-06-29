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


# 4. PikuZheng/smartdns（增强 fork，额外 bugfix + Web UI）
# 自动检测最新 release 版本，确保 C 源码与 .so 版本同步
# ============================================================
SM_TAG="master"          # git tag/branch to clone
SM_VERSION=""             # version string for .so download
SM_UI_VER_FALLBACK="1.2026.v48.1.13"  # pinned fallback if API unavailable

echo "=== Checking latest PikuZheng/smartdns release ==="
for i in 1 2 3; do
  _tag=$(curl -sL --connect-timeout 5 \
    "https://api.github.com/repos/PikuZheng/smartdns/releases?per_page=10" 2>/dev/null | \
    python3 -c "
import sys, json
try:
    for r in json.load(sys.stdin):
        t = r.get('tag_name', '')
        if '_with_ui' in t:
            print(t)
            break
except: pass
" 2>/dev/null)
  if [ -n "$_tag" ]; then
    SM_TAG="$_tag"
    SM_VERSION="${_tag%_with_ui}"
    echo "✅ smartdns: latest release $SM_VERSION (tag: $SM_TAG)"
    break
  fi
  [ $i -lt 3 ] && echo "⚠️ Retrying release check ($i)..." && sleep 2
done

if [ -z "$SM_VERSION" ]; then
  echo "⚠️ smartdns: API unreachable, using master + pinned .so ($SM_UI_VER_FALLBACK)"
  SM_VERSION="$SM_UI_VER_FALLBACK"
fi

# Clone + retry
sm_ok=false
for attempt in 1 2 3 4 5; do
  rm -rf package/emortal/smartdns
  if git -c http.version=HTTP/1.1 clone --depth 1 --single-branch -b "$SM_TAG" \
    "https://github.com/PikuZheng/smartdns.git" \
    "package/emortal/smartdns"; then
    if [ -f package/emortal/smartdns/Makefile ]; then
      sm_ok=true
      echo "✅ smartdns: cloned from GitHub ($SM_TAG)"
      break
    fi
  fi
  echo "⚠️ smartdns clone failed (attempt $attempt), retrying in 3s..."
  sleep 3
done
if [ "$sm_ok" != true ]; then
  echo "❌ smartdns clone failed after 5 attempts"
  exit 1
fi

# Generate OpenWrt package Makefile (once, after successful clone)
# Overwrites upstream C-project Makefile with OpenWrt package definition
_sm_root="${GITHUB_WORKSPACE:-$(dirname "$0")}"
cat > package/emortal/smartdns/Makefile << 'PKG_MK_EOF'
PKG_NAME:=smartdns
PKG_VERSION:=__PKG_VERSION__
PKG_RELEASE:=3

PKG_SOURCE_PROTO:=none

PKG_MAINTAINER:=Nick Peng <pymumu@gmail.com>
PKG_LICENSE:=GPL-3.0-or-later
PKG_LICENSE_FILES:=LICENSE

PKG_BUILD_PARALLEL:=1

include $(INCLUDE_DIR)/package.mk

MAKE_VARS += VER=$(PKG_VERSION)
MAKE_PATH:=src

# === smartdns server ===
define Package/smartdns/default
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=IP Addresses and Names
  URL:=https://github.com/PikuZheng/smartdns
endef

define Package/smartdns
  $(Package/smartdns/default)
  TITLE:=smartdns server (PikuZheng fork)
  DEPENDS:=+libpthread +libopenssl +libatomic +zlib
endef

define Package/smartdns/description
SmartDNS is a local DNS server with local cache, supports UDP, TCP, DoT, DoH, DOQ, DOH3.
endef

define Package/smartdns/conffiles
/etc/config/smartdns
/etc/smartdns/address.conf
/etc/smartdns/blacklist-ip.conf
/etc/smartdns/custom.conf
/etc/smartdns/domain-block.list
/etc/smartdns/domain-forwarding.list
endef

define Package/smartdns/install
	$(INSTALL_DIR) $(1)/usr/sbin $(1)/etc/config $(1)/etc/init.d
	$(INSTALL_DIR) $(1)/etc/smartdns $(1)/etc/smartdns/domain-set $(1)/etc/smartdns/conf.d/
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/src/smartdns $(1)/usr/sbin/smartdns
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/package/openwrt/files/etc/init.d/smartdns $(1)/etc/init.d/smartdns
	$(INSTALL_CONF) $(PKG_BUILD_DIR)/package/openwrt/address.conf $(1)/etc/smartdns/address.conf
	$(INSTALL_CONF) $(PKG_BUILD_DIR)/package/openwrt/blacklist-ip.conf $(1)/etc/smartdns/blacklist-ip.conf
	$(INSTALL_CONF) $(PKG_BUILD_DIR)/package/openwrt/custom.conf $(1)/etc/smartdns/custom.conf
	$(INSTALL_CONF) $(PKG_BUILD_DIR)/package/openwrt/files/etc/config/smartdns $(1)/etc/config/smartdns
endef

# === smartdns-ui (pre-built Web UI .so) ===
define Package/smartdns-ui
  $(Package/smartdns/default)
  TITLE:=smartdns dashboard (pre-built)
  DEPENDS:=+smartdns
endef

define Package/smartdns-ui/description
A dashboard Web UI for smartdns server.
endef

define Package/smartdns-ui/conffiles
/etc/config/smartdns
endef

define Package/smartdns-ui/install
	$(INSTALL_DIR) $(1)/usr/lib $(1)/usr/share/smartdns
	if [ -f "$(PKG_BUILD_DIR)/usr/lib/smartdns_ui.so" ]; then \
		$(INSTALL_BIN) $(PKG_BUILD_DIR)/usr/lib/smartdns_ui.so $(1)/usr/lib/; \
	fi
	if [ -d "$(PKG_BUILD_DIR)/usr/share/smartdns/wwwroot" ]; then \
		cp -r $(PKG_BUILD_DIR)/usr/share/smartdns/wwwroot $(1)/usr/share/smartdns/; \
	fi
endef



# Build/Prepare: local clone with proto=none, copy source from CURDIR
# (instead of PKG_SOURCE_PROTO:=git with default git clone)
define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	cp -rf $(CURDIR)/. $(PKG_BUILD_DIR)/
endef

# Build/Compile: smartdns C code + copy pre-built .so/wwwroot
define Build/Compile
	$(call Build/Compile/Default,smartdns)
	if [ -f "$(PKG_BUILD_DIR)/smartdns-ui-data/usr/lib/smartdns_ui.so" ]; then \
		mkdir -p $(PKG_BUILD_DIR)/usr/lib $(PKG_BUILD_DIR)/usr/share/smartdns; \
		cp -f $(PKG_BUILD_DIR)/smartdns-ui-data/usr/lib/smartdns_ui.so $(PKG_BUILD_DIR)/usr/lib/; \
		cp -rf $(PKG_BUILD_DIR)/smartdns-ui-data/usr/share/smartdns/wwwroot $(PKG_BUILD_DIR)/usr/share/smartdns/; \
	else \
		echo "⚠️ smartdns-ui: pre-built data not found in smartdns-ui-data/"; \
	fi
endef

$(eval $(call BuildPackage,smartdns))
$(eval $(call BuildPackage,smartdns-ui))

PKG_MK_EOF
sed -i "s/__PKG_VERSION__/${SM_VERSION}/" package/emortal/smartdns/Makefile package/emortal/luci-app-smartdns/Makefile
echo "✅ smartdns: generated OpenWrt package Makefile"

# === luci-app-smartdns (separate Makefile in emortal) ===
mkdir -p package/emortal/luci-app-smartdns
cat > package/emortal/luci-app-smartdns/Makefile << 'LUCI_MK_EOF'
PKG_NAME:=luci-app-smartdns
PKG_VERSION:=__PKG_VERSION__
PKG_RELEASE:=3

PKG_SOURCE_PROTO:=none

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-smartdns
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI support for smartdns (PikuZheng fork)
  DEPENDS:=+luci-compat +luci-lua-runtime +smartdns
  PKGARCH:=all
endef

define Package/luci-app-smartdns/description
LuCI configuration pages for PikuZheng smartdns fork.
endef

define Package/luci-app-smartdns/install
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/model/cbi/smartdns
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/i18n
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/view/smartdns
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/package/luci-compat/files/luci/controller/smartdns.lua $(1)/usr/lib/lua/luci/controller/
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/package/luci-compat/files/luci/model/smartdns.lua $(1)/usr/lib/lua/luci/model/
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/package/luci-compat/files/luci/model/cbi/smartdns/smartdns.lua $(1)/usr/lib/lua/luci/model/cbi/smartdns/
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/package/luci-compat/files/luci/model/cbi/smartdns/upstream.lua $(1)/usr/lib/lua/luci/model/cbi/smartdns/
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/package/luci-compat/files/luci/view/smartdns/smartdns_status.htm $(1)/usr/lib/lua/luci/view/smartdns/
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/package/luci-compat/files/luci/i18n/smartdns.zh-cn.po $(1)/usr/lib/lua/luci/i18n/
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/package/luci-compat/files/usr/share/rpcd/acl.d/luci-app-smartdns.json $(1)/usr/share/rpcd/acl.d/
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/package/luci-compat/files/etc/uci-defaults/50_luci-smartdns $(1)/etc/uci-defaults/50_luci-smartdns
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)/package
	cp -rf $(CURDIR)/../smartdns/package/luci-compat $(PKG_BUILD_DIR)/package/
endef

$(eval $(call BuildPackage,luci-app-smartdns))
LUCI_MK_EOF
sed -i "s/__PKG_VERSION__/${SM_VERSION}/" package/emortal/luci-app-smartdns/Makefile
echo "✅ luci-app-smartdns: generated separate OpenWrt package Makefile"

# 4b. Download pre-built smartdns_with_ui ipk (libsmartdns_ui.so + wwwroot)
#     版本自动匹配检测到的 release，API 不可用时用固定版本
if [ -n "$SM_VERSION" ]; then
  _sm_ui_dir="$(pwd)/package/emortal/smartdns/smartdns-ui-data"
  SM_UI_FILE="smartdns_with_ui.${SM_VERSION}.x86_64.ipk"
  SM_UI_URL="https://github.com/PikuZheng/smartdns/releases/download/${SM_VERSION}_with_ui/${SM_UI_FILE}"
  SM_UI_RETRY=0
  until [ $SM_UI_RETRY -ge 3 ]; do
    rm -rf "$_sm_ui_dir"
    mkdir -p "$_sm_ui_dir"
    cd "$_sm_ui_dir"
    if curl -sL --connect-timeout 10 "$SM_UI_URL" -o "$SM_UI_FILE" 2>/dev/null; then
      SM_UI_SIZE=$(stat -c%s "$SM_UI_FILE" 2>/dev/null || echo 0)
      if [ "$SM_UI_SIZE" -gt 100000 ]; then
        # Extract ipk (ar archive: control.tar.gz + data.tar.gz + debian-binary)
        ar x "$SM_UI_FILE" 2>/dev/null && \
        if [ -f data.tar.gz ]; then
          tar xzf data.tar.gz 2>/dev/null && echo "✅ smartdns-ui: data.tar.gz extracted"
        elif [ -f data.tar.xz ]; then
          tar xJf data.tar.xz 2>/dev/null && echo "✅ smartdns-ui: data.tar.xz extracted"
        else
          echo "⚠️ smartdns-ui: no data.tar.* in ipk"
        fi
        rm -f "$SM_UI_FILE" control.tar.gz debian-binary 2>/dev/null
        cd "$_sm_root"
        _sm_so_found=$(find "$_sm_ui_dir" -name "smartdns_ui.so" 2>/dev/null | head -1)
        if [ -n "$_sm_so_found" ]; then
          echo "✅ smartdns-ui: libsmartdns_ui.so found in ipk"
          break
        else
          echo "⚠️ smartdns-ui: .so not found in extracted ipk"
        fi
      else
        echo "⚠️ smartdns-ui: download too small ($SM_UI_SIZE bytes), retrying..."
        rm -f "$SM_UI_FILE"
      fi
    else
      echo "⚠️ smartdns-ui: download failed (attempt $((SM_UI_RETRY+1)))"
    fi
    cd "$_sm_root"
    SM_UI_RETRY=$((SM_UI_RETRY+1))
    sleep 2
  done
  if [ "$SM_UI_RETRY" -ge 3 ]; then
    echo "⚠️ smartdns-ui: all retries exhausted, building without Web UI"
  fi
fi
rm -f package/emortal/smartdns/smartdns-ui-data/smartdns_with_ui*.ipk 2>/dev/null
echo "✅ smartdns: ready"


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
