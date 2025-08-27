#!/usr/bin/env bash

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== Установка MeshCentral на Ubuntu (Node.js 18 + MongoDB 5) ===${NC}"

# Определение версии Ubuntu
UBUNTU_CODENAME=$(lsb_release -cs)
echo -e "${YELLOW}Обнаружена Ubuntu $UBUNTU_CODENAME${NC}"

# Обновление и зависимости
sudo apt update -y
sudo apt install -y curl wget gnupg lsb-release build-essential jq sudo

# === Node.js 18.x ===
echo -e "${GREEN}Установка Node.js 18.x...${NC}"
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt install -y nodejs

# Проверка версии Node.js и npm
NODE_VERSION=$(node -v)
NPM_VERSION=$(npm -v)
echo -e "${GREEN}Установлен Node.js $NODE_VERSION и npm $NPM_VERSION${NC}"

# === MongoDB 5.0 ===
echo -e "${GREEN}Установка MongoDB 5.0...${NC}"
sudo install -d -m 0755 -o root -g root /etc/apt/keyrings
curl -fsSL https://pgp.mongodb.com/server-5.0.asc | sudo gpg --dearmor -o /etc/apt/keyrings/mongodb-server-5.0.gpg
echo "deb [arch=amd64,arm64 signed-by=/etc/apt/keyrings/mongodb-server-5.0.gpg] https://repo.mongodb.org/apt/ubuntu $UBUNTU_CODENAME/mongodb-org/5.0 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-5.0.list
sudo chmod 644 /etc/apt/keyrings/mongodb-server-5.0.gpg
sudo apt update -y
sudo apt install -y mongodb-org
sudo systemctl enable --now mongod

# Проверка MongoDB
sleep 5
if systemctl is-active --quiet mongod; then
    echo -e "${GREEN}MongoDB запущен!${NC}"
else
    echo -e "${RED}Ошибка запуска MongoDB${NC}"
    sudo journalctl -u mongod -n 10 --no-pager
    exit 1
fi

# === MeshCentral ===
echo -e "${GREEN}Установка MeshCentral...${NC}"
sudo mkdir -p /opt/meshcentral
if ! id "meshcentral" &>/dev/null; then
    sudo useradd -r -s /bin/false meshcentral
fi
sudo chown meshcentral:meshcentral /opt/meshcentral
cd /opt/meshcentral
sudo -u meshcentral npm install meshcentral@latest

# === Config.json ===
sudo -u meshcentral mkdir -p /opt/meshcentral/meshcentral-data
CONFIG_CONTENT='{
  "settings": {
    "port": 443,
    "aliasPort": 443,
    "redirPort": 80,
    "TlsOffload": true,
    "MongoDb": "mongodb://127.0.0.1:27017/meshcentral",
    "MongoDbCol": "meshcentral"
  }
}'
echo "$CONFIG_CONTENT" | sudo tee /opt/meshcentral/meshcentral-data/config.json > /dev/null

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
else
    echo -e "${RED}Ошибка запуска MeshCentral${NC}"
    sudo journalctl -u meshcentral -n 15 --no-pager
    exit 1
fi

# === Опциональная автоматическая настройка ===
read -p "Хотите выполнить автоматическую настройку SSL и администратора? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${GREEN}Настройка MeshCentral...${NC}"
    read -p "Введите доменное имя: " dnsnames
    read -p "Введите email для Let's Encrypt: " letsemail
    read -p "Введите название компании: " coname
    read -p "Введите имя администратора: " meshuname
    meshpwd=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 20 | head -n 1)

    sudo systemctl stop meshcentral

    sudo -u meshcentral jq ".settings.cert = \"$dnsnames\"" /opt/meshcentral/meshcentral-data/config.json > /tmp/config.tmp
    sudo mv /tmp/config.tmp /opt/meshcentral/meshcentral-data/config.json

    sudo -u meshcentral jq ".letsencrypt = {\"email\": \"$letsemail\", \"names\": \"$dnsnames\", \"production\": true}" /opt/meshcentral/meshcentral-data/config.json > /tmp/config.tmp
    sudo mv /tmp/config.tmp /opt/meshcentral/meshcentral-data/config.json

    sudo -u meshcentral jq ".settings.agentCustomization = {\"displayname\": \"$coname Support\", \"description\": \"$coname Remote Agent\", \"companyName\": \"$coname\", \"serviceName\": \"${coname}Remote\"}" /opt/meshcentral/meshcentral-data/config.json > /tmp/config.tmp
    sudo mv /tmp/config.tmp /opt/meshcentral/meshcentral-data/config.json

    sudo systemctl start meshcentral

    sleep 5
    echo -e "${GREEN}Создание администратора...${NC}"
    sudo -u meshcentral node /opt/meshcentral/node_modules/meshcentral/meshcentral.js --createaccount "$meshuname" --pass "$meshpwd" --email "$letsemail"
    sudo -u meshcentral node /opt/meshcentral/node_modules/meshcentral/meshcentral.js --adminaccount "$meshuname"

    echo -e "${GREEN}Автоматическая настройка завершена!${NC}"
    echo -e "${YELLOW}Администратор: $meshuname${NC}"
    echo -e "${YELLOW}Пароль: $meshpwd${NC}"
    echo -e "${YELLOW}Доступ: https://$dnsnames/${NC}"
fi

echo -e "${GREEN}Установка завершена!${NC}"
