#!/bin/bash
# 仅注册配置实际请求的软件包，避免未选 feed 包的 Kconfig 影响固件构建。
set -euo pipefail

OPENWRT_DIR=${1:?usage: install_selected_feeds.sh <openwrt-dir> <config-file>}
CONFIG_FILE=${2:?usage: install_selected_feeds.sh <openwrt-dir> <config-file>}

cd "$OPENWRT_DIR"
mapfile -t requested_packages < <(sed -n 's/^CONFIG_PACKAGE_\([A-Za-z0-9_-]*\)=y$/\1/p' "$CONFIG_FILE")
[ "${#requested_packages[@]}" -gt 0 ] || {
	echo "❌ no requested packages found in $CONFIG_FILE"
	exit 1
}

# feeds/ 是可重建的生成链接；重新注册精确的配置闭包，不修改 feeds 源码。
# feeds install 会读取 tmp/info 判断已装/核心包；上一次构建残留的元数据可能把
# 同名 feed 包误判为 core 而跳过，因此先清空生成的包元数据再注册。
rm -f tmp/.packageinfo tmp/info/.packageinfo-*
feed_log=$(mktemp)
trap 'rm -f "$feed_log"' EXIT
if ! ./scripts/feeds uninstall -a >"$feed_log" 2>&1; then
	tail -n 80 "$feed_log" >&2
	echo "❌ failed to unregister previous feed packages"
	exit 1
fi
if ! ./scripts/feeds install "${requested_packages[@]}" >>"$feed_log" 2>&1; then
	tail -n 80 "$feed_log" >&2
	echo "❌ failed to register requested feed packages"
	exit 1
fi
echo "✅ Registered ${#requested_packages[@]} requested feed packages"
