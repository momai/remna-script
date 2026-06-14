#!/usr/bin/env bash
set -euo pipefail

# ====== настройки (можно переопределять env-переменными) ======
BASE_DIR="${BASE_DIR:-/opt/remnanode/nginx-xhttp}"
SOCKETS_DIR="${SOCKETS_DIR:-/opt/remnanode/sockets}"

DOMAIN="${1:-}"
MODE="${2:-http}"           # http | cf | dns
XPATH="${3:-${XPATH:-}}"

SELFS_PORT="${SELFS_PORT:-22253}"

XHTTP_CONTAINER="${XHTTP_CONTAINER:-nginx-xhttp}"
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
        --keep-until-expiring \
        "${email_args[@]}"
      ;;
    *)
      die "Неизвестный режим '${MODE}'. Используй: http | cf | dns"
      ;;
  esac

  log "✅ Сертификат готов: /etc/letsencrypt/live/${DOMAIN}/"
}

normalize_xpath() {
  XPATH="${XPATH:-/api/}"
  [[ "${XPATH}" == /* ]] || XPATH="/${XPATH}"
}

write_files() {
  mkdir -p "${BASE_DIR}/conf.d"
  mkdir -p "${SOCKETS_DIR}"
  chmod 777 "${SOCKETS_DIR}"

  cat > "${BASE_DIR}/docker-compose.yml" <<EOF
services:
  nginx-xhttp:
    image: nginx:alpine
    container_name: ${XHTTP_CONTAINER}
    restart: always
    network_mode: host
    volumes:
      - ${BASE_DIR}/conf.d:/etc/nginx/conf.d:ro
      - /etc/letsencrypt:/etc/letsencrypt:ro
      - ${SOCKETS_DIR}:/var/run/xray
EOF

  cat > "${BASE_DIR}/conf.d/xhttp.conf" <<EOF
server {
    listen ${SELFS_PORT} ssl;
    http2 on;
    server_name ${DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;

    client_max_body_size 0;

    location ^~ ${XPATH} {
        proxy_pass http://unix:/var/run/xray/xhttp.sock:;
        proxy_http_version 1.1;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;

        proxy_buffering off;
        proxy_request_buffering off;

        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }

    location / {
        return 404;
    }
}
EOF
}

ensure_hook() {
  local hook_path="/etc/letsencrypt/renewal-hooks/deploy/remnawave-selfsteal-xhttp.sh"
  mkdir -p "$(dirname "$hook_path")"

  cat > "$hook_path" <<EOF
#!/usr/bin/env bash
set -euo pipefail

XHTTP_CONTAINER="${XHTTP_CONTAINER}"
REMNANODE_CONTAINER="${REMNANODE_CONTAINER}"

mkdir -p /var/log/letsencrypt
echo "[hook] \$(date -Is) fired" >> /var/log/letsencrypt/deploy-hook.log

# reload xhttp nginx if running; fallback to restart
if docker ps --format '{{.Names}}' | grep -qx "\${XHTTP_CONTAINER}"; then
  docker exec "\${XHTTP_CONTAINER}" nginx -s reload || docker restart "\${XHTTP_CONTAINER}"
  echo "[hook] reloaded xhttp nginx: \${XHTTP_CONTAINER}" >> /var/log/letsencrypt/deploy-hook.log
else
  echo "[hook] xhttp nginx container not running: \${XHTTP_CONTAINER}" >> /var/log/letsencrypt/deploy-hook.log
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
    read -r -p "📡 Домен xhttp (пример: de2.getline.pro): " DOMAIN
  fi
  [[ -n "$DOMAIN" ]] || die "Домен пустой."

  if [[ -z "$XPATH" ]]; then
    read -r -p "🧭 Path (default: /api/): " XPATH
  fi
  normalize_xpath

  log "🧩 MODE=${MODE} (http=standalone, cf=cloudflare dns-01, dns=manual dns-01)"
  log "🧭 XPATH=${XPATH}"
  obtain_cert
  write_files

  log "🚀 Поднимаю nginx-xhttp (container_name=${XHTTP_CONTAINER})..."
  compose_up "$BASE_DIR"

  ensure_hook

  log "🎯 Готово."
  echo "— Папка: ${BASE_DIR}"
  echo "— Контейнер: ${XHTTP_CONTAINER}"
  echo "— Серты: /etc/letsencrypt/live/${DOMAIN}/"
  echo "— Socket dir: ${SOCKETS_DIR}"
  echo "— XHTTP path: ${XPATH}"
  echo "— Лог хуков: /var/log/letsencrypt/deploy-hook.log"
  echo
  echo "В Remna/Xray inbound укажи:"
  echo '      "listen": "/var/run/xray/xhttp.sock,0666"'
  echo
  echo "Проверка nginx:"
  echo "  docker exec ${XHTTP_CONTAINER} nginx -t"
  echo
  echo "Запуск:"
  echo "  ./selfsteal-xhttp.sh ${DOMAIN}              # http + path prompt/default"
  echo "  ./selfsteal-xhttp.sh ${DOMAIN} http /api/   # http-01 standalone"
  echo "  ./selfsteal-xhttp.sh ${DOMAIN} cf /api/     # cloudflare dns-01"
  echo "  ./selfsteal-xhttp.sh ${DOMAIN} dns /api/    # manual dns-01"
}

main "$@"
