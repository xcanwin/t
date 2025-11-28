# Build:
# docker build -t xcanwin/t:latest -f t.Dockerfile .
# docker image prune -f

# Run:
# docker run -d --name xt -p 80:80 -p 8443:8443 xcanwin/t:latest
# or
# docker run -d --name xt -p 8443:8443 xcanwin/t:latest


# Stage 1: Builder
FROM alpine:latest AS builder
ARG VER_XRAY=25.6.8
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
    && mkdir -p /run/nginx /opt/tool/xray /opt/tool/cert /usr/share/nginx/html \
    # Install acme.sh
    && curl https://get.acme.sh | sh

# Copy Xray binary only (exclude dat files to save space)
COPY --from=builder /tmp/xray/xray /opt/tool/xray/xray
RUN chmod +x /opt/tool/xray/xray

# Copy t
COPY t.sh /t.sh
RUN chmod +x /t.sh

# Expose ports
EXPOSE 80 8443

# Environment variables with defaults
ENV IS_DOCKER=1 \
    DOMAIN_XRAY=localhost \
    PORT_XRAY=8443 \
    PASS_XRAY=TMPtmp-7 \
    DOMAIN_CERT=localhost

ENTRYPOINT ["/t.sh"]
