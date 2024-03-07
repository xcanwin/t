#!/bin/bash
#bash -c "`curl -fsSL https://github.com/xcanwin/t/raw/main/t.sh`"
domain_xray="localhost"
psd="TMPtmp-7"

read -s -p "Enter t password ( Default is ${psd} ):" psd2; [ -n "${psd2}" ] && psd=$psd2;echo;
if command -v yum &> /dev/null; then
  yum -y --skip-broken install epel-release wget unzip nginx tar nano net-tools nginx-all-modules.noarch
elif command -v apt &> /dev/null; then
  apt update; apt -y install wget unzip nginx tar nano net-tools cron
fi

service nginx start
systemctl enable nginx.service

domain_cert=$domain_xray
path_cert=/opt/tool/cert/
mkdir -p ${path_cert}/${domain_cert}_ecc
cd ${path_cert}/${domain_cert}_ecc
openssl genrsa -out "${domain_cert}.key" 2048
openssl req -new -x509 -days 30 -key "${domain_cert}.key" -out "${domain_cert}.cer" -subj "/C=US"

path_xray=/opt/tool/xray/
path_down=/opt/tool/download/
mkdir -p ${path_down}
cd ${path_down}
xrayver=1.8.8
wget "https://github.com/XTLS/Xray-core/releases/download/v${xrayver}/Xray-linux-64.zip" -O "Xray-linux-64-${xrayver}.zip"
unzip -o -d "${path_xray}" "Xray-linux-64-${xrayver}.zip"
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
    }
  ]
}
EOF
nohup ./xray run -c xs.json &
crontab -l | { cat; echo "@reboot nohup /opt/tool/xray/xray run -c /opt/tool/xray/xs.json &"; } | crontab -

ip1=`curl ipinfo.io/ip  -s | tr -d '\n'`
ip2=`curl api.ipify.org -s | tr -d '\n'`
[ "$ip1" == "$ip2" ] && ip=$ip1 || ip=0.0.0.0
[ "$domain_xray" != "localhost" ] && target=$domain_xray || target=$ip
echo -e "\n\n\n[+] Success:\ntrojan://${psd}@${target}:443?security=tls&allowInsecure=1#trojan_temp"
