# WARP Connector in a container for MikroTik
# Based on Debian Bookworm, installs the official cloudflare-warp package.
# Runs warp-svc without systemd, activates Connector mode using the token from env.

FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

# Cache-buster: GitHub Actions passes run_id here so the apt layer is never
# reused from the gha cache and every build installs the latest cloudflare-warp.
ARG WARP_CACHEBUST=1

# Dependencies + Cloudflare keys + warp package
RUN echo "cachebust=${WARP_CACHEBUST}" && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        curl ca-certificates gnupg lsb-release dbus iproute2 iptables && \
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
        | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ bookworm main" \
        > /etc/apt/sources.list.d/cloudflare-client.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends cloudflare-warp && \
    (dpkg-query -W -f='${Version}' cloudflare-warp > /warp-version || true) && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# WARP state (registrations, config)
VOLUME ["/var/lib/cloudflare-warp"]

# Connection token. Passed via `docker run -e CONNECTOR_TOKEN=...` or through MikroTik envlist
ENV CONNECTOR_TOKEN=""

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
