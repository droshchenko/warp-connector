# WARP Connector в контейнере для MikroTik
# Базируется на Debian Bookworm, ставит официальный cloudflare-warp package.
# Запускает warp-svc без systemd, активирует Connector mode по токену из env.

FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

# Зависимости + ключи Cloudflare + warp пакет
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        curl ca-certificates gnupg lsb-release dbus iproute2 iptables && \
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
        | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ bookworm main" \
        > /etc/apt/sources.list.d/cloudflare-client.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends cloudflare-warp && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Состояние WARP (registrations, конфиг)
VOLUME ["/var/lib/cloudflare-warp"]

# Токен подключения. Передаётся при `docker run -e CONNECTOR_TOKEN=...` или через MikroTik envlist
ENV CONNECTOR_TOKEN=""

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
