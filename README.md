# Keycloak HA Cluster

Отказоустойчивая система авторизации на базе Keycloak, развёрнутая на трёх виртуальных машинах Debian с использованием кластеризации, резервирования входной точки, автоматического переключения PostgreSQL и воспроизводимого развёртывания через Ansible.

Проект выполнен в рамках выпускной квалификационной работы **«Развёртывание системы авторизации Keycloak с применением технологии кластеризации для обеспечения отказоустойчивости»**. Решение ориентировано на развитие уже существующей инфраструктуры авторизации Политеха: после обсуждения вариантов с заказчиком было принято решение не заменять используемый Keycloak другой системой, а повысить его доступность за счёт масштабирования, резервирования и автоматизации развёртывания.

Система развёрнута в тестовом контуре Политеха и предназначена для проверки архитектуры, сценариев отказа и воспроизводимости настройки перед возможным переносом в более строгий эксплуатационный контур.

---

## Оглавление

- [Назначение проекта](#назначение-проекта)
- [Архитектура](#архитектура)
- [Роли узлов](#роли-узлов)
- [Технологический стек](#технологический-стек)
- [Принцип работы](#принцип-работы)
- [Структура проекта](#структура-проекта)
- [Где менять параметры](#где-менять-параметры)
- [Требования к виртуальным машинам](#требования-к-виртуальным-машинам)
- [Подготовка управляющей машины](#подготовка-управляющей-машины)
- [Настройка SSH для Ansible](#настройка-ssh-для-ansible)
- [Локальный файл секретов](#локальный-файл-секретов)
- [Проверка Ansible](#проверка-ansible)
- [Развёртывание](#развёртывание)
- [Проверка после развёртывания](#проверка-после-развёртывания)
- [Проверка отказоустойчивости](#проверка-отказоустойчивости)
- [Полезные команды диагностики](#полезные-команды-диагностики)
- [Особенности текущей реализации](#особенности-текущей-реализации)

---

## Назначение проекта

Keycloak используется как центральный сервис авторизации и единого входа. Если такой сервис работает в единственном экземпляре, отказ узла может привести к недоступности сразу нескольких связанных приложений: внутренних порталов, административных панелей, GitLab, wiki, LMS и других систем, использующих общую авторизацию.

Цель проекта — повысить доступность сервиса авторизации без замены технологической основы. Для этого в проекте реализованы:

- два экземпляра Keycloak на разных рабочих узлах;
- резервирование клиентской точки входа через виртуальный IP-адрес;
- балансировка HTTP-запросов к Keycloak через HAProxy;
- отказоустойчивая база данных PostgreSQL под управлением Patroni;
- распределённое хранилище состояния etcd для координации Patroni;
- отдельный HAProxy для маршрутизации соединений к актуальному primary-узлу PostgreSQL;
- автоматизация развёртывания через Ansible;
- централизованное управление параметрами через inventory, group variables, `.env` и шаблоны;
- проверка поведения системы при отказе Keycloak, PostgreSQL + Patroni, входного узла и одного участника etcd.

---

## Архитектура

![Архитектура Keycloak HA Cluster](arch.svg)

Система построена по трёхузловой схеме. Два узла выполняют роль рабочих узлов приложения и базы данных, третий используется как дополнительный участник etcd для поддержания кворума.

Логически архитектуру можно разделить на пять уровней:

1. **Входной уровень** — VIP, UCARP и HAProxy Keycloak.
2. **Уровень приложения** — два экземпляра Keycloak.
3. **Уровень доступа к базе данных** — HAProxy PostgreSQL, направляющий соединения к текущему primary.
4. **Уровень хранения данных** — PostgreSQL под управлением Patroni.
5. **Уровень координации** — кластер etcd, используемый Patroni как DCS.

Пользователь или внешнее приложение работает только с виртуальным IP-адресом. Внутреннее переключение между узлами, смена primary PostgreSQL и исключение недоступных backend-узлов из балансировки выполняются внутри инфраструктуры.

---

## Роли узлов

| Узел | Пример hostname | Назначение |
|---|---|---|
| `vm1` | `test-vm1` | Keycloak, Keycloak HAProxy, PostgreSQL + Patroni, PostgreSQL HAProxy, etcd, UCARP |
| `vm2` | `test-vm2` | Keycloak, Keycloak HAProxy, PostgreSQL + Patroni, PostgreSQL HAProxy, etcd, UCARP |
| `vm3` | `test-vm3` | etcd-узел для поддержания кворума |
| `VIP` | — | единая клиентская точка входа к Keycloak |

В рабочих сценариях `vm1` и `vm2` являются взаимозаменяемыми узлами для приложения и базы данных. `vm3` не обслуживает пользовательские запросы Keycloak, но участвует в etcd-кластере, чтобы сохранить нечётное количество участников и возможность работы при отказе одного etcd-узла.

---

## Технологический стек

| Компонент | Назначение | Где используется |
|---|---|---|
| **Keycloak** | сервис авторизации и единого входа | `vm1`, `vm2` |
| **PostgreSQL** | хранение постоянных данных Keycloak | `vm1`, `vm2` |
| **Patroni** | управление ролями PostgreSQL и автоматическое переключение primary | `vm1`, `vm2` |
| **etcd** | распределённое хранилище состояния Patroni | `vm1`, `vm2`, `vm3` |
| **HAProxy Keycloak** | балансировка HTTP-запросов к Keycloak | `vm1`, `vm2` |
| **HAProxy PostgreSQL** | маршрутизация соединений к текущему primary PostgreSQL | `vm1`, `vm2` |
| **UCARP** | перенос VIP между рабочими узлами | `vm1`, `vm2` |
| **Docker / Docker Compose** | запуск сервисов в контейнерах | все узлы |
| **Ansible** | автоматизация установки, настройки и запуска компонентов | управляющий узел |
| **Debian 12** | базовая ОС виртуальных машин | все узлы |

---

## Принцип работы

### Входной трафик

Клиент обращается к системе по виртуальному IP-адресу. VIP находится только на одном из рабочих узлов и обслуживается UCARP. На активном узле запрос принимает HAProxy Keycloak и перенаправляет его на доступный backend Keycloak.

Если локальный Keycloak недоступен, HAProxy может исключить его из балансировки и направить запрос к экземпляру на другом рабочем узле. Если проблема затрагивает активный входной узел целиком или локальная проверка доступности не проходит заданное количество раз, UCARP переносит VIP на резервный узел.

### Работа Keycloak

Keycloak запущен на `vm1` и `vm2`. Оба экземпляра используют одну логическую базу данных PostgreSQL, но подключаются к ней не напрямую к конкретному серверу, а через PostgreSQL HAProxy. Это позволяет Keycloak продолжить работу после смены primary-узла PostgreSQL.

Основная проверка доступности Keycloak выполняется через realm endpoint:

```bash
curl -i http://127.0.0.1:8080/realms/master
curl -i http://127.0.0.1/realms/master
curl -i http://<VIP>/realms/master
```

### Работа PostgreSQL и Patroni

PostgreSQL и Patroni рассматриваются как единый управляемый контейнерный компонент. Patroni запускает PostgreSQL, контролирует его состояние, хранит информацию о ролях в etcd и выполняет переключение при отказе primary.

В нормальном состоянии один узел имеет роль `Leader` или `Primary`, второй — `Replica` или `Sync Standby`. Реплика получает изменения от primary, а Patroni следит за тем, чтобы в DCS сохранялась актуальная информация о владельце лидерского lock.

Проверка состояния выполняется командой:

```bash
docker exec -it patroni patronictl -c /etc/patroni/patroni.yml list
```

Ожидаемое состояние:

- один узел является `Leader`;
- второй узел находится в состоянии `Replica` или `Sync Standby`;
- репликация находится в состоянии `streaming`;
- задержка репликации отсутствует или минимальна.

### Работа etcd

etcd используется как DCS — распределённое хранилище состояния для Patroni. В etcd хранится информация о составе кластера PostgreSQL, текущем лидере и служебных ключах, необходимых для корректного failover.

Кластер etcd состоит из трёх участников на `vm1`, `vm2` и `vm3`. Такой состав позволяет сохранить работоспособность при отказе одного участника etcd. Для клиентского доступа используются порты `2379`, для peer-взаимодействия — `2380`.

Пример проверки etcd:

```bash
docker exec -it etcd etcdctl \
  --endpoints=http://<VM1_IP>:2379,http://<VM2_IP>:2379,http://<VM3_IP>:2379 \
  endpoint health
```

### Работа UCARP и VIP

UCARP отвечает за наличие VIP только на одном из рабочих узлов. В проекте используется active/backup-поведение: один узел обслуживает виртуальный адрес, второй готов принять его при отказе.

Важная особенность текущей логики — VIP не обязан автоматически возвращаться на исходный узел сразу после его восстановления. Это снижает вероятность лишних переключений после кратковременных сбоев. Возврат на исходный узел может выполняться вручную администратором или произойти при отказе текущего владельца VIP.

Типовая проверка VIP:

```bash
ip -br addr | grep <VIP> || true
```

VIP должен отображаться только на одном из двух рабочих узлов.

### Healthcheck UCARP

Для контроля входного узла используется healthcheck-сервис. Он проверяет локальную доступность Keycloak через HAProxy. В текущей логике используются следующие параметры:

| Параметр | Значение | Назначение |
|---|---:|---|
| `HEALTHCHECK_URL` | `http://127.0.0.1/realms/master` | локальная проверка Keycloak через HAProxy |
| `INTERVAL` | `5` секунд | периодичность проверки |
| `TIMEOUT` | `3` секунды | таймаут одного запроса |
| `MAX_FAILS` | `3` | число ошибок до остановки участия узла в VIP |
| `SUCCESS_TO_REJOIN` | `12` | число успешных проверок перед возвратом узла в доступное состояние |

Состояние сервисов:

```bash
sudo systemctl status ucarp --no-pager
sudo systemctl status ucarp-healthcheck --no-pager
```

Журналы:

```bash
sudo journalctl -u ucarp --since "15 minutes ago" --no-pager
sudo journalctl -u ucarp-healthcheck --since "15 minutes ago" --no-pager
```

---

## Структура проекта

```text
.
├── ansible/
│   ├── ansible.cfg
│   ├── inventory.yml
│   ├── site.yml
│   ├── group_vars/
│   │   └── all/
│   │       ├── main.yml
│   │       └── secrets.yml          # локальный файл, не должен попадать в Git
│   ├── templates/
│   │   └── env.j2
│   └── roles/
│       ├── common/
│       ├── project/
│       ├── etcd/
│       ├── docker_images/
│       ├── patroni/
│       ├── pg_haproxy/
│       ├── keycloak/
│       ├── keycloak_haproxy/
│       ├── preflight/
│       └── ucarp/
├── config/
│   ├── keycloak-haproxy/
│   ├── patroni/
│   ├── pg-haproxy/
│   └── ucarp/
├── docker-compose-etcd.yml
├── docker-compose-patroni.yml
├── docker-compose-pg-haproxy.yml
├── docker-compose-keycloak.yml
├── docker-compose-keycloak-haproxy.yml
├── haproxy-image/
├── patroni-image/
├── scripts/
├── arch.svg
└── README.md
```

Главный принцип структуры — не хранить сетевые адреса и изменяемые параметры внутри готовых конфигураций. Ansible генерирует `.env`, HAProxy-конфиги, Patroni-конфиги и unit-файлы UCARP из переменных и шаблонов.

---

## Где менять параметры

### 1. Топология стенда

Файл:

```text
ansible/inventory.yml
```

Здесь меняются:

- IP-адреса виртуальных машин;
- SSH-пользователи;
- hostname узлов;
- VIP;
- сетевой интерфейс для VIP, например `ens33`;
- имена участников etcd;
- имена участников Patroni;
- приоритеты UCARP через `ucarp_advskew`;
- распределение узлов по группам Ansible.

Пример фрагмента:

```yaml
vm1:
  ansible_host: 192.168.182.140
  ansible_user: keycloak-vm1
  host_ip: 192.168.182.140
  node_hostname: test-vm1
  etcd_name: etcd-vm1
  patroni_name: test-vm1
  node_role: keycloak_node
  ucarp_advskew: 10
```

При переносе стенда в другую сеть обычно достаточно изменить `ansible_host`, `host_ip`, `vip`, `gateway`, `network_prefix` и сетевой интерфейс в inventory. Ручное исправление IP-адресов в конфигурациях сервисов выполнять не нужно.

### 2. Несекретные параметры сервисов

Файл:

```text
ansible/group_vars/all/main.yml
```

Здесь задаются:

- версии образов;
- имена контейнеров;
- порты сервисов;
- параметры healthcheck;
- имя базы данных Keycloak;
- параметры etcd;
- параметры Patroni;
- имя проекта Docker Compose;
- пути к конфигурациям и volume-каталогам.

### 3. Локальные секреты

Файл:

```text
ansible/group_vars/all/secrets.yml
```

Файл создаётся локально и не должен попадать в публичный репозиторий. В нём хранятся пароли PostgreSQL, пользователя репликации, администратора Keycloak, HAProxy stats и UCARP.

Пример минимального содержимого:

```yaml
---
postgres_password: postgres_pass
replication_username: replicator
replication_password: replicator_pass
keycloak_db_password: keycloak_pass
keycloak_admin: admin
keycloak_admin_password: admin_pass
haproxy_stats_user: admin
haproxy_stats_password: admin123
ucarp_password: keycloak-ha-vip
```

---

## Требования к виртуальным машинам

Перед запуском Ansible должны быть подготовлены три виртуальные машины:

1. Установлен Debian 12.
2. Настроены статические IP-адреса.
3. Узлы доступны друг другу по сети.
4. Установлен и запущен SSH-сервер.
5. Созданы пользователи для подключения Ansible.
6. Пользователи имеют право выполнять команды через `sudo`.
7. На управляющей машине установлен Ansible.
8. Сетевой интерфейс для VIP известен заранее, например `ens33`.

Пример распределения пользователей:

| Узел | Пользователь |
|---|---|
| `vm1` | `keycloak-vm1` |
| `vm2` | `keycloak-vm2` |
| `vm3` | `keycloak-vm3` |

---

## Подготовка управляющей машины

Управляющей машиной может быть `vm1` или отдельная административная машина, имеющая SSH-доступ ко всем трём узлам.

Установить необходимые пакеты:

```bash
sudo apt update
sudo apt install -y git ansible openssh-client
```

Клонировать репозиторий:

```bash
cd /opt
sudo git clone https://github.com/UnexarT/keycloak-ha.git
sudo chown -R $USER:$USER /opt/keycloak-ha
cd /opt/keycloak-ha
```

Проверить ветку:

```bash
git branch --show-current
```

Для текущей версии проекта используется ветка:

```text
keycloak-ansible
```

---

## Настройка SSH для Ansible

Ansible должен подключаться ко всем узлам по SSH.

На управляющей машине создать ключ:

```bash
ssh-keygen -t ed25519 -C "ansible-keycloak-ha"
```

Скопировать ключ на узлы:

```bash
ssh-copy-id keycloak-vm1@<VM1_IP>
ssh-copy-id keycloak-vm2@<VM2_IP>
ssh-copy-id keycloak-vm3@<VM3_IP>
```

Проверить подключение:

```bash
ssh keycloak-vm1@<VM1_IP> hostname
ssh keycloak-vm2@<VM2_IP> hostname
ssh keycloak-vm3@<VM3_IP> hostname
```

---

## Локальный файл секретов

Если файла `ansible/group_vars/all/secrets.yml` нет, его нужно создать вручную:

```bash
cd /opt/keycloak-ha
mkdir -p ansible/group_vars/all
cat > ansible/group_vars/all/secrets.yml <<'EOF'
---
postgres_password: postgres_pass
replication_username: replicator
replication_password: replicator_pass
keycloak_db_password: keycloak_pass
keycloak_admin: admin
keycloak_admin_password: admin_pass
haproxy_stats_user: admin
haproxy_stats_password: admin123
ucarp_password: keycloak-ha-vip
EOF
```

Проверить, что файл не будет добавлен в Git:

```bash
git status --short
```

---

## Проверка Ansible

Перейти в каталог Ansible:

```bash
cd /opt/keycloak-ha/ansible
```

Проверить структуру inventory:

```bash
ansible-inventory --graph
```

Проверить доступность узлов:

```bash
ansible all -m ping
```

Проверить выполнение команд с повышением прав:

```bash
ansible all -m command -a "whoami" --become --ask-become-pass
```

Ожидаемый результат:

```text
root
```

---

## Развёртывание

### Preflight-проверки

```bash
cd /opt/keycloak-ha/ansible
ansible-playbook site.yml --tags preflight --ask-become-pass
```

Preflight-проверки нужны, чтобы до развёртывания выявить базовые проблемы: неподдерживаемую ОС, недоступность узлов, ошибки inventory или отсутствие необходимых прав.

### Полное развёртывание

```bash
cd /opt/keycloak-ha/ansible
ansible-playbook site.yml --ask-become-pass
```

Playbook выполняет следующие этапы:

1. Проверяет базовые условия на узлах.
2. Устанавливает системные пакеты и Docker.
3. Создаёт структуру проекта на целевых узлах.
4. Генерирует `.env` из Ansible-переменных.
5. Генерирует конфигурации etcd, Patroni, HAProxy и UCARP из шаблонов.
6. Запускает etcd-кластер.
7. Запускает PostgreSQL под управлением Patroni.
8. Запускает HAProxy для PostgreSQL.
9. Запускает Keycloak.
10. Запускает HAProxy для Keycloak.
11. Устанавливает и запускает UCARP.
12. Запускает healthcheck-сервис для контроля входного узла.

После выполнения playbook ручное редактирование `.env`, HAProxy-конфигов, Patroni-конфигов и unit-файлов UCARP не требуется: эти файлы должны формироваться из переменных и шаблонов.

---

## Проверка после развёртывания

### Контейнеры

На `vm1` и `vm2`:

```bash
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
```

Ожидаемые контейнеры:

```text
etcd
patroni
pg_haproxy
keycloak
keycloak_haproxy
```

На `vm3`:

```bash
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
```

Ожидаемый контейнер:

```text
etcd
```

### etcd

```bash
docker exec -it etcd etcdctl \
  --endpoints=http://<VM1_IP>:2379,http://<VM2_IP>:2379,http://<VM3_IP>:2379 \
  endpoint health
```

Ожидаемо: все доступные endpoint возвращают состояние `healthy`.

### Patroni / PostgreSQL

На `vm1` или `vm2`:

```bash
docker exec -it patroni patronictl -c /etc/patroni/patroni.yml list
```

Ожидаемо:

- один узел имеет роль `Leader`;
- второй узел имеет роль `Replica` или `Sync Standby`;
- состояние реплики — `streaming`;
- задержка репликации отсутствует или минимальна.

### Keycloak напрямую

На `vm1` и `vm2`:

```bash
curl -i http://127.0.0.1:8080/realms/master
```

Ожидаемо:

```text
HTTP/1.1 200 OK
```

### Keycloak через локальный HAProxy

На `vm1` и `vm2`:

```bash
curl -i http://127.0.0.1/realms/master
```

Ожидаемо:

```text
HTTP/1.1 200 OK
```

### VIP

На `vm1` и `vm2`:

```bash
ip -br addr | grep <VIP> || true
```

VIP должен быть только на одном из двух рабочих узлов.

Проверка клиентского доступа:

```bash
curl -i http://<VIP>/realms/master
```

Ожидаемо:

```text
HTTP/1.1 200 OK
```

Административная консоль Keycloak:

```text
http://<VIP>/admin
```

### HAProxy stats

Keycloak HAProxy:

```text
http://<VIP>:8404/stats
```

PostgreSQL HAProxy:

```text
http://127.0.0.1:7000/stats
```

Через stats-страницы удобно проверять, какие backend-узлы доступны и какой узел исключён из маршрутизации после отказа.

---

## Проверка отказоустойчивости

Перед каждым тестом желательно зафиксировать исходное состояние:

```bash
ip -br addr | grep <VIP> || true
docker ps --format "table {{.Names}}\t{{.Status}}"
docker exec -it patroni patronictl -c /etc/patroni/patroni.yml list
curl -i http://<VIP>/realms/master
```

### 1. Отказ Keycloak

Сценарий проверяет, что при отказе одного экземпляра Keycloak HAProxy исключает недоступный backend и продолжает направлять запросы на доступный экземпляр.

На одном из рабочих узлов остановить Keycloak:

```bash
cd /opt/keycloak-ha
docker compose --env-file .env -f docker-compose-keycloak.yml stop
```

Проверить доступность через VIP:

```bash
curl -i http://<VIP>/realms/master
```

Проверить состояние backend-узлов в HAProxy stats:

```text
http://<VIP>:8404/stats
```

Вернуть Keycloak:

```bash
cd /opt/keycloak-ha
docker compose --env-file .env -f docker-compose-keycloak.yml start
```

Ожидаемый результат: один backend временно становится недоступным, но клиентский запрос через VIP продолжает получать корректный ответ Keycloak.

### 2. Отказ PostgreSQL + Patroni

В проекте PostgreSQL и Patroni рассматриваются как единый контейнерный компонент. Поэтому отказ проверяется остановкой контейнера Patroni на узле, который сейчас является `Leader`.

Определить текущего лидера:

```bash
docker exec -it patroni patronictl -c /etc/patroni/patroni.yml list
```

На узле `Leader` остановить Patroni:

```bash
cd /opt/keycloak-ha
docker compose --env-file .env -f docker-compose-patroni.yml stop
```

На втором рабочем узле проверить смену роли:

```bash
docker exec -it patroni patronictl -c /etc/patroni/patroni.yml list
curl -i http://<VIP>/realms/master
```

Вернуть компонент:

```bash
cd /opt/keycloak-ha
docker compose --env-file .env -f docker-compose-patroni.yml start
```

Ожидаемый результат: резервный узел получает роль primary, PostgreSQL HAProxy начинает направлять соединения к новому primary, Keycloak остаётся доступным после завершения переключения.

### 3. Отказ активного входного узла

Сценарий проверяет перенос VIP между рабочими узлами.

Найти владельца VIP:

```bash
ip -br addr | grep <VIP> || true
```

На узле, где находится VIP, можно остановить сервис UCARP или вызвать отказ локальной проверки доступности:

```bash
sudo systemctl stop ucarp
```

На втором рабочем узле проверить появление VIP:

```bash
ip -br addr | grep <VIP> || true
curl -i http://<VIP>/realms/master
```

Вернуть UCARP:

```bash
sudo systemctl start ucarp
```

Ожидаемый результат: VIP переходит на резервный рабочий узел, клиентский доступ к Keycloak восстанавливается через тот же адрес.

> VIP может не вернуться автоматически на исходный узел после его восстановления. Для текущей логики это нормальное поведение: автоматическое вытеснение активного узла не требуется, чтобы избежать лишних переключений.

### 4. Отказ одного etcd-узла

Сценарий проверяет, что отказ одного участника etcd не нарушает работу Patroni и Keycloak.

Например, на `vm3` остановить etcd:

```bash
cd /opt/keycloak-ha
docker compose --env-file .env -f docker-compose-etcd.yml stop
```

Проверить состояние системы:

```bash
docker exec -it patroni patronictl -c /etc/patroni/patroni.yml list
curl -i http://<VIP>/realms/master
```

Вернуть etcd:

```bash
cd /opt/keycloak-ha
docker compose --env-file .env -f docker-compose-etcd.yml start
```

Ожидаемый результат: оставшиеся два участника etcd сохраняют кворум, Patroni продолжает работать с DCS, Keycloak остаётся доступным.

---

## Изменение IP-адресов и hostname

Если меняются IP-адреса, SSH-пользователи, hostname, VIP или сетевой интерфейс, изменить нужно файл:

```text
ansible/inventory.yml
```

После изменения проверить inventory и доступность узлов:

```bash
cd /opt/keycloak-ha/ansible
ansible-inventory --graph
ansible all -m ping
ansible-playbook site.yml --syntax-check
```

Затем повторно выполнить playbook:

```bash
ansible-playbook site.yml --ask-become-pass
```

Ручное изменение `.env`, `config/patroni/patroni.yml`, конфигураций HAProxy и systemd unit-файлов UCARP не требуется, потому что они формируются из Ansible-переменных.

---

## Полезные команды диагностики

### Логи Keycloak

```bash
docker logs keycloak --tail 100
```

### Логи Patroni

```bash
docker logs patroni --tail 100
```

### Логи etcd

```bash
docker logs etcd --tail 100
```

### Логи HAProxy Keycloak

```bash
docker logs keycloak_haproxy --tail 100
```

### Логи HAProxy PostgreSQL

```bash
docker logs pg_haproxy --tail 100
```

### Состояние UCARP

```bash
sudo systemctl status ucarp --no-pager
sudo systemctl status ucarp-healthcheck --no-pager
```

### Журналы UCARP

```bash
sudo journalctl -u ucarp --since "15 minutes ago" --no-pager
sudo journalctl -u ucarp-healthcheck --since "15 minutes ago" --no-pager
```

### Наличие VIP

```bash
ip -br addr | grep <VIP> || true
```

### Проверка занятых портов

```bash
ss -tulpn | grep -E ':80|:8080|:8404|:5432|:7000|:2379|:2380'
```

---

## Особенности текущей реализации

- Проект развивает существующую инфраструктуру Keycloak, а не заменяет её новой системой авторизации.
- Развёртывание выполняется в тестовом контуре Политеха.
- Основные параметры вынесены в Ansible inventory, group variables, `.env` и шаблоны.
- IP-адреса узлов, VIP и сетевые параметры не должны жёстко прописываться внутри конфигураций сервисов.
- PostgreSQL и Patroni рассматриваются как единый контейнерный компонент, поэтому сценарий отказа проверяется остановкой контейнера Patroni.
- Входная отказоустойчивость реализована через UCARP и VIP.
- Автоматический возврат VIP на исходный узел после восстановления не является обязательным поведением текущей схемы.
- TLS на текущем этапе не включён в конфигурацию, так как в инфраструктуре Политеха меняется схема сертификации, а постоянные сертификаты для закрепления в проекте пока не предоставлены.
- Перед переносом в эксплуатационный контур настройки TLS должны быть согласованы с актуальной политикой сертификатов организации.

---

## Итог

Репозиторий содержит реализацию отказоустойчивой системы авторизации Keycloak для трёх виртуальных машин. Основной результат проекта — не замена существующего сервиса авторизации, а повышение его доступности за счёт кластеризации, автоматического переключения PostgreSQL, резервирования входной точки и воспроизводимого развёртывания через Ansible.
