#!/bin/bash
#
# Copyright (c) 2019-2020 P3TERX <https://p3terx.com>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#
# https://github.com/P3TERX/Actions-OpenWrt
# File name: diy-part2.sh
# 说明：OpenWrt DIY 脚本第二阶段（更新 feeds 后）
#

# =============================================================================
# 构建常量和下载辅助函数
# =============================================================================
Arch="amd64"
CPU_MODEL="${Arch}-v3"
CLASH_META_REPOS_VERNESONG=${CLASH_META_REPOS_VERNESONG:-true}

download_file() {
	local url="$1" destination="$2" temporary

	temporary=$(mktemp "${destination}.tmp.XXXXXX") || return 1
	if curl --fail --show-error --location --retry 5 --retry-all-errors --retry-delay 2 \
		--connect-timeout 20 --output "$temporary" "$url" && [ -s "$temporary" ]; then
		mv -f "$temporary" "$destination" || {
			rm -f "$temporary"
			return 1
		}
		return 0
	fi
	rm -f "$temporary"
	return 1
}

download_required() {
	local url="$1" destination="$2" label="$3"
	download_file "$url" "$destination" || {
		echo "❌ $label download failed"
		exit 1
	}
}

install_mihomo_latest() {
	local destination="$1" version asset archive
	version="$(curl --fail --show-error --location --retry 5 --retry-all-errors --retry-delay 2 --connect-timeout 20 https://api.github.com/repos/MetaCubeX/mihomo/releases/latest 2>/dev/null | grep -E 'tag_name' | grep -E 'v[0-9.]+' -o 2>/dev/null)"
	[ -n "$version" ] || { echo "❌ Mihomo latest version lookup failed"; return 1; }
	asset="mihomo-linux-${CPU_MODEL}-${version}.gz"
	archive="$destination/$asset"
	if ! download_file "https://github.com/MetaCubeX/mihomo/releases/download/${version}/${asset}" "$archive"; then
		asset="mihomo-linux-${Arch}-${version}.gz"
		archive="$destination/$asset"
		download_file "https://github.com/MetaCubeX/mihomo/releases/download/${version}/${asset}" "$archive" || return 1
	fi
	gzip -df "$archive" || return 1
	[ -f "${archive%.gz}" ] || return 1
	install -m 0755 "${archive%.gz}" package/emortal/luci-app-openclash/root/etc/openclash/core/clash_meta
}

# =============================================================================
# 共享构建定制
# =============================================================================
configure_dropbear() {
	sed -i \
		-e '/option _direct/d' \
		-e '/option DirectInterface/d' \
		-e '0,/^[[:space:]]*option enable '\''1'\''$/b' \
		-e '/^[[:space:]]*option enable '\''1'\''$/d' \
		package/network/services/dropbear/files/dropbear.config
}

deploy_base_rootfs_tools() {
	for script in check_smartdns_connect.sh check_openclash_connect.sh check_wan_connect.sh \
		reset_get_img.sh reset_latest.sh reset_offline.sh reset_upload.sh; do
		cp "$GITHUB_WORKSPACE/scripts/$script" package/base-files/files/etc/
		chmod +x "package/base-files/files/etc/$script"
	done

	cp "$GITHUB_WORKSPACE/scripts/verify_rootfs.sh" package/base-files/files/etc/verify_rootfs.sh
	chmod +x package/base-files/files/etc/verify_rootfs.sh
	cp "$GITHUB_WORKSPACE/scripts/rootfs-integrity-check" package/base-files/files/etc/init.d/rootfs-integrity-check
	chmod +x package/base-files/files/etc/init.d/rootfs-integrity-check
	mkdir -p package/base-files/files/etc/hotplug.d/iface
	cp "$GITHUB_WORKSPACE/scripts/zerotier-wan-hotplug" package/base-files/files/etc/hotplug.d/iface/95-zerotier-wan
	chmod +x package/base-files/files/etc/hotplug.d/iface/95-zerotier-wan
}

configure_firstboot_defaults() {
	local defaults=package/emortal/default-settings/files/99-default-settings

	sed -i '/^exit 0$/i /etc/init.d/rootfs-integrity-check start' "$defaults"
	sed -i '/^exit 0$/i\if ! uci -q get network.globals.multipath >/dev/null; then uci -q set network.globals.multipath="1"; uci -q commit network; fi' "$defaults"

	# Base 提供可选检查；是否启用由设备 cron overlay 决定。
	for cron_script in check_smartdns_connect.sh check_openclash_connect.sh check_wan_connect.sh; do
		sed -i '/exit 0/i\if ! grep -q "/etc/'"$cron_script"'" /etc/crontabs/root 2>/dev/null; then echo "#*/5 * * * * /etc/'"$cron_script"'" >> /etc/crontabs/root; fi' "$defaults"
	done

	sed -i '/commit luci/i\set luci.main.mediaurlbase="/luci-static/argon"' "$defaults"
	sed -i '/^exit 0$/i uci -q add_list uhttpd.main.listen_https="0.0.0.0:443"' "$defaults"
	sed -i '/^exit 0$/i uci -q add_list uhttpd.main.listen_https="[::]:443"' "$defaults"
	sed -i '/^exit 0$/i uci -q commit uhttpd' "$defaults"
	sed -i '/^exit 0$/i uci set firewall.@defaults[0].flow_offloading="1"' "$defaults"
	sed -i '/^exit 0$/i uci set firewall.@defaults[0].fullcone="1"' "$defaults"
	sed -i '/^exit 0$/i uci commit firewall' "$defaults"
	sed -i '/^exit 0$/i sysctl -qw net.ipv4.tcp_congestion_control=bbr || true' "$defaults"
	sed -i '/^exit 0$/i grep -qxF "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf' "$defaults"
}

configure_application_defaults() {
	sed -i "s/uci -q set openclash.config.enable=0/uci -q set openclash.config.enable=\$(cat \/etc\/config\/openclash | grep -m 1 \"option enable\" | cut -d: -f2 | awk '{ print \$3}' | cut -d \"'\" -f 2)/g" package/emortal/luci-app-openclash/root/etc/uci-defaults/luci-openclash
	sed -i "s|option command '.*'|option command '/bin/login -f root'|" feeds/packages/utils/ttyd/files/ttyd.config
	local ttyd_init=feeds/packages/utils/ttyd/files/ttyd.init
	[ -f "$ttyd_init" ] && sed -i 's|\${interface:+-i \$interface} ||' "$ttyd_init"
}

zerotier_source_supports_feed_patches() {
	local zt_feed="$1" archive="$2" work_dir source_dir patch

	work_dir=$(mktemp -d) || return 1
	if ! tar -xzf "$archive" -C "$work_dir"; then
		rm -rf "$work_dir"
		return 1
	fi
	source_dir=$(find "$work_dir" -mindepth 1 -maxdepth 1 -type d -name 'ZeroTierOne-*' -print -quit)
	if [ -z "$source_dir" ]; then
		rm -rf "$work_dir"
		return 1
	fi
	for patch in "$zt_feed"/patches/*.patch; do
		[ -f "$patch" ] || continue
		if ! patch --batch --dry-run -d "$source_dir" -p1 < "$patch" >/dev/null; then
			echo "⚠️ zerotier: $(basename "$patch") is incompatible with the requested source"
			rm -rf "$work_dir"
			return 1
		fi
	done
	rm -rf "$work_dir"
	return 0
}

configure_zerotier() {
	# 默认使用最新版本，同时允许设备固定 ZEROTIER_VERSION。
	local zt_feed=feeds/packages/net/zerotier zt_current zt_target zt_hash zt_conf zt_tmp zt_archive
	[ -f "$zt_feed/Makefile" ] || return 0
	zt_current="$(sed -n 's/^PKG_VERSION:=//p' "$zt_feed/Makefile" | head -1)"
	zt_target="${ZEROTIER_VERSION:-latest}"
	if [ "$zt_target" = "latest" ]; then
		zt_target="$(curl --fail --retry 3 --retry-delay 2 --silent --show-error https://api.github.com/repos/zerotier/ZeroTierOne/releases/latest | python3 -c 'import json, sys; print(json.load(sys.stdin).get("tag_name", "").lstrip("v"))' 2>/dev/null)"
	fi
	if [[ ! "$zt_target" =~ ^[0-9]+(\.[0-9]+){2}([.-][0-9A-Za-z._-]+)?$ ]]; then
		echo "WARNING: zerotier release lookup returned an invalid version; keeping $zt_current"
		zt_target="$zt_current"
	fi
	if [ "$zt_current" != "$zt_target" ]; then
		zt_tmp=$(mktemp -d) || return 1
		zt_archive="$zt_tmp/zerotier-$zt_target.tar.gz"
		if curl --fail --retry 3 --retry-delay 2 --silent --show-error -L \
			"https://codeload.github.com/zerotier/ZeroTierOne/tar.gz/$zt_target" -o "$zt_archive"; then
			zt_hash=$(sha256sum "$zt_archive" | awk '{print $1}')
		else
			zt_hash=""
		fi
		case "$zt_hash" in ''|*[!0-9a-f]*) zt_hash="" ;; esac
		if [ "${#zt_hash}" -eq 64 ] && zerotier_source_supports_feed_patches "$zt_feed" "$zt_archive"; then
			sed -i "s/^PKG_VERSION:=$zt_current/PKG_VERSION:=$zt_target/" "$zt_feed/Makefile"
			sed -i "s/^PKG_HASH:=.*/PKG_HASH:=$zt_hash/" "$zt_feed/Makefile"
			echo "✅ zerotier updated $zt_current → $zt_target (hash: ${zt_hash:0:12}...)"
		else
			echo "⚠️ zerotier source or feed patches are incompatible; keeping feed version $zt_current"
		fi
		rm -rf "$zt_tmp"
	fi
	zt_conf="$zt_feed/files/etc/config/zerotier"
	if [ -f "$zt_conf" ]; then
		sed -i "s/#option config_path '.*'/option config_path '\/etc\/zerotier'/" "$zt_conf"
		echo "✅ zerotier config_path enabled for data persistence"
	fi
}

configure_custom_packages() {
	local pkg_dir pkg_name link

	# feed 安装会创建软件包链接；同名时必须由仓库自有实现优先。
	for pkg_dir in package/emortal/*/; do
		[ -d "$pkg_dir" ] || continue
		pkg_name="$(basename "$pkg_dir")"
		find package/feeds -maxdepth 3 -type l -name "$pkg_name" 2>/dev/null | while IFS= read -r link; do
			rm -f "$link"
			echo "✅ Removed conflicting feeds symlink: $link"
		done
	done

	# PikuZheng SmartDNS 服务替换上游软件包；上游元数据也声明了
	# luci-app-smartdns，因此只保留一份当前 LuCI UI。
	if [ -d package/emortal/smartdns ]; then
		if [ ! -d feeds/luci/applications/luci-app-smartdns ]; then
			echo "❌ luci-app-smartdns source is missing from the LuCI feed"
			return 1
		fi
		rm -rf package/emortal/luci-app-smartdns
		cp -a feeds/luci/applications/luci-app-smartdns package/emortal/luci-app-smartdns
		sed -i 's|include ../../luci.mk|include $(TOPDIR)/feeds/luci/luci.mk|' \
			package/emortal/luci-app-smartdns/Makefile
		rm -f package/feeds/luci/luci-app-smartdns
		echo "✅ luci-app-smartdns: paired with custom SmartDNS"
	fi
}

validate_device_overlay() {
	local frpc_config=files/etc/config/frpc

	[ -f "$frpc_config" ] || return 0
	if grep -Eq "^[[:space:]]*option[[:space:]]+proxy_protocol_version[[:space:]]+['\"]?disable" "$frpc_config"; then
		echo "❌ FRPC 0.69 does not support proxy_protocol_version 'disable'"
		return 1
	fi
	echo "✅ Device overlay validation passed"
}

write_custom_build_provenance() {
	local file=files/etc/build-provenance component artifact zt_feed=feeds/packages/net/zerotier

	mkdir -p "$(dirname "$file")"
	{
		echo "format=1"
		echo "openwrt.commit=$(git rev-parse HEAD)"
		echo "openwrt.branch=${OPENWRT_REF:-$(git rev-parse --abbrev-ref HEAD)}"
		[ -f "$zt_feed/Makefile" ] && echo "zerotier.version=$(sed -n 's/^PKG_VERSION:=//p' "$zt_feed/Makefile" | head -1)"
		for component in feeds/packages feeds/luci feeds/routing feeds/telephony feeds/video \
			package/emortal/luci-app-openclash package/emortal/luci-theme-argon package/emortal/smartdns; do
			[ -d "$component/.git" ] && echo "${component//\//.}.commit=$(git -C "$component" rev-parse HEAD)"
		done
		for artifact in \
			package/emortal/luci-app-openclash/root/etc/openclash/core/clash_meta \
			package/emortal/luci-app-openclash/root/etc/openclash/GeoIP.dat \
			package/emortal/luci-app-openclash/root/etc/openclash/ASN.mmdb \
			package/emortal/luci-app-openclash/root/etc/openclash/Model.bin; do
			[ -f "$artifact" ] && echo "${artifact##*/}.sha256=$(sha256sum "$artifact" | awk '{print $1}')"
		done
	} > "$file"
	chmod 0644 "$file"
}

sed -i 's/192.168.1.1/192.168.2.1/g' package/base-files/files/bin/config_generate
validate_device_overlay || exit 1
[ -f files/etc/smartdns/ui/smartdns.db ] && chmod 600 files/etc/smartdns/ui/smartdns.db
configure_dropbear
deploy_base_rootfs_tools
configure_firstboot_defaults
configure_application_defaults
configure_zerotier || exit 1
configure_custom_packages || exit 1

# =============================================================================
# OpenClash 默认配置
# =============================================================================

echo '

config openclash 'config'
	option proxy_port '7892'
	option tproxy_port '7895'
	option mixed_port '7893'
	option socks_port '7891'
	option http_port '7890'
	option dns_port '7874'
	option update '0'
	option auto_update '0'
	option auto_update_time '0'
	option cn_port '9090'
	option ipv6_enable '0'
	option ipv6_dns '0'
	option release_branch 'dev'
	option en_mode 'redir-host'
	option log_level 'silent'
	option proxy_mode 'rule'
	option lan_ac_mode '0'
	option operation_mode 'redir-host'
	option small_flash_memory '0'
	option interface_name '0'
	option log_size '1024'
	option tolerance '0'
	option store_fakeip '1'
	option custom_fallback_filter '0'
	option append_wan_dns '0'
	option stream_auto_select '0'
	option chnr6_custom_url 'https://raw.githubusercontent.com/gaoyifan/china-operator-ip/refs/heads/ip-lists/china6.txt'
	option enable_udp_proxy '1'
	option disable_udp_quic '1'
	option enable_rule_proxy '1'
	option common_ports '21 22 23 53 80 123 143 194 443 465 587 853 993 995 998 2052 2053 2082 2083 2086 2095 2096 5222 5228 5229 5230 8080 8443 8880 8888 8889'
	option china_ip_route '1'
	option intranet_allowed '1'
	option enable_redirect_dns '1'
	option enable_custom_dns '1'
	option disable_masq_cache '1'
	option enable_custom_clash_rules '1'
	option chnr_auto_update '1'
	option chnr_update_week_time '*'
	option chnr_update_day_time '4'
	option chnr_custom_url 'https://raw.githubusercontent.com/gaoyifan/china-operator-ip/refs/heads/ip-lists/china.txt'
	option auto_restart '0'
	option auto_restart_week_time '1'
	option auto_restart_day_time '0'
	option config_path '/etc/openclash/config/config.yaml'
	option core_type 'Smart'
	option bypass_gateway_compatible '0'
	option github_address_mod '0'
	option delay_start '0'
	option filter_aaaa_dns '0'
	option router_self_proxy '1'
	option enable_meta_sniffer '1'
	option enable_meta_sniffer_custom '0'
	option enable_tcp_concurrent '1'
	option geodata_loader 'standard'
	option geosite_auto_update '1'
	option geosite_update_week_time '*'
	option geosite_update_day_time '6'
	option geosite_custom_url 'https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat'
	option enable_geoip_dat '1'
	option geoip_auto_update '1'
	option geoip_update_week_time '*'
	option geoip_update_day_time '5'
	option geoip_custom_url 'https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat'
	option geo_auto_update '1'
	option geo_update_week_time '*'
	option geo_update_day_time '3'
	option geo_custom_url 'https://github.com/alecthw/mmdb_china_ip_list/releases/latest/download/Country-lite.mmdb'
	option dashboard_forward_ssl '0'
	option dashboard_type 'Smart'
	option yacd_type 'Meta'
	option append_default_dns '0'
	option enable_meta_sniffer_pure_ip '0'
	option urltest_address_mod '0'
	option find_process_mode 'always'
	option dnsmasq_noresolv '0'
	option default_resolvfile '/tmp/resolv.conf.d/resolv.conf.auto'
	option dnsmasq_resolvfile '/tmp/resolv.conf.d/resolv.conf.auto'
	option urltest_interval_mod '0'
	option enable_unified_delay '1'
	option skip_proxy_address '1'
	option lan_interface_name '0'
	list intranet_allowed_wan_name 'pppoe-wan'
	option core_version 'linux-amd64-v3'
	option disable_quic_go_gso '1'
	option dashboard_password 'openwrt'
	option geoasn_auto_update '1'
	option geoasn_update_week_time '*'
	option geoasn_update_day_time '1'
	option geoasn_custom_url 'https://github.com/xishang0128/geoip/releases/latest/download/GeoLite2-ASN.mmdb'
	option enable '1'
	option restart '0'
	option enable_respect_rules '0'
	option custom_host '1'
	option enable_custom_domain_dns_server '1'
	option custom_name_policy '0'
	option custom_domain_dns_server '127.0.0.1#6053'
	option smart_enable '1'
	option auto_smart_switch '1'
	option smart_collect '1'
	option smart_collect_size '100'
	option smart_collect_rate '1'
	option smart_prefer_asn '1'
	option smart_tolerance '0'
	option smart_enable_lgbm '1'
	option custom_proxy_server_policy '0'
	option global_ua '0'
	option lgbm_auto_update '1'
	option lgbm_update_interval '12'
	option lgbm_custom_url 'https://github.com/vernesong/mihomo/releases/download/LightGBM-Model/Model-large.bin'
	option redirect_dns '1'
	option dnsmasq_cachesize '0'
	option cachesize_dns '1'

config dns_servers
	option ip '119.29.29.29'
	option type 'udp'
	option interface 'Disable'
	option direct_nameserver '0'
	option node_resolve '0'
	option enabled '0'
	option group 'default'

config dns_servers
	option ip '223.5.5.5'
	option type 'udp'
	option interface 'Disable'
	option direct_nameserver '0'
	option node_resolve '0'
	option enabled '0'
	option group 'default'

config dns_servers
	option ip '119.29.29.29'
	option type 'tcp'
	option interface 'Disable'
	option direct_nameserver '0'
	option node_resolve '0'
	option enabled '0'
	option group 'default'

config dns_servers
	option ip '223.5.5.5'
	option type 'tcp'
	option interface 'Disable'
	option direct_nameserver '0'
	option node_resolve '0'
	option enabled '0'
	option group 'default'

config dns_servers
	option ip '8.8.8.8'
	option type 'udp'
	option interface 'Disable'
	option direct_nameserver '0'
	option node_resolve '0'
	option enabled '0'
	option group 'default'

config dns_servers
	option ip '1.1.1.1'
	option type 'udp'
	option interface 'Disable'
	option direct_nameserver '0'
	option node_resolve '0'
	option enabled '0'
	option group 'default'

config dns_servers
	option ip '1.1.1.1'
	option type 'tcp'
	option interface 'Disable'
	option direct_nameserver '0'
	option node_resolve '0'
	option enabled '0'
	option group 'default'

config dns_servers
	option ip '8.8.8.8'
	option type 'tcp'
	option interface 'Disable'
	option direct_nameserver '0'
	option node_resolve '0'
	option enabled '0'
	option group 'default'

config dns_servers
	option ip 'dot.pub'
	option type 'tls'
	option interface 'Disable'
	option specific_group 'Disable'
	option direct_nameserver '0'
	option node_resolve '0'
	option enabled '0'
	option group 'nameserver'

config dns_servers
	option ip 'dns.alidns.com'
	option type 'tls'
	option interface 'Disable'
	option specific_group 'Disable'
	option direct_nameserver '0'
	option node_resolve '0'
	option enabled '0'
	option group 'nameserver'

config dns_servers
	option ip 'doh.pub/dns-query'
	option type 'https'
	option interface 'Disable'
	option specific_group 'Disable'
	option direct_nameserver '0'
	option skip_cert_verify '0'
	option ecs_override '0'
	option node_resolve '0'
	option http3 '1'
	option enabled '0'
	option group 'nameserver'

config dns_servers
	option ip 'dns.alidns.com/dns-query'
	option type 'https'
	option interface 'Disable'
	option specific_group 'Disable'
	option direct_nameserver '0'
	option skip_cert_verify '0'
	option ecs_override '0'
	option node_resolve '0'
	option http3 '1'
	option enabled '0'
	option group 'nameserver'

config dns_servers
	option ip 'dns.alidns.com'
	option type 'quic'
	option interface 'Disable'
	option specific_group 'Disable'
	option direct_nameserver '0'
	option node_resolve '0'
	option enabled '0'
	option group 'nameserver'

config dns_servers
	option ip '127.0.0.1'
	option port '6053'
	option type 'tcp'
	option interface 'Disable'
	option specific_group 'Disable'
	option node_resolve '0'
	option enabled '1'
	option group 'nameserver'

config dns_servers
	option ip 'cloudflare-dns.com'
	option type 'tls'
	option interface 'Disable'
	option specific_group 'Disable'
	option direct_nameserver '0'
	option node_resolve '0'
	option enabled '0'
	option group 'fallback'

config dns_servers
	option ip 'dns.google'
	option type 'tls'
	option interface 'Disable'
	option specific_group 'Disable'
	option direct_nameserver '0'
	option node_resolve '0'
	option enabled '0'
	option group 'fallback'

config dns_servers
	option ip 'cloudflare-dns.com/dns-query'
	option type 'https'
	option interface 'Disable'
	option specific_group 'Disable'
	option direct_nameserver '0'
	option skip_cert_verify '0'
	option ecs_override '0'
	option node_resolve '0'
	option http3 '1'
	option enabled '0'
	option group 'fallback'

config dns_servers
	option ip 'dns.google/dns-query'
	option type 'https'
	option interface 'Disable'
	option specific_group 'Disable'
	option direct_nameserver '0'
	option skip_cert_verify '0'
	option ecs_override '0'
	option node_resolve '0'
	option http3 '1'
	option enabled '0'
	option group 'fallback'

config dns_servers
	option ip '127.0.0.1'
	option port '7053'
	option type 'tcp'
	option interface 'Disable'
	option specific_group 'Disable'
	option node_resolve '0'
	option enabled '0'
	option group 'fallback'

config groups
	option name 'Proxy'
	option type 'select'
	option enabled '1'
	option config 'config.yaml'
	list other_group 'AutoTest'
	list other_group 'Fallback'

config groups
	option name 'Domestic'
	option type 'select'
	option enabled '1'
	option config 'config.yaml'
	list other_group 'DIRECT'
	list other_group 'Proxy'

config groups
	option name 'Streaming'
	option type 'select'
	option enabled '1'
	option config 'config.yaml'
	list other_group 'AutoTest'
	list other_group 'Fallback'

config groups
	option name 'StreamingSE'
	option type 'select'
	option enabled '1'
	option config 'config.yaml'
	list other_group 'DIRECT'
	list other_group 'Streaming'

config groups
	option name 'Fallback'
	option type 'fallback'
	option enabled '1'
	option disable_udp 'false'
	option test_url 'http://cp.cloudflare.com/generate_204'
	option test_interval '10'
	option other_parameters '    lazy: true
    timeout: 5000
    max-failed-times: 3'
	option config 'config.yaml'

config groups
	option name 'AutoTest'
	option type 'smart'
	option enabled '1'
	option disable_udp 'false'
	option test_url 'http://cp.cloudflare.com/generate_204'
	option test_interval '10'
	option other_parameters '    lazy: true
    timeout: 5000
    max-failed-times: 3'
	option config 'config.yaml'

config groups
	option name 'Guard'
	option type 'select'
	option enabled '1'
	option config 'config.yaml'
	list other_group 'REJECT'
	list other_group 'DIRECT'

config groups
	option name 'Apple'
	option type 'select'
	option enabled '1'
	option config 'config.yaml'
	list other_group 'Domestic'
	list other_group 'Proxy'

config groups
	option name 'OpenAI'
	option type 'select'
	option enabled '1'
	option config 'config.yaml'
	list other_group 'Proxy'
	list other_group 'Domestic'

config groups
	option name 'Telegram'
	option type 'select'
	option enabled '1'
	option config 'config.yaml'
	list other_group 'Streaming'
	list other_group 'StreamingSE'

config groups
	option name 'Netflix'
	option type 'select'
	option enabled '1'
	option config 'config.yaml'
	list other_group 'Streaming'
	list other_group 'StreamingSE'

config groups
	option name 'Disney+'
	option type 'select'
	option enabled '1'
	option config 'config.yaml'
	list other_group 'Streaming'
	list other_group 'StreamingSE'

config groups
	option name 'YouTube'
	option type 'select'
	option enabled '1'
	option config 'config.yaml'
	list other_group 'Streaming'
	list other_group 'StreamingSE'

config groups
	option name 'TikTok'
	option type 'select'
	option enabled '1'
	option config 'config.yaml'
	list other_group 'Streaming'
	list other_group 'StreamingSE'

config groups
	option name 'Spotify'
	option type 'select'
	option enabled '1'
	option config 'config.yaml'
	list other_group 'Streaming'
	list other_group 'StreamingSE'

config groups
	option name 'Gamer'
	option type 'select'
	option enabled '1'
	option config 'config.yaml'
	list other_group 'Domestic'
	list other_group 'Proxy'

config groups
	option name 'Microsoft'
	option type 'select'
	option enabled '1'
	option config 'config.yaml'
	list other_group 'Domestic'
	list other_group 'Proxy'

config groups
	option name 'GlobalMedia'
	option type 'select'
	option enabled '1'
	option config 'config.yaml'
	list other_group 'Streaming'
	list other_group 'StreamingSE'

config config_overwrite
	option name 'rabbit.yaml'
	option type 'file'
	option enable '1'
	option order '1'
	list config 'all'

' >package/emortal/luci-app-openclash/root/etc/config/openclash

# OpenClash 0.47.x 不再消费 UCI rule_providers；Rabbit-Spec 规则集统一走覆写模块。
mkdir -p package/emortal/luci-app-openclash/root/etc/openclash/overwrite
cp "$GITHUB_WORKSPACE/scripts/openclash-rabbit-overwrite.yaml" \
	package/emortal/luci-app-openclash/root/etc/openclash/overwrite/rabbit.yaml
chmod 0644 package/emortal/luci-app-openclash/root/etc/openclash/overwrite/rabbit.yaml

# =============================================================================
# OpenClash 内核与规则数据
# =============================================================================
mkdir -p package/emortal/luci-app-openclash/root/etc/openclash/core
if ${CLASH_META_REPOS_VERNESONG}; then
	CLASH_CORE_TMP=$(mktemp -d)
	if download_file "https://github.com/vernesong/OpenClash/raw/core/dev/smart/clash-linux-${CPU_MODEL}.tar.gz" "$CLASH_CORE_TMP/core.tar.gz" && \
		tar -xzf "$CLASH_CORE_TMP/core.tar.gz" -C "$CLASH_CORE_TMP" && [ -f "$CLASH_CORE_TMP/clash" ]; then
		install -m 0755 "$CLASH_CORE_TMP/clash" package/emortal/luci-app-openclash/root/etc/openclash/core/clash_meta
	else
		echo "⚠️ OpenClash core source unavailable; falling back to official Mihomo"
		install_mihomo_latest "$CLASH_CORE_TMP" || { echo "❌ Mihomo fallback failed"; exit 1; }
	fi
	rm -rf "$CLASH_CORE_TMP"
else
	CLASH_CORE_TMP=$(mktemp -d)
	install_mihomo_latest "$CLASH_CORE_TMP" || { echo "❌ Mihomo core download failed"; exit 1; }
	rm -rf "$CLASH_CORE_TMP"
fi
download_required "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat" package/emortal/luci-app-openclash/root/etc/openclash/GeoIP.dat "GeoIP data"
download_required "https://github.com/xishang0128/geoip/releases/latest/download/GeoLite2-ASN.mmdb" package/emortal/luci-app-openclash/root/etc/openclash/ASN.mmdb "ASN data"
download_required "https://github.com/vernesong/mihomo/releases/download/LightGBM-Model/Model-large.bin" package/emortal/luci-app-openclash/root/etc/openclash/Model.bin "Mihomo model"

# =============================================================================
# SmartDNS 默认配置
# =============================================================================
mkdir -p files/etc/config
echo '

config smartdns
	option server_name 'smartdns'
	option ui '1'
	option ui_data_dir '/etc/smartdns/ui'
	option port '6053'
	option ipv6_server '0'
	option dualstack_ip_selection '0'
	option prefetch_domain '1'
	option serve_expired '1'
	option seconddns_port '7053'
	option seconddns_no_rule_addr '0'
	option seconddns_no_rule_nameserver '0'
	option seconddns_no_rule_ipset '0'
	option seconddns_no_rule_soa '0'
	option coredump '0'
	option enabled '1'
	option seconddns_enabled '1'
	option seconddns_no_dualstack_selection '1'
	option force_aaaa_soa '1'
	option seconddns_server_group 'foreign'
	option tcp_server '1'
	option seconddns_tcp_server '1'
	option seconddns_no_cache '1'
	option seconddns_no_speed_check '1'
	option auto_set_dnsmasq '0'
	option speed_check_mode 'ping,tcp:80,tcp:443'
	option response_mode 'first-ping'
	option bind_device '1'
	option cache_persist '1'
	option resolve_local_hostnames '1'
	option force_https_soa '1'
	option rr_ttl_min '600'
	option seconddns_force_aaaa_soa '1'
	option enable_auto_update '1'
	option proxy_server 'socks5://127.0.0.1:7893'
	list conf_files 'anti-ad.conf'

config server
	option ip '119.29.29.29'
	option type 'udp'
	option enabled '0'

config server
	option ip '223.5.5.5'
	option type 'udp'
	option enabled '0'

config server
	option ip '119.29.29.29'
	option type 'tcp'
	option enabled '0'

config server
	option ip '223.5.5.5'
	option type 'tcp'
	option enabled '0'

config server
	option ip '120.53.53.53'
	option type 'tls'
	option exclude_default_group '0'
	option no_check_certificate '0'
	option blacklist_ip '0'
	option host_name 'dot.pub'
	option enabled '0'

config server
	option ip '223.5.5.5'
	option type 'tls'
	option exclude_default_group '0'
	option no_check_certificate '0'
	option blacklist_ip '0'
	option host_name 'dns.alidns.com'
	option enabled '0'

config server
	option ip '120.53.53.53/dns-query'
	option type 'https'
	option exclude_default_group '0'
	option no_check_certificate '0'
	option blacklist_ip '0'
	option host_name 'doh.pub'
	option http_host 'doh.pub'
	option enabled '1'

config server
	option ip '223.5.5.5/dns-query'
	option type 'https'
	option exclude_default_group '0'
	option no_check_certificate '0'
	option blacklist_ip '0'
	option host_name 'dns.alidns.com'
	option http_host 'dns.alidns.com'
	option enabled '1'

config server
	option ip '8.8.8.8'
	option type 'udp'
	option server_group 'foreign'
	option exclude_default_group '1'
	option blacklist_ip '0'
	option enabled '0'

config server
	option ip '1.1.1.1'
	option type 'udp'
	option server_group 'foreign'
	option exclude_default_group '1'
	option blacklist_ip '0'
	option enabled '0'

config server
	option ip '8.8.8.8'
	option type 'tcp'
	option server_group 'foreign'
	option exclude_default_group '1'
	option blacklist_ip '0'
	option enabled '0'

config server
	option ip '1.1.1.1'
	option type 'tcp'
	option server_group 'foreign'
	option exclude_default_group '1'
	option blacklist_ip '0'
	option enabled '0'

config server
	option ip '8.8.8.8'
	option type 'tls'
	option server_group 'foreign'
	option exclude_default_group '1'
	option no_check_certificate '0'
	option blacklist_ip '0'
	option host_name 'dns.google'
	option enabled '0'

config server
	option ip '1.1.1.1'
	option type 'tls'
	option server_group 'foreign'
	option exclude_default_group '1'
	option no_check_certificate '0'
	option blacklist_ip '0'
	option host_name 'cloudflare-dns.com'
	option enabled '0'

config server
	option ip '1.1.1.1/dns-query'
	option type 'https'
	option server_group 'foreign'
	option exclude_default_group '1'
	option no_check_certificate '0'
	option blacklist_ip '0'
	option host_name 'cloudflare-dns.com'
	option http_host 'cloudflare-dns.com'
	option enabled '1'

config server
	option ip '8.8.8.8/dns-query'
	option type 'https'
	option server_group 'foreign'
	option exclude_default_group '1'
	option no_check_certificate '0'
	option blacklist_ip '0'
	option host_name 'dns.google'
	option http_host 'dns.google'
	option enabled '1'

config domain-rule
	option no_speed_check '0'
	option force_aaaa_soa '0'

config download-file
	option type 'config'
	option name 'anti-ad.conf'
	option url 'https://raw.githubusercontent.com/privacy-protection-tools/anti-AD/master/anti-ad-smartdns.conf'

config client-rule

config ip-rule


' >files/etc/config/smartdns

# =============================================================================
# 构建元数据与设备配置
# =============================================================================
FW_DATE=$(date +%Y%m%d)
FW_HASH=$(git -c safe.directory="$GITHUB_WORKSPACE" -C "$GITHUB_WORKSPACE" rev-parse --short HEAD 2>/dev/null || echo "dev")
if ! git -c safe.directory="$GITHUB_WORKSPACE" -C "$GITHUB_WORKSPACE" diff --quiet --ignore-submodules --; then
	FW_HASH="${FW_HASH}-dirty"
fi
FW_DEVICE=$(grep '^RELEASE_NAME=' "$GITHUB_WORKSPACE/openwrt-device.conf" 2>/dev/null | cut -d= -f2 | tr -d '"')
FW_DEVICE=${FW_DEVICE:-generic}
cat > package/base-files/files/etc/firmware_version <<FWEOF
VERSION=${FW_DATE}-${FW_HASH}
DEVICE=${FW_DEVICE}
BUILD_DATE=$(date -Iseconds)
FWEOF
echo "✅ firmware_version: ${FW_DATE}-${FW_HASH} (${FW_DEVICE})"

if [ -f "$GITHUB_WORKSPACE/openwrt-device.conf" ]; then
	cp "$GITHUB_WORKSPACE/openwrt-device.conf" package/base-files/files/etc/openwrt-device.conf
	echo "✅ openwrt-device.conf → /etc/"
fi

# UPnP friendly_name 由设备 files/etc/config/upnpd 维护。
write_custom_build_provenance
