#!/usr/bin/env bash

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== Установка MeshCentral на Ubuntu ===${NC}"

# Определение версии Ubuntu
UBUNTU_CODENAME=$(lsb_release -cs)
echo -e "${YELLOW}Обнаружена Ubuntu: $UBUNTU_CODENAME${NC}"

# Обновление системы и зависимости
sudo apt update -y
sudo apt install -y curl wget gnupg lsb-release build-essential jq sudo

# === Node.js 20.x ===
echo -e "${GREEN}Установка Node.js 20...${NC}"
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt install -y nodejs

# Проверка Node.js
if ! command -v node &> /dev/null; then
    echo -e "${RED}Node.js не установлен!${NC}"
    exit 1
fi

NODE_VERSION=$(node -v)
echo -e "${GREEN}Установлен Node.js $NODE_VERSION${NC}"

# === MongoDB 5.0 ===
echo -e "${GREEN}Установка MongoDB 5.0...${NC}"
sudo install -d -m 0755 -o root -g root /etc/apt/keyrings

# Установка MongoDB 5.0 (поддерживается на noble)
curl -fsSL https://pgp.mongodb.com/server-5.0.asc | sudo gpg --dearmor -o /etc/apt/keyrings/mongodb-server-5.0.gpg
echo "deb [arch=amd64,arm64 signed-by=/etc/apt/keyrings/mongodb-server-5.0.gpg] https://repo.mongodb.org/apt/ubuntu $UBUNTU_CODENAME/mongodb-org/5.0 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-5.0.list

sudo chmod 644 /etc/apt/keyrings/mongodb-server-5.0.gpg
sudo apt update -y
sudo apt install -y mongodb-org

# Запуск MongoDB
sudo systemctl enable --now mongod

# Проверка MongoDB с перезапуском при необходимости
sleep 5
if systemctl is-active --quiet mongod; then
    echo -e "${GREEN}MongoDB запущен!${NC}"
else
    echo -e "${YELLOW}Попытка перезапуска MongoDB...${NC}"
    sudo systemctl restart mongod
    sleep 3
    if systemctl is-active --quiet mongod; then
        echo -e "${GREEN}MongoDB запущен после перезапуска!${NC}"
    else
        echo -e "${RED}Ошибка запуска MongoDB${NC}"
        echo -e "${YELLOW}Проверка статуса...${NC}"
        sudo systemctl status mongod --no-pager
        exit 1
    fi
fi

# === MeshCentral ===
echo -e "${GREEN}Установка MeshCentral...${NC}"
sudo mkdir -p /opt/meshcentral
if ! id "meshcentral" &>/dev/null; then
    sudo useradd -r -s /bin/false meshcentral
fi
sudo chown meshcentral:meshcentral /opt/meshcentral
cd /opt/meshcentral
sudo -u meshcentral npm install meshcentral

# === Config.json ===
sudo -u meshcentral mkdir -p /opt/meshcentral/meshcentral-data
cat <<EOF | sudo tee /opt/meshcentral/meshcentral-data/config.json
{
  "settings": {
    "MongoDb": "mongodb://127.0.0.1:27017/meshcentral",
    "MongoDbCol": "meshcentral",
    "port": 443,
    "aliasPort": 443,
    "redirPort": 80,
    "TlsOffload": true
  }
}
EOF

# === Systemd service ===
echo -e "${GREEN}Создание systemd сервиса...${NC}"
cat <<EOF | sudo tee /etc/systemd/system/meshcentral.service
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

# Разрешаем Node слушать порты <1024
sudo setcap 'cap_net_bind_service=+ep' $(readlink -f $(which node))

# Запуск MeshCentral
sudo systemctl daemon-reload
sudo systemctl enable --now meshcentral

# Проверка запуска
sleep 10
if systemctl is-active --quiet meshcentral; then
    echo -e "${GREEN}MeshCentral успешно установлен и работает!${NC}"
    IP_ADDRESS=$(hostname -I | awk '{print $1}')
    echo -e "${YELLOW}Откройте в браузере: https://${IP_ADDRESS}/${NC}"
    echo -e "${YELLOW}Или: https://$(hostname)/${NC}"
else
    echo -e "${RED}Ошибка запуска MeshCentral${NC}"
    sudo journalctl -u meshcentral -n 15 --no-pager
    echo -e "${YELLOW}Попытка перезапуска...${NC}"
    sudo systemctl restart meshcentral
    sleep 5
    if systemctl is-active --quiet meshcentral; then
        echo -e "${GREEN}MeshCentral запущен после перезапуска!${NC}"
    else
        exit 1
    fi
fi

echo -e "${GREEN}Установка завершена!${NC}"
echo -e "${YELLOW}Для первоначальной настройки откройте в браузере:${NC}"
echo -e "${YELLOW}https://ваш-ip-адрес/${NC}"
echo -e "${YELLOW}И создайте администратора.${NC}"
