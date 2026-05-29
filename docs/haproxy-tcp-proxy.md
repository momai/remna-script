# HAProxy как TCP-прокси на РФ-ноде

Вариант для случая, когда не хочется ставить полноценную Xray-ноду на российский сервер. HAProxy просто принимает TCP на порту 443 и пробрасывает всё напрямую на зарубежный Xray-сервер.

```
Клиент → РФ-нода :443 (HAProxy) → Зарубежная Xray-нода :443
```

В клиенте указывается IP РФ-ноды, а всё TLS/Reality-рукопожатие происходит уже с зарубежным сервером. РФ-нода только прозрачно проксирует TCP.

---

## Скрипт установки

Сохрани и запусти от root:

```bash
#!/usr/bin/env bash
set -euo pipefail

read -rp "Введите IP зарубежного Xray сервера: " DEST_IP
if [ -z "$DEST_IP" ]; then
  echo "Ошибка: IP не указан"
  exit 1
fi

read -rp "Введите destination port [443]: " DEST_PORT
DEST_PORT="${DEST_PORT:-443}"

if ! [[ "$DEST_PORT" =~ ^[0-9]+$ ]]; then
  echo "Ошибка: порт должен быть числом"
  exit 1
fi

echo
echo "Настройка: :443 -> ${DEST_IP}:${DEST_PORT}"
echo

export DEBIAN_FRONTEND=noninteractive
apt update && apt install -y haproxy

CFG="/etc/haproxy/haproxy.cfg"
BACKUP="/etc/haproxy/haproxy.cfg.bak.$(date +%F-%H%M%S)"

[ -f "$CFG" ] && cp "$CFG" "$BACKUP" && echo "Backup: $BACKUP"

cat > "$CFG" <<CONFIG
global
    log /dev/log local0
    log /dev/log local1 notice
    daemon
    maxconn 100000

defaults
    log global
    mode tcp
    option tcplog
    timeout connect 10s
    timeout client 1m
    timeout server 1m

frontend vless_reality_front
    bind 0.0.0.0:443
    default_backend vless_reality_back

backend vless_reality_back
    server foreign_xray ${DEST_IP}:${DEST_PORT} check
CONFIG

haproxy -c -f "$CFG"

systemctl enable haproxy
systemctl restart haproxy

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q active; then
  ufw allow 443/tcp
fi

echo
echo "=== RESULT ==="
ss -tulpn | grep :443 || true
systemctl --no-pager status haproxy || true
echo
echo "Готово. В клиенте ставь:"
echo "  address = IP этой РФ-ноды"
echo "  port    = 443"
```

---

## Проверка

```bash
# Статус HAProxy
systemctl status haproxy

# Слушает ли порт 443
ss -tulpn | grep :443

# Текущие соединения
echo "show info" | socat stdio /run/haproxy/admin.sock
```

---

## Конфиг вручную

Если нужно отредактировать после установки:

```bash
nano /etc/haproxy/haproxy.cfg
haproxy -c -f /etc/haproxy/haproxy.cfg   # проверка синтаксиса
systemctl restart haproxy
```

---

## Настройки клиента

```
address = <IP РФ-ноды с HAProxy>
port    = 443
```

Всё остальное (UUID, Reality public key, serverName) — от зарубежного Xray-сервера, как обычно.

---

## Когда это полезно

- Хочется использовать дешёвый российский сервер как входную точку, не устанавливая Xray
- Зарубежная нода уже настроена, нужен только проброс
- Быстрое решение без сертификатов и сложной конфигурации на РФ-стороне
