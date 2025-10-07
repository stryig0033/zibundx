#!/bin/bash

# このスクリプトは、対話形式で設定を行いながら、
# UbuntuサーバーにDockerを使用してEspoCRMをデプロイします。
# 途中でエラーが発生した場合は、そこで処理を停止します。
set -e

echo "--- EspoCRM 自動デプロイスクリプト (対話形式) を開始します ---"

# ==============================================================================
# ステップ1: 依存パッケージとDockerのインストール
# ==============================================================================
echo " [1/5] システムを更新し、必要なパッケージをインストールします..."
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg

echo " [2/5] Dockerをインストールします..."
# Dockerの公式GPGキーを追加
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

# Dockerのリポジトリを設定
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Docker Engineをインストール
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# 現在のユーザーをdockerグループに追加
sudo usermod -aG docker ${USER}
echo "Dockerのインストールが完了しました。"
echo "------------------------------------------------------------------"


# ==============================================================================
# ステップ2: 対話形式でのEspoCRM設定
# ==============================================================================
echo " [3/5] EspoCRMの設定情報を入力してください。"

# プロジェクトディレクトリを作成して移動
mkdir -p ~/espocrm
cd ~/espocrm

# ユーザーから設定値を取得
read -p "サーバーの公開IPアドレスまたはドメイン名を入力してください (例: 136.113.229.248): " USER_SITE_URL
read -sp "EspoCRMの管理者(admin)用パスワードを入力してください: " USER_ADMIN_PASSWORD
echo # 改行のため

# データベースパスワードを、確認入力を含めて取得
while true; do
    read -sp "データベース用の新しいパスワードを入力してください: " USER_DB_PASSWORD
    echo
    read -sp "確認のため、もう一度データベース用のパスワードを入力してください: " USER_DB_PASSWORD_CONFIRM
    echo
    if [ "$USER_DB_PASSWORD" = "$USER_DB_PASSWORD_CONFIRM" ]; then
        break
    else
        echo "パスワードが一致しません。もう一度入力してください。"
    fi
done

read -sp "データベースの管理者(root)用の新しいパスワードを入力してください: " USER_MYSQL_ROOT_PASSWORD
echo
echo "------------------------------------------------------------------"
echo "情報のご入力、ありがとうございます。"
echo "------------------------------------------------------------------"


# ==============================================================================
# ステップ3: 設定ファイルを作成
# ==============================================================================
echo " [4/5] 入力された情報をもとに、設定ファイルを自動生成します..."

# .env ファイルをユーザーの入力値で作成
cat <<EOF > .env
# このファイルはスクリプトによって自動生成されました。
ESPOCRM_SITE_URL=http://${USER_SITE_URL}
ESPOCRM_ADMIN_PASSWORD=${USER_ADMIN_PASSWORD}
ESPOCRM_DATABASE_PASSWORD=${USER_DB_PASSWORD}
MYSQL_ROOT_PASSWORD=${USER_MYSQL_ROOT_PASSWORD}
MYSQL_PASSWORD=${USER_DB_PASSWORD}
EOF

# docker-compose.yml ファイルを作成 (内容は前回と同じ)
cat <<EOF > docker-compose.yml
version: '3.8'

services:
  espocrm:
    image: espocrm/espocrm:latest
    container_name: espocrm
    ports:
      - "80:80"
    restart: always
    volumes:
      - ./data:/var/www/html/data
      - ./custom:/var/www/html/custom
      - ./config:/var/www/html/application/config
    environment:
      - ESPOCRM_DATABASE_HOST=db
      - ESPOCRM_DATABASE_USER=espocrm
      - ESPOCRM_DATABASE_PASSWORD=\${ESPOCRM_DATABASE_PASSWORD}
      - ESPOCRM_DATABASE_NAME=espocrm
      - ESPOCRM_ADMIN_USERNAME=admin
      - ESPOCRM_ADMIN_PASSWORD=\${ESPOCRM_ADMIN_PASSWORD}
      - ESPOCRM_SITE_URL=\${ESPOCRM_SITE_URL}
    depends_on:
      - db

  db:
    image: mysql:8.0
    container_name: espocrm-db
    restart: always
    command: --default-authentication-plugin=mysql_native_password
    volumes:
      - ./db-data:/var/lib/mysql
    environment:
      - MYSQL_ROOT_PASSWORD=\${MYSQL_ROOT_PASSWORD}
      - MYSQL_DATABASE=espocrm
      - MYSQL_USER=espocrm
      - MYSQL_PASSWORD=\${MYSQL_PASSWORD}
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost"]
      interval: 10s
      timeout: 5s
      retries: 5
EOF


# ==============================================================================
# ステップ4: EspoCRMの起動
# ==============================================================================
echo " [5/5] 設定ファイルの生成が完了しました。"

while true; do
    read -p "すべての準備が整いました。EspoCRMを起動しますか？ (y/n): " yn
    case $yn in
        [Yy]* )
            echo "EspoCRMを起動します... (初回起動には数分かかる場合があります)"
            # ★★★★★★★★★★★★★★★★★ 変更点 ★★★★★★★★★★★★★★★★★
            sudo docker compose up -d
            # ★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★
            echo ""
            echo "------------------------------------------------------------------"
            echo "★★★★★ 起動処理を開始しました ★★★★★"
            echo "1〜2分後に、以下のコマンドでコンテナの状態を確認してください:"
            echo "    cd ~/espocrm && sudo docker compose ps"
            echo "STATUSが 'Up' または 'healthy' になっていれば成功です。"
            echo ""
            echo "確認後、ブラウザで以下のURLにアクセスしてください:"
            echo "    http://${USER_SITE_URL}"
            echo "------------------------------------------------------------------"
            break;;
        [Nn]* )
            echo "起動をキャンセルしました。後で手動で起動するには、以下のコマンドを実行してください:"
            echo "    cd ~/espocrm && sudo docker compose up -d"
            exit;;
        * ) echo "y または n を入力してください。";;
    esac
done

echo ""
echo "--- スクリプトの処理は以上です ---"