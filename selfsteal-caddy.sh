#!/usr/bin/env bash
set -euo pipefail

# Selfsteal на Caddy: HTTPS-заглушка + автоматический Let's Encrypt (без certbot/nginx).
# Reality dest → localhost:SELFS_PORT

# ====== настройки (можно переопределять env-переменными) ======
BASE_DIR="${BASE_DIR:-/opt/selfsteal}"

DOMAIN="${1:-}"
MODE="${2:-http}"           # http | cf

SELFS_PORT="${SELFS_PORT:-22253}"

SELFSTEAL_CONTAINER="${SELFSTEAL_CONTAINER:-selfsteal}"
REMNANODE_CONTAINER="${REMNANODE_CONTAINER:-remnanode}"

ACME_EMAIL="${ACME_EMAIL:-${CERTBOT_EMAIL:-}}"   # CERTBOT_EMAIL — алиас для совместимости

# Cloudflare DNS-01
CF_API_TOKEN="${CF_API_TOKEN:-}"
CF_CRED_FILE="${CF_CRED_FILE:-/root/.cloudflare.ini}"
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
    die "Порт :${port} занят. Для ACME http-01 Caddy нужен свободный :80."
  fi
}

load_cf_token() {
  if [[ -n "${CF_API_TOKEN}" ]]; then
    return 0
  fi
  [[ -f "${CF_CRED_FILE}" ]] || die "Нет CF_API_TOKEN и файла ${CF_CRED_FILE}"

  # совместимость с certbot cloudflare.ini: dns_cloudflare_api_token = ...
  CF_API_TOKEN="$(
    awk -F= '
      tolower($1) ~ /dns_cloudflare_api_token|cloudflare_api_token/ {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
        print $2
        exit
      }
    ' "${CF_CRED_FILE}"
  )"
  [[ -n "${CF_API_TOKEN}" ]] || die "В ${CF_CRED_FILE} не найден dns_cloudflare_api_token"
  export CF_API_TOKEN
}

install_deps() {
  if ! have_cmd docker; then
    die "Docker не найден."
  fi

  if ! docker compose version >/dev/null 2>&1 && ! have_cmd docker-compose; then
    die "Не найден docker compose (ни 'docker compose', ни 'docker-compose')."
  fi

  if ! have_cmd curl; then
    log "🔧 Ставлю curl..."
    if have_cmd apt-get; then
      apt-get update -y
      apt-get install -y curl
    elif have_cmd yum; then
      yum install -y curl
    elif have_cmd dnf; then
      dnf install -y curl
    else
      die "curl не найден. Поставь вручную."
    fi
  fi
}

compose() {
  local dir="$1"
  shift
  if docker compose version >/dev/null 2>&1; then
    (cd "$dir" && docker compose "$@")
  else
    (cd "$dir" && docker-compose "$@")
  fi
}

write_files() {
  mkdir -p "${BASE_DIR}/html" "${BASE_DIR}/caddy-data" "${BASE_DIR}/caddy-config"

  cat > "${BASE_DIR}/html/index.html" <<EOF
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

  # Caddy сам получает/обновляет сертификат. Сайт слушает только SELFS_PORT (для Reality dest).
  # disable_redirects — не занимаем :80 постоянно под редирект (нужен только на время http-01).
  {
    echo "{"
    if [[ -n "${ACME_EMAIL}" ]]; then
      printf '\temail %s\n' "${ACME_EMAIL}"
    fi
    echo "	auto_https disable_redirects"
    if [[ "${MODE}" == "cf" ]]; then
      echo "	acme_dns cloudflare {env.CF_API_TOKEN}"
    fi
    echo "}"
    echo
    printf '%s:%s {\n' "${DOMAIN}" "${SELFS_PORT}"
    echo "	root * /srv"
    echo "	file_server"
    echo "	encode gzip"
    echo "}"
  } > "${BASE_DIR}/Caddyfile"

  # Образ с DNS-плагином Cloudflare — только для MODE=cf.
  if [[ "${MODE}" == "cf" ]]; then
    cat > "${BASE_DIR}/Dockerfile" <<'EOF'
FROM caddy:2-builder-alpine AS builder
RUN xcaddy build --with github.com/caddy-dns/cloudflare

FROM caddy:2-alpine
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
EOF

    cat > "${BASE_DIR}/docker-compose.yml" <<EOF
services:
  caddy:
    build: .
    image: selfsteal-caddy:local
    container_name: ${SELFSTEAL_CONTAINER}
    network_mode: host
    restart: unless-stopped
    environment:
      CF_API_TOKEN: "\${CF_API_TOKEN:-}"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./html:/srv:ro
      - ./caddy-data:/data
      - ./caddy-config:/config
EOF
  else
    rm -f "${BASE_DIR}/Dockerfile"
    cat > "${BASE_DIR}/docker-compose.yml" <<EOF
services:
  caddy:
    image: caddy:2-alpine
    container_name: ${SELFSTEAL_CONTAINER}
    network_mode: host
    restart: unless-stopped
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./html:/srv:ro
      - ./caddy-data:/data
      - ./caddy-config:/config
EOF
  fi
}

wait_https() {
  local tries="${1:-90}"
  local i
  log "⏳ Жду готовности HTTPS на :${SELFS_PORT} (выпуск сертификата)..."
  for ((i = 1; i <= tries; i++)); do
    if curl -fsSk --resolve "${DOMAIN}:${SELFS_PORT}:127.0.0.1" \
      "https://${DOMAIN}:${SELFS_PORT}/" >/dev/null 2>&1; then
      log "✅ HTTPS отвечает: https://${DOMAIN}:${SELFS_PORT}/"
      return 0
    fi
    sleep 2
  done

  log "⚠️ Таймаут ожидания HTTPS. Логи Caddy:"
  docker logs --tail 80 "${SELFSTEAL_CONTAINER}" || true
  die "Caddy не поднял HTTPS за $((tries * 2))с. Проверь DNS, порт 80 (режим http) или CF_API_TOKEN (режим cf)."
}

maybe_hint_remnanode() {
  if docker ps -a --format '{{.Names}}' | grep -qx "${REMNANODE_CONTAINER}"; then
    log "ℹ️ Контейнер ${REMNANODE_CONTAINER} найден. Для Reality dest перезапуск не обязателен — сертификат отдаёт Caddy на :${SELFS_PORT}."
  fi
}

main() {
  need_root
  install_deps

  if [[ -z "${DOMAIN}" ]]; then
    read -r -p "📡 Домен selfsteal (пример: media-nl2.goodmc.org): " DOMAIN
  fi
  [[ -n "${DOMAIN}" ]] || die "Домен пустой."

  case "${MODE}" in
    http)
      check_port_free 80
      log "🧩 MODE=http — ACME http-01 (нужен свободный :80 и A-запись на этот хост)"
      ;;
    cf)
      load_cf_token
      export CF_API_TOKEN
      log "🧩 MODE=cf — ACME dns-01 через Cloudflare"
      ;;
    *)
      die "Неизвестный режим '${MODE}'. Используй: http | cf"
      ;;
  esac

  write_files

  # прокидываем токен в compose environment для cf
  if [[ "${MODE}" == "cf" ]]; then
    export CF_API_TOKEN
  else
    export CF_API_TOKEN="${CF_API_TOKEN:-}"
  fi

  log "🚀 Поднимаю Caddy (container_name=${SELFSTEAL_CONTAINER})..."
  if [[ "${MODE}" == "cf" ]]; then
    compose "${BASE_DIR}" up -d --build
  else
    compose "${BASE_DIR}" up -d
  fi

  wait_https 90
  maybe_hint_remnanode

  log "🎯 Готово."
  echo "— Папка: ${BASE_DIR}"
  echo "— Контейнер: ${SELFSTEAL_CONTAINER}"
  echo "— HTTPS: https://${DOMAIN}:${SELFS_PORT}/"
  echo "— Серты Caddy: ${BASE_DIR}/caddy-data/caddy/certificates/"
  echo
  echo "Xray realitySettings.dest: \"${SELFS_PORT}\""
  echo "Xray realitySettings.serverNames: [\"${DOMAIN}\"]"
  echo
  echo "Запуск:"
  echo "  ./selfsteal-caddy.sh ${DOMAIN}        # http-01 (default)"
  echo "  ./selfsteal-caddy.sh ${DOMAIN} http   # ACME http-01"
  echo "  ./selfsteal-caddy.sh ${DOMAIN} cf     # Cloudflare dns-01"
  echo
  echo "CF: export CF_API_TOKEN=...  или файл ${CF_CRED_FILE}"
  echo "Email: export ACME_EMAIL=you@example.com"
}

main "$@"
