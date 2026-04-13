#!/usr/bin/env bash
set -euo pipefail

# ====== настройки (можно переопределять env-переменными) ======
BASE_DIR="${BASE_DIR:-/opt/selfsteal}"

DOMAIN="${1:-}"
MODE="${2:-http}"           # http | cf | dns

SELFS_PORT="${SELFS_PORT:-22253}"

SELFSTEAL_CONTAINER="${SELFSTEAL_CONTAINER:-selfsteal}"
REMNANODE_CONTAINER="${REMNANODE_CONTAINER:-remnanode}"

CERTBOT_EMAIL="${CERTBOT_EMAIL:-}"   # опционально, но лучше указать

# Для CF (dns-01)
CF_CRED_FILE="${CF_CRED_FILE:-/root/.cloudflare.ini}"
DNS_PROPAGATION_SECONDS="${DNS_PROPAGATION_SECONDS:-20}"
# ==============================================================

log() { echo -e "[$(date +'%F %T')] $*"; }
die() { echo -e "❌ $*" >&2; exit 1; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

need_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Запусти от root (sudo)."
}

check_port_free() {
  local port="$1"
  if ss -lntp 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}\$"; then
    die "Порт :${port} занят. Для certbot --standalone нужен свободный :${port} (обычно 80)."
  fi
}

install_deps() {
  if ! have_cmd certbot; then
    log "🔧 Ставлю certbot..."
    if have_cmd apt-get; then
      apt-get update -y
      apt-get install -y certbot
    elif have_cmd yum; then
      yum install -y certbot
    elif have_cmd dnf; then
      dnf install -y certbot
    else
      die "Не нашёл пакетный менеджер (apt/yum/dnf). Поставь certbot вручную."
    fi
  fi

  # Cloudflare plugin только если нужен режим cf
  if [[ "${MODE}" == "cf" ]]; then
    if ! python3 -c "import certbot_dns_cloudflare" >/dev/null 2>&1; then
      log "🔧 Ставлю плагин python3-certbot-dns-cloudflare..."
      if have_cmd apt-get; then
        apt-get update -y
        apt-get install -y python3-certbot-dns-cloudflare
      else
        die "Не могу поставить python3-certbot-dns-cloudflare автоматически (не apt). Поставь вручную."
      fi
    fi
  fi

  if ! have_cmd docker; then
    die "Docker не найден."
  fi

  if ! docker compose version >/dev/null 2>&1 && ! have_cmd docker-compose; then
    die "Не найден docker compose (ни 'docker compose', ни 'docker-compose')."
  fi
}

compose_up() {
  local dir="$1"
  if docker compose version >/dev/null 2>&1; then
    (cd "$dir" && docker compose up -d)
  else
    (cd "$dir" && docker-compose up -d)
  fi
}

obtain_cert() {
  local email_args=()
  if [[ -n "${CERTBOT_EMAIL}" ]]; then
    email_args=(--email "${CERTBOT_EMAIL}")
  else
    email_args=(--register-unsafely-without-email)
  fi

  case "${MODE}" in
    http)
      check_port_free 80
      log "📜 (http-01/standalone) Запрашиваю/обновляю сертификат для ${DOMAIN}..."
      certbot certonly \
        --standalone \
        --preferred-challenges http \
        -d "${DOMAIN}" \
        --agree-tos \
        --non-interactive \
        "${email_args[@]}"
      ;;

    cf)
      [[ -f "${CF_CRED_FILE}" ]] || die "Нет файла ${CF_CRED_FILE}. Создай /root/.cloudflare.ini с dns_cloudflare_api_token"
      log "📜 (dns-01/cloudflare) Запрашиваю/обновляю сертификат для ${DOMAIN}..."
      certbot certonly \
        --dns-cloudflare \
        --dns-cloudflare-credentials "${CF_CRED_FILE}" \
        --dns-cloudflare-propagation-seconds "${DNS_PROPAGATION_SECONDS}" \
        -d "${DOMAIN}" \
        --agree-tos \
        --non-interactive \
        "${email_args[@]}"
      ;;

    dns)
      log "📜 (dns-01/manual) Запрашиваю/обновляю сертификат для ${DOMAIN}..."
      log "⚠️ Сейчас certbot покажет TXT запись для:"
      log "   _acme-challenge.${DOMAIN}"
      log "⚠️ Добавь её вручную в DNS, дождись применения, потом нажми Enter."
      log "⚠️ Этот режим НЕ подходит для полностью автоматического renew."

      certbot certonly \
        --manual \
        --preferred-challenges dns \
        -d "${DOMAIN}" \
        --agree-tos \
        --manual-public-ip-logging-ok \
        "${email_args[@]}"
      ;;

    *)
      die "Неизвестный режим '${MODE}'. Используй: http | cf | dns"
      ;;
  esac

  log "✅ Сертификат готов: /etc/letsencrypt/live/${DOMAIN}/"
}

write_files() {
  mkdir -p "${BASE_DIR}/nginx/html"
  mkdir -p "${BASE_DIR}/nginx"

  cat > "${BASE_DIR}/nginx/html/index.html" <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>Just a moment...</title>
</head>
<body>
  <h1>Checking your browser before accessing ${DOMAIN}</h1>
</body>
</html>
EOF

  cat > "${BASE_DIR}/nginx/default.conf" <<EOF
server {
    listen ${SELFS_PORT} ssl;
    http2 on;

    server_name ${DOMAIN};

    ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;

    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    root /usr/share/nginx/html;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

  cat > "${BASE_DIR}/docker-compose.yml" <<EOF
services:
  nginx:
    image: nginx:alpine
    container_name: ${SELFSTEAL_CONTAINER}
    network_mode: host
    restart: unless-stopped
    volumes:
      - ./nginx/html:/usr/share/nginx/html:ro
      - ./nginx/default.conf:/etc/nginx/conf.d/default.conf:ro
      - /etc/letsencrypt:/etc/letsencrypt:ro
EOF
}

ensure_hook() {
  local hook_path="/etc/letsencrypt/renewal-hooks/deploy/remnawave-selfsteal.sh"
  mkdir -p "$(dirname "$hook_path")"

  cat > "$hook_path" <<EOF
#!/usr/bin/env bash
set -euo pipefail

SELFSTEAL_CONTAINER="${SELFSTEAL_CONTAINER}"
REMNANODE_CONTAINER="${REMNANODE_CONTAINER}"

mkdir -p /var/log/letsencrypt
echo "[hook] \$(date -Is) fired" >> /var/log/letsencrypt/deploy-hook.log

# reload selfsteal nginx if running; fallback to restart
if docker ps --format '{{.Names}}' | grep -qx "\${SELFSTEAL_CONTAINER}"; then
  docker exec "\${SELFSTEAL_CONTAINER}" nginx -s reload || docker restart "\${SELFSTEAL_CONTAINER}"
  echo "[hook] reloaded selfsteal nginx: \${SELFSTEAL_CONTAINER}" >> /var/log/letsencrypt/deploy-hook.log
else
  echo "[hook] selfsteal container not running: \${SELFSTEAL_CONTAINER}" >> /var/log/letsencrypt/deploy-hook.log
fi

# restart remnanode so xray surely reloads PEM
if docker ps -a --format '{{.Names}}' | grep -qx "\${REMNANODE_CONTAINER}"; then
  docker restart "\${REMNANODE_CONTAINER}"
  echo "[hook] restarted remnanode: \${REMNANODE_CONTAINER}" >> /var/log/letsencrypt/deploy-hook.log
else
  echo "[hook] remnanode container not found: \${REMNANODE_CONTAINER}" >> /var/log/letsencrypt/deploy-hook.log
fi
EOF

  chmod +x "$hook_path"
  log "✅ Deploy-hook установлен: ${hook_path}"
}

main() {
  need_root
  install_deps

  if [[ -z "$DOMAIN" ]]; then
    read -r -p "📡 Домен selfsteal (пример: media-nl2.goodmc.org): " DOMAIN
  fi
  [[ -n "$DOMAIN" ]] || die "Домен пустой."

  log "🧩 MODE=${MODE} (http=standalone, cf=cloudflare dns-01, dns=manual dns-01)"
  obtain_cert
  write_files

  log "🚀 Поднимаю selfsteal (container_name=${SELFSTEAL_CONTAINER})..."
  compose_up "$BASE_DIR"

  ensure_hook

  log "🎯 Готово."
  echo "— Папка: ${BASE_DIR}"
  echo "— Контейнер: ${SELFSTEAL_CONTAINER}"
  echo "— Серты: /etc/letsencrypt/live/${DOMAIN}/"
  echo "— Лог хуков: /var/log/letsencrypt/deploy-hook.log"
  echo
  echo "Запуск:"
  echo "  ./selfsteal.sh ${DOMAIN}            # http (default)"
  echo "  ./selfsteal.sh ${DOMAIN} http       # http-01 standalone"
  echo "  ./selfsteal.sh ${DOMAIN} cf         # cloudflare dns-01"
  echo "  ./selfsteal.sh ${DOMAIN} dns        # manual dns-01"
}

main "$@"
