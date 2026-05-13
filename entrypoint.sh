#!/usr/bin/env bash
# WARP Connector entrypoint for MikroTik containers
# Starts D-Bus + warp-svc, accepts TOS, registers as Connector with CONNECTOR_TOKEN, connects.

set -e

log() {
    echo "[warp-entrypoint $(date -u +%H:%M:%S)] $*"
}

cleanup() {
    log "Caught signal, disconnecting and stopping warp-svc..."
    warp-cli --accept-tos disconnect 2>/dev/null || true
    if [ -n "$WARP_PID" ]; then
        kill -TERM "$WARP_PID" 2>/dev/null || true
        wait "$WARP_PID" 2>/dev/null || true
    fi
    exit 0
}
trap cleanup SIGTERM SIGINT

# --- Sanity ---
if [ -z "${CONNECTOR_TOKEN}" ]; then
    log "ERROR: CONNECTOR_TOKEN env is empty. Set it via -e CONNECTOR_TOKEN=... or MikroTik envlist."
    exit 1
fi

# --- /dev/net/tun ---
# На Debian char-устройство НЕ создаётся автоматически. Создаём руками (нужен CAP_MKNOD — есть в MikroTik containers).
# Bind-mount /dev/net/tun из хоста НЕ работает на MikroTik, потому что хост не имеет реального tun-device — будет каталог-заглушка.
if [ ! -c /dev/net/tun ]; then
    log "/dev/net/tun missing — creating via mknod (c 10 200)..."
    mkdir -p /dev/net
    if mknod /dev/net/tun c 10 200 2>&1; then
        chmod 600 /dev/net/tun
        log "Created /dev/net/tun"
    else
        log "ERROR: mknod failed. Без CAP_MKNOD контейнер не сможет запустить WARP."
        exit 3
    fi
else
    log "/dev/net/tun already present"
fi

# --- D-Bus ---
mkdir -p /var/run/dbus
if [ ! -S /var/run/dbus/system_bus_socket ]; then
    log "Starting dbus-daemon..."
    dbus-daemon --system --fork
fi

# --- warp-svc daemon ---
log "Starting warp-svc..."
warp-svc &
WARP_PID=$!

# Wait until warp-cli can talk to the daemon
for i in $(seq 1 30); do
    if warp-cli --accept-tos status >/dev/null 2>&1; then
        log "warp-svc ready after ${i}s"
        break
    fi
    sleep 1
done
if ! warp-cli --accept-tos status >/dev/null 2>&1; then
    log "ERROR: warp-svc did not become ready in 30s. Exiting."
    exit 2
fi

# --- Register as Connector (idempotent) ---
log "Current status:"
warp-cli --accept-tos status || true

# Если уже зарегистрирован — пропускаем
if warp-cli --accept-tos registration show 2>/dev/null | grep -q "Account ID"; then
    log "Already registered, skipping connector new."
else
    log "Registering as Connector..."
    warp-cli --accept-tos connector new "${CONNECTOR_TOKEN}"
fi

# --- Connect ---
log "Connecting..."
warp-cli --accept-tos connect

sleep 3
log "Final status:"
warp-cli --accept-tos status || true

# Hold container until warp-svc exits
wait "$WARP_PID"
