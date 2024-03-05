#!/bin/bash
#bash -c "`curl -fsSL https://github.com/xcanwin/t/raw/main/t.sh`"
domain=localhost
read -s -p "Enter t password:" psd; [ -z "$psd" ] && psd=TMPtmp-7;echo;
ip1=`curl ipinfo.io/ip -s | tr -d '\n'`
ip2=`curl ifconfig.io  -s | tr -d '\n'`
[ "$ip1" == "$ip2" ] && ip=$ip1 || ip=0.0.0.0
[ "$domain" != "localhost" ] && target=$domain || target=$ip
if command -v yum &> /dev/null; then
    yum -y --skip-broken install epel-release wget unzip nginx tar nano
elif command -v apt &> /dev/null; then
    apt update; apt -y install wget unzip nginx tar nano cron
fi
service nginx start
systemctl enable nginx.service
pcert=/opt/tool/cert/
mkdir -p ${pcert}/${domain}

cd ${pcert}/${domain}
openssl genrsa -out "${domain}.key" 2048
openssl req -new -x509 -days 3650 -key "${domain}.key" -out "fullchain.cer" -subj "/C=cn/OU=myorg/O=mycomp/CN=${domain}"
mkdir -p /opt/tool/
cd /opt/tool/
xrayver=1.8.7
wget "https://github.com/XTLS/Xray-core/releases/download/v${xrayver}/Xray-linux-64.zip" -O "Xray-linux-64-${xrayver}.zip"
unzip -o -d xray "Xray-linux-64-${xrayver}.zip"
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
              "certificateFile": "${pcert}/${domain}/fullchain.cer",
              "keyFile": "${pcert}/${domain}/${domain}.key"
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
crontab -l | { cat; echo "@reboot nohup /opt/tool/xray/xray run -c /opt/tool/xray/xs.json &"; } | crontab -
echo -e "\n\n\n[+] Success:\ntrojan://${psd}@${target}:443?security=tls&allowInsecure=1#trojan_temp"
