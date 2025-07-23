#!/usr/bin/env bash

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # без цвета

if ! which lsb_release >/dev/null
then
  sudo apt-get install -y lsb-core > /dev/null
fi

sudo apt-get install -y curl sudo > /dev/null

echo -e "${GREEN}Установка MeshCentral${NC}"
curl -sL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt update > /dev/null
sudo apt install -y gcc g++ make > /dev/null
sudo apt install -y nodejs > /dev/null
sudo npm install -g npm

sudo mkdir -p /opt/meshcentral/meshcentral-data
sudo chown ${USER}:${USER} -R /opt/meshcentral
cd /opt/meshcentral
npm install --save --save-exact meshcentral
sudo chown ${USER}:${USER} -R /opt/meshcentral

rm /opt/meshcentral/package.json

mesh_pkg="$(
  cat <<EOF
{
  "dependencies": {
    "acme-client": "4.2.5",
    "archiver": "5.3.1",
    "meshcentral": "1.4.4",
    "otplib": "10.2.3",
    "pg": "8.7.1",
    "pgtools": "0.3.2"
  }
}
EOF
)"
echo "${mesh_pkg}" >/opt/meshcentral/package.json

meshservice="$(cat << EOF
[Unit]
Description=MeshCentral Server
After=network.target
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
)"
echo "${meshservice}" | sudo tee /etc/systemd/system/meshcentral.service > /dev/null

sudo setcap 'cap_net_bind_service=+ep' `which node`
sudo systemctl daemon-reload
sudo systemctl enable meshcentral.service
sudo systemctl start meshcentral.service

if [ -d "/opt/meshcentral/meshcentral-files/" ]; then
  echo -e "${GREEN}Папка meshcentral-files найдена${NC}"
  pause
fi

echo -e "${YELLOW}По умолчанию будет установлена MongoDB.${NC}"

# Установка MongoDB по умолчанию

while ! [[ $CHECK_MESH_SERVICE1 ]]; do
  CHECK_MESH_SERVICE1=$(sudo systemctl status meshcentral.service | grep "Active: active (running)")
  echo -ne "${YELLOW}Meshcentral ещё не готов...${NC}\n"
  sleep 3
done

sudo systemctl stop meshcentral

if [ $(lsb_release -si | tr '[:upper:]' '[:lower:]') = "ubuntu" ]
then
  wget -qO - https://www.mongodb.org/static/pgp/server-5.0.asc | sudo apt-key add -
  echo "deb http://repo.mongodb.org/apt/ubuntu $(lsb_release -cs)/mongodb-org/5.0 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-5.0.list
elif [ $(lsb_release -si | tr '[:upper:]' '[:lower:]') = "debian" ]
then
  wget -qO - https://www.mongodb.org/static/pgp/server-5.0.asc | sudo apt-key add -
  echo "deb http://repo.mongodb.org/apt/debian $(lsb_release -cs)/mongodb-org/5.0 main" | sudo tee /etc/apt/sources.list.d/mongodb-org-5.0.list
fi

sudo apt-get update > /dev/null
sudo apt-get install -y mongodb-org > /dev/null
sudo systemctl enable mongod
sudo systemctl start mongod
sed -i '/"settings": {/a "MongoDb": "mongodb://127.0.0.1:27017/meshcentral",\n"MongoDbCol": "meshcentral",' /opt/meshcentral/meshcentral-data/config.json

while ! [[ $CHECK_MONGO_SERVICE ]]; do
  CHECK_MONGO_SERVICE=$(sudo systemctl status mongod.service | grep "Active: active (running)")
  echo -ne "${YELLOW}MongoDB ещё не готов...${NC}\n"
  sleep 3
done

sudo systemctl start meshcentral.service

# Настройка по выбору — оставляем только "Да" и "Нет" (без изменений)

PS3='Хотите, чтобы скрипт настроил MeshCentral с оптимальными параметрами? Введите номер: '
OPTIONS=("Да" "Нет")
select opt in "${OPTIONS[@]}"; do
  case $opt in
    "Да")
      if ! which jq >/dev/null
      then
        sudo apt-get install -y jq > /dev/null
      fi

      echo -ne "Введите домен или публичный IP для MeshCentral: "
      read dnsnames

      echo -ne "Введите ваш email для Let's Encrypt: "
      read letsemail

      echo -ne "Введите название вашей компании: "
      read coname

      echo -ne "Введите желаемое имя пользователя: "
      read meshuname

      meshpwd=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 20 | head -n 1)

      while ! [[ $CHECK_MESH_SERVICE3 ]]; do
        CHECK_MESH_SERVICE3=$(sudo systemctl status meshcentral.service | grep "Active: active (running)")
        echo -ne "${YELLOW}Meshcentral ещё не готов...${NC}\n"
        sleep 3
      done
      sudo systemctl stop meshcentral.service

      sed -i 's|"_letsencrypt": |"letsencrypt": |g' /opt/meshcentral/meshcentral-data/config.json
      sed -i 's|"_redirPort": |"redirPort": |g' /opt/meshcentral/meshcentral-data/config.json
      sed -i 's|"_cert": |"cert": |g' /opt/meshcentral/meshcentral-data/config.json
      sed -i 's|    "production": false|    "production": true|g' /opt/meshcentral/meshcentral-data/config.json
      sed -i 's|      "_title": "MyServer",|      "title": "'"${coname}"' Support",|g' /opt/meshcentral/meshcentral-data/config.json
      sed -i 's|      "_newAccounts": true,|      "newAccounts": false,|g' /opt/meshcentral/meshcentral-data/config.json
      sed -i 's|      "_userNameIsEmail": true|      "_userNameIsEmail": true,|g' /opt/meshcentral/meshcentral-data/config.json
      sed -i '/     "_userNameIsEmail": true,/a "agentInviteCodes": true,\n "agentCustomization": {\n"displayname": "'"$coname"' Support",\n"description": "'"$coname"' Remote Agent",\n"companyName": "'"$coname"'",\n"serviceName": "'"$coname"'Remote"\n}' /opt/meshcentral/meshcentral-data/config.json
      sed -i '/"settings": {/a "plugins":{\n"enabled": true\n},' /opt/meshcentral/meshcentral-data/config.json
      sed -i '/"settings": {/a "MaxInvalidLogin": {\n"time": 5,\n"count": 5,\n"coolofftime": 30\n},' /opt/meshcentral/meshcentral-data/config.json

      cat "/opt/meshcentral/meshcentral-data/config.json" |     
      jq " .settings.cert |= \"$dnsnames\" " |
      jq " .letsencrypt.email |= \"$letsemail\" " |
      jq " .letsencrypt.names |= \"$dnsnames\" " > /opt/meshcentral/meshcentral-data/config2.json
      mv /opt/meshcentral/meshcentral-data/config2.json /opt/meshcentral/meshcentral-data/config.json

      echo -e "${GREEN}Получаем SSL сертификат MeshCentral${NC}"
      sudo systemctl start meshcentral

      sleep 15
      while ! [[ $CHECK_MESH_SERVICE4 ]]; do
        CHECK_MESH_SERVICE4=$(sudo systemctl status meshcentral.service | grep "Active: active (running)")
        echo -ne "${YELLOW}Meshcentral ещё не готов...${NC}\n"
        sleep 3
      done
      sleep 3
      while ! [[ $CHECK_MESH_SERVICE5 ]]; do
        CHECK_MESH_SERVICE5=$(sudo systemctl status meshcentral.service | grep "Active: active (running)")
        echo -ne "${YELLOW}Meshcentral ещё не готов...${NC}\n"
        sleep 3
      done

      sudo systemctl stop meshcentral

      echo -e "${GREEN}Создаём пользователя${NC}"

      node node_modules/meshcentral --createaccount $meshuname --pass $meshpwd --email $letsemail
      sleep 1
      node node_modules/meshcentral --adminaccount $meshuname 
      sleep 3
      sudo systemctl start meshcentral
      while ! [[ $CHECK_MESH_SERVICE6 ]]; do
        CHECK_MESH_SERVICE6=$(sudo systemctl status meshcentral.service | grep "Active: active (running)")
        echo -ne "${YELLOW}Meshcentral ещё не готов...${NC}\n"
        sleep 3
      done

      echo -e "${GREEN}Настраиваем параметры MeshCentral по умолчанию${NC}"
      node node_modules/meshcentral/meshctrl.js --url wss://$dnsnames:443 --loginuser $meshuname --loginpass $meshpwd AddDeviceGroup --name "$coname"
      node node_modules/meshcentral/meshctrl.js --url wss://$dnsnames:443 --loginuser $meshuname --loginpass $meshpwd EditDeviceGroup --group "$coname" --desc ''"$coname"' Support Group' --consent 71
      node node_modules/meshcentral/meshctrl.js --url wss://$dnsnames:443 --loginuser $meshuname --loginpass $meshpwd EditUser --userid $meshuname --realname ''"$coname"' Support'
      sudo systemctl restart meshcentral

      echo -e "${GREEN}Вы можете зайти на https://$dnsnames 
      с логином:${NC} $meshuname ${GREEN} 
      и паролем:${NC} $meshpwd"
      echo -e "${GREEN}Приятной работы!${NC}"

      break
      ;;
    "Нет")
      break
      ;;
    *)
      echo -e "${RED}Неверный выбор: $REPLY${NC}"
      ;;
  esac
done
