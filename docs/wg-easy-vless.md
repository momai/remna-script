# WG-Easy + sing-box + VLESS Reality Gateway

Схема: WireGuard-клиент подключается к wg-easy, весь трафик через sing-box (TUN) уходит в VLESS Reality на зарубежную ноду.

```
WireGuard-клиент
  │  WireGuard (UDP 51820)
  ▼
wg-easy (контейнер, 10.8.0.x/24)
  │  policy routing: from 10.8.0.0/24 → table 100 → dev sb-tun
  ▼
sing-box (TUN-интерфейс sb-tun)
  │  VLESS + Reality + XTLS Vision
  ▼
Зарубежная Xray-нода
```

---

## 1. Структура файлов

```bash
mkdir -p ~/wg/sing-box
cd ~/wg
```

```
~/wg/
├── docker-compose.yml
├── wg-easy/          ← данные WireGuard (создаётся автоматически)
└── sing-box/
    └── config.json
```

---

## 2. docker-compose.yml

```yaml
services:
  wg-easy:
    image: ghcr.io/wg-easy/wg-easy:latest
    container_name: wg-easy
    environment:
      - WG_HOST=wg.your-domain.com          # публичный домен или IP сервера
      - WG_DEFAULT_ADDRESS=10.8.0.x
      - WG_DEFAULT_DNS=1.1.1.1
      - WG_ALLOWED_IPS=0.0.0.0/0
      # - PASSWORD_HASH=PUT_HASH_HERE       # рекомендуется для защиты UI
    volumes:
      - ./wg-easy:/etc/wireguard
    ports:
      - "51820:51820/udp"
      - "51821:51821/tcp"                   # Web UI
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv4.conf.all.src_valid_mark=1
    restart: unless-stopped

  sing-box:
    image: ghcr.io/sagernet/sing-box:latest
    container_name: sing-box
    environment:
      - ENABLE_DEPRECATED_LEGACY_DNS_SERVERS=true
    network_mode: host
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    volumes:
      - ./sing-box/config.json:/etc/sing-box/config.json:ro
    command: run -c /etc/sing-box/config.json
    restart: unless-stopped
```

---

## 3. sing-box/config.json

```json
{
  "log": {
    "level": "info"
  },
  "dns": {
    "servers": [
      {
        "tag": "local",
        "address": "1.1.1.1",
        "detour": "direct"
      }
    ],
    "final": "local"
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "sb-tun",
      "address": ["172.19.0.1/30"],
      "mtu": 1500,
      "auto_route": true,
      "auto_redirect": true,
      "strict_route": true,
      "stack": "system"
    }
  ],
  "outbounds": [
    {
      "type": "vless",
      "tag": "vless-out",
      "server": "your-node.example.com",
      "server_port": 443,
      "uuid": "YOUR_UUID",
      "flow": "xtls-rprx-vision",
      "tls": {
        "enabled": true,
        "server_name": "your-node.example.com",
        "utls": {
          "enabled": true,
          "fingerprint": "chrome"
        },
        "reality": {
          "enabled": true,
          "public_key": "YOUR_REALITY_PUBLIC_KEY",
          "short_id": ""
        }
      },
      "packet_encoding": "xudp"
    },
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "auto_detect_interface": true,
    "final": "vless-out"
  }
}
```

Заменить:
- `your-node.example.com` — домен зарубежной Xray-ноды
- `YOUR_UUID` — UUID клиента
- `YOUR_REALITY_PUBLIC_KEY` — публичный ключ Reality

---

## 4. Запуск

```bash
cd ~/wg
docker compose up -d
```

Логи:
```bash
docker compose logs -f sing-box
docker compose logs -f wg-easy
```

---

## 5. Проверка TUN-интерфейса sing-box

```bash
ip a | grep sb-tun
```

Должен появиться интерфейс `sb-tun`.

---

## 6. Policy routing — маршрутизация трафика WireGuard через sing-box

Трафик из подсети WireGuard (`10.8.0.0/24`) нужно завернуть в TUN-интерфейс sing-box.

### Очистка старых правил (если нужно пересоздать)

```bash
ip rule del from 10.8.0.0/24 table 100 2>/dev/null || true
ip route flush table 100

iptables -t nat -D POSTROUTING -s 10.8.0.0/24 -o sb-tun -j MASQUERADE 2>/dev/null || true
iptables -D FORWARD -i wg0 -o sb-tun -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -i sb-tun -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
```

### Добавление маршрутов

```bash
ip rule add from 10.8.0.0/24 table 100
ip route add default dev sb-tun table 100

iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o sb-tun -j MASQUERADE
iptables -A FORWARD -i wg0 -o sb-tun -j ACCEPT
iptables -A FORWARD -i sb-tun -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT
```

---

## 7. Проверка маршрутизации

```bash
ip rule
ip route show table 100
```

Ожидаемый вывод:
```
from 10.8.0.0/24 lookup 100
default dev sb-tun
```

---

## Примечания

- Web UI wg-easy доступен по `http://SERVER_IP:51821`
- Правила iptables и ip rule не переживают перезагрузку — добавь их в systemd-сервис или `/etc/rc.local`
- Если sing-box не стартует, проверь `config.json` командой:
  ```bash
  docker run --rm -v $(pwd)/sing-box/config.json:/etc/sing-box/config.json \
    ghcr.io/sagernet/sing-box:latest check -c /etc/sing-box/config.json
  ```
