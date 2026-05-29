# Hysteria2 через цепочку UDP DNAT (LTE-гейт)

Мануал для схемы с несколькими хопами, когда Hysteria2 клиент не может напрямую достучаться до зарубежной ноды. Трафик проходит через цепочку промежуточных серверов по UDP DNAT.

---

## Схема

```
Клиент (Hysteria2)
  │  UDP :9443
  ▼
Хоп 1 — РФ-сервер (например, Selectel с белым списком)
  │  UDP DNAT → Хоп 2
  ▼
Хоп 2 — РФ-сервер2 (что бы не палить селектел сервер зарубежным трафиком)
  │  UDP DNAT → Хоп 3
  ▼
Хоп 3 — Зарубежная нода (Xray / Remnawave)
  │  Hysteria2 inbound
  ▼
Интернет
```

Клиент видит только IP первого хопа. Реальный сервер скрыт за цепочкой.

---

## Хоп 3 — Xray inbound на зарубежной ноде

В Remnawave / Xray добавить inbound:

```json
{
  "tag": "hy2-lte",
  "port": 9443,
  "protocol": "hysteria",
  "settings": {
    "users": [],
    "clients": [],
    "version": 2
  },
  "streamSettings": {
    "network": "hysteria",
    "security": "tls",
    "tlsSettings": {
      "alpn": ["h3"],
      "serverName": "your-node.example.com",
      "certificates": [
        {
          "keyFile": "/etc/letsencrypt/live/your-node.example.com/privkey.pem",
          "certificateFile": "/etc/letsencrypt/live/your-node.example.com/fullchain.pem"
        }
      ]
    },
    "hysteriaSettings": {
      "version": 2
    }
  }
}
```

> `your-node.example.com` — домен зарубежной ноды с TLS-сертификатом.

---

## Хоп 1 — РФ-сервер (принимает клиента, пробрасывает на хоп 2)

```bash
# Включить форвардинг
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv4.conf.all.rp_filter=0
sysctl -w net.ipv4.conf.default.rp_filter=0
sysctl -w net.ipv4.conf.eth0.rp_filter=0

# Очистить старые правила (осторожно на продакшне)
iptables -t nat -F
iptables -F FORWARD

# DNAT: входящий UDP 9443 → хоп 2
iptables -t nat -A PREROUTING \
  -p udp --dport 9443 \
  -j DNAT --to-destination HOP2_IP:9443

iptables -t nat -A POSTROUTING \
  -p udp -d HOP2_IP --dport 9443 \
  -j MASQUERADE

iptables -A FORWARD -p udp -d HOP2_IP --dport 9443 -j ACCEPT
iptables -A FORWARD -p udp -s HOP2_IP --sport 9443 -j ACCEPT
```

> Замени `HOP2_IP` на IP второго хопа (LTE-гейта).

---

## Хоп 2 — РФ-хоп2 (принимает от хопа 1, пробрасывает на зарубежную ноду)

```bash
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv4.conf.all.rp_filter=0
sysctl -w net.ipv4.conf.default.rp_filter=0
sysctl -w net.ipv4.conf.eth0.rp_filter=0

iptables -t nat -F
iptables -F FORWARD

# DNAT: входящий UDP 9443 → зарубежная нода
iptables -t nat -A PREROUTING \
  -p udp --dport 9443 \
  -j DNAT --to-destination HOP3_IP:9443

iptables -t nat -A POSTROUTING \
  -p udp -d HOP3_IP --dport 9443 \
  -j MASQUERADE

iptables -A FORWARD -p udp -d HOP3_IP --dport 9443 -j ACCEPT
iptables -A FORWARD -p udp -s HOP3_IP --sport 9443 -j ACCEPT
```

> Замени `HOP3_IP` на IP зарубежной ноды (хоп 3).

---

## Сохранение правил iptables

После проверки — сохранить правила, чтобы они выжили после перезагрузки:

```bash
apt install -y iptables-persistent
netfilter-persistent save
```

---

## Настройки клиента

```
address    = HOP1_IP     # IP первого хопа (РФ-сервер)
port       = 9443
```

SNI и alpn должны совпадать с сертификатом на **конечной** (третьей) ноде:

```
serverName = your-node.example.com
alpn       = h3
```

---

## Диагностика

### Хоп 1

```bash
iptables -t nat -L -n -v
iptables -L FORWARD -n -v
tcpdump -ni any udp port 9443
```

### Хоп 2

```bash
iptables -t nat -L -n -v
iptables -L FORWARD -n -v
tcpdump -ni any udp port 9443
```

### Хоп 3 (зарубежная нода)

```bash
ss -lunp | grep 9443
tcpdump -ni any udp port 9443
```

---

## Что должно быть видно в tcpdump

**На хопе 1:**
```
client_ip.PORT -> HOP1_IP.9443
HOP1_IP.PORT   -> HOP2_IP.9443
```

**На хопе 2:**
```
HOP1_IP.PORT   -> HOP2_IP.9443
HOP2_IP.PORT   -> HOP3_IP.9443
```

**На хопе 3:**
```
HOP2_IP.PORT   -> HOP3_IP.9443
```

---

## Важно: Selectel NAT

Если первый хоп находится за Selectel Cloud Router / NAT — тестировать нужно с **внешней** сети, не из той же внутренней сети Selectel. UDP hairpin NAT там может не работать.
