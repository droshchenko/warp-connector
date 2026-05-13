# WARP Connector в Docker-контейнере для MikroTik

Экспериментальная сборка официального `cloudflare-warp` для запуска в MikroTik container engine (RouterOS v7.x).

✅ **Pre-check пройден** (тестировано на RouterOS 7.22.3 x86_64):
- `CAP_NET_ADMIN` есть (`CapEff: 0x3ffffffff`)
- `CAP_MKNOD` есть → можем создать `/dev/net/tun` руками
- `ip tuntap add` работает, TUN-интерфейс успешно создаётся внутри контейнера

Bind-mount `/dev/net/tun` через `/container/mounts` **не нужен** — хост MikroTik не имеет реального tun-device, монт создаст пустой каталог. Вместо этого entrypoint сам делает `mknod /dev/net/tun c 10 200`.

## Файлы

- `Dockerfile` — образ на базе `debian:bookworm-slim` с `cloudflare-warp`
- `entrypoint.sh` — стартует D-Bus + warp-svc без systemd, регистрируется как Connector

## Сборка

### Вариант A: Docker на ПК (Linux/macOS/Windows с Docker Desktop)

```bash
cd warp-connector
docker buildx build --platform linux/amd64 -t YOUR_DOCKERHUB_USER/warp-connector:latest .
docker push YOUR_DOCKERHUB_USER/warp-connector:latest
```

(Перед push: `docker login`.)

### Вариант B: GitHub Actions → ghcr.io

Создайте репозиторий с этими файлами, добавьте `.github/workflows/build.yml`:

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

После пуша образ будет доступен как `ghcr.io/ВАШ_USERNAME/warp-connector:latest`.

## Развёртывание на MikroTik

**Важно:** на RouterOS 7.22 CLI `/container/envs/add name=...` и `/container/mounts/add name=...` глючат (баг парсера). Параметр env-list создавать через **WebFig GUI** (Container → Envs → New) или прямо через `cmd="..."` с `--token` встроенным внутрь команды.

```routeros
# 1. Создать veth для WARP-контейнера (отдельный от cloudflared)
/interface veth
add name=veth-warp address=192.168.89.3/24 gateway=192.168.89.1

/interface bridge port
add bridge=containers interface=veth-warp

# 2. Создать env через WebFig GUI (Container → Envs → New):
#    List: warp_envs
#    Key:  CONNECTOR_TOKEN
#    Value: <ваш WARP Connector token из Zero Trust dashboard>

# 3. Создать контейнер (mount /dev/net/tun НЕ нужен — entrypoint сам создаст через mknod)
/container
add remote-image=ghcr.io/droshchenko/warp-connector:latest \
    interface=veth-warp \
    root-dir=warp \
    dns=192.168.89.1 \
    envlist=warp_envs \
    start-on-boot=yes \
    logging=yes \
    comment="WARP Connector"

# 4. Подождать скачивания (~1-2 мин), запустить
/container start [find tag~"warp-connector"]
```

## Отладка

Логи:
```routeros
/log print where topics~"container" and message~"warp"
/container/shell [find tag~"warp-connector"]
# внутри контейнера:
warp-cli --accept-tos status
warp-cli --accept-tos settings
journalctl --no-pager # не сработает, нет systemd
```

Типичные ошибки:
- `Operation not permitted` при создании tun → MikroTik не даёт NET_ADMIN. Безнадёжно без хака.
- `warp-svc not running` → D-Bus или daemon не стартанули, смотреть `dmesg` внутри контейнера.
- `Connection refused` к API Cloudflare → DNS внутри контейнера. Проверьте `dns=192.168.89.1`.

## Маршрутизация трафика через WARP

Когда WARP активен внутри контейнера, у него появляется `CloudflareWARP` интерфейс с IPv4 из CGNAT-диапазона `100.96.0.0/12`. Чтобы домашняя сеть начала ходить через него, нужна маршрутизация на MikroTik:

```routeros
# Маркируем трафик из LAN в новую routing-table
/ip firewall mangle
add chain=prerouting src-address=192.168.88.0/24 action=mark-routing new-routing-mark=via-warp

# Добавляем маршрут в эту таблицу через контейнер
/ip route
add dst-address=0.0.0.0/0 gateway=192.168.89.3 routing-table=via-warp comment="Default via WARP"
```

Это полностью аналогично тому, что делал ваш старый disabled `WARP route` (`0 Xs 0.0.0.0/0 WARP`) в `/ip/route/print`.
