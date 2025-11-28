# Build:
# docker build -t xcanwin/t:latest -f t.Dockerfile .
# docker image prune -f

# Run:
# docker run -d --name xt --restart=always -p 8443:8443 xcanwin/t:latest
# or
# docker run -d --name xt --restart=always -p 8443:8443 -p 80:80 -e DOMAIN_XRAY=localhost -e PORT_XRAY=8443 -e PASS_XRAY=TMPtmp-8 xcanwin/t:latest


# Stage 1: Builder
FROM alpine:latest AS builder
ARG VER_XRAY=25.10.15
RUN apk add --no-cache curl unzip
RUN curl -L -H "Cache-Control: no-cache" -o /tmp/xray.zip \
    "https://github.com/XTLS/Xray-core/releases/download/v${VER_XRAY}/Xray-linux-64.zip" \
    && unzip /tmp/xray.zip -d /tmp/xray

# Stage 2: Final
FROM alpine:latest

# Install dependencies
RUN apk add --no-cache \
    bash \
    nginx \
    openssl \
    curl \
    socat \
    ca-certificates \
    tzdata \
    && mkdir -p /run/nginx /opt/tool/t /opt/tool/xray /opt/tool/cert /usr/share/nginx/html \
    # Install acme.sh
    && curl https://get.acme.sh | sh

# Copy Xray binary only (exclude dat files to save space)
COPY --from=builder /tmp/xray/ /opt/tool/xray/
RUN chmod +x /opt/tool/xray/xray

# Copy t
COPY t.sh /opt/tool/t/t.sh
RUN chmod +x /opt/tool/t/t.sh

# Expose ports
EXPOSE 80 8443

# Environment variables with defaults
ENV IS_DOCKER=1 \
    DOMAIN_XRAY=localhost \
    PORT_XRAY=8443 \
    PASS_XRAY=TMPtmp-7 \
    DOMAIN_CERT=localhost

WORKDIR /opt/tool/t
ENTRYPOINT ["/opt/tool/t/t.sh"]
