#!/usr/bin/env bash

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== Установка MeshCentral на Ubuntu ===${NC}"

# Определение версии Ubuntu
UBUNTU_CODENAME=$(lsb_release -cs)
UBUNTU_VERSION=$(lsb_release -rs)

echo -e "${YELLOW}Обнаружена Ubuntu $UBUNTU_VERSION ($UBUNTU_CODENAME)${NC}"

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

# Выбор базы данных
echo -e "${GREEN}Выбор базы данных:${NC}"
PS3='Выберите базу данных: '
options=("MongoDB" "PostgreSQL" "NeDB")
select opt in "${options[@]}"
do
    case $opt in
        "MongoDB")
            DB_CHOICE="mongodb"
            break
            ;;
        "PostgreSQL")
            DB_CHOICE="postgresql"
            break
            ;;
        "NeDB")
            DB_CHOICE="nedb"
            break
            ;;
        *) echo "Неверный вариант $REPLY";;
    esac
done

# === Установка выбранной базы данных ===
case $DB_CHOICE in
    "mongodb")
        echo -e "${GREEN}Установка MongoDB 5.0...${NC}"
        sudo install -d -m 0755 -o root -g root /etc/apt/keyrings
        
        # Установка MongoDB 5.0
        curl -fsSL https://pgp.mongodb.com/server-5.0.asc | sudo gpg --dearmor -o /etc/apt/keyrings/mongodb-server-5.0.gpg
        echo "deb [arch=amd64,arm64 signed-by=/etc/apt/keyrings/mongodb-server-5.0.gpg] https://repo.mongodb.org/apt/ubuntu $UBUNTU_CODENAME/mongodb-org/5.0 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-5.0.list
        
        sudo chmod 644 /etc/apt/keyrings/mongodb-server-5.0.gpg
        sudo apt update -y
        sudo apt install -y mongodb-org
        
        # Запуск MongoDB
        sudo systemctl enable --now mongod
        
        # Проверка MongoDB
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
                sudo journalctl -u mongod -n 10 --no-pager
                exit 1
            fi
        fi
        ;;
        
    "postgresql")
        echo -e "${GREEN}Установка PostgreSQL...${NC}"
        sudo apt install -y postgresql postgresql-contrib
        sudo systemctl enable --now postgresql
        
        # Проверка PostgreSQL
        sleep 5
        if systemctl is-active --quiet postgresql; then
            echo -e "${GREEN}PostgreSQL запущен!${NC}"
        else
            echo -e "${RED}Ошибка запуска PostgreSQL${NC}"
            exit 1
        fi
        
        # Создание базы данных и пользователя
        DBUSER="meshcentral_user"
        DBPWD=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 20 | head -n 1)
        
        sudo -u postgres psql -c "CREATE DATABASE meshcentral;"
        sudo -u postgres psql -c "CREATE USER ${DBUSER} WITH PASSWORD '${DBPWD}';"
        sudo -u postgres psql -c "ALTER ROLE ${DBUSER} SET client_encoding TO 'utf8';"
        sudo -u postgres psql -c "ALTER ROLE ${DBUSER} SET default_transaction_isolation TO 'read committed';"
        sudo -u postgres psql -c "ALTER ROLE ${DBUSER} SET timezone TO 'UTC';"
        sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE meshcentral TO ${DBUSER};"
        ;;
        
    "nedb")
        echo -e "${GREEN}Использование NeDB (встроенная база данных)...${NC}"
        ;;
esac

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

# Базовый конфиг
CONFIG_CONTENT='{
  "settings": {
    "port": 443,
    "aliasPort": 443,
    "redirPort": 80,
    "TlsOffload": true
  }
}'

# Добавляем настройки базы данных в конфиг
case $DB_CHOICE in
    "mongodb")
        CONFIG_CONTENT=$(echo "$CONFIG_CONTENT" | jq '.settings.MongoDb = "mongodb://127.0.0.1:27017/meshcentral" | .settings.MongoDbCol = "meshcentral"')
        ;;
    "postgresql")
        CONFIG_CONTENT=$(echo "$CONFIG_CONTENT" | jq --arg user "$DBUSER" --arg pass "$DBPWD" '.settings.postgres = {
            "user": $user,
            "password": $pass,
            "port": "5432",
            "host": "localhost",
            "database": "meshcentral"
        }')
        ;;
esac

echo "$CONFIG_CONTENT" | sudo tee /opt/meshcentral/meshcentral-data/config.json > /dev/null

# === Systemd service ===
echo -e "${GREEN}Создание systemd сервиса...${NC}"
cat <<EOF | sudo tee /etc/systemd/system/meshcentral.service
[Unit]
Description=MeshCentral Server
After=network.target mongod.service postgresql.service

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
    
    if [ "$DB_CHOICE" = "postgresql" ]; then
        echo -e "${YELLOW}Данные для подключения к PostgreSQL:${NC}"
        echo -e "${YELLOW}Пользователь: $DBUSER${NC}"
        echo -e "${YELLOW}Пароль: $DBPWD${NC}"
        echo -e "${YELLOW}База данных: meshcentral${NC}"
    fi
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

# Опциональная автоматическая настройка
read -p "Хотите выполнить автоматическую настройку? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${GREEN}Настройка MeshCentral...${NC}"
    
    echo -ne "Введите доменное имя: "
    read dnsnames
    
    echo -ne "Введите email для Let's Encrypt: "
    read letsemail
    
    echo -ne "Введите название компании: "
    read coname
    
    # Останавливаем MeshCentral для настройки
    sudo systemctl stop meshcentral
    
    # Обновляем конфиг
    sudo -u meshcentral cp /opt/meshcentral/meshcentral-data/config.json /opt/meshcentral/meshcentral-data/config.json.backup
    
    # Используем jq для модификации конфига
    sudo -u meshcentral jq ".settings.cert = \"$dnsnames\"" /opt/meshcentral/meshcentral-data/config.json > /tmp/config.tmp
    sudo mv /tmp/config.tmp /opt/meshcentral/meshcentral-data/config.json
    
    sudo -u meshcentral jq ".letsencrypt = {\"email\": \"$letsemail\", \"names\": \"$dnsnames\", \"production\": true}" /opt/meshcentral/meshcentral-data/config.json > /tmp/config.tmp
    sudo mv /tmp/config.tmp /opt/meshcentral/meshcentral-data/config.json
    
    sudo -u meshcentral jq ".settings.agentCustomization = {\"displayname\": \"$coname Support\", \"description\": \"$coname Remote Agent\", \"companyName\": \"$coname\", \"serviceName\": \"${coname}Remote\"}" /opt/meshcentral/meshcentral-data/config.json > /tmp/config.tmp
    sudo mv /tmp/config.tmp /opt/meshcentral/meshcentral-data/config.json
    
    # Запускаем MeshCentral
    sudo systemctl start meshcentral
    
    echo -e "${GREEN}Настройка завершена!${NC}"
    echo -e "${YELLOW}MeshCentral доступен по адресу: https://$dnsnames/${NC}"
fi

echo -e "${GREEN}Установка завершена!${NC}"
