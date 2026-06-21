#!/bin/bash
#
# Copyright (c) 2019-2020 P3TERX <https://p3terx.com>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#
# https://github.com/P3TERX/Actions-OpenWrt
# File name: diy-part2.sh
# Description: OpenWrt DIY script part 2 (After Update feeds)
#

# Modify default IP
sed -i 's/192.168.1.1/192.168.2.1/g' package/base-files/files/bin/config_generate

LUCI_BRANCH=master
Arch="amd64"
CPU_MODEL="${Arch}-v3"
CLASH_META_REPOS_VERNESONG=${CLASH_META_REPOS_VERNESONG:-true}

# ============================================================
# Dropbear: remove DirectInterface 'lan' restriction (SSH on all interfaces)
# ============================================================
# Remove DirectInterface restriction AND deduplicate option enable
# (source file has 2x option enable '1'; keep only the first)
sed -i \
  -e '/option _direct/d' \
  -e '/option DirectInterface/d' \
  -e '0,/^[[:space:]]*option enable '\''1'\''$/b' \
  -e '/^[[:space:]]*option enable '\''1'\''$/d' \
  package/network/services/dropbear/files/dropbear.config

rm -rf feeds/luci/themes/luci-theme-argon
git clone --depth 1 -b $LUCI_BRANCH https://github.com/jerrykuku/luci-theme-argon.git feeds/luci/themes/luci-theme-argon
sed -i "s/\$(TOPDIR)\/luci.mk/\$(TOPDIR)\/feeds\/luci\/luci.mk/g" feeds/luci/themes/luci-theme-argon/Makefile


rm -rf feeds/packages/net/smartdns/conf
mkdir -p feeds/packages/net/smartdns/conf
# SmartDNS conf: smartdns.conf generated locally, custom.conf fetched via curl
cat > feeds/packages/net/smartdns/conf/smartdns.conf << 'SMARTDNS_EOF'
# SmartDNS default configuration
SMARTDNS_EOF
sed -i 's#PKG_BUILD_DIR)/package/openwrt/custom.conf#CURDIR)/conf/custom.conf#g' feeds/packages/net/smartdns/Makefile
sed -i 's#PKG_BUILD_DIR)/package/openwrt/files/etc/config/smartdns#CURDIR)/conf/smartdns.conf#g' feeds/packages/net/smartdns/Makefile
for script in check_smartdns_connect.sh check_openclash_connect.sh check_wan_connect.sh \
              reset_get_img.sh reset_latest.sh reset_offline.sh reset_upload.sh; do
  cp "$GITHUB_WORKSPACE/scripts/$script" package/base-files/files/etc/
  chmod +x "package/base-files/files/etc/$script"
done

for cron_script in check_smartdns_connect.sh check_openclash_connect.sh check_wan_connect.sh; do
  sed -i '/exit 0/i\if ! grep -q "/etc/'"$cron_script"'" /etc/crontabs/root 2>/dev/null; then echo "#*/5 * * * * /etc/'"$cron_script"'" >> /etc/crontabs/root; fi' package/emortal/default-settings/files/99-default-settings
done

sed -i '/commit luci/i\set luci.main.mediaurlbase="/luci-static/argon"' package/emortal/default-settings/files/99-default-settings

# Software flow offloading + Fullcone NAT (turboacc replacement)
sed -i '/^exit 0$/i uci set firewall.@defaults[0].flow_offloading="1"' package/emortal/default-settings/files/99-default-settings
sed -i '/^exit 0$/i uci set firewall.@zone[1].fullcone="1"' package/emortal/default-settings/files/99-default-settings
sed -i '/^exit 0$/i uci commit firewall' package/emortal/default-settings/files/99-default-settings

sed -i "s/uci -q set openclash.config.enable=0/uci -q set openclash.config.enable=\$(cat \/etc\/config\/openclash | grep -m 1 \"option enable\" | cut -d: -f2 | awk '{ print \$3}' | cut -d \"'\" -f 2)/g" package/emortal/luci-app-openclash/root/etc/uci-defaults/luci-openclash

sed -i "s|option command '.*'|option command '/bin/login -f root'|" feeds/packages/utils/ttyd/files/ttyd.config

# (Type-C / USB-C support removed - BIOS hides pinctrl, unlikely to work)

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
	option servers_if_update '0'
	option servers_update '0'
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
	option stream_domains_prefetch '0'
	option stream_auto_select '0'
	option chnr6_custom_url 'https://ispip.clang.cn/all_cn_ipv6.txt'
	option enable_udp_proxy '1'
	option disable_udp_quic '0'
	option enable_rule_proxy '1'
	option common_ports '21 22 23 53 80 123 143 194 443 465 587 853 993 995 998 2052 2053 2082 2083 2086 2095 2096 5222 5228 5229 5230 8080 8443 8880 8888 8889'
	option china_ip_route '1'
	option intranet_allowed '1'
	option enable_redirect_dns '1'
	option enable_custom_dns '1'
	option disable_masq_cache '1'
	option dns_advanced_setting '1'
	option rule_source '1'
	option enable_custom_clash_rules '1'
	option other_rule_auto_update '1'
	option other_rule_update_week_time '*'
	option other_rule_update_day_time '2'
	option chnr_auto_update '1'
	option chnr_update_week_time '*'
	option chnr_update_day_time '4'
	option chnr_custom_url 'https://fastly.jsdelivr.net/gh/Hackl0us/GeoIP2-CN@release/CN-ip-cidr.txt'
	option auto_restart '0'
	option auto_restart_week_time '1'
	option auto_restart_day_time '0'
	option config_path '/etc/openclash/config/config.yaml'
	option restricted_mode '0'
	option core_type 'Smart'
	option bypass_gateway_compatible '0'
	option github_address_mod '0'
	option delay_start '0'
	option filter_aaaa_dns '0'
	option router_self_proxy '1'
	option enable_meta_core '1'
	option enable_meta_sniffer '1'
	option enable_meta_sniffer_custom '0'
	option enable_tcp_concurrent '1'
	option geodata_loader 'standard'
	option geosite_auto_update '1'
	option geosite_update_week_time '*'
	option geosite_update_day_time '6'
	option geosite_custom_url 'https://fastly.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geosite.dat'
	option enable_geoip_dat '1'
	option geoip_auto_update '1'
	option geoip_update_week_time '*'
	option geoip_update_day_time '5'
	option geoip_custom_url 'https://fastly.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geoip.dat'
	option geo_auto_update '1'
	option geo_update_week_time '*'
	option geo_update_day_time '3'
	option geo_custom_url 'https://testingcf.jsdelivr.net/gh/alecthw/mmdb_china_ip_list@release/Country.mmdb'
	option dashboard_forward_ssl '0'
	option enable_http3 '1'
	option dashboard_type 'Smart'
	option yacd_type 'Meta'
	option append_default_dns '0'
	option enable_meta_sniffer_pure_ip '0'
	option cndomain_custom_url 'https://testingcf.jsdelivr.net/gh/felixonmars/dnsmasq-china-list@master/accelerated-domains.china.conf'
	option urltest_address_mod '0'
	option find_process_mode 'always'
	option dnsmasq_noresolv '0'
	option global_client_fingerprint '0'
	option create_config '0'
	option default_resolvfile '/tmp/resolv.conf.d/resolv.conf.auto'
	option dnsmasq_resolvfile '/tmp/resolv.conf.d/resolv.conf.auto'
	option urltest_interval_mod '0'
	option enable_unified_delay '1'
	option keep_alive_interval '0'
	option config_reload '1'
	option skip_proxy_address '1'
	option proxy_dns_group 'Disable'
	option lan_interface_name '0'
	list intranet_allowed_wan_name 'pppoe-wan'
	option core_version 'linux-amd64-v3'
	option disable_quic_go_gso '0'
	option dashboard_password 'openwrt'
	option geoasn_auto_update '1'
	option geoasn_update_week_time '*'
	option geoasn_update_day_time '1'
	option geoasn_custom_url 'https://fastly.jsdelivr.net/gh/xishang0128/geoip@release/GeoLite2-ASN.mmdb'
	option enable '1'
	option restart '0'
	option enable_respect_rules '0'
	option custom_host '1'
	option enable_custom_domain_dns_server '1'
	option custom_name_policy '0'
	option custom_domain_dns_server '127.0.0.1#6053'
	option smart_enable '1'
	option auto_smart_switch '1'
	option smart_strategy 'sticky-sessions'
	option smart_collect '1'
	option smart_collect_size '100'
	option smart_collect_rate '1'
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
	option config 'config.yaml'

config groups
	option name 'AutoTest'
	option type 'smart'
	option enabled '1'
	option disable_udp 'false'
	option test_url 'http://cp.cloudflare.com/generate_204'
	option test_interval '10'
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

config rule_providers
	option enabled '1'
	option config 'config.yaml'
	option name 'AntiAd'
	option type 'http'
	option format 'yaml'
	option behavior 'domain'
	option url 'https://anti-ad.net/clash.yaml'
	option interval '43200'
	option position '1'
	option group 'Guard'

config rule_providers
	option enabled '1'
	option config 'config.yaml'
	option name 'RejectDomainset'
	option type 'http'
	option format 'text'
	option behavior 'domain'
	option url 'https://ruleset.skk.moe/Clash/domainset/reject.txt'
	option interval '43200'
	option position '1'
	option group 'Guard'

config rule_providers
	option enabled '1'
	option config 'config.yaml'
	option name 'RejectNonIp'
	option type 'http'
	option format 'text'
	option behavior 'classical'
	option url 'https://ruleset.skk.moe/Clash/non_ip/reject.txt'
	option interval '43200'
	option position '1'
	option group 'Guard'

config rule_providers
	option enabled '1'
	option config 'config.yaml'
	option name 'Apple'
	option type 'http'
	option format 'yaml'
	option behavior 'classical'
	option url 'https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/Apple/Apple_Classical_No_Resolve.yaml'
	option interval '43200'
	option position '1'
	option group 'Apple'

config rule_providers
	option enabled '1'
	option config 'config.yaml'
	option name 'Spotify'
	option type 'http'
	option format 'yaml'
	option behavior 'classical'
	option url 'https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/Spotify/Spotify.yaml'
	option interval '43200'
	option position '1'
	option group 'Spotify'

config rule_providers
	option enabled '1'
	option config 'config.yaml'
	option name 'TikTok'
	option type 'http'
	option format 'yaml'
	option behavior 'classical'
	option url 'https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/TikTok/TikTok_No_Resolve.yaml'
	option interval '43200'
	option position '1'
	option group 'TikTok'

config rule_providers
	option enabled '1'
	option config 'config.yaml'
	option name 'Netflix'
	option type 'http'
	option format 'yaml'
	option behavior 'classical'
	option url 'https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/Netflix/Netflix_Classical_No_Resolve.yaml'
	option interval '43200'
	option position '1'
	option group 'Netflix'

config rule_providers
	option enabled '1'
	option config 'config.yaml'
	option name 'Disney+'
	option type 'http'
	option format 'yaml'
	option behavior 'classical'
	option url 'https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/Disney/Disney_No_Resolve.yaml'
	option interval '43200'
	option position '1'
	option group 'Disney+'

config rule_providers
	option enabled '1'
	option config 'config.yaml'
	option name 'YouTube'
	option type 'http'
	option format 'yaml'
	option behavior 'classical'
	option url 'https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/YouTube/YouTube_No_Resolve.yaml'
	option interval '43200'
	option position '1'
	option group 'YouTube'

config rule_providers
	option enabled '1'
	option config 'config.yaml'
	option name 'ChinaMedia'
	option type 'http'
	option format 'yaml'
	option behavior 'classical'
	option url 'https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/ChinaMedia/ChinaMedia.yaml'
	option interval '43200'
	option position '1'
	option group 'Domestic'

config rule_providers
	option enabled '1'
	option config 'config.yaml'
	option name 'GlobalMedia'
	option type 'http'
	option format 'yaml'
	option behavior 'classical'
	option url 'https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/GlobalMedia/GlobalMedia_Classical.yaml'
	option interval '43200'
	option position '1'
	option group 'GlobalMedia'

config rule_providers
	option enabled '1'
	option config 'config.yaml'
	option name 'Nintendo'
	option type 'http'
	option format 'yaml'
	option behavior 'classical'
	option url 'https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/Nintendo/Nintendo.yaml'
	option interval '43200'
	option position '1'
	option group 'Gamer'

config rule_providers
	option enabled '1'
	option config 'config.yaml'
	option name 'PlayStation'
	option type 'http'
	option format 'yaml'
	option behavior 'classical'
	option url 'https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/PlayStation/PlayStation.yaml'
	option interval '43200'
	option position '1'
	option group 'Gamer'

config rule_providers
	option enabled '1'
	option config 'config.yaml'
	option name 'Epic'
	option type 'http'
	option format 'yaml'
	option behavior 'classical'
	option url 'https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/Epic/Epic.yaml'
	option interval '43200'
	option position '1'
	option group 'Gamer'

config rule_providers
	option enabled '1'
	option config 'config.yaml'
	option name 'Xbox'
	option type 'http'
	option format 'yaml'
	option behavior 'classical'
	option url 'https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/Xbox/Xbox.yaml'
	option interval '43200'
	option position '1'
	option group 'Gamer'

config rule_providers
	option enabled '1'
	option config 'config.yaml'
	option name 'OpenAI'
	option type 'http'
	option format 'yaml'
	option behavior 'classical'
	option url 'https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/OpenAI/OpenAI_No_Resolve.yaml'
	option interval '43200'
	option position '1'
	option group 'OpenAI'

config rule_providers
	option enabled '1'
	option config 'config.yaml'
	option name 'Microsoft'
	option type 'http'
	option format 'yaml'
	option behavior 'classical'
	option url 'https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/Microsoft/Microsoft_No_Resolve.yaml'
	option interval '43200'
	option position '1'
	option group 'Microsoft'

config rule_providers
	option enabled '1'
	option config 'config.yaml'
	option name 'Proxy'
	option type 'http'
	option format 'yaml'
	option behavior 'classical'
	option url 'https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/Proxy/Proxy_Classical_No_Resolve.yaml'
	option interval '43200'
	option position '1'
	option group 'Proxy'

config rule_providers
	option enabled '1'
	option config 'config.yaml'
	option name 'China'
	option type 'http'
	option format 'yaml'
	option behavior 'classical'
	option url 'https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/refs/heads/master/rule/Clash/ChinaMax/ChinaMax_Classical.yaml'
	option interval '43200'
	option position '1'
	option group 'Domestic'

config rule_providers
	option enabled '1'
	option config 'config.yaml'
	option name 'LAN'
	option type 'http'
	option format 'yaml'
	option behavior 'classical'
	option url 'https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/Lan/Lan.yaml'
	option interval '43200'
	option position '1'
	option group 'DIRECT'


' >package/emortal/luci-app-openclash/root/etc/config/openclash
mkdir -p package/emortal/luci-app-openclash/root/etc/openclash/core
if ${CLASH_META_REPOS_VERNESONG}; then
  curl --retry 5 -L https://github.com/vernesong/OpenClash/raw/core/dev/smart/clash-linux-${CPU_MODEL}.tar.gz | tar zxf -
  mv clash package/emortal/luci-app-openclash/root/etc/openclash/core/clash_meta
else
  CLASH_META_VERSION="$(curl --retry 5 -L https://api.github.com/repos/MetaCubeX/mihomo/releases/latest 2>/dev/null|grep -E 'tag_name' |grep -E 'v[0-9.]+' -o 2>/dev/null)"
  curl --retry 5 -L https://github.com/MetaCubeX/mihomo/releases/download/${CLASH_META_VERSION}/mihomo-linux-amd64-${CLASH_META_VERSION}.gz -O
  gzip -d mihomo-linux-amd64-${CLASH_META_VERSION}.gz
  mv mihomo-linux-amd64-${CLASH_META_VERSION} package/emortal/luci-app-openclash/root/etc/openclash/core/clash_meta
fi
chmod +x package/emortal/luci-app-openclash/root/etc/openclash/core/clash_meta
curl --retry 5 -L https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat -o package/emortal/luci-app-openclash/root/etc/openclash/GeoIP.dat
curl --retry 5 -L https://github.com/vernesong/mihomo/releases/download/LightGBM-Model/Model-large.bin -o package/emortal/luci-app-openclash/root/etc/openclash/Model.bin
echo '

config smartdns
	option server_name 'smartdns'
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


' >feeds/packages/net/smartdns/conf/smartdns.conf

curl --retry 5 -L https://github.com/pymumu/smartdns/raw/master/package/openwrt/custom.conf -o feeds/packages/net/smartdns/conf/custom.conf

# ============================================================
# firmware_version (dynamic, generated at build time)
# ============================================================
FW_DATE=$(date +%Y%m%d)
FW_HASH=$(git -C "$GITHUB_WORKSPACE" rev-parse --short HEAD 2>/dev/null || echo "dev")
FW_DEVICE=$(grep '^RELEASE_NAME=' "$GITHUB_WORKSPACE/openwrt-device.conf" 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "unknown")
cat > package/base-files/files/etc/firmware_version <<FWEOF
VERSION=${FW_DATE}-${FW_HASH}
DEVICE=${FW_DEVICE}
BUILD_DATE=$(date -Iseconds)
FWEOF
echo "✅ firmware_version: ${FW_DATE}-${FW_HASH} (${FW_DEVICE})"

cp "$GITHUB_WORKSPACE/openwrt-device.conf" package/base-files/files/etc/openwrt-device.conf
echo "✅ openwrt-device.conf → /etc/"

# ============================================================
# r8152 USB NIC: rc.local — boot-time TSO/GSO/GRO disable + USB power mgmt
# Strategy: Keep autoneg ON (stable), disable TSO/GSO/GRO only (prevents deadlock)
# NOTE: Do NOT force autoneg off — r8152 driver flapping under forced mode.
# NOTE: Do NOT ethtool -K rx/tx checksum — keep for performance.
# ============================================================
cat > package/base-files/files/etc/rc.local <<'RCLOCAL'
# Put your custom commands here that should be executed once
# the system init finished. By default this file does nothing.

# r8152 TSO/GSO/GRO: disable to prevent USB deadlock under high TX load
# Super-frames from TSO exceed USB URB limits when USB NIC is under heavy TX
for i in 1 2 3 4 5; do
  if [ -f /sys/class/net/eth2/carrier ] && [ "$(cat /sys/class/net/eth2/carrier)" = "1" ]; then
    /usr/sbin/ethtool -K eth2 tso off gso off gro off 2>/dev/null
    logger -t "r8152-fix" "TSO/GSO/GRO disabled on eth2 (attempt $i)"
    break
  fi
  sleep 1
done

# Safety net: ethtool -K is driver-level, does not require active link
/usr/sbin/ethtool -K eth2 tso off gso off gro off 2>/dev/null
logger -t "r8152-fix" "TSO/GSO/GRO disabled (safety net)"

ip link set eth2 txqueuelen 5000 2>/dev/null
echo -1 > /sys/module/usbcore/parameters/autosuspend

exit 0
RCLOCAL
echo "✅ rc.local: r8152 TSO/GSO/GRO + USB power mgmt"

# ============================================================
# r8152 USB NIC: Late-boot init script (START=99)
# Runs after ALL init scripts (firewall, network) so offload stays off
# Needed because rc.local runs too early — network/firewall restart later resets TSO/GSO
# ============================================================
mkdir -p package/base-files/files/etc/init.d
cat > package/base-files/files/etc/init.d/r8152-fix <<'INITEOF'
#!/bin/sh /etc/rc.common
# r8152-fix: Disable TSO/GSO/GRO + USB device power mgmt on r8152 NIC
# Fixes carrier flapping and USB deadlock
# Runs at START=99 after all network services are up

USE_PROCD=1
START=99

boot() {
    sleep 5
    apply_fix
}

start_service() {
    apply_fix
}

apply_fix() {
    local eth="eth2"

    [ ! -d "/sys/class/net/$eth" ] && {
        logger -t "r8152-fix" "WARNING: $eth does not exist, skipping"
        return 1
    }

    # Fix 1: Disable TSO/GSO/GRO (super-frames exceed USB URB limits)
    local tso_status
    tso_status=$(/usr/sbin/ethtool -k "$eth" 2>/dev/null | grep "tcp-segmentation-offload:" | awk "{print \$2}")
    if [ "$tso_status" = "off" ]; then
        logger -t "r8152-fix" "TSO already off, no action needed"
    else
        /usr/sbin/ethtool -K "$eth" tso off gso off gro off 2>/dev/null && \
            logger -t "r8152-fix" "TSO/GSO/GRO disabled (init.d)" || \
            logger -t "r8152-fix" "ERROR: failed to disable offload"
    fi

    ip link set "$eth" txqueuelen 5000 2>/dev/null

    # Fix 2: Disable USB device power management (prevents carrier flapping)
    local usb_root
    usb_root=$(readlink -f /sys/class/net/$eth/device 2>/dev/null)
    usb_root=$(dirname "$usb_root" 2>/dev/null)
    if [ -w "$usb_root/power/control" ]; then
        echo "on" > "$usb_root/power/control" 2>/dev/null
        echo "0" > "$usb_root/power/autosuspend_delay_ms" 2>/dev/null
        logger -t "r8152-fix" "USB device power management disabled"
    else
        logger -t "r8152-fix" "WARNING: cannot disable USB device power mgmt"
    fi
}

fix_status() {
    local eth="eth2"
    echo "=== r8152 Fix Status ==="
    if [ -d "/sys/class/net/$eth" ]; then
        echo "Interface: $eth"
        /usr/sbin/ethtool -k "$eth" 2>/dev/null | grep -E "tcp-segmentation-offload:|generic-segmentation-offload:|generic-receive-offload:"
        echo "txqueuelen: $(ip link show "$eth" | grep -o "qlen [0-9]*" | cut -d" " -f2)"
        echo "Carrier changes: $(cat /sys/class/net/eth2/carrier_changes 2>/dev/null || echo 'N/A')"
        local usb_root
        usb_root=$(readlink -f /sys/class/net/$eth/device 2>/dev/null)
        usb_root=$(dirname "$usb_root" 2>/dev/null)
        if [ -r "$usb_root/power/control" ]; then
            echo "USB device power control: $(cat "$usb_root/power/control" 2>/dev/null)"
            echo "USB device autosuspend: $(cat "$usb_root/power/autosuspend_delay_ms" 2>/dev/null)ms"
        fi
    else
        echo "Interface $eth does not exist"
    fi
    echo ""
    echo "Last 10 log entries:"
    logread | grep "r8152-fix" | tail -10
}
INITEOF
chmod +x package/base-files/files/etc/init.d/r8152-fix
echo "✅ r8152 init.d script created (START=99)"

# ============================================================
# r8152 USB NIC hotplug: disable TSO/GSO/GRO + set txqueuelen
# ============================================================
mkdir -p package/base-files/files/etc/hotplug.d/net
cat > package/base-files/files/etc/hotplug.d/net/99-r8152-offload <<'HOTPLUG'
#!/bin/sh
# Disable TSO/GSO/GRO + set txqueuelen for Realtek USB NICs
# NOTE: do NOT disable rx/tx checksum — keep for performance

[ "$ACTION" = "add" ] || exit 0

DRIVER=$(ethtool -i "$DEVICENAME" 2>/dev/null | sed -n 's/^driver: //p')
[ "$DRIVER" = "r8152" ] || exit 0

ip link set "$DEVICENAME" txqueuelen 5000 2>/dev/null
/usr/sbin/ethtool -K "$DEVICENAME" tso off gso off gro off 2>/dev/null
logger -t "r8152-fix" "txqueuelen 5000, tso/gso/gro off for $DEVICENAME"
HOTPLUG
chmod +x package/base-files/files/etc/hotplug.d/net/99-r8152-offload
echo "✅ r8152 hotplug script created (TSO/GSO/GRO)"

# ============================================================
# ============================================================
# UPnP: friendly_name is configured per-device via files/etc/config/upnpd in device repos (NUC8/ZBOX)
# ============================================================

