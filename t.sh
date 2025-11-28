#!/bin/bash
# Requirements:
# 1. Set the DNS A record for domain to IPv4
# 2. Set the DNS AAAA record for domain to IPv6
# Command:
# bash -c "`curl -fsSL https://github.com/xcanwin/t/raw/main/t.sh`"


# Detect Docker
if [ -f /.dockerenv ] || [ "$IS_DOCKER" == "1" ]; then
    IS_DOCKER=1
else
    IS_DOCKER=0
fi

# Sudo check
if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
else
    SUDO="sudo"
fi

# Defaults
domain_xray=${DOMAIN_XRAY:-"localhost"}
port_xray=${PORT_XRAY:-8443}
pass_xray=${PASS_XRAY:-"TMPtmp-7"}

# Interactive setup (Skip in Docker)
if [ "$IS_DOCKER" -eq 0 ]; then
    read -p "Enter xray domain ( Default is ${domain_xray} ):" domain_xray2; [ -n "${domain_xray2}" ] && domain_xray=$domain_xray2;echo;
fi

if [[ "$domain_xray" == *.* ]]; then
    domain_cert="*.${domain_xray#*.}"
else
    domain_cert="$domain_xray"
fi
# Allow override via ENV in Docker
domain_cert=${DOMAIN_CERT:-$domain_cert}

if [ "$IS_DOCKER" -eq 0 ]; then
    read -p "Enter cert domain ( Default is ${domain_cert} ):" domain_cert2; [ -n "${domain_cert2}" ] && domain_cert=$domain_cert2;echo;
    read -p "Enter xray port ( Set above 1024. Default is ${port_xray} ):" port_xray2; [ -n "${port_xray2}" ] && port_xray=$port_xray2;echo;
    read -s -p "Enter xray password ( Default is ${pass_xray} ):" pass_xray2; [ -n "${pass_xray2}" ] && pass_xray=$pass_xray2;echo;
fi

# install lib (Skip in Docker)
if [ "$IS_DOCKER" -eq 0 ]; then
    if command -v yum &> /dev/null; then
      APT_YUM_OPTIONS="-y --skip-broken"
      if yum install --help 2>&1 | grep -q -- "--skip-unavailable"; then
          APT_YUM_OPTIONS="-y --skip-broken --skip-unavailable"
      fi
      $SUDO yum update -y; $SUDO yum install epel-release wget unzip nginx tar nano net-tools nginx-all-modules.noarch socat git cronie $APT_YUM_OPTIONS
      webroot="/usr/share/nginx/html"
    elif command -v apt &> /dev/null; then
      APT_YUM_OPTIONS="-y"
      $SUDO apt update; $SUDO apt install wget unzip nginx tar nano net-tools socat git cronie $APT_YUM_OPTIONS
      webroot="/var/www/html"
    fi
else
    # Docker paths
    webroot="/usr/share/nginx/html"
fi

# nginx
if [ "$IS_DOCKER" -eq 0 ]; then
    $SUDO service nginx start
    $SUDO systemctl enable nginx.service
else
    mkdir -p /run/nginx
    nginx
fi

# chown
$SUDO mkdir -p "/opt/tool/" "${webroot}"
$SUDO chown $(whoami) "/opt/tool/" "${webroot}"

# firewall (Skip in Docker)
if [ "$IS_DOCKER" -eq 0 ]; then
    if [[ "$(firewall-cmd --state 2>/dev/null)" == "running" ]]; then
      $SUDO firewall-cmd --permanent --add-port=80/tcp
      $SUDO firewall-cmd --permanent --add-port=${port_xray}/tcp
      $SUDO firewall-cmd --reload
    fi
fi

# cert
path_cert="/opt/tool/cert/"
if [ "$domain_cert" = "localhost" ]; then
  mkdir -p ${path_cert}/${domain_cert}_ecc
  cd ${path_cert}/${domain_cert}_ecc
  openssl genrsa -out "${domain_cert}.key" 1024
  openssl req -new -x509 -days 3650 -key "${domain_cert}.key" -out "fullchain.cer" -subj "/CN=${domain_cert}"
else
  path_cert="/opt/tool/cert/"

  # Check if certs already exist (persistence in Docker)
  if [ ! -f "${path_cert}/${domain_cert}_ecc/fullchain.cer" ]; then
      mkdir -p "${path_cert}" "${HOME}/.acme.sh/"

      # Install acme.sh if missing
      if [ ! -f "${HOME}/.acme.sh/acme.sh" ]; then
          cd /tmp/
          git clone https://github.com/acmesh-official/acme.sh.git
          cd /tmp/acme.sh/
          ./acme.sh --install --cert-home "${path_cert}" --log "${HOME}/.acme.sh/acme.sh.log" --log-level 2
      fi

      . "${HOME}/.acme.sh/acme.sh.env"
      export LE_WORKING_DIR="${HOME}/.acme.sh"
      "${HOME}/.acme.sh/acme.sh" --set-default-ca --server letsencrypt
      "${HOME}/.acme.sh/acme.sh" --issue -d "${domain_cert}" --webroot "${webroot}"
      "${HOME}/.acme.sh/acme.sh" --upgrade --auto-upgrade
  fi
fi

# xray
path_xray=/opt/tool/xray/
path_down=/opt/tool/download/
mkdir -p ${path_xray}
mkdir -p ${path_down}

# Download Xray if not present
if [ ! -f "${path_xray}/xray" ]; then
    cd ${path_down}
    ver_xray=25.6.8
    wget "https://github.com/XTLS/Xray-core/releases/download/v${ver_xray}/Xray-linux-64.zip" -O "Xray-linux-64-${ver_xray}.zip"
    unzip -o -d "${path_xray}" "Xray-linux-64-${ver_xray}.zip"
fi

cd ${path_xray}
cat > xs.json << EOF
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

# wan ip
ip1=`curl ipinfo.io/ip  -s | tr -d '\n'`
ip2=`curl api.ipify.org -s | tr -d '\n'`
[ "$ip1" == "$ip2" ] && ip_wan=$ip1 || ip_wan=0.0.0.0
[ "$domain_xray" = "localhost" ] && { target_xray=$ip_wan; allow_insecure=1; } || { target_xray=$domain_xray; allow_insecure=0; }
echo -e "\n\n\n[+] Success:\ntrojan://${pass_xray}@${target_xray}:${port_xray}?security=tls&sni=${domain_xray}&alpn=h2%2Chttp%2F1.1&fp=randomized&type=tcp&headerType=none&allowInsecure=${allow_insecure}#trojan_temp"

# Run
if [ "$IS_DOCKER" -eq 0 ]; then
    nohup ./xray run -c xs.json &
    add_cron_once() {
      entry="$1"
      (crontab -l 2>/dev/null | grep -Fxq "$entry") || \
        (crontab -l 2>/dev/null; echo "$entry") | crontab -
    }
    add_cron_once '@reboot nohup /opt/tool/xray/xray run -c /opt/tool/xray/xs.json &'
else
    # Docker: Run in foreground
    exec ./xray run -c xs.json
fi
