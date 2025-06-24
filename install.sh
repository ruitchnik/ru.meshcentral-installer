#!/bin/bash

# Цвета для вывода
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Проверка root
if [[ $EUID -ne 0 ]]; then
   echo -e "${YELLOW}❌ Ошибка: Скрипт должен запускаться от имени root!${NC}"
   exit 1
fi

echo -e "${GREEN}🚀 Начинается установка MeshCentral...${NC}"

# Обновление системы
apt update && apt upgrade -y

# Установка зависимостей
apt install -y curl wget gnupg mongodb-org nodejs npm python3-pip certbot

# Установка bcrypt для генерации хэша пароля
pip3 install bcrypt || { echo -e "${YELLOW}❌ Не удалось установить bcrypt${NC}"; exit 1; }

# Создание директории MeshCentral
mkdir -p /opt/meshcentral
cd /opt/meshcentral || exit

# Установка MeshCentral через NPM
npm install meshcentral

# Запрос данных у пользователя
read -p "🌐 Введите доменное имя: " DOMAIN
read -p "📧 Введите email для Let's Encrypt: " EMAIL
read -p "🏢 Введите название компании: " COMPANY
read -p "👤 Введите имя администратора: " ADMIN_USER
read -s -p "🔐 Введите пароль администратора: " ADMIN_PASS
echo

# Генерация bcrypt хэша
HASH=$(python3 -c '
import bcrypt, sys
password = sys.argv[1].encode("utf-8")
hashed = bcrypt.hashpw(password, bcrypt.gensalt())
print(hashed.decode("utf-8"))
' "$ADMIN_PASS")

# Файл конфигурации
cat <<EOT > config.js
{
  "settings": {
    "cert": "$DOMAIN",
    "https": 443,
    "wss": 443,
    "dbType": "mongo",
    "db": {
      "uri": "mongodb://localhost:27017/meshcentral"
    },
    "letsEncrypt": {
      "email": "$EMAIL",
      "names": "$DOMAIN"
    }
  },
  "domains": {
    "": {
      "title": "$COMPANY Remote Management",
      "title2": "$COMPANY Control Panel",
      "newUser": false
    }
  }
}
EOT

# Файл пользователей
cat <<EOT > user.json
{
  "$ADMIN_USER": {
    "name": "$ADMIN_USER",
    "pwd": "$HASH",
    "roles": ["admin"]
  }
}
EOT

# Настройка автозапуска
cat <<EOT > /etc/systemd/system/meshcentral.service
[Unit]
Description=MeshCentral Server
After=network.target

[Service]
ExecStart=/usr/bin/node /opt/meshcentral/node_modules/meshcentral
WorkingDirectory=/opt/meshcentral
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOT

systemctl daemon-reload
systemctl enable meshcentral --now

# Информация о завершении
echo -e "${GREEN}✅ Настройка завершена!${NC}"
echo -e "Адрес: ${GREEN}https://$DOMAIN${NC}"   
echo -e "Логин: ${GREEN}$ADMIN_USER${NC}"
echo -e "Пароль: ${GREEN}$ADMIN_PASS${NC}"

echo -e "${GREEN}💡 Откройте браузер и войдите в систему:${NC}"
