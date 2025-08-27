#!/usr/bin/env bash

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== Установка MeshCentral на Ubuntu ===${NC}"

# Устанавливаем зависимости
sudo apt update -y
sudo apt install -y curl wget gnupg lsb-release build-essential sudo jq

# === Node.js LTS (20.x) ===
echo -e "${GREEN}Установка Node.js 20...${NC}"
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt install -y nodejs
sudo npm install -g npm

# === MongoDB (7.0) ===
echo -e "${GREEN}Установка MongoDB 7.0...${NC}"
curl -fsSL https://pgp.mongodb.com/server-7.0.asc | \
  sudo gpg --dearmor -o /usr/share/keyrings/mongodb-server-7.0.gpg

echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg ] https://repo.mongodb.org/apt/ubuntu $(lsb_release -cs)/mongodb-org/7.0 multiverse" | \
  sudo tee /etc/apt/sources.list.d/mongodb-org-7.0.list

sudo apt update -y
sudo apt install -y mongodb-org
sudo systemctl enable mongod
sudo systemctl start mongod

# Проверка Mongo
if systemctl status mongod | grep -q "active (running)"; then
  echo -e "${GREEN}MongoDB запущен!${NC}"
else
  echo -e "${RED}Ошибка запуска MongoDB${NC}"
  exit 1
fi

# === MeshCentral ===
echo -e "${GREEN}Установка MeshCentral...${NC}"
sudo mkdir -p /opt/meshcentral
sudo chown $USER:$USER /opt/meshcentral
cd /opt/meshcentral
npm install meshcentral

# === Config.json ===
mkdir -p /opt/meshcentral/meshcentral-data
cat <<EOF > /opt/meshcentral/meshcentral-data/config.json
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
User=$USER
WorkingDirectory=/opt/meshcentral
ExecStart=/usr/bin/node /opt/meshcentral/node_modules/meshcentral
Restart=always
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
EOF

sudo setcap 'cap_net_bind_service=+ep' $(which node)
sudo systemctl daemon-reload
sudo systemctl enable meshcentral
sudo systemctl start meshcentral

# === Проверка ===
if systemctl status meshcentral | grep -q "active (running)"; then
  echo -e "${GREEN}MeshCentral успешно установлен и работает!${NC}"
  echo -e "${YELLOW}Откройте в браузере: http://$(hostname -I | awk '{print $1}'):443${NC}"
else
  echo -e "${RED}Ошибка запуска MeshCentral${NC}"
  exit 1
fi
