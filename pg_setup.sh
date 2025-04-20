#!/bin/bash

SSH_KEY="$HOME/.ssh/id_rsa"
DB_USER="student"
DB_PASS="studentpass"
DB_NAME="postgres"

while [[ "$1" != "" ]]; do
    case $1 in
        --key )        shift; SSH_KEY=$1 ;;
        --user )       shift; DB_USER=$1 ;;
        --password )   shift; DB_PASS=$1 ;;
        --db )         shift; DB_NAME=$1 ;;
        * )            SERVERS_STR=$1 ;;
    esac
    shift
done

if [ -z "$SERVERS_STR" ]; then
    echo "Usage: $0 ip1,ip2 [--key /path/to/key] [--user user] [--password pass] [--db dbname]"
    exit 1
fi

IFS=',' read -ra SERVERS <<< "$SERVERS_STR"
IP1=${SERVERS[0]}
IP2=${SERVERS[1]}

for cmd in ssh awk sed grep bc netstat ss; do
    command -v $cmd >/dev/null || { echo "[ERROR] Command $cmd not found."; exit 1; }
done

echo "[INFO] Checking PostgreSQL client on both hosts"
for HOST in $IP1 $IP2; do
  ssh -i $SSH_KEY root@$HOST "
    command -v psql >/dev/null || (
      echo '[INFO] Installing PostgreSQL client on $HOST'
      source /etc/os-release
      case \$ID in
        debian|ubuntu) apt update && apt install -y postgresql-client ;;
        centos|almalinux|rhel) dnf install -y postgresql ;;
        *) echo '[ERROR] Неизвестная ОС: '\$ID ;;
      esac
    )"
done

get_load() {
    ssh -i $SSH_KEY root@$1 "uptime" | awk -F'load average:' '{ print $2 }' | cut -d',' -f1
}

LOAD1=$(get_load $IP1)
LOAD2=$(get_load $IP2)

if (( $(echo "$LOAD1 < $LOAD2" | bc -l) )); then
    TARGET=$IP1
    OTHER=$IP2
else
    TARGET=$IP2
    OTHER=$IP1
fi

echo "[INFO] Target selected: $TARGET"

OS_ID=$(ssh -i $SSH_KEY root@$TARGET "source /etc/os-release && echo \$ID")

install_postgres() {
    if [[ "$1" == "debian" ]]; then
        ssh -i $SSH_KEY root@$2 "
            apt update &&
            apt install -y postgresql &&
            systemctl enable --now postgresql
        "
    elif [[ "$1" == "centos" || "$1" == "almalinux" ]]; then
        ssh -i $SSH_KEY root@$2 "
            dnf install -y postgresql-server postgresql-contrib &&
            [ ! -f /var/lib/pgsql/data/PG_VERSION ] && postgresql-setup --initdb &&
            systemctl enable --now postgresql
        "
    fi
}

echo "[INFO] Installing PostgreSQL on $TARGET"
install_postgres $OS_ID $TARGET

echo "[INFO] Opening port 5432 on $TARGET (firewalld)"  
ssh -i $SSH_KEY root@$TARGET "
    if command -v firewall-cmd >/dev/null; then
        firewall-cmd --add-port=5432/tcp --permanent && firewall-cmd --reload
    else
        echo '[WARN] Firewalld не активен'
    fi

    if command -v semanage >/dev/null; then
        semanage boolean -l | grep postgres_can_network_connect >/dev/null && \
        setsebool -P postgres_can_network_connect 1
    fi
"

configure_postgres() {
    ssh -i $SSH_KEY root@$1 bash <<EOF
source /etc/os-release

if [[ "\$ID" == "debian" || "\$ID" == "ubuntu" ]]; then
    PG_CONF="/etc/postgresql/13/main/postgresql.conf"
    PG_HBA="/etc/postgresql/13/main/pg_hba.conf"
elif [[ "\$ID" == "centos" || "\$ID" == "almalinux" || "\$ID" == "rhel" ]]; then
    PGDATA_DIR="/var/lib/pgsql/data"
    PG_CONF="\$PGDATA_DIR/postgresql.conf"
    PG_HBA="\$PGDATA_DIR/pg_hba.conf"
else
    echo "[ERROR] Неизвестная ОС для конфигурации PostgreSQL!"
    exit 1
fi

echo "[DEBUG] PG_CONF: \$PG_CONF"
echo "[DEBUG] PG_HBA: \$PG_HBA"

if [[ -f "\$PG_CONF" && -f "\$PG_HBA" ]]; then
    sed -i "s/^#\\?listen_addresses\\s*=.*/listen_addresses = '*'/" "\$PG_CONF"
    echo "host all $DB_USER $OTHER/32 md5" >> "\$PG_HBA"
    echo "host all $DB_USER 127.0.0.1/32 md5" >> "\$PG_HBA"
    systemctl restart postgresql || systemctl restart postgresql-*
else
    echo "[ERROR] Конфигурационные файлы PostgreSQL не найдены!"
    exit 1
fi
EOF
}

echo "[INFO] Configuring PostgreSQL on $TARGET"
configure_postgres $TARGET

echo "[INFO] Creating PostgreSQL user '$DB_USER'"
ssh -i $SSH_KEY root@$TARGET "
    sudo -u postgres psql -tc \"SELECT 1 FROM pg_roles WHERE rolname = '$DB_USER'\" | grep -q 1 || \
    sudo -u postgres psql -c \"CREATE USER $DB_USER WITH PASSWORD '$DB_PASS';\"
"

echo "[INFO] Checking if PostgreSQL is listening on port 5432"
ssh -i $SSH_KEY root@$TARGET "ss -tulnp | grep 5432 || netstat -tlpn | grep 5432"

echo "[INFO] Testing connection to $OTHER"
ssh -i $SSH_KEY root@$OTHER "
    command -v psql >/dev/null || (
        echo '[INFO] Installing PostgreSQL client (psql) on $OTHER'
        source /etc/os-release
        case \$ID in
            debian|ubuntu) apt update && apt install -y postgresql-client ;;
            centos|almalinux|rhel) dnf install -y postgresql ;;
        esac
    )
    echo "[INFO] Executing 'SELECT 1' on $TARGET"
    PGPASSWORD=$DB_PASS psql -h $TARGET -U $DB_USER -d $DB_NAME -c 'SELECT 1;'
" && echo "[SUCCESS] Подключение успешно!" || echo "[ERROR] Не удалось подключиться!"

echo "[DONE] PostgreSQL установлен и настроен на $TARGET"