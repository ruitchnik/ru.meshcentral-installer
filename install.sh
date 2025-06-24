#!/bin/bash

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}❌ Ошибка: Запускать нужно от root${NC}"
   exit 1
fi

echo -e "${GREEN}🚀 Установка MeshCentral...${NC}"

echo -e "${YELLOW}🔄 Обновление системы${NC}"
apt update && apt upgrade -y

echo -e "${YELLOW}📦 Добавляю репозиторий MongoDB и устанавливаю MongoDB...${NC}"
wget -qO - https://www.mongodb.org/static/pgp/server-5.0.asc | apt-key add -
CODENAME=$(lsb_release -cs)
echo "deb [ arch=amd64 ] https://repo.mongodb.org/apt/ubuntu $CODENAME/mongodb-org/5.0 multiverse" | tee /etc/apt/sources.list.d/mongodb-org-5.0.list
apt update
apt install -y mongodb-org curl nodejs npm

echo -e "${YELLOW}🔄 Запускаю MongoDB${NC}"
systemctl enable mongod
systemctl start mongod
sleep 5

echo -e "${YELLOW}📥 Устанавливаю MeshCentral${NC}"
mkdir -p /opt/meshcentral
cd /opt/meshcentral || exit
npm install --save --save-exact meshcentral@1.1.9

# Запрашиваем у пользователя данные
read -p "🌐 Домен: " DOMAIN
read -p "📧 Email для Let's Encrypt: " EMAIL
read -p "🏢 Название компании: " COMPANY
read -p "👤 Имя администратора: " ADMIN_USER
read -s -p "🔐 Пароль администратора: " ADMIN_PASS
echo

CONFIG_FILE="/opt/meshcentral/meshcentral-data/config.json"

mkdir -p /opt/meshcentral/meshcentral-data

# Записываем конфиг
cat <<EOF > $CONFIG_FILE
{
  "settings": {
    "cert": "$DOMAIN",
    "MongoDb": "mongodb://127.0.0.1:27017/meshcentral",
    "MongoDbCol": "meshcentral",
    "port": 443,
    "aliasPort": 443,
    "redirPort": 80,
    "tlsOffload": false,
    "WANonly": true,
    "SelfUpdate": true,
    "letsencrypt": {
      "email": "$EMAIL",
      "names": ["$DOMAIN"]
    }
  }
}
EOF

echo -e "${YELLOW}📃 Создаю systemd юнит${NC}"
cat <<EOF > /etc/systemd/system/meshcentral.service
[Unit]
Description=MeshCentral Server
After=network.target mongod.service

[Service]
ExecStart=$(which node) /opt/meshcentral/node_modules/meshcentral
WorkingDirectory=/opt/meshcentral
Restart=always
User=root
Group=root
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable meshcentral
systemctl start meshcentral

echo -e "${YELLOW}⏳ Ждем пока MeshCentral запустится...${NC}"
sleep 10

echo -e "${YELLOW}🔧 Создаю администратора...${NC}"
cd /opt/meshcentral || exit
node ./node_modules/meshcentral --createaccount "$ADMIN_USER" --pass "$ADMIN_PASS" --email "$EMAIL"
node ./node_modules/meshcentral --adminaccount "$ADMIN_USER"

echo -e "${GREEN}✅ Установка и настройка завершены!${NC}"
echo -e "Адрес: https://$DOMAIN"
echo -e "Логин: $ADMIN_USER"
echo -e "Пароль: $ADMIN_PASS"
