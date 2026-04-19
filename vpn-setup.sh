#!/bin/bash
# ============================================================
# VPN Server All-in-One Setup Script
# Installs: SSH Tunnel, Xray (VLESS+Reality), V2Ray (VMess+WS+TLS),
#           Shadowsocks, Nginx + Certbot
# Points everything to YOUR domain
#
# Usage: chmod +x vpn-setup.sh && sudo ./vpn-setup.sh
# OS: Ubuntu 20.04 / 22.04 / 24.04, Debian 11/12
# ============================================================

set -e

# ============================================================
# COLORS
# ============================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

echo ""
echo -e "${PURPLE}${BOLD}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${PURPLE}${BOLD}║        VPN SERVER ALL-IN-ONE SETUP                    ║${NC}"
echo -e "${PURPLE}${BOLD}║        SSH + V2Ray + Xray + Shadowsocks               ║${NC}"
echo -e "${PURPLE}${BOLD}╚════════════════════════════════════════════════════════╝${NC}"
echo ""

# ============================================================
# CHECK ROOT
# ============================================================
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[ERROR] Run as root: sudo ./vpn-setup.sh${NC}"
    exit 1
fi

# ============================================================
# OS DETECTION
# ============================================================
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS=$ID
    VER=$VERSION_ID
else
    echo -e "${RED}[ERROR] Cannot detect OS${NC}"
    exit 1
fi

echo -e "${GREEN}[OK] OS: $PRETTY_NAME${NC}"

# ============================================================
# GATHER INFO
# ============================================================
echo ""
echo -e "${CYAN}${BOLD}[1/7] Configuration${NC}"
echo ""

# Domain
read -p "  Enter your domain (e.g. vpn.yourdomain.com): " DOMAIN
if [[ -z "$DOMAIN" ]]; then
    echo -e "${RED}[ERROR] Domain is required!${NC}"
    exit 1
fi
DOMAIN=$(echo "$DOMAIN" | tr '[:upper:]' '[:lower:]' | sed 's|https://||;s|http://||;s|/.*||')

# Email for certbot
read -p "  Enter your email (for SSL cert): " EMAIL
EMAIL=${EMAIL:-admin@example.com}

# SSH port
read -p "  SSH port [22]: " SSH_PORT
SSH_PORT=${SSH_PORT:-22}

# VLESS+Reality port
read -p "  Xray VLESS+Reality port [443]: " REALITY_PORT
REALITY_PORT=${REALITY_PORT:-443}

# VMess+WS port
read -p "  V2Ray VMess+WebSocket port [8443]: " VMESS_PORT
VMESS_PORT=${VMESS_PORT:-8443}

# Shadowsocks port
read -p "  Shadowsocks port [18888]: " SS_PORT
SS_PORT=${SS_PORT:-18888}

# Shadowsocks password
SS_PASS=$(openssl rand -base64 16)

echo ""
echo -e "${YELLOW}  Summary:${NC}"
echo "    Domain:          $DOMAIN"
echo "    Email:           $EMAIL"
echo "    SSH Port:        $SSH_PORT"
echo "    Reality Port:    $REALITY_PORT"
echo "    VMess+WS Port:   $VMESS_PORT"
echo "    Shadowsocks Port: $SS_PORT"
echo ""
read -p "  Continue? (y/n): " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "Cancelled."
    exit 0
fi

# ============================================================
# 2/7 SYSTEM UPDATE
# ============================================================
echo ""
echo -e "${CYAN}${BOLD}[2/7] Updating system...${NC}"

apt-get update -y
apt-get upgrade -y
apt-get install -y curl wget unzip gnupg2 lsof net-tools jq \
    nginx certbot python3-certbot-nginx \
    qrencode

echo -e "${GREEN}[OK] System updated${NC}"

# ============================================================
# 3/7 FIREWALL SETUP
# ============================================================
echo ""
echo -e "${CYAN}${BOLD}[3/7] Configuring firewall...${NC}"

# Use ufw if available
if command -v ufw &> /dev/null; then
    ufw --force enable
    ufw allow $SSH_PORT/tcp
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw allow $VMESS_PORT/tcp
    ufw allow $SS_PORT/tcp
    ufw allow $SS_PORT/udp
    echo -e "${GREEN}[OK] UFW firewall configured${NC}"
else
    echo -e "${YELLOW}[INFO] UFW not found, using iptables...${NC}"
    iptables -A INPUT -p tcp --dport 80 -j ACCEPT
    iptables -A INPUT -p tcp --dport 443 -j ACCEPT
    iptables -A INPUT -p tcp --dport $VMESS_PORT -j ACCEPT
    iptables -A INPUT -p tcp --dport $SS_PORT -j ACCEPT
    iptables -A INPUT -p udp --dport $SS_PORT -j ACCEPT
    echo -e "${GREEN}[OK] Iptables rules added${NC}"
fi

# Enable BBR congestion control
if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf 2>/dev/null; then
    cat >> /etc/sysctl.conf << EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
EOF
    sysctl -p
    echo -e "${GREEN}[OK] TCP BBR enabled${NC}"
fi

# ============================================================
# 4/7 NGINX + SSL CERTIFICATE
# ============================================================
echo ""
echo -e "${CYAN}${BOLD}[4/7] Setting up Nginx + SSL...${NC}"

# Create nginx config for the domain
cat > /etc/nginx/sites-available/$DOMAIN << EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF

ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

nginx -t && systemctl restart nginx

# Get SSL certificate
echo -e "${YELLOW}[INFO] Getting SSL certificate for $DOMAIN...${NC}"
certbot --nginx -d $DOMAIN --email $EMAIL --agree-tos --non-interactive --redirect

if [[ $? -eq 0 ]]; then
    echo -e "${GREEN}[OK] SSL certificate obtained!${NC}"
else
    echo -e "${YELLOW}[WARN] SSL cert failed. Make sure your domain DNS A record points to this server IP.${NC}"
    echo -e "${YELLOW}       Server IP: $(curl -s ifconfig.me 2>/dev/null)${NC}"
    echo -e "${YELLOW}       You can run 'certbot --nginx -d $DOMAIN' later.${NC}"
fi

# Create final nginx config
cat > /etc/nginx/sites-available/$DOMAIN << 'NGINXEOF'
server {
    listen 80;
    server_name __DOMAIN__;

    location / {
        return 301 https://$host$request_uri;
    }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name __DOMAIN__;

    ssl_certificate /etc/letsencrypt/live/__DOMAIN__/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/__DOMAIN__/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;

    # V2Ray VMess WebSocket path
    location /vmess-ws {
        proxy_pass http://127.0.0.1:__VMESS_PORT__;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }

    # Fake website (decoy)
    location / {
        root /var/www/html;
        index index.html;
        try_files $uri $uri/ =404;
    }
}
NGINXEOF

sed -i "s|__DOMAIN__|$DOMAIN|g" /etc/nginx/sites-available/$DOMAIN
sed -i "s|__VMESS_PORT__|$VMESS_PORT|g" /etc/nginx/sites-available/$DOMAIN

# Create decoy page
mkdir -p /var/www/html
cat > /var/www/html/index.html << 'HTMLEOF'
<!DOCTYPE html>
<html>
<head><title>Welcome to nginx!</title></head>
<body><h1>Welcome to nginx!</h1><p>If you see this page, the nginx web server is successfully installed.</p></body>
</html>
HTMLEOF

nginx -t && systemctl reload nginx
echo -e "${GREEN}[OK] Nginx configured with SSL${NC}"

# ============================================================
# 5/7 XRAY (VLESS + Reality)
# ============================================================
echo ""
echo -e "${CYAN}${BOLD}[5/7] Installing Xray (VLESS+Reality)...${NC}"

# Install Xray
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

# Stop xray if running
systemctl stop xray 2>/dev/null || true

# Generate Reality keys
REALITY_KEYS=$(xray x25519)
REALITY_PRIVATE=$(echo "$REALITY_KEYS" | head -1 | awk '{print $3}')
REALITY_PUBLIC=$(echo "$REALITY_KEYS" | tail -1 | awk '{print $3}')
REALITY_SNI="www.microsoft.com"
REALITY_SHORT_ID=$(openssl rand -hex 8)
REALITY_UUID=$(cat /proc/sys/kernel/random/uuid)

# Create Xray config
cat > /usr/local/etc/xray/config.json << XRAYEOF
{
    "log": {
        "loglevel": "warning"
    },
    "inbounds": [
        {
            "listen": "0.0.0.0",
            "port": __REALITY_PORT__,
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id": "__REALITY_UUID__",
                        "flow": "xtls-rprx-vision"
                    }
                ],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "show": false,
                    "dest": "__REALITY_SNI__:443",
                    "xver": 0,
                    "serverNames": [
                        "__REALITY_SNI__"
                    ],
                    "privateKey": "__REALITY_PRIVATE__",
                    "shortIds": [
                        "__REALITY_SHORT_ID__",
                        "6ba85179e30d4fc2",
                        ""
                    ]
                }
            },
            "sniffing": {
                "enabled": true,
                "destOverride": [
                    "http",
                    "tls"
                ]
            }
        }
    ],
    "outbounds": [
        {
            "protocol": "freedom",
            "tag": "direct"
        },
        {
            "protocol": "blackhole",
            "tag": "block"
        }
    ],
    "routing": {
        "rules": [
            {
                "type": "field",
                "outboundTag": "block",
                "ip": [
                    "geoip:private"
                ]
            }
        ]
    }
}
XRAYEOF

sed -i "s|__REALITY_PORT__|$REALITY_PORT|g" /usr/local/etc/xray/config.json
sed -i "s|__REALITY_UUID__|$REALITY_UUID|g" /usr/local/etc/xray/config.json
sed -i "s|__REALITY_SNI__|$REALITY_SNI|g" /usr/local/etc/xray/config.json
sed -i "s|__REALITY_PRIVATE__|$REALITY_PRIVATE|g" /usr/local/etc/xray/config.json
sed -i "s|__REALITY_SHORT_ID__|$REALITY_SHORT_ID|g" /usr/local/etc/xray/config.json

systemctl enable xray
systemctl start xray

if systemctl is-active --quiet xray; then
    echo -e "${GREEN}[OK] Xray running on port $REALITY_PORT${NC}"
else
    echo -e "${RED}[ERROR] Xray failed to start. Check: journalctl -u xray${NC}"
fi

# ============================================================
# 6/7 V2RAY (VMess + WebSocket)
# ============================================================
echo ""
echo -e "${CYAN}${BOLD}[6/7] Installing V2Ray (VMess+WebSocket+TLS)...${NC}"

# Install V2Ray
bash -c "$(curl -L https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh)"

systemctl stop v2ray 2>/dev/null || true

VMESS_UUID=$(cat /proc/sys/kernel/random/uuid)
VMESS_PATH="vmess-ws"
VMESS_ALTERID=0

# Create V2Ray config
cat > /usr/local/etc/v2ray/config.json << V2RAYEOF
{
    "log": {
        "loglevel": "warning"
    },
    "inbounds": [
        {
            "port": __VMESS_PORT__,
            "protocol": "vmess",
            "settings": {
                "clients": [
                    {
                        "id": "__VMESS_UUID__",
                        "alterId": __VMESS_ALTERID__
                    }
                ]
            },
            "streamSettings": {
                "network": "ws",
                "wsSettings": {
                    "path": "/__VMESS_PATH__"
                }
            }
        }
    ],
    "outbounds": [
        {
            "protocol": "freedom",
            "tag": "direct"
        }
    ]
}
V2RAYEOF

sed -i "s|__VMESS_PORT__|$VMESS_PORT|g" /usr/local/etc/v2ray/config.json
sed -i "s|__VMESS_UUID__|$VMESS_UUID|g" /usr/local/etc/v2ray/config.json
sed -i "s|__VMESS_ALTERID__|$VMESS_ALTERID|g" /usr/local/etc/v2ray/config.json
sed -i "s|__VMESS_PATH__|$VMESS_PATH|g" /usr/local/etc/v2ray/config.json

systemctl enable v2ray
systemctl start v2ray

if systemctl is-active --quiet v2ray; then
    echo -e "${GREEN}[OK] V2Ray running on port $VMESS_PORT${NC}"
else
    echo -e "${RED}[ERROR] V2Ray failed to start. Check: journalctl -u v2ray${NC}"
fi

# ============================================================
# 7/7 SHADOWSOCKS
# ============================================================
echo ""
echo -e "${CYAN}${BOLD}[7/7] Installing Shadowsocks...${NC}"

# Install shadowsocks-rust via cargo or binary
if command -v apt &> /dev/null; then
    # Try snap first
    if command -v snap &> /dev/null; then
        snap install shadowsocks-rust 2>/dev/null || true
    fi

    # Install via script
    bash -c "$(curl -fsSL https://raw.githubusercontent.com/shadowsocks/shadowsocks-rust/master/install.sh)" 2>/dev/null || {
        echo -e "${YELLOW}[INFO] Installing shadowsocks-libev...${NC}"
        apt-get install -y shadowsocks-libev simple-obfs 2>/dev/null || {
            # Manual install
            SS_VERSION="latest"
            SS_ARCH=$(uname -m)
            if [[ "$SS_ARCH" == "x86_64" ]]; then
                SS_ARCH="amd64"
            elif [[ "$SS_ARCH" == "aarch64" ]]; then
                SS_ARCH="arm64"
            fi

            SS_URL="https://github.com/shadowsocks/shadowsocks-rust/releases/latest/download/shadowsocks-${SS_VERSION}.${SS_ARCH}-unknown-linux-gnu.tar.xz"
            cd /tmp
            curl -Lo ss.tar.xz "$SS_URL"
            tar xf ss.tar.xz
            mv ssserver /usr/local/bin/
            chmod +x /usr/local/bin/ssserver
            cd -
            rm -rf /tmp/ss*
        }
    }
fi

SS_CIPHER="2022-blake3-aes-256-gcm"
SS_PLUGIN=""

# Create shadowsocks config
mkdir -p /etc/shadowsocks
cat > /etc/shadowsocks/config.json << SSEOF
{
    "server": "0.0.0.0",
    "server_port": __SS_PORT__,
    "password": "__SS_PASS__",
    "timeout": 300,
    "method": "__SS_CIPHER__",
    "mode": "tcp_and_udp",
    "fast_open": true,
    "no_delay": true
}
SSEOF

sed -i "s|__SS_PORT__|$SS_PORT|g" /etc/shadowsocks/config.json
sed -i "s|__SS_PASS__|$SS_PASS|g" /etc/shadowsocks/config.json
sed -i "s|__SS_CIPHER__|$SS_CIPHER|g" /etc/shadowsocks/config.json

# Create systemd service
cat > /etc/systemd/system/shadowsocks.service << SSSERVICE
[Unit]
Description=Shadowsocks Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/ssserver -c /etc/shadowsocks/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
SSSERVICE

# If ssserver not found, try ss-local or other names
if [[ ! -f /usr/local/bin/ssserver ]]; then
    for cmd in /usr/bin/ssserver /usr/sbin/ssserver /snap/bin/shadowsocks-rust; do
        if [[ -f "$cmd" ]]; then
            sed -i "s|/usr/local/bin/ssserver|$cmd|" /etc/systemd/system/shadowsocks.service
            break
        fi
    done
fi

systemctl daemon-reload
systemctl enable shadowsocks
systemctl start shadowsocks

if systemctl is-active --quiet shadowsocks; then
    echo -e "${GREEN}[OK] Shadowsocks running on port $SS_PORT (UDP+TCP)${NC}"
else
    echo -e "${YELLOW}[WARN] Shadowsocks may not have started. Check: journalctl -u shadowsocks${NC}"
fi

# ============================================================
# SSH TUNNEL INFO
# ============================================================
SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || curl -s icanhazip.com 2>/dev/null || echo "YOUR_IP")

# ============================================================
# RESULTS
# ============================================================
echo ""
echo -e "${PURPLE}${BOLD}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${PURPLE}${BOLD}║           ALL VPN SERVICES INSTALLED!                ║${NC}"
echo -e "${PURPLE}${BOLD}╚════════════════════════════════════════════════════════╝${NC}"
echo ""

echo -e "${BOLD}Server IP:${NC} $SERVER_IP"
echo -e "${BOLD}Domain:${NC} $DOMAIN"
echo ""

# --------------------------------------------------------
# 1) Xray VLESS + Reality
# --------------------------------------------------------
echo -e "${GREEN}${BOLD}━━━ 1. Xray VLESS + Reality (Recommended) ━━━${NC}"
echo ""
echo -e "  ${BOLD}Protocol:${NC}    vless"
echo -e "  ${BOLD}Address:${NC}     $SERVER_IP"
echo -e "  ${BOLD}Port:${NC}        $REALITY_PORT"
echo -e "  ${BOLD}UUID:${NC}        $REALITY_UUID"
echo -e "  ${BOLD}Flow:${NC}        xtls-rprx-vision"
echo -e "  ${BOLD}SNI:${NC}         $REALITY_SNI"
echo -e "  ${BOLD}Public Key:${NC}  $REALITY_PUBLIC"
echo -e "  ${BOLD}Short ID:${NC}    $REALITY_SHORT_ID"
echo -e "  ${BOLD}Security:${NC}    reality"
echo ""
echo -e "  ${CYAN}VLESS Link:${NC}"
echo -e "  vless://${REALITY_UUID}@${SERVER_IP}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUBLIC}&sid=${REALITY_SHORT_ID}#ToxicVPN-Reality&type=tcp"
echo ""
echo -e "  ${CYAN}QR Code saved to:${NC} /root/vpn-reality-qr.png"

# Save QR
echo -n "vless://${REALITY_UUID}@${SERVER_IP}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUBLIC}&sid=${REALITY_SHORT_ID}#ToxicVPN-Reality" \
    | qrencode -o /root/vpn-reality-qr.png -s 6 2>/dev/null || echo -e "  ${YELLOW}(QR generation skipped - install qrencode)${NC}"

echo ""

# --------------------------------------------------------
# 2) V2Ray VMess + WebSocket
# --------------------------------------------------------
echo -e "${GREEN}${BOLD}━━━ 2. V2Ray VMess + WebSocket + TLS ━━━${NC}"
echo ""
echo -e "  ${BOLD}Protocol:${NC}    vmess"
echo -e "  ${BOLD}Address:${NC}     $DOMAIN"
echo -e "  ${BOLD}Port:${NC}        443 (via Nginx)"
echo -e "  ${BOLD}UUID:${NC}        $VMESS_UUID"
echo -e "  ${BOLD}Alter ID:${NC}    $VMESS_ALTERID"
echo -e "  ${BOLD}Network:${NC}     ws"
echo -e "  ${BOLD}WS Path:${NC}     /${VMESS_PATH}"
echo -e "  ${BOLD}TLS:${NC}         enabled (via Nginx)"
echo ""
echo -e "  ${CYAN}VMess Link:${NC}"
echo -e "  vmess://$(echo -n '{\"v\":\"2\",\"ps\":\"ToxicVPN\",\"add\":\"'$DOMAIN'\",\"port\":\"443\",\"id\":\"'$VMESS_UUID'\",\"aid\":\"'$VMESS_ALTERID'\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"'$DOMAIN'\",\"path\":\"/'$VMESS_PATH'\",\"tls\":\"tls\",\"sni\":\"'$DOMAIN'\"}' | base64 -w0)"
echo ""
echo -e "  ${CYAN}QR Code saved to:${NC} /root/vpn-vmess-qr.png"

echo -n "vmess://$(echo -n '{\"v\":\"2\",\"ps\":\"ToxicVPN\",\"add\":\"'$DOMAIN'\",\"port\":\"443\",\"id\":\"'$VMESS_UUID'\",\"aid\":\"'$VMESS_ALTERID'\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"'$DOMAIN'\",\"path\":\"/'$VMESS_PATH'\",\"tls\":\"tls\",\"sni\":\"'$DOMAIN'\"}' | base64 -w0)" \
    | qrencode -o /root/vpn-vmess-qr.png -s 6 2>/dev/null || echo -e "  ${YELLOW}(QR generation skipped)${NC}"

echo ""

# --------------------------------------------------------
# 3) Shadowsocks
# --------------------------------------------------------
echo -e "${GREEN}${BOLD}━━━ 3. Shadowsocks (TCP + UDP) ━━━${NC}"
echo ""
echo -e "  ${BOLD}Server:${NC}     $SERVER_IP"
echo -e "  ${BOLD}Port:${NC}       $SS_PORT"
echo -e "  ${BOLD}Password:${NC}   $SS_PASS"
echo -e "  ${BOLD}Cipher:${NC}     $SS_CIPHER"
echo -e "  ${BOLD}Mode:${NC}       tcp_and_udp"
echo ""
SS_URI="ss://$(echo -n "${SS_CIPHER}:${SS_PASS}" | base64 -w0)@${SERVER_IP}:${SS_PORT}#ToxicVPN-SS"
echo -e "  ${CYAN}SS Link:${NC}"
echo -e "  $SS_URI"
echo ""
echo -e "  ${CYAN}QR Code saved to:${NC} /root/vpn-ss-qr.png"

echo -n "$SS_URI" | qrencode -o /root/vpn-ss-qr.png -s 6 2>/dev/null || echo -e "  ${YELLOW}(QR generation skipped)${NC}"

echo ""

# --------------------------------------------------------
# 4) SSH Tunnel
# --------------------------------------------------------
echo -e "${GREEN}${BOLD}━━━ 4. SSH Tunnel ━━━${NC}"
echo ""
echo -e "  ${BOLD}Server:${NC}     $SERVER_IP"
echo -e "  ${BOLD}Port:${NC}       $SSH_PORT"
echo -e "  ${BOLD}Command:${NC}    ssh -D 1080 -C -N root@${SERVER_IP} -p ${SSH_PORT}"
echo ""
echo -e "  ${CYAN}SOCKS5 proxy on localhost:1080 via SSH${NC}"
echo ""

# ============================================================
# SAVE ALL CONFIGS TO FILE
# ============================================================
cat > /root/vpn-configs.txt << SAVEEOF
╔════════════════════════════════════════════════════════╗
║       TOXIC VPN — ALL CONFIGURATIONS                   ║
║       Generated: $(date)               ║
╚════════════════════════════════════════════════════════╝

SERVER: $SERVER_IP
DOMAIN: $DOMAIN

━━━ 1. XRAY VLESS + REALITY ━━━
Protocol:  vless
Address:   $SERVER_IP
Port:      $REALITY_PORT
UUID:      $REALITY_UUID
Flow:      xtls-rprx-vision
SNI:       $REALITY_SNI
PublicKey: $REALITY_PUBLIC
ShortID:   $REALITY_SHORT_ID
Security:  reality

Link: vless://${REALITY_UUID}@${SERVER_IP}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUBLIC}&sid=${REALITY_SHORT_ID}#ToxicVPN-Reality

━━━ 2. V2RAY VMESS + WS + TLS ━━━
Protocol: vmess
Address:   $DOMAIN
Port:      443 (Nginx)
UUID:      $VMESS_UUID
AlterID:   $VMESS_ALTERID
Network:   ws
WS Path:   /${VMESS_PATH}
TLS:       enabled

━━━ 3. SHADOWSOCKS ━━━
Server:   $SERVER_IP
Port:     $SS_PORT
Password: $SS_PASS
Cipher:   $SS_CIPHER
Mode:     tcp_and_udp

Link: ss://$(echo -n "${SS_CIPHER}:${SS_PASS}" | base64 -w0)@${SERVER_IP}:${SS_PORT}#ToxicVPN-SS

━━━ 4. SSH TUNNEL ━━━
Port:     $SSH_PORT
Command:  ssh -D 1080 -C -N root@${SERVER_IP} -p ${SSH_PORT}

━━━ USEFUL COMMANDS ━━━
systemctl status xray
systemctl status v2ray
systemctl status shadowsocks
journalctl -u xray -f
journalctl -u v2ray -f
journalctl -u shadowsocks -f
nginx -t && systemctl reload nginx
certbot renew

QR Codes: /root/vpn-reality-qr.png /root/vpn-vmess-qr.png /root/vpn-ss-qr.png
SAVEEOF

echo -e "${GREEN}${BOLD}All configs saved to:${NC} /root/vpn-configs.txt"
echo -e "${GREEN}${BOLD}QR codes saved to:${NC} /root/vpn-*-qr.png"
echo ""
echo -e "${BOLD}━━━ Recommended Client Apps ━━━${NC}"
echo -e "  ${CYAN}Android:${NC}   v2rayNG / NekoBox"
echo -e "  ${CYAN}iOS:${NC}       Streisand / V2Box / Shadowrocket"
echo -e "  ${CYAN}Windows:${NC}   v2rayN / NekoRay"
echo -e "  ${CYAN}Mac:${NC}       V2RayXS / NekoRay"
echo -e "  ${CYAN}Linux:${NC}     v2rayA / NekoRay"
echo -e "  ${CYAN}Chrome:${NC}    Proxy SwitchyOmega"
echo ""
echo -e "${PURPLE}${BOLD}Done! Setup complete.${NC}"
