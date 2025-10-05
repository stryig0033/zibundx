#!/usr/bin/env bash
set -euo pipefail

#========================================
# BookStack 一発デプロイスクリプト
#  - Ubuntu 22.04/24.04想定
#  - Docker + MariaDB + BookStack(+任意でCaddy/HTTPS)
#  - 対話で .env / docker-compose.yml を生成し、起動まで実施
#========================================

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "このスクリプトは root で実行してください（例: sudo $0）"
    exit 1
  fi
}

detect_os() {
  if [ -r /etc/os-release ]; then
    . /etc/os-release
    OS_ID="${ID:-}"
    OS_VERSION_ID="${VERSION_ID:-}"
  else
    echo "/etc/os-release が見つかりません。Ubuntu系を想定しています。"
    exit 1
  fi
  if [[ "$OS_ID" != "ubuntu" && "$OS_ID" != "debian" ]]; then
    echo "このスクリプトは Ubuntu/Debian 系のみサポートします。検出: $OS_ID $OS_VERSION_ID"
    exit 1
  fi
}

prompt_default() {
  local prompt="$1"
  local default="${2:-}"
  local var=""
  if [ -n "$default" ]; then
    read -r -p "$prompt [$default]: " var || true
    echo "${var:-$default}"
  else
    read -r -p "$prompt: " var || true
    echo "$var"
  fi
}

random_string() {
  # 32文字の英数字
  openssl rand -hex 24
}

install_packages() {
  echo "==> パッケージ更新 & 事前ツール導入"
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg lsb-release ufw
}

install_docker() {
  if command -v docker >/dev/null 2>&1; then
    echo "==> Docker は既にインストールされています。"
    return
  fi
  echo "==> Docker をインストールします（公式リポジトリ）"
  install_packages

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  ARCH="$(dpkg --print-architecture)"
  CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  echo \
"deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${CODENAME} stable" \
    | tee /etc/apt/sources.list.d/docker.list >/dev/null

  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  systemctl enable docker
  systemctl start docker
}

enable_firewall() {
  if command -v ufw >/dev/null 2>&1; then
    if ufw status | grep -qi inactive; then
      echo "==> UFW（ファイアウォール）を有効化します"
      ufw allow OpenSSH >/dev/null 2>&1 || true
      ufw --force enable
    fi
  fi
}

allow_ports() {
  local use_caddy="$1"
  if command -v ufw >/dev/null 2>&1; then
    if [ "$use_caddy" = "yes" ]; then
      ufw allow 80/tcp >/dev/null 2>&1 || true
      ufw allow 443/tcp >/dev/null 2>&1 || true
    else
      ufw allow 8080/tcp >/dev/null 2>&1 || true
    fi
  fi
}

create_project_skeleton() {
  mkdir -p /opt/bookstack/{db_data,app_data,caddy_data,caddy_config}
}

write_env_file() {
  local env_path="$1"
  local PUID="$2"
  local PGID="$3"
  local TZ="$4"
  local APP_URL="$5"
  local DB_DATABASE="$6"
  local DB_USER="$7"
  local DB_PASS="$8"
  local DB_ROOT_PASS="$9"

  cat > "$env_path" <<EOF
#==== BookStack 環境変数 (.env) ====
PUID=${PUID}
PGID=${PGID}
TZ=${TZ}

# BookStack アプリ URL
APP_URL=${APP_URL}

# DB接続設定
DB_HOST=db
DB_DATABASE=${DB_DATABASE}
DB_USER=${DB_USER}
DB_PASS=${DB_PASS}

# MariaDB root
MYSQL_ROOT_PASSWORD=${DB_ROOT_PASS}
MYSQL_DATABASE=${DB_DATABASE}
MYSQL_USER=${DB_USER}
MYSQL_PASSWORD=${DB_PASS}
EOF
}

write_compose_no_tls() {
  local compose_path="$1"
  cat > "$compose_path" <<'EOF'
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
    depends_on:
      - db
    restart: unless-stopped
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
      - APP_URL=${APP_URL}
      - DB_HOST=db
      - DB_DATABASE=${DB_DATABASE}
      - DB_USER=${DB_USER}
      - DB_PASS=${DB_PASS}
    volumes:
      - ./app_data:/config
    ports:
      - "8080:80"
EOF
}

write_compose_with_caddy() {
  local compose_path="$1"
  cat > "$compose_path" <<'EOF'
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
    depends_on:
      - db
    restart: unless-stopped
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
      - APP_URL=${APP_URL}
      - DB_HOST=db
      - DB_DATABASE=${DB_DATABASE}
      - DB_USER=${DB_USER}
      - DB_PASS=${DB_PASS}
    volumes:
      - ./app_data:/config

  caddy:
    image: caddy:2
    container_name: bookstack_caddy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    environment:
      - ACME_AGREE=true
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./caddy_data:/data
      - ./caddy_config:/config
EOF
}

write_caddyfile() {
  local caddyfile_path="$1"
  local acme_email="$2"
  local domain="$3"

  cat > "$caddyfile_path" <<EOF
{
  email ${acme_email}
}

${domain} {
  encode gzip
  reverse_proxy bookstack:80
}
EOF
}

post_instructions() {
  local use_caddy="$1"
  local app_url="$2"

  echo
  echo "============================================================="
  echo "  ✅ BookStack デプロイ完了"
  echo "-------------------------------------------------------------"
  echo "URL: ${app_url}"
  if [ "$use_caddy" = "yes" ]; then
    echo "※ 初回アクセス時に自動でLet's Encryptにより証明書取得します。"
  else
    echo "※ 8080番ポートで稼働中（例： http://<サーバIP>:8080 ）"
  fi
  echo
  echo "[管理ガイド]"
  echo "  起動   : docker compose up -d"
  echo "  停止   : docker compose down"
  echo "  ログ   : docker compose logs -f"
  echo "  更新   : docker compose pull && docker compose up -d"
  echo "  バックアップ(DB): docker exec bookstack_db sh -c 'mysqldump -u\"$MYSQL_USER\" -p\"$MYSQL_PASSWORD\" \"$MYSQL_DATABASE\"' > /opt/bookstack/backup_$(date +%Y%m%d).sql"
  echo
  echo "[補足]"
  echo "  - 初回アクセス後、画面の案内に従って管理ユーザーを作成してください。"
  echo "  - メール送信等が必要な場合は、/opt/bookstack/app_data 内の .env を編集して再起動してください。"
  echo "============================================================="
}

main() {
  require_root
  detect_os
  install_docker
  enable_firewall

  echo "==> BookStack セットアップを開始します（所要 3〜10分）"
  echo

  #=== 対話入力 ===
  SERVER_IP=$(hostname -I | awk '{print $1}')
  DOMAIN="$(prompt_default 'ドメイン名（HTTPSを使う場合は入力。未設定なら空でOK）' '')"
  USE_CADDY="no"
  APP_URL=""
  ACME_EMAIL=""
  if [ -n "$DOMAIN" ]; then
    USE_CADDY="yes"
    ACME_EMAIL="$(prompt_default 'Let\'s Encrypt 通知用メールアドレス' 'admin@'"${DOMAIN#*.}")"
    APP_URL="https://${DOMAIN}"
  else
    APP_URL="http://${SERVER_IP}:8080"
  fi

  TZ_INPUT="$(prompt_default 'タイムゾーン' 'Asia/Tokyo')"
  DB_NAME="$(prompt_default 'DB名' 'bookstackapp')"
  DB_USER="$(prompt_default 'DBユーザー' 'bookstack')"
  DB_PASS_DEFAULT="$(random_string)"
  DB_PASS="$(prompt_default 'DBパスワード' "$DB_PASS_DEFAULT")"
  DB_ROOT_PASS_DEFAULT="$(random_string)"
  DB_ROOT_PASS="$(prompt_default 'DB root パスワード' "$DB_ROOT_PASS_DEFAULT")"

  # 実行ユーザーの UID/GID を PUID/PGID に合わせる（rootなら 0/0）
  PUID="${SUDO_UID:-0}"
  PGID="${SUDO_GID:-0}"

  #=== 構成生成 ===
  create_project_skeleton
  cd /opt/bookstack

  write_env_file "/opt/bookstack/.env" "$PUID" "$PGID" "$TZ_INPUT" "$APP_URL" "$DB_NAME" "$DB_USER" "$DB_PASS" "$DB_ROOT_PASS"

  if [ "$USE_CADDY" = "yes" ]; then
    write_compose_with_caddy "/opt/bookstack/docker-compose.yml"
    write_caddyfile "/opt/bookstack/Caddyfile" "$ACME_EMAIL" "$DOMAIN"
  else
    write_compose_no_tls "/opt/bookstack/docker-compose.yml"
  fi

  #=== 起動 ===
  allow_ports "$USE_CADDY"

  echo "==> コンテナを起動します（初回はイメージ取得のため少し時間がかかります）"
  docker compose pull
  docker compose up -d

  post_instructions "$USE_CADDY" "$APP_URL"
}

main "$@"