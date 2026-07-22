#!/bin/bash
#
# Copyright (c) 2019-2020 P3TERX <https://p3terx.com>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#
# https://github.com/P3TERX/Actions-OpenWrt
# File name: diy-part1.sh
# 说明：OpenWrt DIY 脚本第一阶段（更新 feeds 前）
#

# =============================================================================
# 构建输入
# =============================================================================
OPENCLASH_BRANCH=dev

# =============================================================================
# 源码获取辅助函数
# cache_clone：从 GitHub 克隆；仅在明确启用时回退至本地缓存。
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
# =============================================================================
cache_clone() {
  local name="$1" url="$2" branch="$3" target="$4" sparse="${5:-}"
  local cache="${BUILD_CACHE_DIR:+"$BUILD_CACHE_DIR/$name"}"
  local ok=false

  rm -rf "$target"

  for attempt in 1 2 3; do
    if [ -n "$sparse" ]; then
      local tmpdir
      tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/cache-${name}.XXXXXX") || {
        echo "❌ ${name}: failed to create sparse-clone temporary directory"
        exit 1
      }
      if git clone --depth 1 -b "$branch" --filter=blob:none --sparse \
           "$url" --no-checkout "$tmpdir" && \
         (cd "$tmpdir" && git sparse-checkout init --cone \
           && git sparse-checkout set "$sparse" \
           && git checkout) && \
         mv "${tmpdir}/${sparse}" "$target"; then
        rm -rf "$tmpdir"
        ok=true
        break
      fi
      rm -rf "$tmpdir"
    elif git clone --depth 1 -b "$branch" "$url" "$target"; then
      ok=true
      break
    fi
    rm -rf "$target"
    [ "$attempt" -lt 3 ] && echo "WARNING: ${name} clone attempt ${attempt} failed; retrying..." && sleep 2
  done

  if $ok; then
    echo "✅ ${name}: cloned from GitHub"
    if [ -n "$BUILD_CACHE_DIR" ]; then
      mkdir -p "$(dirname "$cache")"
      rm -rf "$cache"
      cp -r "$target" "$cache"
      echo "✅ ${name}: cache updated"
    fi
  elif [ -n "$BUILD_CACHE_DIR" ] && [ -d "$cache" ] && [ "${ALLOW_STALE_SOURCE_CACHE:-0}" = "1" ]; then
    echo "⚠️ ${name}: GitHub clone failed, using explicitly allowed local build-cache"
    cp -r "$cache" "$target"
  elif [ -n "$BUILD_CACHE_DIR" ] && [ -d "$cache" ]; then
    echo "❌ ${name}: GitHub clone failed; refusing stale build-cache (set ALLOW_STALE_SOURCE_CACHE=1 to opt in)"
    exit 1
  else
    echo "❌ ${name}: both GitHub clone and local cache failed"
    exit 1
  fi
}

# =============================================================================
# 第三方软件包源码
# =============================================================================
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

# =============================================================================
# 可选 SmartDNS 增强功能及 feed 回退
# =============================================================================
# 4. PikuZheng/smartdns（增强 fork，额外 bugfix + Web UI）
#    发布标签、源码和 UI 资源必须对应同一版本。发现版本失败时不能回退到
#    master 或固定 UI 资源；ImmortalWrt feed 是兼容回退路径。
install_pikuzheng_smartdns() (
SM_TAG=""
SM_VERSION=""
SM_UI_FILE=""
SM_UI_URL=""

echo "=== Checking latest PikuZheng/smartdns release ==="
_release=$(curl --fail --silent --show-error --retry 5 --retry-delay 2 --location \
  "https://api.github.com/repos/PikuZheng/smartdns/releases/latest" 2>/dev/null | \
  python3 -c '
import json
import sys

try:
    release = json.load(sys.stdin)
    tag = release.get("tag_name", "")
    if not release.get("draft") and not release.get("prerelease") and tag.endswith("_with_ui"):
        version = tag.removesuffix("_with_ui")
        wanted = f"smartdns_with_ui.{version}.x86_64.ipk"
        for asset in release.get("assets", []):
            if asset.get("name") == wanted and asset.get("browser_download_url"):
                print("\t".join((tag, version, wanted, asset["browser_download_url"]))
                sys.exit(0)
except (ValueError, TypeError):
    pass

sys.exit(1)
' 2>/dev/null)

if [ -z "$_release" ]; then
  echo "❌ smartdns: unable to discover a compatible source tag and x86_64 UI asset"
  return 1
fi
IFS=$'\t' read -r SM_TAG SM_VERSION SM_UI_FILE SM_UI_URL <<< "$_release"
echo "✅ smartdns: latest compatible release $SM_VERSION (tag: $SM_TAG)"

# 4a. 下载已验证的预编译 SmartDNS UI 资源（.so 与 wwwroot）。
_sm_root="$(pwd)"
_sm_ui_tmp=$(mktemp -d "${TMPDIR:-/tmp}/smartdns-ui.XXXXXX") || {
  echo "❌ smartdns-ui temporary directory creation failed"
  return 1
}
trap 'rm -rf "$_sm_ui_tmp"' EXIT
cd "$_sm_ui_tmp"
curl --fail --show-error --retry 5 --retry-delay 2 --location "$SM_UI_URL" -o "$SM_UI_FILE" || {
  echo "❌ smartdns-ui asset download failed"
  return 1
}
SM_UI_SIZE=$(stat -c%s "$SM_UI_FILE" 2>/dev/null || echo 0)
[ "$SM_UI_SIZE" -gt 100000 ] || { echo "❌ smartdns-ui asset is too small ($SM_UI_SIZE bytes)"; return 1; }
(ar x "$SM_UI_FILE" 2>/dev/null || tar xzf "$SM_UI_FILE" 2>/dev/null) || {
  echo "❌ smartdns-ui asset extraction failed"
  return 1
}
if [ -f data.tar.gz ]; then
  tar xzf data.tar.gz || { echo "❌ smartdns-ui data extraction failed"; return 1; }
elif [ -f data.tar.xz ]; then
  tar xJf data.tar.xz || { echo "❌ smartdns-ui data extraction failed"; return 1; }
else
  echo "❌ smartdns-ui asset has no data archive"
  return 1
fi
rm -f "$SM_UI_FILE" control.tar.gz debian-binary
cd "$_sm_root"

# config.seed 选择了 smartdns-ui。不能只生成 manifest 中存在、但缺少共享对象或
# Web 资源的软件包。
if [ ! -f "$_sm_ui_tmp/usr/lib/smartdns_ui.so" ] || \
   [ ! -d "$_sm_ui_tmp/usr/share/smartdns/wwwroot" ]; then
  echo "❌ smartdns-ui assets are incomplete; refusing to build an empty UI package"
  return 1
fi

# 清理版本号：apk mkpkg 不接受版本组成部分的 `v` 前缀（例如 `.v48`）。
SM_VERSION="$(echo "$SM_VERSION" | sed 's/\.v\([0-9]\)/.\1/g')"

# 4b. 克隆 PikuZheng/smartdns 源码（带重试）。
sm_ok=false
for attempt in 1 2 3 4 5; do
  rm -rf package/emortal/smartdns
  if git -c http.version=HTTP/1.1 clone --depth 1 --single-branch -b "$SM_TAG" \
    "https://github.com/PikuZheng/smartdns.git" \
    "package/emortal/smartdns"; then
    if [ -f package/emortal/smartdns/Makefile ]; then
      sm_ok=true
      echo "✅ smartdns: cloned from GitHub ($SM_TAG)"
      rm -f package/emortal/smartdns/package/openwrt/Makefile
      if [ -d "$_sm_ui_tmp" ] && [ -f "$_sm_ui_tmp/usr/lib/smartdns_ui.so" ]; then
        mkdir -p package/emortal/smartdns/smartdns-ui-data
        cp -r "$_sm_ui_tmp/usr" package/emortal/smartdns/smartdns-ui-data/
        echo "✅ smartdns-ui: lib restored from /tmp"
      fi
      break
    fi
  fi
  echo "⚠️ smartdns clone failed (attempt $attempt), retrying in 3s..."
  sleep 3
done
if [ "$sm_ok" != true ]; then
  echo "❌ smartdns clone failed after 5 attempts"
  return 1
fi

# 生成 smartdns 与 smartdns-ui 的 OpenWrt 软件包 Makefile
cat > package/emortal/smartdns/Makefile << 'PKG_MK_EOF'
PKG_NAME:=smartdns
PKG_VERSION:=__PKG_VERSION__
PKG_RELEASE:=3
PKG_SOURCE_PROTO:=none
PKG_MAINTAINER:=Nick Peng <pymumu@gmail.com>
PKG_LICENSE:=GPL-3.0-or-later
PKG_LICENSE_FILES:=LICENSE
PKG_BUILD_PARALLEL:=1
include $(TOPDIR)/rules.mk
include $(INCLUDE_DIR)/package.mk
MAKE_VARS += VER=$(PKG_VERSION)
MAKE_PATH:=src

# === smartdns 服务端 ===
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

# === smartdns-ui（预编译 Web UI .so）===
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

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	cp -rf $(CURDIR)/. $(PKG_BUILD_DIR)/
endef

define Build/Compile
	$(call Build/Compile/Default,smartdns)
	if [ -f "$(PKG_BUILD_DIR)/smartdns-ui-data/usr/lib/smartdns_ui.so" ]; then \
		mkdir -p $(PKG_BUILD_DIR)/usr/lib $(PKG_BUILD_DIR)/usr/share/smartdns; \
		cp -f $(PKG_BUILD_DIR)/smartdns-ui-data/usr/lib/smartdns_ui.so $(PKG_BUILD_DIR)/usr/lib/; \
		cp -rf $(PKG_BUILD_DIR)/smartdns-ui-data/usr/share/smartdns/wwwroot $(PKG_BUILD_DIR)/usr/share/smartdns/; \
	else \
		echo "❌ smartdns-ui: pre-built data not found in smartdns-ui-data/"; \
		exit 1; \
	fi
endef

$(eval $(call BuildPackage,smartdns))
$(eval $(call BuildPackage,smartdns-ui))
PKG_MK_EOF
sed -i "s/__PKG_VERSION__/${SM_VERSION}/" package/emortal/smartdns/Makefile
echo "✅ smartdns: generated OpenWrt package Makefile"

# luci-app-smartdns 使用 ImmortalWrt feed 版本，此处不重复生成
echo "✅ smartdns: ready"
return 0
)

if ! install_pikuzheng_smartdns; then
  rm -rf package/emortal/smartdns
  echo "⚠️ smartdns: PikuZheng source unavailable; using ImmortalWrt feed smartdns, smartdns-ui and luci-app-smartdns"
fi

# =============================================================================
# OpenClash 运行时兼容性
# =============================================================================
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
