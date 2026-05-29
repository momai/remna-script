# Selfsteal + пример конфига Xray для роутинга

Мануал показывает, как связать selfsteal-nginx с Xray-inbound на VLESS Reality, и как настроить роутинг, чтобы нода пропускала трафик через другой Xray-сервер.

---

## Схема

```
Клиент
  │  VLESS + Reality (443)
  ▼
Xray-inbound (порт 443)
  │  dest: localhost:22253
  ▼
selfsteal nginx (порт 22253, HTTPS)
  │  отдаёт заглушку
  ▼
(если роутинг) → Xray-outbound → другой Xray-сервер
```

---

## 1. nginx для selfsteal

Этот конфиг создаётся автоматически при запуске `selfsteal.sh`. Приведён для справки.

```nginx
server {
    listen 22253 ssl;
    http2 on;

    server_name example.org;

    ssl_certificate     /etc/letsencrypt/live/example.org/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/example.org/privkey.pem;

    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    root /usr/share/nginx/html;
    index index.html;

    location / {
        try_files $uri $uri/ =404;
    }
}
```

> `22253` — внутренний порт nginx (задаётся через `SELFS_PORT`).  
> Xray смотрит в `dest: "22253"`, то есть пробрасывает TLS-handshake на этот nginx.

---

## 2. Xray inbound — VLESS Reality с selfsteal

```json
{
  "inbounds": [
    {
      "tag": "vless-reality",
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [],
        "decryption": "none",
        "packetEncoding": "xudp"
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "dest": "22253",
          "show": false,
          "xver": 0,
          "shortIds": [""],
          "privateKey": "YOUR_PRIVATE_KEY",
          "fingerprint": "chrome",
          "serverNames": [
            "example.org"
          ]
        }
      }
    }
  ]
}
```

- `dest: "22253"` — selfsteal nginx слушает на этом порту
- `serverNames` — домен, на который выписан TLS-сертификат selfsteal
- `privateKey` — приватный ключ Reality (генерируется командой `xray x25519`)

---

## 3. Xray outbound + роутинг (опционально)

Если нода должна не просто принимать клиентов, а перенаправлять их трафик на другой Xray-сервер (например, основную зарубежную ноду):

```json
{
  "outbounds": [
    {
      "tag": "TO-VLESS-REALITY",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "DESTINATION_SERVER_IP",
            "port": 443,
            "users": [
              {
                "id": "YOUR_UUID",
                "flow": "xtls-rprx-vision",
                "encryption": "none"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "shortId": "",
          "publicKey": "DESTINATION_PUBLIC_KEY",
          "serverName": "destination-domain.example.com",
          "fingerprint": "chrome"
        }
      }
    }
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "inboundTag": ["vless-reality"],
        "outboundTag": "TO-VLESS-REALITY"
      }
    ]
  }
}
```

- `DESTINATION_SERVER_IP` — IP зарубежной Xray-ноды
- `YOUR_UUID` — UUID клиента на той ноде
- `DESTINATION_PUBLIC_KEY` — публичный ключ Reality зарубежной ноды
- `destination-domain.example.com` — serverName зарубежной ноды (selfsteal-домен той ноды)

---

## 4. Генерация ключей Reality

```bash
# Через xray
xray x25519

# Через remnanode в Docker
docker exec remnanode xray x25519
```

Вывод:
```
Private key: <PRIVATE_KEY>
Public key:  <PUBLIC_KEY>
```

`privateKey` — в inbound на этой ноде.  
`publicKey` — передать клиентам и в outbound другой ноды.
