[🇺🇸 English](README.md) | [🇷🇺 Русский](README.ru.md)

# WARP Connector in Docker container for MikroTik

Experimental build of the official `cloudflare-warp` to run in the MikroTik container engine (RouterOS v7.x).

✅ **Pre-check passed** (tested on RouterOS 7.22.3 x86_64):
- `CAP_NET_ADMIN` is present (`CapEff: 0x3ffffffff`)
- `CAP_MKNOD` is present → we can create `/dev/net/tun` manually
- `ip tuntap add` works, the TUN interface is successfully created inside the container

Bind-mounting `/dev/net/tun` via `/container/mounts` **is not required** — the MikroTik host does not have a real tun-device, so mounting it will just create an empty directory. Instead, the entrypoint itself runs `mknod /dev/net/tun c 10 200`.

## Files

- `Dockerfile` — image based on `debian:bookworm-slim` with `cloudflare-warp`
- `entrypoint.sh` — starts D-Bus + warp-svc without systemd, registers as a Connector

## Build

### Option A: Docker on PC (Linux/macOS/Windows with Docker Desktop)

```bash
cd warp-connector
docker buildx build --platform linux/amd64 -t YOUR_DOCKERHUB_USER/warp-connector:latest .
docker push YOUR_DOCKERHUB_USER/warp-connector:latest
```

(Before push: `docker login`.)

### Option B: GitHub Actions → ghcr.io

Create a repository with these files, add `.github/workflows/build.yml`:

```yaml
name: Build & Push
on:
  push:
    branches: [main]
jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      packages: write
    steps:
      - uses: actions/checkout@v4
      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - uses: docker/build-push-action@v5
        with:
          context: .
          platforms: linux/amd64
          push: true
          tags: ghcr.io/${{ github.repository_owner }}/warp-connector:latest
```

After pushing, the image will be available as `ghcr.io/YOUR_USERNAME/warp-connector:latest`.

## Deployment on MikroTik

**Important:** on RouterOS 7.22 CLI `/container/envs/add name=...` and `/container/mounts/add name=...` are buggy (parser bug). Create the env-list parameter via **WebFig GUI** (Container → Envs → New) or directly via `cmd="..."` with the `--token` embedded inside the command.

```routeros
# 1. Create a veth for the WARP container (separate from cloudflared)
/interface veth
add name=veth-warp address=192.168.89.3/24 gateway=192.168.89.1

/interface bridge port
add bridge=containers interface=veth-warp

# 2. Create env via WebFig GUI (Container → Envs → New):
#    List: warp_envs
#    Key:  CONNECTOR_TOKEN
#    Value: <your WARP Connector token from Zero Trust dashboard>

# 3. Create container (mount /dev/net/tun is NOT needed — entrypoint will create it via mknod)
/container
add remote-image=ghcr.io/droshchenko/warp-connector:latest \
    interface=veth-warp \
    root-dir=warp \
    dns=192.168.89.1 \
    envlist=warp_envs \
    start-on-boot=yes \
    logging=yes \
    comment="WARP Connector"

# 4. Wait for download (~1-2 min), then start
/container start [find tag~"warp-connector"]
```

## Debugging

Logs:
```routeros
/log print where topics~"container" and message~"warp"
/container/shell [find tag~"warp-connector"]
# inside the container:
warp-cli --accept-tos status
warp-cli --accept-tos settings
journalctl --no-pager # will not work, no systemd
```

Typical errors:
- `Operation not permitted` when creating tun → MikroTik does not grant NET_ADMIN. Hopeless without a hack.
- `warp-svc not running` → D-Bus or daemon didn't start, check `dmesg` inside the container.
- `Connection refused` to Cloudflare API → DNS inside container. Check `dns=192.168.89.1`.

## Routing traffic through WARP

When WARP is active inside the container, it gets a `CloudflareWARP` interface with an IPv4 from the CGNAT range `100.96.0.0/12`. For your home network to start routing through it, routing on MikroTik is needed:

```routeros
# Mark traffic from LAN to a new routing-table
/ip firewall mangle
add chain=prerouting src-address=192.168.88.0/24 action=mark-routing new-routing-mark=via-warp

# Add a route to this table through the container
/ip route
add dst-address=0.0.0.0/0 gateway=192.168.89.3 routing-table=via-warp comment="Default via WARP"
```

This is completely analogous to what your old disabled `WARP route` (`0 Xs 0.0.0.0/0 WARP`) in `/ip/route/print` did.
