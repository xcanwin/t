#!/bin/bash
# Two modes, both end up borrowing a TLS handshake from a real site:
#
#   MODE=self   (default)  Borrow your own site. Needs a domain whose A/AAAA
#                          record points here, a cert, and a local nginx. The
#                          name a client claims then really does resolve here.
#   MODE=borrow            Borrow someone else's site. No domain, no cert, no
#                          nginx, but the claimed name resolves elsewhere.
#                          Pick a TLS1.3 + H2 site, ideally in the same ASN.
#                          Never a shared CDN, or this box relays for others.
# Command:
# bash -c "`curl -fsSL https://github.com/xcanwin/t/raw/main/t.sh`"

set -euo pipefail

ver_xray=26.2.6

# Profile. The whole scheme is defined by these four; swap them here when it
# needs replacing, nothing else in this file hardcodes it.
p_proto=${P_PROTO:-"vless"}
p_flow=${P_FLOW:-"xtls-rprx-vision"}
p_net=${P_NET:-"raw"}
p_sec=${P_SEC:-"reality"}

# Defaults (env override)
# 443 only; Xray warns that other ports may get the IP blocked.
mode_xray=${MODE_XRAY:-"self"}
domain_xray=${DOMAIN_XRAY:-"localhost"}
domain_cert=${DOMAIN_CERT:-"$domain_xray"}
dest_xray=${DEST_XRAY:-""}
port_xray=${PORT_XRAY:-443}
port_web=${PORT_WEB:-8443}
uuid_xray=${UUID_XRAY:-""}
ver_xray=${VER_XRAY:-"$ver_xray"}

allow_bad=${ALLOW_BAD_DEST:-0}

case "$mode_xray" in self|borrow) ;; *) echo "[x] MODE_XRAY must be self or borrow"; exit 1 ;; esac

# A bad dest is not merely suboptimal. A shared CDN one lets strangers pull
# certificates for unrelated sites through this box -- their traffic, your IP,
# your abuse complaints -- and makes it act like an edge node. One that cannot
# carry a tunnel leaves a running service and a share link that never works.
# Both are worse than not deploying, so stop instead of warning.
bad_dest() {
    if [ "$allow_bad" = "1" ]; then
        echo "[!] ALLOW_BAD_DEST=1 set, continuing anyway"
        return 0
    fi
    echo "[x] Aborting. No config written, no service started."
    echo "    Pick another dest, or re-run with ALLOW_BAD_DEST=1 to override."
    exit 1
}

# Detect Docker
if [ -f /.dockerenv ] || [ "${IS_DOCKER:-0}" = "1" ]; then
    IS_DOCKER=1
else
    IS_DOCKER=0
fi

# Sudo
if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

# A shared CDN edge hands out a different cert per SNI, so anyone could pull
# arbitrary certs through this box and it would behave like an edge node itself.
# A single-site server returns the same cert no matter what SNI is asked for.
dest_cert() {
    timeout 12 openssl s_client -connect "${dest_xray}:443" -servername "$1" </dev/null 2>/dev/null \
        | openssl x509 -noout -subject 2>/dev/null
}
check_dest() {
    own=$(dest_cert "${dest_xray}") || true
    bogus=$(dest_cert "zz$(openssl rand -hex 4).invalid") || true
    if [ -z "$own" ]; then
        echo "[!] dest ${dest_xray}: handshake failed"; return 1
    elif [ "$own" != "$bogus" ]; then
        echo "[!] dest ${dest_xray}: shared CDN edge, pick another"
        echo "    own SNI   -> ${own}"
        echo "    bogus SNI -> ${bogus}"
        return 1
    fi
    return 0
}
# The checks above only say the dest looks reasonable, not that it actually
# works as one. Some sites pass every static check and still fail the handshake
# (oversized certificate records are one known way). So stand a throwaway pair
# up on loopback and push one request through it before committing to anything.
verify_dest() {
    local xr="$1" tgt="$2" sni="$3" url="$4"
    local p k pv pb sd u rc
    p=$(( 20000 + RANDOM % 20000 ))
    k=$("$xr" x25519)
    pv=$(echo "$k" | awk '/PrivateKey:/{print $NF}')
    pb=$(echo "$k" | awk '/^Password/{print $NF}')
    sd=$(openssl rand -hex 8); u=$("$xr" uuid)
    cat > /tmp/xs.try.s.json <<J
{"log":{"loglevel":"error"},
 "inbounds":[{"listen":"127.0.0.1","port":${p},"protocol":"${p_proto}",
  "settings":{"clients":[{"id":"${u}","flow":"${p_flow}"}],"decryption":"none"},
  "streamSettings":{"network":"${p_net}","security":"${p_sec}",
   "${p_sec}Settings":{"target":"${tgt}","serverNames":["${sni}"],"privateKey":"${pv}","shortIds":["${sd}"]}}}],
 "outbounds":[{"protocol":"freedom"}]}
J
    cat > /tmp/xs.try.c.json <<J
{"log":{"loglevel":"error"},
 "inbounds":[{"listen":"127.0.0.1","port":$((p+1)),"protocol":"socks","settings":{"udp":false}}],
 "outbounds":[{"protocol":"${p_proto}","settings":{"vnext":[{"address":"127.0.0.1","port":${p},
   "users":[{"id":"${u}","flow":"${p_flow}","encryption":"none"}]}]},
  "streamSettings":{"network":"tcp","security":"${p_sec}",
   "${p_sec}Settings":{"serverName":"${sni}","fingerprint":"chrome","publicKey":"${pb}","shortId":"${sd}"}}}]}
J
    "$xr" run -c /tmp/xs.try.s.json >/dev/null 2>&1 &
    local sp=$!
    "$xr" run -c /tmp/xs.try.c.json >/dev/null 2>&1 &
    local cp=$!
    sleep 3
    rc=$(curl -sk --max-time 15 --socks5-hostname "127.0.0.1:$((p+1))" -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true)
    kill "$sp" "$cp" 2>/dev/null || true
    rm -f /tmp/xs.try.s.json /tmp/xs.try.c.json
    if [ "${rc:-000}" = "000" ]; then
        echo "[!] dest ${sni}: passes the static checks but no traffic gets through it."
        echo "    A tunnel built on it could not complete a handshake. Pick another dest."
        return 1
    fi
    return 0
}

[ "${1:-}" = "check" ] && {
    check_dest || exit 1
    if [ -x /opt/tool/xray/xray ]; then
        verify_dest /opt/tool/xray/xray "${dest_xray}:443" "${dest_xray}" "https://${dest_xray}/" >/dev/null 2>&1 \
            || verify_dest /opt/tool/xray/xray "${dest_xray}:443" "${dest_xray}" "https://${dest_xray}/" \
            || exit 1
        echo "[*] dest ${dest_xray}: ok"
    else
        echo "[*] dest ${dest_xray}: static checks ok (install first for the live check)"
    fi
    exit 0
}

# Interactive (non-Docker)
if [ "$IS_DOCKER" -eq 0 ]; then
    if [ "$mode_xray" = "self" ]; then
        read -p "Enter xray domain ( Default ${domain_xray} ):" v; [ -n "$v" ] && { domain_xray="$v"; domain_cert="$v"; }; echo
        read -p "Enter cert domain ( Default ${domain_cert} ):" v; [ -n "$v" ] && domain_cert="$v"; echo
    else
        [ -n "$dest_xray" ] || { read -p "Enter dest ( e.g. www.example.com ):" v; dest_xray="$v"; echo; }
    fi
    read -p "Enter xray port ( Default ${port_xray} ):" v; [ -n "$v" ] && port_xray="$v"; echo
fi

# What the client claims (sni), and where the handshake is actually relayed.
if [ "$mode_xray" = "self" ]; then
    sni_xray="$domain_xray"
    target_xray="127.0.0.1:${port_web}"
else
    [ -n "$dest_xray" ] || { echo "[x] DEST_XRAY is required"; exit 1; }
    sni_xray="$dest_xray"
    target_xray="${dest_xray}:443"
    check_dest || bad_dest
fi

# Install libs (non-Docker). nginx is only the local site borrowed in self mode.
if [ "$IS_DOCKER" -eq 0 ]; then
    [ "$mode_xray" = "self" ] && WEB=nginx || WEB=
    if command -v yum &>/dev/null; then
        APT_YUM_OPTIONS="-y --skip-broken"
        if yum install --help 2>&1 | grep -q -- "--skip-unavailable"; then
            APT_YUM_OPTIONS="-y --skip-broken --skip-unavailable"
        fi
        $SUDO yum update -y
        $SUDO yum install epel-release curl wget unzip $WEB tar nano net-tools socat git cronie $APT_YUM_OPTIONS
    elif command -v apt &>/dev/null; then
        APT_YUM_OPTIONS="-y"
        $SUDO apt update
        $SUDO apt install curl wget unzip $WEB tar nano net-tools socat git cron $APT_YUM_OPTIONS
    elif command -v apk &>/dev/null; then
        APT_YUM_OPTIONS="--no-cache"
        $SUDO apk add curl wget unzip $WEB socat git openssl ca-certificates tzdata bash $APT_YUM_OPTIONS
    fi
fi

# OS-specific webroot
if command -v yum &>/dev/null; then # redhat
    webroot="/usr/share/nginx/html"
elif command -v apt &>/dev/null; then # ubuntu
    webroot="/var/www/html"
elif command -v apk &>/dev/null; then # alpine
    webroot="/var/lib/nginx/html"
else
    webroot="/usr/share/nginx/html"
fi

# Paths
$SUDO mkdir -p "/opt/tool/"
$SUDO chown "$(whoami)" "/opt/tool/" || true
if [ "$mode_xray" = "self" ]; then
    $SUDO mkdir -p /run/nginx "${webroot}"
    $SUDO chown "$(whoami)" "${webroot}" || true
fi

# Firewall (Skip in Docker). Port 80 is only for the ACME http-01 challenge.
[ "$mode_xray" = "self" ] && ports_open="80 ${port_xray}" || ports_open="${port_xray}"
if [ "$IS_DOCKER" -eq 0 ]; then
    if command -v firewall-cmd >/dev/null 2>&1 \
       && [[ "$(firewall-cmd --state 2>/dev/null)" == "running" ]]; then
        # firewalld: RHEL / CentOS / Fedora
        for p in $ports_open; do $SUDO firewall-cmd --permanent --add-port=${p}/tcp; done
        $SUDO firewall-cmd --reload
    elif command -v ufw >/dev/null 2>&1 \
       && [[ "$(ufw status 2>/dev/null | awk 'NR==1{print $2}')" == "active" ]]; then
        # ufw: Debian / Ubuntu
        for p in $ports_open; do $SUDO ufw allow ${p}/tcp; done
    fi
fi

if [ "$mode_xray" = "self" ]; then

# Nginx start
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
    pgrep -x nginx >/dev/null || nginx
fi

# Cert
path_cert="/opt/tool/cert"
mkdir -p "${path_cert}/${domain_cert}_ecc"

if [ "$domain_cert" = "localhost" ]; then
    cd "${path_cert}/${domain_cert}_ecc"
    if [ ! -f "${domain_cert}.key" ]; then
        # openssl ecparam -genkey -name prime256v1 -out "${domain_cert}.key"
        openssl ecparam -genkey -name secp384r1 -out "${domain_cert}.key"
        openssl req -new -x509 -days 365 -key "${domain_cert}.key" -out "fullchain.cer" -subj "/CN=${domain_cert}"
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
        "${HOME}/.acme.sh/acme.sh" --set-default-ca --server zerossl
        "${HOME}/.acme.sh/acme.sh" --register-account -m "ssl@${domain_cert}"
        "${HOME}/.acme.sh/acme.sh" --issue -d "${domain_cert}" --webroot "${webroot}" --days 20
        "${HOME}/.acme.sh/acme.sh" --upgrade --auto-upgrade

        # Docker: ensure crond running for renew (optional)
        if [ "$IS_DOCKER" -eq 1 ]; then
            if ! pgrep -x crond >/dev/null 2>&1; then
                crond
            fi
        fi
    fi
fi

# The site to borrow: loopback-only, TLS1.3 + H2, serving the real cert.
if [ -d /etc/nginx/http.d ]; then conf_web=/etc/nginx/http.d/xs.conf; else conf_web=/etc/nginx/conf.d/xs.conf; fi
$SUDO tee "${conf_web}" >/dev/null <<EOF3
server {
    # "listen ... http2" rather than the 1.25.1+ "http2 on;" directive: distro
    # nginx is often older, and the old form still works on new versions.
    listen 127.0.0.1:${port_web} ssl http2;
    server_name ${domain_xray};
    ssl_certificate     ${path_cert}/${domain_cert}_ecc/fullchain.cer;
    ssl_certificate_key ${path_cert}/${domain_cert}_ecc/${domain_cert}.key;
    ssl_protocols TLSv1.3;
    root ${webroot};
    index index.html index.htm;
}
EOF3
$SUDO nginx -t && { $SUDO nginx -s reload 2>/dev/null || $SUDO service nginx reload 2>/dev/null || true; }

fi

# Xray
path_xray="/opt/tool/xray/"
path_down="/opt/tool/download/"
mkdir -p "${path_xray}"
mkdir -p "${path_down}"

# Download Xray
if [ ! -f "${path_xray}/xray" ]; then
    cd "${path_down}"
    curl -fL --retry 3 --retry-delay 2 --connect-timeout 10 \
        "https://github.com/XTLS/Xray-core/releases/download/v${ver_xray}/Xray-linux-64.zip" \
        -o "Xray-linux-64-${ver_xray}.zip"
    unzip -o -d "${path_xray}" "Xray-linux-64-${ver_xray}.zip"
fi

cd "${path_xray}"
chmod +x xray

# Live check, now that the binary exists.
if [ "$mode_xray" = "self" ]; then
    probe_url="https://127.0.0.1:${port_web}/"
else
    probe_url="https://${dest_xray}/"
fi
# Retry once before condemning it: a dest that is merely slow can miss the
# timeout on the first go.
if ! verify_dest "${path_xray}/xray" "${target_xray}" "${sni_xray}" "${probe_url}" >/dev/null 2>&1; then
    echo "[*] dest ${sni_xray}: first attempt failed, retrying once"
    verify_dest "${path_xray}/xray" "${target_xray}" "${sni_xray}" "${probe_url}" || bad_dest
fi

# Key material. Reuse on re-run so existing clients keep working.
if [ -f xs.key ]; then
    . ./xs.key
else
    keys_xray=$(./xray x25519)
    priv_xray=$(echo "$keys_xray" | awk '/PrivateKey:/{print $NF}')
    publ_xray=$(echo "$keys_xray" | awk '/^Password/{print $NF}')
    sid_xray=$(openssl rand -hex 8)
    [ -n "$uuid_xray" ] || uuid_xray=$(./xray uuid)
    umask 077
    cat > xs.key <<EOF2
priv_xray=${priv_xray}
publ_xray=${publ_xray}
sid_xray=${sid_xray}
uuid_xray=${uuid_xray}
EOF2
fi

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
      "protocol": "${p_proto}",
      "settings": {
        "clients": [
          {
            "id": "${uuid_xray}",
            "flow": "${p_flow}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "${p_net}",
        "security": "${p_sec}",
        "${p_sec}Settings": {
          "target": "${target_xray}",
          "serverNames": [ "${sni_xray}" ],
          "privateKey": "${priv_xray}",
          "shortIds": [ "${sid_xray}" ]
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

# Compute link. In self mode the domain resolves here, so use it rather than the
# bare IP: that is the whole point of owning the name.
if [ "$mode_xray" = "self" ] && [ "$domain_xray" != "localhost" ]; then
    host_xray="$domain_xray"
else
    ip1=$(curl -s ipinfo.io/ip | tr -d '\n')
    ip2=$(curl -s api.ipify.org | tr -d '\n')
    [ "$ip1" = "$ip2" ] && host_xray="$ip1" || host_xray="0.0.0.0"
fi
echo -e "\n\n\n[+] Success:\n${p_proto}://${uuid_xray}@${host_xray}:${port_xray}?encryption=none&flow=${p_flow}&security=${p_sec}&sni=${sni_xray}&fp=chrome&pbk=${publ_xray}&sid=${sid_xray}&type=tcp#t_temp"

# A borrowed site that is fine today can move behind a CDN later, so re-check
# daily. Findings are written in full sentences: nobody remembers what this file
# is for six months from now. Only borrow mode needs this; in self mode the site
# is our own nginx and cannot turn into a CDN on its own.
if [ "$mode_xray" = "borrow" ]; then
cat > xs.watch <<EOF2
#!/bin/bash
# Installed by t.sh. Checks daily that the dest is still a safe one to borrow.
d="${dest_xray}"
w=/opt/tool/xray/xs.warn
c(){ timeout 12 openssl s_client -connect "\$d:443" -servername "\$1" </dev/null 2>/dev/null | openssl x509 -noout -subject 2>/dev/null; }
a=\$(c "\$d"); b=\$(c "zz\$(openssl rand -hex 4).invalid")
if [ -z "\$a" ]; then
    sig="OFFLINE"
    msg="The dest '\$d' no longer answers TLS on port 443.
  What this means: this server relays every incoming handshake to the dest, so
    if the dest is gone, this server stops working for everyone.
  What to do: check whether the dest is reachable. If it is gone for good,
    rerun t.sh with a different DEST_XRAY."
elif [ "\$a" != "\$b" ]; then
    sig="CDN:\$b"
    msg="The dest '\$d' has moved behind a shared CDN since this was installed.
  How we know: it used to return the same certificate no matter which name was
    asked for. It now returns different ones, which is what a CDN edge does.
      asked for \$d -> \$a
      asked for a made-up name  -> \$b
  What this means: anyone can now pull certificates for unrelated sites through
    this server, and this server starts behaving like a CDN edge node rather
    than a normal single-site host. Both make it easier to pick out.
  What to do: rerun t.sh with a different DEST_XRAY that is not on a shared CDN.
    Check a candidate first with:  DEST_XRAY=candidate bash t.sh check"
else
    exit 0
fi
# Only record a given problem once, or a daily cron fills the file with copies.
grep -qF "[\$sig]" "\$w" 2>/dev/null || printf '%s [%s]\n  %s\n\n' "\$(date -Is)" "\$sig" "\$msg" >> "\$w"
EOF2
chmod +x xs.watch
[ -s xs.warn ] && { echo "[!] dest problem reported since install, see /opt/tool/xray/xs.warn:"; echo; cat xs.warn; }
fi

# Run
if [ "$IS_DOCKER" -eq 0 ]; then
    nohup ./xray run -c xs.json &
    add_cron_once() {
        entry="$1"
        cur=$(crontab -l 2>/dev/null || true)
        if printf '%s\n' "$cur" | grep -Fxq "$entry"; then
            return 0
        fi
        { [ -n "$cur" ] && printf '%s\n' "$cur"; echo "$entry"; } | crontab -
    }
    add_cron_once '@reboot nohup /opt/tool/xray/xray run -c /opt/tool/xray/xs.json &'
    if [ -x xs.watch ]; then
        add_cron_once '17 6 * * * /opt/tool/xray/xs.watch'
    fi
else
    exec ./xray run -c xs.json
fi
