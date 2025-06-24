#!/usr/bin/env bash

# Установка MeshCentral с использованием MongoDB
set -e

# Цветовые константы
GREEN='\033[1;32m'
RED='\033[1;31m'
NC='\033[0m'

# Проверка архитектуры
ARCH=$(uname -m)
if [[ "$ARCH" != "x86_64" && "$ARCH" != "aarch64" ]]; then
  echo -e "${RED}❌ Неподдерживаемая архитектура: $ARCH${NC}"
  exit 1
fi

echo -e "${GREEN}▶ Проверка и установка зависимостей...${NC}"
if ! command -v lsb_release &> /dev/null; then
  sudo apt-get update
  sudo apt-get install -y lsb-core
fi

DISTRO=$(lsb_release -si | tr '[:upper:]' '[:lower:]')
CODENAME=$(lsb_release -cs)

# Проверка версии ОС для Ubuntu
if [[ "$DISTRO" == "ubuntu" && "$(lsb_release -rs | cut -d'.' -f1)" -lt 20 ]]; then
  echo -e "${RED}❌ Требуется Ubuntu 20.04 или новее${NC}"
  exit 1
fi

sudo apt-get update
sudo apt-get install -y curl sudo jq gnupg

echo -e "${GREEN}▶ Установка Node.js 18...${NC}"
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt-get install -y gcc g++ make nodejs
sudo npm install -g npm

echo -e "${GREEN}▶ Установка MeshCentral...${NC}"
sudo mkdir -p /opt/meshcentral/meshcentral-data
sudo chown "$USER":"$USER" -R /opt/meshcentral
cd /opt/meshcentral
npm init -y

# Установка фиксированных версий пакетов
npm install --save --save-exact meshcentral@1.1.9 acme-client@4.2.5 archiver@5.3.1 otplib@10.2.3 pg@8.7.1 pgtools@0.3.2

echo -e "${GREEN}▶ Создание службы systemd...${NC}"
cat <<EOF | sudo tee /etc/systemd/system/meshcentral.service > /dev/null
[Unit]
Description=MeshCentral Server
After=network.target mongod.service

[Service]
Type=simple
LimitNOFILE=1000000
ExecStart=/usr/bin/node /opt/meshcentral/node_modules/meshcentral
Environment=NODE_ENV=production
WorkingDirectory=/opt/meshcentral
User=${USER}
Group=${USER}
Restart=always
RestartSec=10s

[Install]
WantedBy=multi-user.target
EOF

sudo setcap 'cap_net_bind_service=+ep' "$(which node)"
sudo systemctl daemon-reload
sudo systemctl enable meshcentral

echo -e "${GREEN}▶ Установка MongoDB 7.0...${NC}"
# Установка MongoDB 7.0
wget -qO - https://www.mongodb.org/static/pgp/server-7.0.asc | sudo gpg --dearmor -o /usr/share/keyrings/mongodb.gpg
echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb.gpg ] https://repo.mongodb.org/apt/ubuntu ${CODENAME}/mongodb-org/7.0 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-7.0.list
sudo apt-get update
sudo apt-get install -y mongodb-org

# Настройка MongoDB
sudo systemctl enable mongod
sudo systemctl start mongod

echo -e "${GREEN}▶ Ожидание запуска MongoDB...${NC}"
for i in {1..30}; do
  if mongosh --eval "db.runCommand({ping:1})" >/dev/null 2>&1; then
    break
  fi
  sleep 2
  if [ "$i" -eq 30 ]; then
    echo -e "${RED}❌ Не удалось запустить MongoDB${NC}"
    exit 1
  fi
done

echo -e "${GREEN}▶ Настройка MeshCentral на использование MongoDB...${NC}"
CONFIG_FILE="/opt/meshcentral/meshcentral-data/config.json"

cat <<EOF > "$CONFIG_FILE"
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

echo -e "${GREEN}▶ Ожидание запуска MeshCentral...${NC}"
for i in {1..30}; do
  if systemctl is-active --quiet meshcentral; then
    break
  fi
  sleep 2
  if [ "$i" -eq 30 ]; then
    echo -e "${RED}❌ Не удалось запустить MeshCentral${NC}"
    exit 1
  fi
done

echo -e "${GREEN}▶ Хотите выполнить предварительную настройку?${NC}"
select choice in "Да" "Нет"; do
  case $choice in
    "Да")
      read -p "Введите доменное имя (DNS): " dnsname
      read -p "Email для Let's Encrypt: " email
      read -p "Название компании: " company
      read -p "Имя администратора: " username
      password=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20)

      sudo systemctl stop meshcentral

      jq \
        --arg dns "$dnsname" \
        --arg email "$email" \
        --argjson prod true \
        '.settings.cert = $dns |
         .settings.production = $prod |
         .letsencrypt.email = $email |
         .letsencrypt.names = [$dns]' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp"
      mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

      sudo systemctl start meshcentral
      echo -e "${GREEN}⏳ Ожидание запуска MeshCentral...${NC}"
      sleep 10

      echo -e "${GREEN}▶ Создание администратора...${NC}"
      cd /opt/meshcentral
      node ./node_modules/meshcentral --createaccount "$username" --pass "$password" --email "$email"
      node ./node_modules/meshcentral --adminaccount "$username"

      echo -e "${GREEN}▶ Создание группы устройств...${NC}"
      node ./node_modules/meshcentral/meshctrl.js --url "wss://$dnsname:443" --loginuser "$username" --loginpass "$password" AddDeviceGroup --name "$company"
      node ./node_modules/meshcentral/meshctrl.js --url "wss://$dnsname:443" --loginuser "$username" --loginpass "$password" EditDeviceGroup --group "$company" --desc "$company Support Group" --consent 71
      node ./node_modules/meshcentral/meshctrl.js --url "wss://$dnsname:443" --loginuser "$username" --loginpass "$password" EditUser --userid "$username" --realname "$company Support"

      echo -e "${GREEN}✅ Установка завершена!${NC}"
      echo "Адрес: https://$dnsname"
      echo "Логин: $username"
      echo "Пароль: $password"
      break
      ;;
    "Нет")
      echo -e "${GREEN}✅ Установка завершена без предварительной настройки.${NC}"
      echo "Для завершения настройки отредактируйте файл: $CONFIG_FILE"
      break
      ;;
    *)
      echo "Выберите 'Да' или 'Нет'"
      ;;
  esac
done
