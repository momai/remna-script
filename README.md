# remna-script

Скрипты и мануалы для развёртывания и обслуживания Remnawave / Xray нод.

---

## Содержание

- [selfsteal.sh](#selfstealsh) — автоматическая настройка selfsteal (TLS-сертификат + nginx)
- [Мануалы](#мануалы)
  - [Selfsteal + конфиг Xray для роутинга](docs/selfsteal-xray-routing.md)
  - [HAProxy TCP-прокси на РФ-ноде](docs/haproxy-tcp-proxy.md)
  - [WireGuard + sing-box + VLESS Reality](docs/wg-easy-vless.md)
  - [Hysteria2 через цепочку UDP DNAT](docs/hysteria2-lte-udp-dnat.md)
- [Команды для проверки и тестирования сервера](#команды-для-проверки-и-тестирования-сервера)

---

## selfsteal.sh

Скрипт автоматически:
1. Получает TLS-сертификат через Let's Encrypt (три режима: http-01, dns-01/cloudflare, dns-01/manual)
2. Поднимает nginx-контейнер (selfsteal), который отдаёт поддельную HTML-страницу по HTTPS
3. Прописывает deploy-hook для автоматического перезапуска контейнеров при обновлении сертификата

### Быстрый старт

```bash
curl -fsSL https://raw.githubusercontent.com/momai/remna-script/main/selfsteal.sh -o selfsteal.sh \
  && chmod +x selfsteal.sh \
  && ./selfsteal.sh your.domain.com dns
```

> Замени `your.domain.com` на домен selfsteal, `dns` на нужный режим получения сертификата.

### Режимы

| Режим | Описание |
|-------|----------|
| `http` | http-01 standalone — certbot поднимает временный HTTP-сервер на порту 80. Порт 80 должен быть свободен. |
| `cf`   | dns-01 через Cloudflare API — полностью автоматически, порт 80 не нужен. Требует `/root/.cloudflare.ini`. |
| `dns`  | dns-01 manual — certbot покажет TXT-запись, которую нужно добавить в DNS вручную. Не подходит для авторенью. |

### Синтаксис

```bash
./selfsteal.sh <domain> [mode]

# Примеры:
./selfsteal.sh your.domain.com           # http (по умолчанию)
./selfsteal.sh your.domain.com http      # явно http-01
./selfsteal.sh your.domain.com cf        # Cloudflare dns-01
./selfsteal.sh your.domain.com dns       # manual dns-01
```

### Переменные окружения

| Переменная | По умолчанию | Описание |
|---|---|---|
| `BASE_DIR` | `/opt/selfsteal` | Каталог с файлами nginx и docker-compose |
| `SELFS_PORT` | `22253` | Порт, на котором nginx принимает HTTPS |
| `SELFSTEAL_CONTAINER` | `selfsteal` | Имя Docker-контейнера nginx |
| `REMNANODE_CONTAINER` | `remnanode` | Имя Docker-контейнера Xray-ноды |
| `CERTBOT_EMAIL` | _(пусто)_ | Email для Let's Encrypt (необязательно, но рекомендуется) |
| `CF_CRED_FILE` | `/root/.cloudflare.ini` | Путь к файлу с токеном Cloudflare (режим `cf`) |
| `DNS_PROPAGATION_SECONDS` | `20` | Время ожидания DNS-пропагации (режим `cf`) |

### Cloudflare credentials (режим `cf`)

```ini
# /root/.cloudflare.ini
dns_cloudflare_api_token = YOUR_CF_API_TOKEN
```

```bash
chmod 600 /root/.cloudflare.ini
```

### Что создаётся

```
/opt/selfsteal/
├── docker-compose.yml
└── nginx/
    ├── default.conf       ← конфиг nginx (HTTPS на SELFS_PORT)
    └── html/
        └── index.html     ← заглушка "Just a moment..."

/etc/letsencrypt/renewal-hooks/deploy/remnawave-selfsteal.sh  ← deploy-hook
```

### Xray realitySettings

В настройках Xray-inbound укажи selfsteal как цель:

```json
"realitySettings": {
  "dest": "22253",
  "serverNames": ["your.domain.com"]
}
```

Подробнее с примером полного конфига → [docs/selfsteal-xray-routing.md](docs/selfsteal-xray-routing.md)


## selfsteal-xhttp.sh

Тоже что и selfsteal.sh но нода подключается через сокет.

### Что создаётся

```
/opt/remnanode/nginx-xhttp
├── docker-compose.yml
└── conf.d/
    ├── default.conf       ← конфиг nginx (HTTPS на SELFS_PORT)
    └── html/
        └── index.html     ← заглушка "Just a moment..."

/etc/letsencrypt/renewal-hooks/deploy/remnawave-selfsteal.sh  ← deploy-hook
```

### Xray settings
```json
"tag": "xhttp-direct",
"listen": "/var/run/xray/xhttp.sock,0666",
...
```
Рядом, на 443 порт вы можете посадить vless
```
      "tag": "vless-direct-grpc",
      "port": 443,
```

И настроив подключения, вы сможете реализовать схему, где xray принимает запрос на 443 порт, и в зависимости от конфигурации подключения, роутит его либо на vless, либо на xhttp через nginx.

---

## Мануалы

| Файл | Описание |
|------|----------|
| [docs/selfsteal-xray-routing.md](docs/selfsteal-xray-routing.md) | Конфиги nginx и Xray для selfsteal + пример роутинга |
| [docs/haproxy-tcp-proxy.md](docs/haproxy-tcp-proxy.md) | HAProxy как TCP-прокси — гнать трафик на зарубежный сервер без установки Xray на РФ-ноду |
| [docs/wg-easy-vless.md](docs/wg-easy-vless.md) | WireGuard (wg-easy) + sing-box + VLESS Reality — шлюз для WireGuard-клиентов |
| [docs/hysteria2-lte-udp-dnat.md](docs/hysteria2-lte-udp-dnat.md) | Hysteria2 через цепочку UDP DNAT (LTE-гейт) |

---

## Команды для проверки и тестирования сервера

### Проверка IP на блокировки и чистоту

```bash
bash <(curl -Ls https://IP.Check.Place) -l en
```

### Включить BBR (рекомендуется для скорости)

```bash
echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf \
  && echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf \
  && sysctl -p
```

### Параметры сервера и тест скорости к зарубежным провайдерам

```bash
bash <(curl -Ls https://bench.sh)
```

### Гео-тест IP (регион, YouTube и т.д.)

```bash
bash <(wget -qO- https://github.com/Davoyan/ipregion/raw/main/ipregion.sh)
```

### Yet Another Benchmark Script (yabs)

```bash
curl -sL https://yabs.sh | bash -s -- -4
```

### Тест процессора (оценка выделенного CPU)

```bash
# В --threads указывать количество ядер
sysbench cpu run --threads=1
```
