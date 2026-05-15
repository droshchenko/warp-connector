#!/usr/bin/env bash
# WARP Connector entrypoint for MikroTik containers
# - НЕ exit при первой ошибке (warp-svc прогревается ~5-10s)
# - retry на connector new и connect
# - watchdog: при разрыве переподключается

log() {
    echo "[warp-entrypoint $(date -u +%H:%M:%S)] $*"
}

cleanup() {
    log "Caught signal, disconnecting and stopping warp-svc..."
    warp-cli --accept-tos disconnect 2>/dev/null || true
    if [ -n "${WARP_PID:-}" ]; then
        kill -TERM "$WARP_PID" 2>/dev/null || true
        wait "$WARP_PID" 2>/dev/null || true
    fi
    exit 0
}
trap cleanup SIGTERM SIGINT

# --- Sanity ---
if [ -z "${CONNECTOR_TOKEN}" ]; then
    log "ERROR: CONNECTOR_TOKEN env is empty. Set via envlist on MikroTik container."
    sleep 30
    exit 1
fi

# --- /dev/net/tun (на Debian не auto-провижится, делаем mknod; CAP_MKNOD есть в MikroTik containers) ---
if [ ! -c /dev/net/tun ]; then
    log "/dev/net/tun missing — creating via mknod c 10 200..."
    mkdir -p /dev/net
    if ! mknod /dev/net/tun c 10 200 2>&1; then
        log "ERROR: mknod failed."
        sleep 30
        exit 3
    fi
    chmod 600 /dev/net/tun
fi
log "/dev/net/tun OK"

# --- D-Bus ---
rm -f /run/dbus/pid /var/run/dbus/pid 2>/dev/null || true
mkdir -p /var/run/dbus
log "Starting dbus-daemon..."
dbus-daemon --system --fork 2>&1 || log "dbus-daemon warning (may already be up)"

# --- warp-svc daemon ---
log "Starting warp-svc..."
warp-svc > /tmp/warp-svc.log 2>&1 &
WARP_PID=$!
log "warp-svc PID=$WARP_PID"

# Wait until daemon socket is reachable. warp-svc нужно ~5-10s чтобы быть полностью готовым.
log "Waiting for warp-svc to be ready..."
sleep 10
for i in $(seq 1 30); do
    if warp-cli --accept-tos status >/dev/null 2>&1; then
        log "warp-svc IPC ready after $((10 + i))s total"
        break
    fi
    sleep 1
done

# --- Register as Connector (idempotent + retries) ---
# При перезапуске контейнера warp-svc может видеть старую registration,
# и connector new падает с "Old registration is still around. Try running warp-cli registration delete".
# Делаем delete сначала (молча, ошибки игнорим), потом connector new.

log "Cleaning old registration (if any)..."
warp-cli --accept-tos registration delete 2>&1 | sed 's/^/  /' || true
sleep 2

REGISTERED=0
for attempt in 1 2 3 4 5; do
    log "Connector registration attempt $attempt/5..."
    OUTPUT=$(warp-cli --accept-tos connector new "${CONNECTOR_TOKEN}" 2>&1)
    RC=$?
    log "Output: $OUTPUT"
    if [ $RC -eq 0 ]; then
        log "Registered as Connector ✓"
        REGISTERED=1
        break
    fi
    # Если "already registered" — тоже считаем успехом
    if echo "$OUTPUT" | grep -qiE "already|exists"; then
        log "Already registered (idempotent)"
        REGISTERED=1
        break
    fi
    # Если "old registration still around" — повторим delete и попробуем снова
    if echo "$OUTPUT" | grep -qi "old registration"; then
        log "Old registration detected, forcing delete..."
        warp-cli --accept-tos registration delete 2>&1 | sed 's/^/  /' || true
        sleep 3
    fi
    log "Attempt failed, sleep 10s..."
    sleep 10
done

if [ $REGISTERED -ne 1 ]; then
    log "WARN: Could not register. Continuing — maybe registration is from prior run."
fi

# --- Connect with retries ---
for attempt in 1 2 3 4 5; do
    log "Connect attempt $attempt/5..."
    OUTPUT=$(warp-cli --accept-tos connect 2>&1)
    RC=$?
    log "Output: $OUTPUT"
    if [ $RC -eq 0 ]; then
        log "Connect succeeded ✓"
        break
    fi
    sleep 10
done

sleep 5
log "Final status:"
warp-cli --accept-tos status 2>&1 || true

# --- NAT MASQUERADE on WARP interface (so traffic from LAN→container→WARP gets back) ---
# Wait for CloudflareWARP interface to exist, then add MASQUERADE if not already present.
for i in $(seq 1 30); do
    if ip link show CloudflareWARP >/dev/null 2>&1; then
        log "CloudflareWARP iface present after ${i}s"
        break
    fi
    sleep 1
done

if ip link show CloudflareWARP >/dev/null 2>&1; then
    # Outbound: LAN → Internet через WARP (selective voip routing)
    # MikroTik MANGLE-маркирует voip-трафик и маршрутизирует на этот контейнер;
    # MASQUERADE на CloudflareWARP перепишет источник на 100.96.0.18 для возврата ответов.
    # Для INBOUND mesh-доступа (WARP-Client → LAN) используется cloudflared tunnel
    # с привязанным CIDR route — этот контейнер inbound не обслуживает.
    if ! iptables -t nat -C POSTROUTING -o CloudflareWARP -j MASQUERADE 2>/dev/null; then
        log "Adding MASQUERADE on CloudflareWARP (outbound voip)..."
        iptables -t nat -A POSTROUTING -o CloudflareWARP -j MASQUERADE && log "Outbound MASQUERADE OK" || log "Outbound MASQUERADE FAILED"
    else
        log "Outbound MASQUERADE already present"
    fi
else
    log "WARN: CloudflareWARP iface never appeared, skipping MASQUERADE"
fi

# --- Watchdog loop: keep container alive, reconnect if disconnected ---
log "Entering watchdog loop (60s interval)..."
while true; do
    sleep 60

    # If warp-svc died — exit so MikroTik restarts container
    if ! kill -0 "$WARP_PID" 2>/dev/null; then
        log "ERROR: warp-svc died. Exiting so container can restart."
        exit 4
    fi

    STATUS=$(warp-cli --accept-tos status 2>&1 || true)
    if echo "$STATUS" | grep -qi "Connected"; then
        # Healthy. Re-add MASQUERADE if missing (after reconnect interface may reset).
        if ip link show CloudflareWARP >/dev/null 2>&1 \
           && ! iptables -t nat -C POSTROUTING -o CloudflareWARP -j MASQUERADE 2>/dev/null; then
            log "MASQUERADE missing after reconnect, re-adding..."
            iptables -t nat -A POSTROUTING -o CloudflareWARP -j MASQUERADE 2>&1 || true
        fi
    else
        log "Not connected. Status: $STATUS — reconnecting..."
        warp-cli --accept-tos connect 2>&1 || true
    fi
done
