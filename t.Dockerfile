# Build:
# docker build -t xcanwin/t:latest -f t.Dockerfile .
# docker image prune -f

# Run (domain: localhost):
# docker run -d --name xt -p 8443:8443 -p 80:80 xcanwin/t:latest

# Run (domain: real domain):
# docker run -d --name xt -p 8443:8443 -p 80:80 -e DOMAIN_XRAY=your.domain.com -e DOMAIN_CERT=your.domain.com -e PORT_XRAY=8443 -e PASS_XRAY=TMPtmp-7 -v certs:/opt/tool/cert -v acme:/root/.acme.sh xcanwin/t:latest

FROM alpine:latest AS builder
ARG VER_XRAY=25.12.8
RUN apk add --no-cache wget unzip
RUN wget "https://github.com/XTLS/Xray-core/releases/download/v${VER_XRAY}/Xray-linux-64.zip" -O /tmp/xray.zip --progress=dot:mega && \
    unzip -o -d /tmp/xray /tmp/xray.zip

FROM alpine:latest
ENV IS_DOCKER=1 \
    DOMAIN_XRAY=localhost \
    DOMAIN_CERT= \
    PORT_XRAY=8443 \
    PASS_XRAY=TMPtmp-7 \
    VER_XRAY="$VER_XRAY" \
    TZ=UTC

# Install dependencies
RUN apk add --no-cache curl wget unzip nginx socat git openssl ca-certificates tzdata bash && \
    ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone && \
    mkdir -p /run/nginx /opt/tool/t /opt/tool/xray /opt/tool/cert

# Copy Xray
COPY --from=builder /tmp/xray /opt/tool/xray
RUN chmod +x /opt/tool/xray/xray

# Copy script
COPY t.sh /opt/tool/t/t.sh
RUN chmod +x /opt/tool/t/t.sh

WORKDIR /opt/tool/t

EXPOSE 80 8443

# Healthcheck: check xray port is listening
# HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 CMD nc -z 127.0.0.1 ${PORT_XRAY} || exit 1

CMD ["/opt/tool/t/t.sh"]
