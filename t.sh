#!/bin/bash
# First: DNS: domain -> ip
# sudo bash -c "`curl -fsSL https://github.com/xcanwin/t/raw/main/t.sh`"

domain_xray="localhost"
pass_xray="TMPtmp-7"

# init
read -s -p "Enter xray domain ( Default is ${domain_xray} ):" domain_xray2; [ -n "${domain_xray2}" ] && domain_xray=$domain_xray2;echo;
read -s -p "Enter xray password ( Default is ${pass_xray} ):" pass_xray2; [ -n "${pass_xray2}" ] && pass_xray=$pass_xray2;echo;
if command -v yum &> /dev/null; then
  yum -y --skip-broken install epel-release wget unzip nginx tar nano net-tools nginx-all-modules.noarch socat
  webroot="/usr/share/nginx/html"
elif command -v apt &> /dev/null; then
  apt update; apt -y install wget unzip nginx tar nano net-tools cron socat
  webroot="/var/www/html"
fi

# nginx
service nginx start
systemctl enable nginx.service
service_name="trojan"
if ! grep -q "include /etc/nginx/stream.d/" "/etc/nginx/nginx.conf"; then
  mkdir -p /etc/nginx/stream.d/
  cat >> /etc/nginx/nginx.conf << EOF
stream {
  include /etc/nginx/stream.d/*.conf;
}
EOF
fi
cat > /etc/nginx/stream.d/${service_name}.conf << EOF
upstream ${service_name} {
  server 127.0.0.2:81;
}
server {
  listen 443;
  proxy_pass ${service_name};
}
EOF
service nginx force-reload

# cert
domain_cert=$domain_xray
path_cert=/opt/tool/cert/
if [ "$domain_xray" = "localhost" ]; then
  mkdir -p ${path_cert}/${domain_cert}_ecc
  cd ${path_cert}/${domain_cert}_ecc
  openssl genrsa -out "${domain_cert}.key" 1024
  openssl req -new -x509 -days 3650 -key "${domain_cert}.key" -out "fullchain.cer" -subj "/CN=${domain_cert}"
else
  path_acme=/opt/tool/acmesh/
  mkdir -p $path_cert
  mkdir -p $path_acme
  curl -L https://get.acme.sh | sh -s home "${path_acme}" --cert-home "${path_cert}"
  source ~/.bashrc
  $path_acme/acme.sh --set-default-ca --server letsencrypt
  $path_acme/acme.sh --issue -d "${domain_cert}" --webroot "${webroot}"
  $path_acme/acme.sh --upgrade --auto-upgrade
fi

# xray
path_xray=/opt/tool/xray/
path_down=/opt/tool/download/
mkdir -p ${path_xray}
mkdir -p ${path_down}
cd ${path_down}
ver_xray=1.8.8
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
      "listen": "127.0.0.2",
      "port": 81,
      "protocol": "trojan",
      "settings": {
        "clients": [
          {
            "password": "${pass_xray}"
          }
        ],
        "fallbacks": [
          {
            "dest": 80
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
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
      "tag": "ss",
      "protocol": "shadowsocks",
      "settings": {
        "servers": [
          {
            "address": "server_wan._.com",
            "port": 443,
            "method": "2022-blake3-chacha20-poly1305",
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
          "outboundTag": "ss",
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
crontab -l | { cat; echo "@reboot nohup /opt/tool/xray/xray run -c /opt/tool/xray/xs.json &"; } | crontab -

# wan ip
ip1=`curl ipinfo.io/ip  -s | tr -d '\n'`
ip2=`curl api.ipify.org -s | tr -d '\n'`
[ "$ip1" == "$ip2" ] && ip_wan=$ip1 || ip_wan=0.0.0.0
[ "$domain_xray" = "localhost" ] && ( target_xray=$ip_wan; allow_insecure=1; ) || ( target_xray=$domain_xray; allow_insecure=0; )
echo -e "\n\n\n[+] Success:\ntrojan://${pass_xray}@${target_xray}:443?security=tls&sni=${domain_xray}&fp=randomized&allowInsecure=${allow_insecure}#trojan_temp"
