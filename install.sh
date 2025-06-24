#!/usr/bin/env bash

# Установка MeshCentral с MongoDB
set -e

# Цветовые константы
GREEN='\033[1;32m'
RED='\033[1;31m'
NC='\033[0m'

# Проверка root-прав
if [[ $EUID -eq 0 ]]; then
  echo -e "${RED}❌ Скрипт не должен запускаться от root${NC}"
  exit 1
fi

# Установка зависимостей
echo -e "${GREEN}▶ Установка базовых зависимостей...${NC}"
sudo apt-get update > /dev/null
sudo apt-get install -y curl sudo lsb-release jq > /dev/null

# Установка Node.js 18
echo -e "${GREEN}▶ Установка Node.js 18...${NC}"
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt-get install -y gcc g++ make nodejs > /dev/null
sudo npm install -g npm > /dev/null

# Установка MeshCentral
echo -e "${GREEN}▶ Установка MeshCentral...${NC}"
sudo mkdir -p /opt/meshcentral/meshcentral-data
sudo chown ${USER}:${USER} -R /opt/meshcentral
cd /opt/meshcentral

# Создание package.json с фиксированными версиями
cat <<EOF > package.json
{
  "dependencies": {
    "acme-client": "4.2.5",
    "archiver": "5.3.1",
    "meshcentral": "1.1.9",
    "otplib": "10.2.3"
  }
}
EOF

npm install > /dev/null

# Настройка службы systemd
echo -e "${GREEN}▶ Настройка службы MeshCentral...${NC}"
cat <<EOF | sudo tee /etc/systemd/system/meshcentral.service > /dev/null
[Unit]
Description=MeshCentral Server
After=network.target mongod.service

[Service]
Type=simple
LimitNOFILE=1000000
ExecStart=/usr/bin/node node_modules/meshcentral
Environment=NODE_ENV=production
WorkingDirectory=/opt/meshcentral
User=${USER}
Group=${USER}
Restart=always
RestartSec=10s

[Install]
WantedBy=multi-user.target
EOF

sudo setcap 'cap_net_bind_service=+ep' $(which node)
sudo systemctl daemon-reload
sudo systemctl enable meshcentral > /dev/null

# Установка MongoDB 6.0
echo -e "${GREEN}▶ Установка MongoDB 6.0...${NC}"
wget -qO - https://www.mongodb.org/static/pgp/server-6.0.asc | sudo gpg --dearmor -o /usr/share/keyrings/mongodb.gpg
echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb.gpg ] https://repo.mongodb.org/apt/ubuntu $(lsb_release -cs)/mongodb-org/6.0 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-6.0.list
sudo apt-get update > /dev/null
sudo apt-get install -y mongodb-org > /dev/null
sudo systemctl enable mongod
sudo systemctl start mongod

# Ожидание запуска MongoDB
echo -e "${GREEN}▶ Ожидание запуска MongoDB...${NC}"
for i in {1..30}; do
  if mongosh --eval "db.runCommand({ping:1})" >/dev/null 2>&1; then
    break
  fi
  sleep 2
  if [ "$i" -eq 30 ]; then
    echo -e "${RED}❌ Не удалось запустить MongoDB${NC}"
    sudo journalctl -u mongod --no-pager -n 50
    exit 1
  fi
done

# Настройка MeshCentral для работы с MongoDB
echo -e "${GREEN}▶ Настройка MeshCentral для работы с MongoDB...${NC}"
cat <<EOF > /opt/meshcentral/meshcentral-data/config.json
{
  "settings": {
    "MongoDb": "mongodb://127.0.0.1:27017/meshcentral",
    "MongoDbCol": "meshcentral",
    "port": 443,
    "aliasPort": 443,
    "redirPort": 80,
    "tlsOffload": false,
    "WANonly": true,
    "SelfUpdate": true
  }
}
EOF

sudo systemctl start meshcentral

# Ожидание запуска MeshCentral
echo -e "${GREEN}▶ Ожидание запуска MeshCentral...${NC}"
for i in {1..30}; do
  if systemctl is-active --quiet meshcentral; then
    break
  fi
  sleep 2
  if [ "$i" -eq 30 ]; then
    echo -e "${RED}❌ Не удалось запустить MeshCentral${NC}"
    sudo journalctl -u meshcentral --no-pager -n 50
    exit 1
  fi
done

# Дополнительная настройка
echo -e "${GREEN}▶ Хотите выполнить дополнительную настройку?${NC}"
select yn in "Да" "Нет"; do
  case $yn in
    "Да")
      read -p "Введите доменное имя: " DOMAIN
      read -p "Введите email для Let's Encrypt: " EMAIL
      read -p "Введите название компании: " COMPANY
      read -p "Введите имя администратора: " ADMIN_USER
      ADMIN_PASS=$(tr -dc 'A-Za-z0-9' < /dev/urandom | fold -w 20 | head -n 1)

      sudo systemctl stop meshcentral

      # Настройка конфигурации
      jq --arg DOMAIN "$DOMAIN" \
         --arg EMAIL "$EMAIL" \
         --arg COMPANY "$COMPANY" \
         '.settings += {
            "cert": $DOMAIN,
            "production": true,
            "title": $COMPANY,
            "newAccounts": false,
            "agentInviteCodes": true,
            "agentCustomization": {
              "displayname": ($COMPANY + " Support"),
              "description": ($COMPANY + " Remote Agent"),
              "companyName": $COMPANY,
              "serviceName": ($COMPANY + "Remote")
            },
            "plugins": { "enabled": true },
            "MaxInvalidLogin": {
              "time": 5,
              "count": 5,
              "coolofftime": 30
            }
          } |
          .letsencrypt += {
            "email": $EMAIL,
            "names": [$DOMAIN]
          }' /opt/meshcentral/meshcentral-data/config.json > config.tmp && mv config.tmp /opt/meshcentral/meshcentral-data/config.json

      sudo systemctl start meshcentral

      # Ожидание запуска
      for i in {1..30}; do
        if systemctl is-active --quiet meshcentral; then
          break
        fi
        sleep 2
      done

      # Создание администратора
      cd /opt/meshcentral
      node node_modules/meshcentral --createaccount "$ADMIN_USER" --pass "$ADMIN_PASS" --email "$EMAIL"
      node node_modules/meshcentral --adminaccount "$ADMIN_USER"

      # Настройка группы устройств
      node node_modules/meshcentral/meshctrl.js --url "wss://$DOMAIN:443" --loginuser "$ADMIN_USER" --loginpass "$ADMIN_PASS" AddDeviceGroup --name "$COMPANY"
      node node_modules/meshcentral/meshctrl.js --url "wss://$DOMAIN:443" --loginuser "$ADMIN_USER" --loginpass "$ADMIN_PASS" EditDeviceGroup --group "$COMPANY" --desc "$COMPANY Support Group" --consent 71
      node node_modules/meshcentral/meshctrl.js --url "wss://$DOMAIN:443" --loginuser "$ADMIN_USER" --loginpass "$ADMIN_PASS" EditUser --userid "$ADMIN_USER" --realname "$COMPANY Support"

      echo -e "${GREEN}✅ Настройка завершена!${NC}"
      echo -e "Адрес: ${GREEN}https://$DOMAIN${NC}"
      echo -e "Логин: ${GREEN}$ADMIN_USER${NC}"
      echo -e "Пароль: ${GREEN}$ADMIN_PASS${NC}"
      break
      ;;
    "Нет")
      echo -e "${GREEN}✅ Установка завершена. Не забудьте настроить MeshCentral вручную.${NC}"
      echo -e "Файл конфигурации: ${GREEN}/opt/meshcentral/meshcentral-data/config.json${NC}"
      break
      ;;
  esac
done
