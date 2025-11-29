#!/bin/bash
# Requirements:
# 1. Set the DNS A record for domain to IPv4
# 2. Set the DNS AAAA record for domain to IPv6
# Command:
# bash -c "`curl -fsSL https://github.com/xcanwin/t/raw/main/t.sh`"

set -euo pipefail

ver_xray=25.10.15

# Defaults (env override)
domain_xray=${DOMAIN_XRAY:-"localhost"}
domain_cert=${DOMAIN_CERT:-"$domain_xray"}
port_xray=${PORT_XRAY:-8443}
pass_xray=${PASS_XRAY:-"TMPtmp-7"}
ver_xray=${VER_XRAY:-"$ver_xray"}

# Detect Docker
if [ -f /.dockerenv ] || [ "${IS_DOCKER:-0}" = "1" ]; then
    IS_DOCKER=1
else
    IS_DOCKER=0
fi

# Sudo
if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

# Interactive (non-Docker)
if [ "$IS_DOCKER" -eq 0 ]; then
    read -p "Enter xray domain ( Default ${domain_xray} ):" v; [ -n "$v" ] && domain_xray="$v"; echo
    read -p "Enter cert domain ( Default ${domain_cert} ):" v; [ -n "$v" ] && domain_cert="$v"; echo
    read -p "Enter xray port ( Default ${port_xray} ):" v; [ -n "$v" ] && port_xray="$v"; echo
    read -s -p "Enter xray password ( Default ${pass_xray} ):" v; [ -n "$v" ] && pass_xray="$v"; echo
fi

# OS-specific webroot
if command -v yum &>/dev/null; then
    webroot="/usr/share/nginx/html"
elif command -v apt &>/dev/null; then
    webroot="/var/www/html"
elif command -v apk &>/dev/null; then
    webroot="/var/lib/nginx/html"
else
    webroot="/usr/share/nginx/html"
fi

# Install libs (non-Docker)
if [ "$IS_DOCKER" -eq 0 ]; then
    if command -v yum &>/dev/null; then
        APT_YUM_OPTIONS="-y --skip-broken"
        if yum install --help 2>&1 | grep -q -- "--skip-unavailable"; then
            APT_YUM_OPTIONS="-y --skip-broken --skip-unavailable"
        fi
        $SUDO yum update -y
        $SUDO yum install epel-release curl wget unzip nginx tar nano net-tools socat git cronie $APT_YUM_OPTIONS
    elif command -v apt &>/dev/null; then
        APT_YUM_OPTIONS="-y"
        $SUDO apt update
        $SUDO apt install curl wget unzip nginx tar nano net-tools socat git cron $APT_YUM_OPTIONS
    elif command -v apk &>/dev/null; then
        APT_YUM_OPTIONS="--no-cache"
        $SUDO apk add curl wget unzip nginx socat git openssl ca-certificates tzdata bash $APT_YUM_OPTIONS
    fi
fi

# Paths
$SUDO mkdir -p "/opt/tool/" "${webroot}"
$SUDO chown "$(whoami)" "/opt/tool/" "${webroot}" || true

# Nginx start
mkdir -p /run/nginx "${webroot}"
if [ "$IS_DOCKER" -eq 0 ]; then
    $SUDO service nginx start || $SUDO systemctl start nginx
    $SUDO systemctl enable nginx.service || true
else
    # Add webroot if missing in nginx conf
    if [ "$webroot" = "/var/lib/nginx/html" ]; then
        sed -i 's|return 404;|root /var/lib/nginx/html; index index.html index.htm;|' /etc/nginx/http.d/default.conf
    fi
    # Add index.html if missing
    if [ ! -f "${webroot}/index.html" ]; then
        echo ok > "${webroot}/index.html"
    fi
    nginx
fi

# Firewall (Skip in Docker)
if [ "$IS_DOCKER" -eq 0 ]; then
    if [[ "$(firewall-cmd --state 2>/dev/null)" == "running" ]]; then
        $SUDO firewall-cmd --permanent --add-port=80/tcp
        $SUDO firewall-cmd --permanent --add-port=${port_xray}/tcp
        $SUDO firewall-cmd --reload
    fi
fi

# Cert
path_cert="/opt/tool/cert"
mkdir -p "${path_cert}/${domain_cert}_ecc"

if [ "$domain_cert" = "localhost" ]; then
    cd "${path_cert}/${domain_cert}_ecc"
    if [ ! -f "${domain_cert}.key" ]; then
        # openssl ecparam -genkey -name prime256v1 -out "${domain_cert}.key"
        openssl ecparam -genkey -name secp384r1 -out "${domain_cert}.key"
        openssl req -new -x509 -days 3650 -key "${domain_cert}.key" -out "fullchain.cer" -subj "/CN=${domain_cert}"
    fi
else
    if [ ! -f "${path_cert}/${domain_cert}_ecc/fullchain.cer" ]; then
        mkdir -p "${HOME}/.acme.sh/"
        # Install acme.sh if missing
        if [ ! -f "${HOME}/.acme.sh/acme.sh" ]; then
            cd /tmp
            git clone https://github.com/acmesh-official/acme.sh.git
            cd acme.sh
            ./acme.sh --install --cert-home "${path_cert}" --log "${HOME}/.acme.sh/acme.sh.log" --log-level 2
        fi
        . "${HOME}/.acme.sh/acme.sh.env"
        export LE_WORKING_DIR="${HOME}/.acme.sh"
        "${HOME}/.acme.sh/acme.sh" --set-default-ca --server letsencrypt
        "${HOME}/.acme.sh/acme.sh" --issue -d "${domain_cert}" --webroot "${webroot}"
        "${HOME}/.acme.sh/acme.sh" --upgrade --auto-upgrade

        # Docker: ensure crond running for renew (optional)
        if [ "$IS_DOCKER" -eq 1 ]; then
            if ! pgrep -x crond >/dev/null 2>&1; then
                crond
            fi
        fi
    fi
fi

# Xray
path_xray="/opt/tool/xray/"
path_down="/opt/tool/download/"
mkdir -p "${path_xray}"
mkdir -p "${path_down}"

# Download Xray
if [ ! -f "${path_xray}/xray" ]; then
    cd "${path_down}"
    wget -q "https://github.com/XTLS/Xray-core/releases/download/v${ver_xray}/Xray-linux-64.zip" -O "Xray-linux-64-${ver_xray}.zip"
    unzip -o -d "${path_xray}" "Xray-linux-64-${ver_xray}.zip"
fi

cd "${path_xray}"
chmod +x xray
cat > xs.json <<EOF
{
  "log": {
    "loglevel": "info",
    "dnsLog": false
  },
  "inbounds": [
    {
      "tag": "tj",
      "listen": "::",
      "port": ${port_xray},
      "protocol": "trojan",
      "settings": {
        "clients": [
          {
            "password": "${pass_xray}"
          }
        ],
        "fallbacks": [ { "dest": 80 } ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
          "alpn": [ "http/1.1" ],
          "certificates": [
            {
              "certificateFile": "${path_cert}/${domain_cert}_ecc/fullchain.cer",
              "keyFile": "${path_cert}/${domain_cert}_ecc/${domain_cert}.key"
            }
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom"
    },
    {
      "tag": "block",
      "protocol": "blackhole",
      "settings": {
        "response": {
          "type": "http"
        }
      }
    },
    {
      "tag": "ss.jump",
      "protocol": "shadowsocks",
      "settings": {
        "servers": [
          {
            "address": "server_wan._.com",
            "port": 443,
            "method": "2022-blake3-aes-256-gcm",
            "password": "R2VuZXJhdGUgcGFzc3dvcmQ6IG9wZW5zc2wgcmFuZCAtYmFzZTY0IDMy"
          }
        ]
      }
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "outboundTag": "block",
        "domain": [
          "pwnedpasswords.com",
          "api.pwnedpasswords.com"
        ],
        "enabled": true
      },
      {
        "type": "field",
        "outboundTag": "ss.jump",
        "domain": [
          "server_lan._.com"
        ],
        "enabled": true
      }
    ]
  }
}
EOF

# Compute trojan link
ip1=$(curl -s ipinfo.io/ip | tr -d '\n')
ip2=$(curl -s api.ipify.org | tr -d '\n')
[ "$ip1" = "$ip2" ] && ip_wan="$ip1" || ip_wan="0.0.0.0"
if [ "$domain_xray" = "localhost" ]; then
    target_xray="$ip_wan"
    allow_insecure=1
else
    target_xray="$domain_xray"
    allow_insecure=0
fi
echo -e "\n\n\n[+] Success:\ntrojan://${pass_xray}@${target_xray}:${port_xray}?security=tls&sni=${domain_xray}&alpn=h2%2Chttp%2F1.1&fp=randomized&type=tcp&headerType=none&allowInsecure=${allow_insecure}#trojan_temp"

# Run
if [ "$IS_DOCKER" -eq 0 ]; then
    nohup ./xray run -c xs.json &
    add_cron_once() {
        entry="$1"
        (crontab -l 2>/dev/null | grep -Fxq "$entry") || (crontab -l 2>/dev/null; echo "$entry") | crontab -
    }
    add_cron_once '@reboot nohup /opt/tool/xray/xray run -c /opt/tool/xray/xs.json &'
else
    exec ./xray run -c xs.json
fi
