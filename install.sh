#!/usr/bin/env bash

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== Установка MeshCentral на Ubuntu ===${NC}"

# Обновление системы и зависимости
sudo apt update -y
sudo apt install -y curl wget gnupg lsb-release build-essential jq sudo

# === Node.js 20.x ===
echo -e "${GREEN}Установка Node.js 20...${NC}"
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt install -y nodejs

# === MongoDB 7.0 (репозиторий Jammy для Ubuntu 24.04) ===
echo -e "${GREEN}Установка MongoDB 7.0...${NC}"
sudo install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://pgp.mongodb.com/server-7.0.asc | sudo gpg --dearmor -o /etc/apt/keyrings/mongodb-server-7.0.gpg

# Жёстко указываем jammy вместо noble
UBUNTU_CODENAME="jammy"

echo "deb [arch=amd64,arm64 signed-by=/etc/apt/keyrings/mongodb-server-7.0.gpg] \
https://repo.mongodb.org/apt/ubuntu $UBUNTU_CODENAME/mongodb-org/7.0 multiverse" | \
  sudo tee /etc/apt/sources.list.d/mongodb-org-7.0.list

sudo apt update -y
sudo apt install -y mongodb-org
sudo systemctl enable --now mongod

# Проверка MongoDB
if systemctl is-active --quiet mongod; then
  echo -e "${GREEN}MongoDB запущен!${NC}"
else
  echo -e "${RED}Ошибка запуска MongoDB${NC}"
  exit 1
fi

# === MeshCentral ===
echo -e "${GREEN}Установка MeshCentral...${NC}"
sudo mkdir -p /opt/meshcentral
sudo useradd -r -s /bin/false meshcentral || true
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
    "redirPort": 80
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
User=meshcentral
WorkingDirectory=/opt/meshcentral
ExecStart=/usr/bin/node /opt/meshcentral/node_modules/meshcentral --launch
Restart=always
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
EOF

# Разрешаем Node слушать порты <1024
sudo setcap 'cap_net_bind_service=+ep' $(which node)

# Запуск MeshCentral
sudo systemctl daemon-reload
sudo systemctl enable --now meshcentral

# === Проверка ===
if systemctl is-active --quiet meshcentral; then
  echo -e "${GREEN}MeshCentral успешно установлен и работает!${NC}"
  echo -e "${YELLOW}Откройте в браузере: https://$(hostname -I | awk '{print $1}')/${NC}"
else
  echo -e "${RED}Ошибка запуска MeshCentral${NC}"
  exit 1
fi
