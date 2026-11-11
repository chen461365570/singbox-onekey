#!/usr/bin/env bash
# singbox-onekey: one-click multi-protocol proxy + HTTPS subscription
#   VLESS-Reality / Hysteria2 / TUIC v5 / Shadowsocks-2022 / VMess-WS
#   + Caddy subscription with Let's Encrypt IP certificate + BBR + swap
# Usage: bash install.sh [install|info|regen|uninstall] [options]
set -euo pipefail

SELF_URL="https://raw.githubusercontent.com/chen461365570/singbox-onekey/main/install.sh"
STATE=/etc/onekey-proxy
SB_CONF=/etc/sing-box/config.json
WWW=/var/www/onekey-sub

# ---------- defaults (override with options) ----------
SNI=www.microsoft.com
CERT_CN=bing.com
NAME=""
SWAP=8G
DOMAIN=""
P_VLESS=443 P_HY2=8443 P_TUIC=8444 P_SS=8388 P_VMESS=8080 P_SUB=2096
NO_SUB=0

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }
die()   { red "错误: $*"; exit 1; }

usage() {
cat <<'EOF'
用法: bash install.sh [命令] [选项]

命令:
  install      安装或更新（默认）。重复运行会沿用已有密钥，订阅链接不变
  info         显示订阅链接和节点链接
  regen        重新生成全部密钥和订阅链接（旧链接立即失效）
  uninstall    卸载 sing-box、Caddy 及全部配置（保留虚拟内存）

选项:
  --name 名称        节点名前缀，默认自动识别国家代码，如 JP
  --sni 域名         Reality 伪装站点，默认 www.microsoft.com
  --swap 大小        虚拟内存大小，如 2G、8G；0 表示不创建，默认 8G
  --domain 域名      订阅使用自己的域名（需已解析到本机），默认直接用 IP
  --sub-port 端口    订阅 HTTPS 端口，默认 2096
  --no-sub           不安装订阅服务（--with-sub 重新启用）
  --ports a,b,c,d,e  依次为 VLESS,Hy2,TUIC,SS,VMess 端口，默认 443,8443,8444,8388,8080
  -h, --help         显示帮助
EOF
}

# ---------- arg parsing ----------
CMD=install
if [ $# -gt 0 ] && [[ "$1" != -* ]]; then CMD=$1; shift; fi
# previous settings become the defaults; command-line options override them
# shellcheck disable=SC1091
[ -f "$STATE/settings.env" ] && . "$STATE/settings.env"
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME=$2; shift 2;;
    --sni) SNI=$2; shift 2;;
    --swap) SWAP=$2; shift 2;;
    --domain) DOMAIN=$2; shift 2;;
    --sub-port) P_SUB=$2; shift 2;;
    --no-sub) NO_SUB=1; shift;;
    --with-sub) NO_SUB=0; shift;;
    --ports) IFS=, read -r P_VLESS P_HY2 P_TUIC P_SS P_VMESS <<<"$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) die "未知参数 $1（用 --help 查看用法）";;
  esac
done

[ "$(id -u)" = 0 ] || die "请用 root 运行"

# ---------- helpers ----------
check_os() {
  command -v apt-get >/dev/null || die "目前只支持 Debian / Ubuntu"
  command -v systemctl >/dev/null || die "需要 systemd"
}

public_ip() {
  local ip
  for u in https://api.ipify.org https://ifconfig.me https://ipv4.icanhazip.com; do
    ip=$(curl -4 -fsS --max-time 6 "$u" 2>/dev/null | tr -d '[:space:]') && [ -n "$ip" ] && { echo "$ip"; return; }
  done
  hostname -I | awk '{print $1}'
}

port_owner() { { ss -lntup 2>/dev/null | grep -E "[:.]$1\b" | grep -oP 'users:\(\("\K[^"]+' | head -1; } || true; }

check_ports() {
  local p o
  for p in "$P_VLESS" "$P_HY2" "$P_TUIC" "$P_SS" "$P_VMESS"; do
    o=$(port_owner "$p")
    [ -z "$o" ] || [ "$o" = sing-box ] || die "端口 $p 已被 $o 占用，请用 --ports 换端口"
  done
}

# retry while apt/dpkg is locked (fresh VPS often runs unattended-upgrades on boot)
with_apt_lock() {
  local i err=/tmp/onekey-apt.err
  for i in $(seq 1 60); do
    if "$@" >/dev/null 2>"$err"; then return 0; fi
    if ! grep -qiE 'lock|unattended|another process' "$err"; then cat "$err" >&2; return 1; fi
    [ "$i" = 1 ] && yellow "系统正在自动更新，等待 apt 锁释放（最多 5 分钟）..."
    sleep 5
  done
  cat "$err" >&2; return 1
}

apt_install() {
  export DEBIAN_FRONTEND=noninteractive
  with_apt_lock apt-get update -qq || die "apt-get update 失败"
  with_apt_lock apt-get install -y -qq "$@" || die "安装 $* 失败"
}

setup_swap() {
  [ "$SWAP" = 0 ] && { yellow "跳过虚拟内存"; return; }
  if [ -n "$(swapon --show --noheadings)" ]; then
    green "已有虚拟内存，跳过：$(swapon --show --noheadings | awk '{print $1" "$3}' | tr '\n' ' ')"
    return
  fi
  local want_mb free_mb
  want_mb=$(numfmt --from=iec "$SWAP" 2>/dev/null) || die "--swap 格式不对，例：2G"
  want_mb=$((want_mb / 1024 / 1024))
  free_mb=$(df -m --output=avail / | tail -1)
  if [ $((free_mb - 2048)) -lt "$want_mb" ]; then
    want_mb=$((free_mb - 2048))
    [ "$want_mb" -lt 512 ] && { yellow "磁盘空间不足，跳过虚拟内存"; return; }
    yellow "磁盘空间不够 $SWAP，改为 ${want_mb}M"
  fi
  fallocate -l "${want_mb}M" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count="$want_mb" status=none
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  echo 'vm.swappiness=10' > /etc/sysctl.d/99-onekey-swap.conf
  sysctl -q -p /etc/sysctl.d/99-onekey-swap.conf
  green "虚拟内存 ${want_mb}M 已创建"
}

setup_bbr() {
  cat > /etc/sysctl.d/99-onekey-net.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=16777216
net.core.wmem_max=16777216
EOF
  sysctl -q -p /etc/sysctl.d/99-onekey-net.conf 2>/dev/null || true
}

install_singbox() {
  if ! command -v sing-box >/dev/null; then
    # official .deb from SagerNet GitHub releases
    local ver arch deb=/tmp/onekey-sing-box.deb
    arch=$(dpkg --print-architecture)
    case "$arch" in armhf) arch=armv7;; esac
    ver=$(curl -fsSL --max-time 15 https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name | sed 's/^v//')
    if [ -n "$ver" ] && [ "$ver" != null ] && \
       curl -fsSL --max-time 120 -o "$deb" "https://github.com/SagerNet/sing-box/releases/download/v$ver/sing-box_${ver}_linux_${arch}.deb"; then
      with_apt_lock dpkg -i "$deb" || die "sing-box 安装失败"
      rm -f "$deb"
    else
      curl -fsSL https://sing-box.app/install.sh | sh >/dev/null
    fi
  fi
  command -v sing-box >/dev/null || die "sing-box 安装失败"
  green "$(sing-box version | head -1)"
}

load_or_make_secrets() {
  mkdir -p "$STATE"; chmod 700 "$STATE"
  if [ -f "$STATE/secrets.env" ] && [ "${REGEN:-0}" != 1 ]; then
    local cli_name=$NAME
    # shellcheck disable=SC1091
    . "$STATE/secrets.env"; green "沿用已有密钥"
    if [ -n "$cli_name" ] && [ "$cli_name" != "$NAME" ]; then
      NAME=$cli_name; sed -i "s/^NAME=.*/NAME=$NAME/" "$STATE/secrets.env"
    fi
    return
  fi
  local kp
  UUID=$(sing-box generate uuid)
  kp=$(sing-box generate reality-keypair)
  PRIV=$(awk '/PrivateKey/{print $2}' <<<"$kp")
  PUB=$(awk '/PublicKey/{print $2}' <<<"$kp")
  SID=$(sing-box generate rand --hex 8)
  PW=$(sing-box generate rand --hex 16)
  SSKEY=$(sing-box generate rand --base64 16)
  WSPATH=/$(sing-box generate rand --hex 6)
  TOKEN=$(sing-box generate rand --hex 16)
  [ -n "$NAME" ] || NAME=$(curl -fsS --max-time 6 https://ipinfo.io/country 2>/dev/null | tr -cd 'A-Z' || true)
  [ -n "$NAME" ] || NAME=VPS
  cat > "$STATE/secrets.env" <<EOF
UUID=$UUID
PRIV=$PRIV
PUB=$PUB
SID=$SID
PW=$PW
SSKEY=$SSKEY
WSPATH=$WSPATH
TOKEN=$TOKEN
NAME=$NAME
EOF
  chmod 600 "$STATE/secrets.env"
  green "已生成新密钥"
}

save_settings() {
  cat > "$STATE/settings.env" <<EOF
SNI=$SNI
CERT_CN=$CERT_CN
DOMAIN=$DOMAIN
P_VLESS=$P_VLESS
P_HY2=$P_HY2
P_TUIC=$P_TUIC
P_SS=$P_SS
P_VMESS=$P_VMESS
P_SUB=$P_SUB
NO_SUB=$NO_SUB
EOF
}

write_singbox() {
  mkdir -p /etc/sing-box
  if [ ! -f /etc/sing-box/cert.pem ]; then
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -days 3650 \
      -subj "/CN=$CERT_CN" -keyout /etc/sing-box/key.pem -out /etc/sing-box/cert.pem 2>/dev/null
  fi
  chmod 644 /etc/sing-box/cert.pem /etc/sing-box/key.pem
  cat > "$SB_CONF" <<EOF
{
  "log": { "level": "warn", "timestamp": true },
  "inbounds": [
    { "type": "vless", "tag": "vless-reality", "listen": "::", "listen_port": $P_VLESS,
      "users": [ { "uuid": "$UUID", "flow": "xtls-rprx-vision" } ],
      "tls": { "enabled": true, "server_name": "$SNI",
        "reality": { "enabled": true, "handshake": { "server": "$SNI", "server_port": 443 },
                     "private_key": "$PRIV", "short_id": [ "$SID" ] } } },
    { "type": "hysteria2", "tag": "hy2", "listen": "::", "listen_port": $P_HY2,
      "users": [ { "password": "$PW" } ],
      "tls": { "enabled": true, "alpn": [ "h3" ],
               "certificate_path": "/etc/sing-box/cert.pem", "key_path": "/etc/sing-box/key.pem" } },
    { "type": "tuic", "tag": "tuic", "listen": "::", "listen_port": $P_TUIC,
      "users": [ { "uuid": "$UUID", "password": "$PW" } ], "congestion_control": "bbr",
      "tls": { "enabled": true, "alpn": [ "h3" ],
               "certificate_path": "/etc/sing-box/cert.pem", "key_path": "/etc/sing-box/key.pem" } },
    { "type": "shadowsocks", "tag": "ss", "listen": "::", "listen_port": $P_SS,
      "method": "2022-blake3-aes-128-gcm", "password": "$SSKEY" },
    { "type": "vmess", "tag": "vmess-ws", "listen": "::", "listen_port": $P_VMESS,
      "users": [ { "uuid": "$UUID", "alterId": 0 } ],
      "transport": { "type": "ws", "path": "$WSPATH" } }
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ]
}
EOF
  sing-box check -c "$SB_CONF" || die "sing-box 配置校验失败"
  systemctl enable sing-box >/dev/null 2>&1
  systemctl restart sing-box
  sleep 1
  systemctl is-active --quiet sing-box || die "sing-box 启动失败：journalctl -u sing-box"
  green "sing-box 已运行"
}

write_client_files() {
  local ip=$1 b64ss vmjson
  b64ss=$(printf '%s' "2022-blake3-aes-128-gcm:$SSKEY" | base64 -w0 | tr '+/' '-_' | tr -d '=')
  vmjson=$(jq -nc --arg a "$ip" --arg id "$UUID" --arg p "$WSPATH" --arg n "$NAME-VMess-WS" --arg port "$P_VMESS" \
    '{v:"2",ps:$n,add:$a,port:$port,id:$id,aid:"0",scy:"auto",net:"ws",type:"none",host:"",path:$p,tls:""}')
  cat > "$STATE/links.txt" <<EOF
vless://$UUID@$ip:$P_VLESS?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$SNI&fp=chrome&pbk=$PUB&sid=$SID&type=tcp#$NAME-VLESS-Reality
hysteria2://$PW@$ip:$P_HY2?sni=$CERT_CN&alpn=h3&insecure=1#$NAME-Hysteria2
tuic://$UUID:$PW@$ip:$P_TUIC?sni=$CERT_CN&alpn=h3&congestion_control=bbr&udp_relay_mode=native&allow_insecure=1#$NAME-TUIC
ss://$b64ss@$ip:$P_SS#$NAME-SS2022
vmess://$(printf '%s' "$vmjson" | base64 -w0)
EOF
  base64 -w0 "$STATE/links.txt" > "$STATE/subscription.txt"
  local N=$NAME
  cat > "$STATE/clash.yaml" <<EOF
mixed-port: 7890
allow-lan: false
mode: rule
log-level: warning
ipv6: true
unified-delay: true
tcp-concurrent: true
# rule data from a mirror reachable inside mainland China
geo-auto-update: true
geo-update-interval: 24
geox-url:
  geoip: "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip-lite.dat"
  geosite: "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geosite.dat"
  mmdb: "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/country-lite.mmdb"
dns:
  enable: true
  ipv6: true
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  # mainland + LAN names get real IPs, resolved by mainland DNS (correct CDN node)
  fake-ip-filter: ["*.lan", "*.local", "+.msftconnecttest.com", "+.msftncsi.com", "time.*.com", "ntp.*.com", "+.pool.ntp.org", "geosite:cn"]
  default-nameserver: [223.5.5.5, 119.29.29.29]
  proxy-server-nameserver: [https://223.5.5.5/dns-query, https://doh.pub/dns-query]
  nameserver-policy:
    "geosite:private,cn": [https://223.5.5.5/dns-query, https://doh.pub/dns-query]
  # everything else is resolved through the proxy: no DNS leak, no poisoned answers
  nameserver: ["https://1.1.1.1/dns-query#PROXY", "https://8.8.8.8/dns-query#PROXY"]
proxies:
  - { name: $N-VLESS-Reality, type: vless, server: $ip, port: $P_VLESS, uuid: $UUID, network: tcp, tls: true, udp: true, flow: xtls-rprx-vision, servername: $SNI, client-fingerprint: chrome, reality-opts: { public-key: $PUB, short-id: $SID } }
  - { name: $N-Hysteria2, type: hysteria2, server: $ip, port: $P_HY2, password: $PW, sni: $CERT_CN, alpn: [h3], skip-cert-verify: true }
  - { name: $N-TUIC, type: tuic, server: $ip, port: $P_TUIC, uuid: $UUID, password: $PW, sni: $CERT_CN, alpn: [h3], congestion-controller: bbr, udp-relay-mode: native, skip-cert-verify: true }
  - { name: $N-SS2022, type: ss, server: $ip, port: $P_SS, cipher: 2022-blake3-aes-128-gcm, password: "$SSKEY", udp: true }
  - { name: $N-VMess-WS, type: vmess, server: $ip, port: $P_VMESS, uuid: $UUID, alterId: 0, cipher: auto, network: ws, udp: true, ws-opts: { path: "$WSPATH" } }
proxy-groups:
  - { name: PROXY, type: select, proxies: [AUTO, $N-VLESS-Reality, $N-Hysteria2, $N-TUIC, $N-SS2022, $N-VMess-WS, DIRECT] }
  - { name: AUTO, type: url-test, url: "https://www.gstatic.com/generate_204", interval: 300, proxies: [$N-VLESS-Reality, $N-Hysteria2, $N-TUIC, $N-SS2022, $N-VMess-WS] }
rules:
  - GEOSITE,private,DIRECT
  - GEOIP,private,DIRECT,no-resolve
  # ---- mainland China: direct ----
  - GEOSITE,cn,DIRECT
  - GEOSITE,apple-cn,DIRECT
  - GEOSITE,microsoft@cn,DIRECT
  - GEOSITE,steam@cn,DIRECT
  - GEOSITE,category-games@cn,DIRECT
  # ---- known foreign sites: proxy, without a local DNS lookup ----
  - GEOSITE,geolocation-!cn,PROXY
  # ---- anything left: mainland IP direct, the rest proxy ----
  - GEOIP,CN,DIRECT
  - MATCH,PROXY
EOF
  # sing-box client profile (SFA / SFI / SFM / sing-box core), same mainland-direct split
  # rule sets: MetaCubeX/meta-rules-dat (same data as the Clash profile, built on
  # Loyalsoldier/v2ray-rules-dat), refreshed by the client once a day
  local RS=https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo
  local RSOPT='"type": "remote", "format": "binary", "download_detour": "direct", "update_interval": "1d"'
  local CN_SETS='[ "geosite-cn", "geosite-apple-cn", "geosite-microsoft-cn", "geosite-steam-cn", "geosite-games-cn" ]'
  cat > "$STATE/singbox.json" <<EOF
{
  "log": { "level": "warn", "timestamp": true },
  "dns": {
    "servers": [
      { "type": "https", "tag": "dns-proxy", "server": "1.1.1.1", "detour": "PROXY" },
      { "type": "https", "tag": "dns-cn", "server": "223.5.5.5" }
    ],
    "rules": [ { "rule_set": $CN_SETS, "server": "dns-cn" } ],
    "final": "dns-proxy",
    "strategy": "prefer_ipv4"
  },
  "inbounds": [
    { "type": "tun", "tag": "tun-in", "address": [ "172.19.0.1/30", "fdfe:dcba:9876::1/126" ],
      "auto_route": true, "strict_route": true },
    { "type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": 2080 }
  ],
  "outbounds": [
    { "type": "selector", "tag": "PROXY", "default": "AUTO",
      "outbounds": [ "AUTO", "$N-VLESS-Reality", "$N-Hysteria2", "$N-TUIC", "$N-SS2022", "$N-VMess-WS" ] },
    { "type": "urltest", "tag": "AUTO", "url": "https://www.gstatic.com/generate_204", "interval": "5m",
      "outbounds": [ "$N-VLESS-Reality", "$N-Hysteria2", "$N-TUIC", "$N-SS2022", "$N-VMess-WS" ] },
    { "type": "vless", "tag": "$N-VLESS-Reality", "server": "$ip", "server_port": $P_VLESS,
      "uuid": "$UUID", "flow": "xtls-rprx-vision",
      "tls": { "enabled": true, "server_name": "$SNI", "utls": { "enabled": true, "fingerprint": "chrome" },
               "reality": { "enabled": true, "public_key": "$PUB", "short_id": "$SID" } } },
    { "type": "hysteria2", "tag": "$N-Hysteria2", "server": "$ip", "server_port": $P_HY2, "password": "$PW",
      "tls": { "enabled": true, "server_name": "$CERT_CN", "insecure": true, "alpn": [ "h3" ] } },
    { "type": "tuic", "tag": "$N-TUIC", "server": "$ip", "server_port": $P_TUIC, "uuid": "$UUID", "password": "$PW",
      "congestion_control": "bbr",
      "tls": { "enabled": true, "server_name": "$CERT_CN", "insecure": true, "alpn": [ "h3" ] } },
    { "type": "shadowsocks", "tag": "$N-SS2022", "server": "$ip", "server_port": $P_SS,
      "method": "2022-blake3-aes-128-gcm", "password": "$SSKEY" },
    { "type": "vmess", "tag": "$N-VMess-WS", "server": "$ip", "server_port": $P_VMESS, "uuid": "$UUID",
      "security": "auto", "transport": { "type": "ws", "path": "$WSPATH" } },
    { "type": "direct", "tag": "direct" }
  ],
  "route": {
    "auto_detect_interface": true,
    "default_domain_resolver": "dns-cn",
    "rule_set": [
      { "tag": "geosite-private", $RSOPT, "url": "$RS/geosite/private.srs" },
      { "tag": "geosite-cn", $RSOPT, "url": "$RS/geosite/cn.srs" },
      { "tag": "geosite-apple-cn", $RSOPT, "url": "$RS/geosite/apple-cn.srs" },
      { "tag": "geosite-microsoft-cn", $RSOPT, "url": "$RS/geosite/microsoft@cn.srs" },
      { "tag": "geosite-steam-cn", $RSOPT, "url": "$RS/geosite/steam@cn.srs" },
      { "tag": "geosite-games-cn", $RSOPT, "url": "$RS/geosite/category-games@cn.srs" },
      { "tag": "geosite-!cn", $RSOPT, "url": "$RS/geosite/geolocation-!cn.srs" },
      { "tag": "geoip-cn", $RSOPT, "url": "$RS/geoip/cn.srs" }
    ],
    "rules": [
      { "action": "sniff" },
      { "protocol": "dns", "action": "hijack-dns" },
      { "ip_is_private": true, "outbound": "direct" },
      { "rule_set": "geosite-private", "outbound": "direct" },
      { "rule_set": $CN_SETS, "outbound": "direct" },
      { "rule_set": "geosite-!cn", "outbound": "PROXY" },
      { "rule_set": "geoip-cn", "outbound": "direct" }
    ],
    "final": "PROXY"
  },
  "experimental": { "cache_file": { "enabled": true } }
}
EOF
  sing-box check -c "$STATE/singbox.json" || die "sing-box 客户端配置校验失败"
  chmod 600 "$STATE"/*
}

setup_sub() {
  local ip=$1 host o
  [ "$NO_SUB" = 1 ] && { yellow "跳过订阅服务"; return; }
  o=$(port_owner 80)
  if [ -n "$o" ] && [ "$o" != caddy ]; then
    yellow "80 端口被 $o 占用，无法申请证书，跳过订阅服务（节点链接用 info 查看）"
    NO_SUB=1; save_settings; return
  fi
  if ! command -v caddy >/dev/null; then
    apt_install debian-keyring debian-archive-keyring apt-transport-https gnupg
    curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/gpg.key | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt > /etc/apt/sources.list.d/caddy-stable.list
    apt_install caddy
  fi
  rm -rf "$WWW"; mkdir -p "$WWW/$TOKEN"
  cp "$STATE/clash.yaml" "$WWW/$TOKEN/clash.yaml"
  cp "$STATE/subscription.txt" "$WWW/$TOKEN/sub.txt"
  cp "$STATE/singbox.json" "$WWW/$TOKEN/singbox.json"
  chown -R caddy:caddy "$WWW"; chmod -R u=rwX,g=rX,o= "$WWW"
  host=${DOMAIN:-$ip}
  local tls_block
  if [ -n "$DOMAIN" ]; then
    tls_block=""
  else
    tls_block=$'\ttls {\n\t\tissuer acme {\n\t\t\tprofile shortlived\n\t\t\tdisable_tlsalpn_challenge\n\t\t}\n\t}'
  fi
  cat > /etc/caddy/Caddyfile <<EOF
https://$host:$P_SUB {
$tls_block
	root * $WWW
	header -Server
	@clash {
		path /$TOKEN
		header_regexp User-Agent (?i)(clash|mihomo|meta|verge|stash|party|nyanpasu)
	}
	handle @clash {
		rewrite * /$TOKEN/clash.yaml
		header Content-Type "text/yaml; charset=utf-8"
		header Content-Disposition "attachment; filename=$NAME"
		header Profile-Update-Interval 24
		file_server
	}
	@singbox {
		path /$TOKEN
		header_regexp User-Agent (?i)(sing-box|SFA|SFI|SFM|SFT)
	}
	handle @singbox {
		rewrite * /$TOKEN/singbox.json
		header Content-Type "application/json; charset=utf-8"
		file_server
	}
	handle /$TOKEN/singbox {
		rewrite * /$TOKEN/singbox.json
		header Content-Type "application/json; charset=utf-8"
		file_server
	}
	handle /$TOKEN {
		rewrite * /$TOKEN/sub.txt
		header Content-Type "text/plain; charset=utf-8"
		file_server
	}
	handle /$TOKEN/clash {
		rewrite * /$TOKEN/clash.yaml
		header Content-Type "text/yaml; charset=utf-8"
		header Content-Disposition "attachment; filename=$NAME"
		file_server
	}
	handle {
		respond 404
	}
}
EOF
  caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 || die "Caddy 配置校验失败"
  systemctl enable caddy >/dev/null 2>&1
  systemctl restart caddy
  local i
  for i in $(seq 1 30); do
    curl -fsS -o /dev/null --max-time 5 "https://$host:$P_SUB/$TOKEN" 2>/dev/null && { green "订阅服务已就绪（证书有效）"; return; }
    sleep 3
  done
  yellow "订阅证书暂未就绪，可能需要再等一会儿；排查：journalctl -u caddy -n 50"
}

open_firewall() {
  if command -v ufw >/dev/null && ufw status | grep -q 'Status: active'; then
    ufw allow "$P_VLESS"/tcp >/dev/null; ufw allow "$P_HY2"/udp >/dev/null; ufw allow "$P_TUIC"/udp >/dev/null
    ufw allow "$P_SS" >/dev/null; ufw allow "$P_VMESS"/tcp >/dev/null
    [ "$NO_SUB" = 1 ] || { ufw allow 80/tcp >/dev/null; ufw allow "$P_SUB"/tcp >/dev/null; }
    green "ufw 已放行端口"
  fi
}

install_cmd() {
  local dst=/usr/local/bin/onekey
  if [ -f "$0" ] && [ -r "$0" ] && head -c 20 "$0" | grep -q bash; then
    [ "$(readlink -f "$0")" = "$dst" ] || cp "$0" "$dst"
  else
    curl -fsSL "$SELF_URL" -o "$dst" 2>/dev/null || return 0
  fi
  chmod 755 "$dst"
}

show_info() {
  [ -f "$STATE/secrets.env" ] || die "尚未安装"
  . "$STATE/secrets.env"; . "$STATE/settings.env"
  local ip host
  ip=$(public_ip); host=${DOMAIN:-$ip}
  echo
  green "================ 安装信息 ================"
  if [ "${NO_SUB:-0}" != 1 ]; then
    echo "订阅链接（所有客户端通用，自动识别格式）："
    yellow "  https://$host:$P_SUB/$TOKEN"
    echo "Clash 强制格式："
    yellow "  https://$host:$P_SUB/$TOKEN/clash"
    echo "sing-box 强制格式："
    yellow "  https://$host:$P_SUB/$TOKEN/singbox"
    echo "（Clash 和 sing-box 格式自带分流：大陆直连，其余走代理）"
    echo
  fi
  echo "单个节点链接："
  sed 's/^/  /' "$STATE/links.txt"
  echo
  echo "以后查看：onekey info    卸载：onekey uninstall"
  red "订阅链接等于全部节点的钥匙，不要外泄；泄露后运行 onekey regen 更换"
}

do_install() {
  check_os
  green ">> 安装依赖"
  apt_install curl openssl jq ca-certificates iproute2 coreutils
  install_singbox
  check_ports
  load_or_make_secrets
  save_settings
  setup_bbr
  setup_swap
  write_singbox
  local ip; ip=$(public_ip)
  write_client_files "$ip"
  open_firewall
  setup_sub "$ip"
  install_cmd
  show_info
}

do_uninstall() {
  systemctl disable --now sing-box >/dev/null 2>&1 || true
  systemctl disable --now caddy >/dev/null 2>&1 || true
  DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq sing-box caddy >/dev/null 2>&1 || true
  rm -rf /etc/sing-box /etc/caddy "$WWW" "$STATE" /etc/sysctl.d/99-onekey-net.conf \
         /etc/apt/sources.list.d/caddy-stable.list /usr/share/keyrings/caddy-stable-archive-keyring.gpg \
         /usr/local/bin/onekey
  green "已卸载（虚拟内存保留，如需删除：swapoff /swapfile && rm /swapfile 并删掉 /etc/fstab 中对应行）"
}

case "$CMD" in
  install) do_install;;
  info) show_info;;
  regen)
    [ -f "$STATE/secrets.env" ] || die "尚未安装"
    CLI_NAME=$NAME; . "$STATE/secrets.env"; NAME=${CLI_NAME:-$NAME}
    REGEN=1 do_install;;
  uninstall) do_uninstall;;
  *) usage; exit 1;;
esac
