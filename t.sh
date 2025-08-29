#!/bin/bash
# Requirements:
# 1. Set the DNS A record for domain to IPv4
# 2. Set the DNS AAAA record for domain to IPv6
# Command:
# bash -c "`curl -fsSL https://github.com/xcanwin/t/raw/main/t.sh`"

domain_xray="localhost"
port_xray=8443
pass_xray="TMPtmp-7"

# init
read -p "Enter xray domain ( Default is ${domain_xray} ):" domain_xray2; [ -n "${domain_xray2}" ] && domain_xray=$domain_xray2;echo;
read -p "Enter xray port ( Set above 1024. Default is ${port_xray} ):" port_xray2; [ -n "${port_xray2}" ] && port_xray=$port_xray2;echo;
read -s -p "Enter xray password ( Default is ${pass_xray} ):" pass_xray2; [ -n "${pass_xray2}" ] && pass_xray=$pass_xray2;echo;
if command -v yum &> /dev/null; then
  sudo yum update -y; sudo yum -y --skip-broken install epel-release wget unzip nginx tar nano net-tools nginx-all-modules.noarch socat git cronie
  webroot="/usr/share/nginx/html"
elif command -v apt &> /dev/null; then
  sudo apt update; sudo apt -y install wget unzip nginx tar nano net-tools socat git cronie
  webroot="/var/www/html"
fi

# nginx
sudo service nginx start
sudo systemctl enable nginx.service

# chown
sudo mkdir -p "/opt/tool/" "${webroot}"
sudo chown $(whoami) "/opt/tool/" "${webroot}"

# cert
domain_cert=$domain_xray
path_cert="/opt/tool/cert/"
if [ "$domain_xray" = "localhost" ]; then
  mkdir -p ${path_cert}/${domain_cert}_ecc
  cd ${path_cert}/${domain_cert}_ecc
  openssl genrsa -out "${domain_cert}.key" 1024
  openssl req -new -x509 -days 3650 -key "${domain_cert}.key" -out "fullchain.cer" -subj "/CN=${domain_cert}"
else
  path_cert="/opt/tool/cert/"

  mkdir -p "${path_cert}" "${HOME}/.acme.sh/"
  cd /tmp/
  git clone https://github.com/acmesh-official/acme.sh.git
  cd /tmp/acme.sh/
  ./acme.sh --install --cert-home "${path_cert}" --log "${HOME}/.acme.sh/acme.sh.log" --log-level 2
  . "${HOME}/.acme.sh/acme.sh.env"
  export LE_WORKING_DIR="${HOME}/.acme.sh"
  "${HOME}/.acme.sh/acme.sh" --set-default-ca --server letsencrypt
  "${HOME}/.acme.sh/acme.sh" --issue -d "${domain_cert}" --webroot "${webroot}"
  "${HOME}/.acme.sh/acme.sh" --upgrade --auto-upgrade
fi

# xray
path_xray=/opt/tool/xray/
path_down=/opt/tool/download/
mkdir -p ${path_xray}
mkdir -p ${path_down}
cd ${path_down}
ver_xray=25.6.8
wget "https://github.com/XTLS/Xray-core/releases/download/v${ver_xray}/Xray-linux-64.zip" -O "Xray-linux-64-${ver_xray}.zip"
unzip -o -d "${path_xray}" "Xray-linux-64-${ver_xray}.zip"
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
    "settings": {
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
}
EOF
nohup ./xray run -c xs.json &
add_cron_once() {
  entry="$1"
  (crontab -l 2>/dev/null | grep -Fxq "$entry") || \
    (crontab -l 2>/dev/null; echo "$entry") | crontab -
}
add_cron_once '@reboot nohup /opt/tool/xray/xray run -c /opt/tool/xray/xs.json &'


# wan ip
ip1=`curl ipinfo.io/ip  -s | tr -d '\n'`
ip2=`curl api.ipify.org -s | tr -d '\n'`
[ "$ip1" == "$ip2" ] && ip_wan=$ip1 || ip_wan=0.0.0.0
[ "$domain_xray" = "localhost" ] && { target_xray=$ip_wan; allow_insecure=1; } || { target_xray=$domain_xray; allow_insecure=0; }
echo -e "\n\n\n[+] Success:\ntrojan://${pass_xray}@${target_xray}:${port_xray}?security=tls&sni=${domain_xray}&fp=randomized&allowInsecure=${allow_insecure}#trojan_temp"
