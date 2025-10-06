#!/usr/bin/env bash
# BookStack one-shot installer for Ubuntu/Debian (HTTP or HTTPS w/ Caddy)
# - Idempotent: safe to re-run
# - Auto-fixes Docker apt repo (Ubuntu/Debian)
# - Cleans stale app_data/www/.env if it's wrong (e.g., database_username)
set -Eeuo pipefail
trap 'echo "❌ Error on line $LINENO"; exit 1' ERR
log() { printf "\n\033[1;34m[INFO]\033[0m %s\n" "$*"; }
die() { printf "\033[1;31m[ERR ]\033[0m %s\n" "$*"; exit 1; }

require_root(){ [ "$(id -u)" -eq 0 ] || die "Please run as root (sudo)."; }
detect_os(){ . /etc/os-release || die "Unsupported OS"; case "$ID" in ubuntu|debian) :;; *) die "Ubuntu/Debian only (got: $ID)";; esac; }
usage(){
cat <<'USAGE'
Usage: sudo ./setup-bookstack.sh [options]
  --non-interactive
  --domain=FQDN              (HTTPS via Caddy + Let's Encrypt)
  --http-only                (force HTTP on :80 using external IP)
  --tz=Asia/Tokyo
  --db-name=bookstackapp
  --db-user=bookstack
  --email=admin@example.com  (required with --domain)
Env (when --non-interactive): ZDX_DOMAIN, ZDX_HTTP_ONLY=1, ZDX_TZ, ZDX_DB_NAME, ZDX_DB_USER, ZDX_EMAIL
USAGE
}

# ---------------- args ----------------
NONINT=0; WANT_DOMAIN=""; HTTP_ONLY=0; TZ_INPUT=""; DB_NAME=""; DB_USER=""; ACME_EMAIL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --non-interactive) NONINT=1 ;;
    --domain=*)  WANT_DOMAIN="${1#*=}" ;;
    --http-only) HTTP_ONLY=1 ;;
    --tz=*)      TZ_INPUT="${1#*=}" ;;
    --db-name=*) DB_NAME="${1#*=}" ;;
    --db-user=*) DB_USER="${1#*=}" ;;
    --email=*)   ACME_EMAIL="${1#*=}" ;;
    *) die "Unknown option: $1";;
  esac; shift
done
if [ "$NONINT" = "1" ]; then
  : "${TZ_INPUT:=${ZDX_TZ:-Asia/Tokyo}}"
  : "${DB_NAME:=${ZDX_DB_NAME:-bookstackapp}}"
  : "${DB_USER:=${ZDX_DB_USER:-bookstack}}"
  [ "${ZDX_HTTP_ONLY:-0}" = "1" ] && HTTP_ONLY=1
  : "${WANT_DOMAIN:=${ZDX_DOMAIN:-}}"
  : "${ACME_EMAIL:=${ZDX_EMAIL:-}}"
fi

# ---------------- docker install ----------------
fix_docker_repo() {
  . /etc/os-release || die "Unsupported OS"
  case "$ID" in ubuntu) DOCKER_OS="ubuntu" ;; debian) DOCKER_OS="debian" ;; *) die "Unsupported: $ID" ;; esac
  install -m0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/${DOCKER_OS}/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  cat >/etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/${DOCKER_OS} ${VERSION_CODENAME} stable
EOF
}
install_docker(){
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    log "Docker & Compose already installed."; return
  fi
  log "Installing Docker for ${ID} (${VERSION_CODENAME})..."
  rm -f /etc/apt/sources.list.d/docker.list || true
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg lsb-release
  fix_docker_repo
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
}

# ---------------- firewall (UFW) ----------------
ensure_fw(){
  apt-get install -y ufw >/dev/null 2>&1 || true
  if ufw status 2>/dev/null | grep -qi inactive; then ufw allow OpenSSH >/dev/null 2>&1 || true; ufw --force enable || true; fi
}
allow_ports(){ if command -v ufw >/dev/null 2>&1; then ufw allow 80/tcp >/dev/null 2>&1 || true; [ "${1:-no}" = "yes" ] && ufw allow 443/tcp >/dev/null 2>&1 || true; fi; }

# ---------------- utils ----------------
ext_ip(){ curl -fsS --max-time 3 ifconfig.me || hostname -I | awk '{print $1}'; }
# 正式な appkey 呼び出し（LSIOイメージのエントリポイントに含まれてる）
gen_app_key(){
  # Laravel互換の 32バイト鍵（base64:プレフィクス付き）をローカル生成
  echo "base64:$(openssl rand -base64 32 | tr -d '\n')"
}
pick_puid_pgID(){
  local uid gid
  uid=$(awk -F: '$3>=1000 && $3<60000 {print $3; exit}' /etc/passwd || true)
  gid=$(awk -F: '$3>=1000 && $3<60000 {print $4; exit}' /etc/passwd || true)
  echo "${uid:-1000}:${gid:-1000}"
}

# ---------------- writers ----------------
write_env(){
  local puid="${1%:*}" pgid="${1#*:}"
cat > .env <<EOF
# --- LinuxServer.io standard ---
PUID=${puid}
PGID=${pgid}
TZ=${TZ_INPUT}

# --- App base URL & key ---
APP_URL=${APP_URL}
APP_KEY=${APP_KEY}

# --- DB connection from app ---
DB_HOST=db
DB_DATABASE=${DB_NAME}
DB_USER=${DB_USER}
DB_PASS=${DB_PASS}

# --- DB bootstrap for mariadb service ---
MYSQL_ROOT_PASSWORD=${DB_ROOT}
MYSQL_DATABASE=${DB_NAME}
MYSQL_USER=${DB_USER}
MYSQL_PASSWORD=${DB_PASS}

# (Optional mail settings – leave commented if not needed)
# MAIL_DRIVER=smtp
# MAIL_HOST=smtp.gmail.com
# MAIL_PORT=587
# MAIL_ENCRYPTION=tls
# MAIL_USERNAME=
# MAIL_PASSWORD=
# MAIL_FROM=BookStack <noreply@example.com>
EOF
}

compose_http(){
cat > docker-compose.yml <<'EOF'
services:
  db:
    image: mariadb:10.6
    container_name: bookstack_db
    restart: unless-stopped
    environment:
      - MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}
      - MYSQL_DATABASE=${MYSQL_DATABASE}
      - MYSQL_USER=${MYSQL_USER}
      - MYSQL_PASSWORD=${MYSQL_PASSWORD}
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost"]
      interval: 5s
      timeout: 3s
      retries: 30
    volumes:
      - ./db_data:/var/lib/mysql

  bookstack:
    image: ghcr.io/linuxserver/bookstack:latest
    container_name: bookstack_app
    depends_on:
      db:
        condition: service_healthy
    restart: unless-stopped
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
      - APP_URL=${APP_URL}
      - APP_KEY=${APP_KEY}
      - DB_HOST=db
      - DB_DATABASE=${DB_DATABASE}
      - DB_USER=${DB_USER}
      - DB_PASS=${DB_PASS}
    volumes:
      - ./app_data:/config
    ports:
      - "80:80"
EOF
}

compose_https(){
cat > docker-compose.yml <<'EOF'
services:
  db:
    image: mariadb:10.6
    container_name: bookstack_db
    restart: unless-stopped
    environment:
      - MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}
      - MYSQL_DATABASE=${MYSQL_DATABASE}
      - MYSQL_USER=${MYSQL_USER}
      - MYSQL_PASSWORD=${MYSQL_PASSWORD}
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost"]
      interval: 5s
      timeout: 3s
      retries: 30
    volumes:
      - ./db_data:/var/lib/mysql

  bookstack:
    image: ghcr.io/linuxserver/bookstack:latest
    container_name: bookstack_app
    depends_on:
      db:
        condition: service_healthy
    restart: unless-stopped
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
      - APP_URL=${APP_URL}
      - APP_KEY=${APP_KEY}
      - DB_HOST=db
      - DB_DATABASE=${DB_DATABASE}
      - DB_USER=${DB_USER}
      - DB_PASS=${DB_PASS}
    volumes:
      - ./app_data:/config
    expose:
      - "80"

  caddy:
    image: caddy:2
    container_name: bookstack_caddy
    depends_on: [bookstack]
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
EOF
}

write_caddyfile(){
cat > Caddyfile <<EOF
{
  email ${ACME_EMAIL}
}
${DOMAIN} {
  encode gzip
  reverse_proxy bookstack:80
}
EOF
}

# ---------------- app .env cleaner ----------------
clean_stale_app_env(){
  # 既存の app_data/www/.env が「database_username」を含む or APP_KEY/DB_* が欠落していれば削除して再生成させる
  local app_env="app_data/www/.env"
  if [ -f "$app_env" ]; then
    if grep -q 'database_username' "$app_env" \
       || ! grep -q '^APP_KEY=' "$app_env" \
       || ! grep -q '^DB_DATABASE=' "$app_env" \
       || ! grep -q '^DB_USER=' "$app_env"; then
      log "Found stale app .env -> removing to regenerate"
      rm -f "$app_env"
      rm -f app_data/www/bootstrap/cache/*.php 2>/dev/null || true
    fi
  fi
}

# ---------------- main ----------------
main(){
  require_root; detect_os
  log "Detected OS: ID=${ID} CODENAME=${VERSION_CODENAME}"
  [ -f /etc/apt/sources.list.d/docker.list ] && { echo "--- docker.list (before) ---"; cat /etc/apt/sources.list.d/docker.list || true; echo "----------------------------"; }

  install_docker
  ensure_fw

  # inputs
  if [ "$NONINT" = "1" ]; then
    : "${TZ_INPUT:=Asia/Tokyo}"
    : "${DB_NAME:=bookstackapp}"
    : "${DB_USER:=bookstack}"
    [ -n "${WANT_DOMAIN}" ] && [ "$HTTP_ONLY" -eq 1 ] && die "Use either --domain or --http-only, not both."
  else
    [ -z "$TZ_INPUT" ] && TZ_INPUT="$(read -r -p 'Timezone [Asia/Tokyo]: ' X || true; echo "${X:-Asia/Tokyo}")"
    [ -z "$DB_NAME" ]  && DB_NAME="$(read -r -p 'DB name [bookstackapp]: ' X || true; echo "${X:-bookstackapp}")"
    [ -z "$DB_USER" ]  && DB_USER="$(read -r -p 'DB user [bookstack]: ' X || true; echo "${X:-bookstack}")"
    if [ -z "$WANT_DOMAIN" ] && [ "$HTTP_ONLY" -eq 0 ]; then
      read -r -p 'Domain for HTTPS (empty = HTTP only): ' W || true; WANT_DOMAIN="${W:-}"
    fi
    if [ -n "$WANT_DOMAIN" ] && [ -z "$ACME_EMAIL" ]; then
      read -r -p "Let's Encrypt email [admin@${WANT_DOMAIN#*.}]: " E || true; ACME_EMAIL="${E:-admin@${WANT_DOMAIN#*.}}"
    fi
  fi

  DB_PASS="$(openssl rand -hex 16)"
  DB_ROOT="$(openssl rand -hex 16)"
  APP_KEY="$(gen_app_key)"
  [ -z "$APP_KEY" ] && die "Failed to generate APP_KEY"

  mkdir -p /opt/bookstack && cd /opt/bookstack
  mkdir -p db_data app_data

  PUID_PGID="$(pick_puid_pgID)"
  if [ -n "$WANT_DOMAIN" ]; then
    DOMAIN="$WANT_DOMAIN"; APP_URL="https://${DOMAIN}"
    write_env "$PUID_PGID"; compose_https; [ -z "$ACME_EMAIL" ] && die "--email required when using --domain"; write_caddyfile; allow_ports yes
  else
    APP_URL="http://$(ext_ip)"
    write_env "$PUID_PGID"; compose_http; allow_ports no
  fi

  # app 側の古い .env を掃除（必要時のみ）
  clean_stale_app_env

  # app ディレクトリの所有権を PUID:PGID に（php-fpm が root を拒否するため）
  chown -R "${PUID_PGID%:*}:${PUID_PGID#*:}" app_data || true

  log "Pulling images & starting containers..."
  docker compose pull
  docker compose up -d

  # 簡易ヘルスチェック（失敗しても続行）
  sleep 3
  if command -v curl >/dev/null 2>&1; then
    curl -fsS -I http://127.0.0.1 | head -n1 || true
  fi

  log "Done."
  echo "==============================================="
  echo " ✅ BookStack deployed!"
  echo " URL : ${APP_URL}"
  [ -n "$WANT_DOMAIN" ] && echo " Note: HTTPS cert auto-issuance by Let's Encrypt via Caddy."
  echo "-----------------------------------------------"
  echo " Manage: cd /opt/bookstack && docker compose logs -f"
  echo " Update: docker compose pull && docker compose up -d"
  echo " Stop  : docker compose down"
  echo "==============================================="
}

main