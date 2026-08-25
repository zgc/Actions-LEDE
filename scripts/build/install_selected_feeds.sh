#!/bin/bash
# 注册完整 feed 包图。仅注册配置请求的包会漏掉只作为 host/build 依赖的
# 工具链提供者（例如 golang1.27/host），导致 frp 等 Go 包在编译时找不到 go。
set -euo pipefail

OPENWRT_DIR=${1:?usage: install_selected_feeds.sh <openwrt-dir> <config-file>}
CONFIG_FILE=${2:?usage: install_selected_feeds.sh <openwrt-dir> <config-file>}

cd "$OPENWRT_DIR"
mapfile -t requested_packages < <(sed -n 's/^CONFIG_PACKAGE_\([A-Za-z0-9_-]*\)=y$/\1/p' "$CONFIG_FILE")
[ "${#requested_packages[@]}" -gt 0 ] || {
	echo "❌ no requested packages found in $CONFIG_FILE"
	exit 1
}

# feeds/ 是可重建的生成链接；重新注册包图，不修改 feeds 源码。
# 上一次构建残留的元数据可能把同名 feed 包误判为 core 而跳过，先清空再注册。
rm -f tmp/.packageinfo tmp/info/.packageinfo-*
feed_log=$(mktemp)
trap 'rm -f "$feed_log"' EXIT
if ! ./scripts/feeds uninstall -a >"$feed_log" 2>&1; then
	tail -n 80 "$feed_log" >&2
	echo "❌ failed to unregister previous feed packages"
	exit 1
fi
if ! ./scripts/feeds install -a >>"$feed_log" 2>&1; then
	tail -n 80 "$feed_log" >&2
	echo "❌ failed to register feed packages"
	exit 1
fi
# 剔除会触发上游 Kconfig 递归依赖且当前未选中的包，避免完整包图被上游坏包阻塞。
while IFS= read -r name; do
	[ -n "$name" ] || continue
	if ! printf '%s\n' "${requested_packages[@]}" | grep -qx "$name"; then
		if ./scripts/feeds uninstall "$name" >>"$feed_log" 2>&1; then
			echo "⚠️ Excluded unselected $name until its upstream Kconfig is fixed"
		fi
	fi
done <<'EOF'
trafficshaper
freeradius3
EOF
echo "✅ Registered feed package graph"
