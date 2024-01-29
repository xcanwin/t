#!/bin/bash
domain=localhost
read -s -p "Enter password:" psd; [ -z "$psd" ] && psd=t3mp;echo;
ip1=`curl ifconfig.io  -s | tr -d '\n'`
ip2=`curl ipinfo.io/ip -s | tr -d '\n'`
[ "$ip1" == "$ip2" ] && ip=$ip1
[ "$domain" != "localhost" ] && target=$domain || target=$ip
yum -y --skip-broken install epel-release wget unzip nginx tar socat nano
mkdir /ssl/
cd /ssl/
openssl genrsa -out "${domain}.key" 2048
openssl req -new -x509 -days 3650 -key "${domain}.key" -out "${domain}-fullchain.crt" -subj "/C=cn/OU=myorg/O=mycomp/CN=${domain}"
mkdir /opt/tool/
cd /opt/tool/
xrayver=1.8.7
wget "https://github.com/XTLS/Xray-core/releases/download/v${xrayver}/Xray-linux-64.zip" -O "Xray-linux-64-${xrayver}.zip"
unzip "Xray-linux-64-${xrayver}.zip" -d xray
cd xray
cat > xs.json << EOF
{
  "log": {
    "loglevel": "info",
    "dnsLog": false
  },
  "inbounds": [
    {
      "tag": "tj",
      "port": 443,
      "protocol": "trojan",
      "settings": {
        "clients": [
          {
            "password": "${psd}"
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
          "alpn": [
            "http/1.1"
          ],
          "certificates": [
            {
              "certificateFile": "/ssl/${domain}-fullchain.crt",
              "keyFile": "/ssl/${domain}.key"
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
    }
  ]
}
EOF
nohup ./xray run -c xs.json &
crontab -l | { cat; echo "@reboot nohup /opt/tool/xray/xray run -c /opt/tool/xray/xs.json &"; } | crontab --
echo -e "[+] Success:\ntrojan://${psd}@${target}:443?security=tls&allowInsecure=1#trojan_temp"
