#!/bin/bash
# setup.sh — автоматическое развертывание на любой VM

set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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
echo -e "${YELLOW}Текущий IP: ${HOST_IP}${NC}"

# Определяем роль VM
if [ "$HOST_IP" == "$VM3_IP" ]; then
    ROLE="etcd"
    echo -e "${GREEN}Роль: etcd (координатор)${NC}"
elif [ "$HOST_IP" == "$VM1_IP" ] || [ "$HOST_IP" == "$VM2_IP" ]; then
    ROLE="app"
    echo -e "${GREEN}Роль: приложение (Keycloak + Patroni)${NC}"
else
    echo -e "${RED}Неизвестный IP! Проверь .env${NC}"
    exit 1
fi

# Установка Docker
echo -e "${YELLOW}Установка Docker...${NC}"
sudo apt update
sudo apt install -y docker.io docker-compose
sudo systemctl enable docker
sudo systemctl start docker
sudo usermod -aG docker $USER

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
    sed -e "s/{{HOST_IP}}/$HOST_IP/g" \
        -e "s/{{UCARP_VHID}}/$UCARP_VHID/g" \
        -e "s/{{VIP}}/$VIP/g" \
        -e "s/{{PRIORITY}}/$PRIORITY/g" \
        -e "s/{{SKEW}}/$SKEW/g" \
        ucarp/ucarp.service.template | sudo tee /etc/systemd/system/ucarp.service > /dev/null
    
    sudo systemctl daemon-reload
    sudo systemctl enable ucarp
fi

# Генерация haproxy.cfg из шаблона
if [ "$ROLE" == "app" ] && [ -f haproxy.cfg.template ]; then
    echo -e "${YELLOW}Генерация конфига HAProxy...${NC}"
    envsubst < haproxy.cfg.template > haproxy.cfg
fi

# Запуск Docker Compose
echo -e "${YELLOW}Запуск контейнеров...${NC}"
if [ "$ROLE" == "etcd" ]; then
    docker-compose -f docker-compose-etcd.yml up -d
elif [ "$ROLE" == "app" ]; then
    docker-compose -f docker-compose-patroni-keycloak.yml up -d
    docker-compose -f docker-compose-haproxy.yml up -d
    
    # Ожидание запуска Patroni и создание базы данных
    echo -e "${YELLOW}Ожидание запуска PostgreSQL...${NC}"
    sleep 30
    docker exec -it patroni psql -U postgres -c "CREATE USER ${POSTGRES_USER} WITH PASSWORD '${POSTGRES_PASSWORD}';" 2>/dev/null || true
    docker exec -it patroni psql -U postgres -c "CREATE DATABASE ${POSTGRES_DB} OWNER ${POSTGRES_USER};" 2>/dev/null || true
fi

echo -e "${GREEN}=== Развертывание завершено! ===${NC}"
echo -e "Проверь: ${YELLOW}docker-compose logs${NC}"
