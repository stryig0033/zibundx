#!/usr/bin/env bash
set -euo pipefail

# ==== 基本チェック ====
require_root(){ [ "$(id -u)" -eq 0 ] || { echo "Please run as root (sudo)."; exit 1; }; }
detect_os(){ . /etc/os-release || { echo "Unsupported OS"; exit 1; }; case "$ID" in ubuntu|debian) :;; *) echo "Ubuntu/Debian only"; exit 1;; esac; }
prompt(){ local q="$1" def="${2:-}" a=""; read -r -p "$q ${def:+[$def]}: " a || true; echo "${a:-$def}"; }

# ==== Dockerインストール ====
install_docker(){
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    echo "✅ Docker & Compose already installed."
    return
  fi
  echo "🚀 Installing Docker..."
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg lsb-release
  install -m0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -y && apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  systemctl enable docker; systemctl start docker
}

# ==== Firewall設定 ====
ensure_fw(){
  apt-get install -y ufw >/dev/null 2>&1 || true
  if ufw status 2>/dev/null | grep -qi inactive; then
    ufw allow OpenSSH >/dev/null 2>&1 || true
    ufw --force enable || true
  fi
}
allow_ports(){ if command -v ufw >/dev/null 2>&1; then
  if [ "$1" = "yes" ]; then
    ufw allow 80/tcp >/dev/null 2>&1 || true
    ufw allow 443/tcp >/dev/null 2>&1 || true
  else
    ufw allow 80/tcp >/dev/null 2>&1 || true
  fi
fi; }

# ==== Utility関数 ====
ext_ip(){ curl -fsS --max-time 3 ifconfig.me || hostname -I | awk '{print $1}'; }
gen_app_key(){ docker pull ghcr.io/linuxserver/bookstack:latest >/dev/null; docker run --rm ghcr.io/linuxserver/bookstack:latest appkey | tail -n1; }

# ==== .env生成 ====
write_env(){
cat > .env <<EOF
PUID=0
PGID=0
TZ=$TZ_INPUT

APP_URL=$APP_URL
APP_KEY=$APP_KEY

DB_HOST=db
DB_DATABASE=$DB_NAME
DB_USER=$DB_USER
DB_PASS=$DB_PASS

MYSQL_ROOT_PASSWORD=$DB_ROOT
MYSQL_DATABASE=$DB_NAME
MYSQL_USER=$DB_USER
MYSQL_PASSWORD=$DB_PASS
EOF
}

# ==== docker-compose生成 ====
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
    volumes:
      - ./db_data:/var/lib/mysql

  bookstack:
    image: ghcr.io/linuxserver/bookstack:latest
    container_name: bookstack_app
    depends_on: [db]
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
    volumes:
      - ./db_data:/var/lib/mysql

  bookstack:
    image: ghcr.io/linuxserver/bookstack:latest
    container_name: bookstack_app
    depends_on: [db]
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
  email $ACME_EMAIL
}
$DOMAIN {
  encode gzip
  reverse_proxy bookstack:80
}
EOF
}

# ==== 終了メッセージ ====
post_note(){
  echo
  echo "==============================================="
  echo " ✅ BookStack deployed!"
  echo " URL : $APP_URL"
  [ "$USE_TLS" = "yes" ] && echo " Note: HTTPS cert will be issued automatically (Let's Encrypt)."
  echo "-----------------------------------------------"
  echo " Manage: cd /opt/bookstack && docker compose logs -f"
  echo " Update: docker compose pull && docker compose up -d"
  echo " Stop  : docker compose down"
  echo "==============================================="
}

# ==== メイン処理 ====
main(){
  require_root; detect_os; install_docker; ensure_fw

  DOMAIN="$(prompt 'Domain for HTTPS (empty = HTTP only)')"
  TZ_INPUT="$(prompt 'Timezone' 'Asia/Tokyo')"
  DB_NAME="$(prompt 'DB name' 'bookstackapp')"
  DB_USER="$(prompt 'DB user' 'bookstack')"
  DB_PASS="$(openssl rand -hex 16)"
  DB_ROOT="$(openssl rand -hex 16)"
  APP_KEY="$(gen_app_key)"

  if [ -n "$DOMAIN" ]; then
    USE_TLS="yes"
    APP_URL="https://$DOMAIN"
    ACME_EMAIL="$(prompt "Let's Encrypt email" "admin@${DOMAIN#*.}")"
  else
    USE_TLS="no"
    APP_URL="http://$(ext_ip)"
  fi

  mkdir -p /opt/bookstack && cd /opt/bookstack
  mkdir -p db_data app_data

  write_env
  if [ "$USE_TLS" = "yes" ]; then compose_https; write_caddyfile; else compose_http; fi

  allow_ports "$USE_TLS"
  docker compose pull
  docker compose up -d
  post_note
}

main