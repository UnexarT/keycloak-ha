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
    
    # Создание конфига UCARP
    sudo mkdir -p /etc/ucarp
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
    
    sudo tee /etc/systemd/system/ucarp.service > /dev/null <<EOF
[Unit]
Description=UCARP IP Failover
After=network.target

[Service]
Type=forking
User=root
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW
$SKEW
ExecStart=/usr/sbin/ucarp --interface=ens33 --srcip=$HOST_IP --vhid=$UCARP_VHID --passfile=/etc/ucarp/ucarp.pass --addr=$VIP --upscript=/usr/local/bin/vip-up.sh --downscript=/usr/local/bin/vip-down.sh --preempt --advbase=1 --deadratio=2 $PRIORITY --daemonize
ExecStop=/usr/bin/pkill -f "ucarp.*vhid=$UCARP_VHID"
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    # Создание скриптов для UCARP
    sudo tee /usr/local/bin/vip-up.sh > /dev/null <<'EOF'
#!/bin/bash
INTERFACE=$1
VIP=$2
ip addr add $VIP/24 dev $INTERFACE
logger "UCARP: VIP $VIP added on $INTERFACE"
EOF

    sudo tee /usr/local/bin/vip-down.sh > /dev/null <<'EOF'
#!/bin/bash
INTERFACE=$1
VIP=$2
ip addr del $VIP/24 dev $INTERFACE 2>/dev/null
logger "UCARP: VIP $VIP removed from $INTERFACE"
EOF

    sudo chmod +x /usr/local/bin/vip-up.sh /usr/local/bin/vip-down.sh
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
