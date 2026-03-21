#!/bin/bash
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}=== Keycloak HA Deployer ===${NC}"

# Загрузка .env
if [ -f .env ]; then
    source .env
else
    echo -e "${RED}Ошибка: файл .env не найден!${NC}"
    exit 1
fi

# Определение текущей VM по IP
HOST_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v 127.0.0.1 | head -1)
HOSTNAME=$(hostname)
echo -e "${YELLOW}Текущий IP: ${HOST_IP}${NC}"
echo -e "${YELLOW}Текущий hostname: ${HOSTNAME}${NC}"

# Определяем роль VM
if [ "$HOST_IP" == "$VM3_IP" ]; then
    ROLE="etcd"
    echo -e "${GREEN}Роль: etcd (координатор)${NC}"
elif [ "$HOST_IP" == "$VM1_IP" ] || [ "$HOST_IP" == "$VM2_IP" ]; then
    ROLE="app"
    echo -e "${GREEN}Роль: приложение (Keycloak + HAProxy)${NC}"
else
    echo -e "${RED}Неизвестный IP! Проверь .env${NC}"
    exit 1
fi

# Установка Docker и настройка прав
echo -e "${YELLOW}Установка Docker...${NC}"
sudo apt update
sudo apt install -y docker.io docker-compose
sudo systemctl enable docker
sudo systemctl start docker

# Проверка и добавление пользователя в группу docker
if ! groups $USER | grep -q docker; then
    echo -e "${YELLOW}Добавление пользователя $USER в группу docker...${NC}"
    sudo usermod -aG docker $USER
    DOCKER_GROUP_ADDED=true
else
    echo -e "${GREEN}Пользователь уже в группе docker${NC}"
    DOCKER_GROUP_ADDED=false
fi

# Если пользователь был добавлен в группу, нужно перезапустить сессию
if [ "$DOCKER_GROUP_ADDED" = true ]; then
    echo -e "${BLUE}========================================${NC}"
    echo -e "${YELLOW}ВНИМАНИЕ!${NC}"
    echo -e "Пользователь добавлен в группу docker."
    echo -e "Для применения изменений необходимо:"
    echo -e "  1. Выйти из сессии (exit)"
    echo -e "  2. Зайти заново"
    echo -e "  3. Запустить скрипт снова: ${GREEN}./setup.sh${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo -e "${RED}Скрипт остановлен. Перезайди и запусти снова.${NC}"
    exit 0
fi

# Проверка, что Docker работает
if ! docker ps &>/dev/null; then
    echo -e "${RED}Ошибка: Docker не работает или нет прав. Попробуй перезагрузить VM.${NC}"
    exit 1
fi

# Установка UCARP (только для app-нод)
if [ "$ROLE" == "app" ]; then
    echo -e "${YELLOW}Установка UCARP...${NC}"
    sudo apt install -y ucarp

    # Создание папки и копирование скриптов
    sudo mkdir -p /usr/local/bin /etc/ucarp
    sudo cp ucarp/vip-up.sh /usr/local/bin/
    sudo cp ucarp/vip-down.sh /usr/local/bin/
    sudo chmod +x /usr/local/bin/vip-up.sh /usr/local/bin/vip-down.sh

    # Создание пароля
    echo "$UCARP_PASSWORD" | sudo tee /etc/ucarp/ucarp.pass > /dev/null
    sudo chmod 600 /etc/ucarp/ucarp.pass

    # Определение приоритета
    if [ "$HOST_IP" == "$VM1_IP" ]; then
        PRIORITY=""
        SKEW=""
    else
        PRIORITY="--advskew=50"
        SKEW="ExecStartPre=/bin/sleep 5"
    fi

    # Генерация systemd сервиса из шаблона
    sed -e "s|{{HOST_IP}}|$HOST_IP|g" \
        -e "s|{{UCARP_VHID}}|$UCARP_VHID|g" \
        -e "s|{{VIP}}|$VIP|g" \
        -e "s|{{PRIORITY}}|$PRIORITY|g" \
        -e "s|{{SKEW}}|$SKEW|g" \
        ucarp/ucarp.service.template | sudo tee /etc/systemd/system/ucarp.service > /dev/null

    sudo systemctl daemon-reload
    sudo systemctl unmask ucarp 2>/dev/null || true
    sudo systemctl enable ucarp
fi

# Генерация haproxy.cfg из шаблона
if [ "$ROLE" == "app" ] && [ -f haproxy.cfg.template ]; then
    echo -e "${YELLOW}Генерация конфига HAProxy...${NC}"
    export VIP HAPROXY_STATS_USER HAPROXY_STATS_PASSWORD VM1_IP VM2_IP
    envsubst < haproxy.cfg.template | sudo tee haproxy.cfg > /dev/null
    sudo chmod 644 haproxy.cfg
    echo -e "${GREEN}HAProxy конфиг создан${NC}"
fi

# Обновление .env с HOSTNAME и HOST_IP
echo -e "${YELLOW}Обновление .env с текущими значениями HOSTNAME и HOST_IP...${NC}"
sed -i '/^HOSTNAME=/d' .env
sed -i '/^HOST_IP=/d' .env
echo "HOSTNAME=$HOSTNAME" >> .env
echo "HOST_IP=$HOST_IP" >> .env

# Запуск Docker Compose
echo -e "${YELLOW}Запуск контейнеров...${NC}"

# Удаляем version из docker-compose файлов (чтобы убрать warnings)
for f in docker-compose-*.yml; do
    sudo sed -i '/^version:/d' "$f" 2>/dev/null || true
done

if [ "$ROLE" == "etcd" ]; then
    docker-compose -f docker-compose-etcd.yml up -d
    echo -e "${GREEN}etcd запущен${NC}"

elif [ "$ROLE" == "app" ]; then
    docker-compose -f docker-compose-patroni-keycloak.yml up -d
    docker-compose -f docker-compose-haproxy.yml up -d
    echo -e "${GREEN}Keycloak и HAProxy запущены${NC}"
fi

# Запуск UCARP (только для app-нод)
if [ "$ROLE" == "app" ]; then
    echo -e "${YELLOW}Запуск UCARP...${NC}"
    sudo systemctl start ucarp
    sudo systemctl status ucarp --no-pager || true
fi

echo -e "${GREEN}=== Развертывание завершено! ===${NC}"
echo ""
echo -e "${YELLOW}Проверь:${NC}"
echo "  docker-compose logs keycloak   # логи Keycloak"
echo "  sudo systemctl status ucarp    # статус UCARP"
echo "  curl http://${VIP}/realms/master  # проверка Keycloak"
echo ""
echo -e "${YELLOW}Статистика HAProxy:${NC} http://${VIP}:8404/stats (логин: ${HAPROXY_STATS_USER})"
