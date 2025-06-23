#!/usr/bin/env bash

# Скрипт установки MeshCentral с базой данных MongoDB
set -e

# Цвета
GREEN='\033[1;32m'
NC='\033[0m'

# Проверка зависимостей
echo -e "${GREEN}Проверка и установка необходимых компонентов...${NC}"
if ! command -v lsb_release &> /dev/null; then
  sudo apt-get update
  sudo apt-get install -y lsb-core
fi

sudo apt-get install -y curl sudo jq

# Установка Node.js 18.x
echo -e "${GREEN}Установка Node.js...${NC}"
curl -sL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt-get install -y gcc g++ make nodejs
sudo npm install -g npm

# Установка MeshCentral
echo -e "${GREEN}Установка MeshCentral...${NC}"
sudo mkdir -p /opt/meshcentral/meshcentral-data
sudo chown "$USER":"$USER" -R /opt/meshcentral
cd /opt/meshcentral || exit
npm install --save --save-exact meshcentral
sudo chown "$USER":"$USER" -R /opt/meshcentral

# Создание package.json с фиксированными версиями зависимостей
cat <<EOF > /opt/meshcentral/package.json
{
  "dependencies": {
    "meshcentral": "1.1.9",
    "acme-client": "4.2.5",
    "archiver": "5.3.1",
    "otplib": "10.2.3",
    "pg": "8.7.1",
    "pgtools": "0.3.2"
  }
}
EOF

# Создание systemd сервиса
echo -e "${GREEN}Создание службы systemd для MeshCentral...${NC}"
cat <<EOF | sudo tee /etc/systemd/system/meshcentral.service > /dev/null
[Unit]
Description=MeshCentral Server
After=network.target

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
sudo systemctl start meshcentral

# Ожидание запуска MeshCentral
echo -e "${GREEN}Ожидание запуска MeshCentral...${NC}"
until systemctl is-active --quiet meshcentral; do
  echo "Ожидание запуска MeshCentral..."
  sleep 3
done

# Установка MongoDB
echo -e "${GREEN}Установка MongoDB...${NC}"
DISTRO=$(lsb_release -si | tr '[:upper:]' '[:lower:]')
CODENAME=$(lsb_release -cs)

wget -qO - https://www.mongodb.org/static/pgp/server-5.0.asc | sudo apt-key add -
if [ "$DISTRO" == "ubuntu" ]; then
  echo "deb http://repo.mongodb.org/apt/ubuntu $CODENAME/mongodb-org/5.0 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-5.0.list
elif [ "$DISTRO" == "debian" ]; then
  echo "deb http://repo.mongodb.org/apt/debian $CODENAME/mongodb-org/5.0 main" | sudo tee /etc/apt/sources.list.d/mongodb-org-5.0.list
fi

sudo apt-get update
sudo apt-get install -y mongodb-org
sudo systemctl enable mongod
sudo systemctl start mongod

# Проверка запуска MongoDB
echo -e "${GREEN}Ожидание запуска MongoDB...${NC}"
until systemctl is-active --quiet mongod; do
  echo "Ожидание запуска MongoDB..."
  sleep 3
done

# Настройка конфигурации MeshCentral на MongoDB
echo -e "${GREEN}Настройка MeshCentral на использование MongoDB...${NC}"
sudo systemctl stop meshcentral
CONFIG_FILE="/opt/meshcentral/meshcentral-data/config.json"

if [ ! -f "$CONFIG_FILE" ]; then
  echo '{ "settings": {} }' > "$CONFIG_FILE"
fi

jq '.settings.MongoDb = "mongodb://127.0.0.1:27017/meshcentral" | .settings.MongoDbCol = "meshcentral"' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp"
mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

sudo systemctl start meshcentral

# Предварительная настройка
echo -e "${GREEN}Хотите выполнить предварительную настройку сервера?${NC}"
select choice in "Да" "Нет"; do
  case $choice in
    "Да")
      read -p "Введите ваш домен (DNS): " dnsname
      read -p "Введите ваш email: " email
      read -p "Введите название компании: " company
      read -p "Введите имя администратора: " username
      password=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20)

      sudo systemctl stop meshcentral

      jq \
        --arg dns "$dnsname" \
        --arg email "$email" \
        --argjson production true \
        '.settings.cert = $dns | .letsencrypt.email = $email | .letsencrypt.names = [$dns] | .settings.production = $production' \
        "$CONFIG_FILE" > "${CONFIG_FILE}.tmp"
      mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

      sudo systemctl start meshcentral
      echo -e "${GREEN}Ждем 10 секунд для запуска MeshCentral...${NC}"
      sleep 10

      echo -e "${GREEN}Создание администратора...${NC}"
      cd /opt/meshcentral || exit
      node ./node_modules/meshcentral --createaccount "$username" --pass "$password" --email "$email"
      node ./node_modules/meshcentral --adminaccount "$username"

      echo -e "${GREEN}Создание группы устройств...${NC}"
      node ./node_modules/meshcentral/meshctrl.js --url "wss://$dnsname:443" --loginuser "$username" --loginpass "$password" AddDeviceGroup --name "$company"
      node ./node_modules/meshcentral/meshctrl.js --url "wss://$dnsname:443" --loginuser "$username" --loginpass "$password" EditDeviceGroup --group "$company" --desc "$company Support Group" --consent 71
      node ./node_modules/meshcentral/meshctrl.js --url "wss://$dnsname:443" --loginuser "$username" --loginpass "$password" EditUser --userid "$username" --realname "$company Support"

      echo -e "${GREEN}Установка завершена!${NC}"
      echo "Вы можете зайти на https://$dnsname"
      echo "Логин: $username"
      echo "Пароль: $password"
      break
      ;;
    "Нет")
      echo -e "${GREEN}Установка завершена без предварительной настройки.${NC}"
      break
      ;;
    *)
      echo "Неверный выбор"
      ;;
  esac
done
