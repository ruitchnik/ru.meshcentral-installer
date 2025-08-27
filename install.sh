#!/usr/bin/env bash

# ========================================
# Установка MeshCentral на Ubuntu
# ========================================

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== Установка MeshCentral на Ubuntu ===${NC}"

# Определяем версию Ubuntu
UBUNTU_CODENAME=$(lsb_release -cs)
echo -e "${YELLOW}Обнаружена Ubuntu $UBUNTU_CODENAME${NC}"

# =========================
# Обновление системы и зависимости
# =========================
echo -e "${GREEN}Обновление системы и установка зависимостей...${NC}"
sudo apt update -y
sudo apt upgrade -y
sudo apt install -y curl wget gnupg lsb-release build-essential jq sudo software-properties-common apt-transport-https

# =========================
# Node.js 18.x + npm
# =========================
echo -e "${GREEN}Установка Node.js 18.x и npm...${NC}"
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt install -y nodejs
echo -e "${GREEN}Node.js $(node -v), npm $(npm -v) установлен${NC}"

# =========================
# MongoDB 6.x
# =========================
echo -e "${GREEN}Установка MongoDB 6.x...${NC}"
sudo install -d -m 0755 -o root -g root /etc/apt/keyrings
curl -fsSL https://pgp.mongodb.com/server-6.0.asc | sudo gpg --dearmor -o /etc/apt/keyrings/mongodb-server-6.0.gpg
echo "deb [arch=amd64,arm64 signed-by=/etc/apt/keyrings/mongodb-server-6.0.gpg] https://repo.mongodb.org/apt/ubuntu $UBUNTU_CODENAME/mongodb-org/6.0 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-6.0.list
sudo chmod 644 /etc/apt/keyrings/mongodb-server-6.0.gpg
sudo apt update -y
sudo apt install -y mongodb-org
sudo systemctl enable --now mongod

# Проверка запуска MongoDB
sleep 5
if systemctl is-active --quiet mongod; then
    echo -e "${GREEN}MongoDB успешно запущен${NC}"
else
    echo -e "${RED}Ошибка запуска MongoDB${NC}"
    sudo journalctl -u mongod -n 10 --no-pager
    exit 1
fi

# =========================
# Создание пользователя и директорий MeshCentral
# =========================
echo -e "${GREEN}Создание пользователя и директорий для MeshCentral...${NC}"
sudo mkdir -p /opt/meshcentral
if ! id "meshcentral" &>/dev/null; then
    sudo useradd -r -s /usr/sbin/nologin meshcentral
fi
sudo chown -R meshcentral:meshcentral /opt/meshcentral

# =========================
# Установка MeshCentral
# =========================
echo -e "${GREEN}Установка MeshCentral...${NC}"
sudo -u meshcentral npm install meshcentral@latest --prefix /opt/meshcentral --unsafe-perm
sudo -u meshcentral mkdir -p /opt/meshcentral/meshcentral-data

# =========================
# Создание config.json
# =========================
echo -e "${GREEN}Создание конфигурационного файла MeshCentral...${NC}"
CONFIG_FILE="/opt/meshcentral/meshcentral-data/config.json"
sudo tee $CONFIG_FILE > /dev/null <<EOF
{
  "settings": {
    "port": 443,
    "aliasPort": 443,
    "redirPort": 80,
    "TlsOffload": true,
    "MongoDb": "mongodb://127.0.0.1:27017/meshcentral",
    "MongoDbCol": "meshcentral",
    "WANonly": true
  }
}
EOF
sudo chown -R meshcentral:meshcentral /opt/meshcentral/meshcentral-data

# =========================
# Настройка systemd сервиса
# =========================
echo -e "${GREEN}Создание systemd сервиса MeshCentral...${NC}"
sudo tee /etc/systemd/system/meshcentral.service > /dev/null <<EOF
[Unit]
Description=MeshCentral Server
After=network.target mongod.service

[Service]
Type=simple
User=meshcentral
WorkingDirectory=/opt/meshcentral
ExecStart=/usr/bin/node /opt/meshcentral/node_modules/meshcentral/meshcentral.js
Restart=always
RestartSec=5
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
EOF

# Разрешаем Node.js слушать порты <1024
sudo setcap 'cap_net_bind_service=+ep' $(readlink -f $(which node))

# =========================
# Запуск MeshCentral
# =========================
echo -e "${GREEN}Запуск MeshCentral...${NC}"
sudo systemctl daemon-reload
sudo systemctl enable --now meshcentral
sleep 10

if systemctl is-active --quiet meshcentral; then
    echo -e "${GREEN}MeshCentral успешно установлен и запущен!${NC}"
    IP_ADDRESS=$(hostname -I | awk '{print $1}')
    echo -e "${YELLOW}Откройте в браузере: https://${IP_ADDRESS}/${NC}"
else
    echo -e "${RED}Ошибка запуска MeshCentral${NC}"
    sudo journalctl -u meshcentral -n 15 --no-pager
    exit 1
fi

echo -e "${GREEN}=== Установка завершена ===${NC}"
