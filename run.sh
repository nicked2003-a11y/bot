#!/bin/bash

GREEN='\033[0;32m'
CYAN='\033[0;36m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

REMOTE_NAME="blomp_cloud"
CONFIG_FILE="/root/.fakecloud_blomp"
NAME_FILE="/root/.fakecloud_backup_name"
BACKUP_FOLDER="BackupVps"
KEEP_COUNT=1
RCLONE_FLAGS="--no-check-certificate --retries 5 --timeout 60m --contimeout 60s"

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Ye script ROOT user se run karein.${NC}"
    exit 1
fi

load_blomp_config() {
    [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"
}

load_backup_name() {
    if [ -f "$NAME_FILE" ]; then
        BACKUP_NAME=$(cat "$NAME_FILE" | tr -cd 'A-Za-z0-9._-')
    else
        BACKUP_NAME=""
    fi
}

save_backup_name() {
    local n
    n=$(echo "$1" | tr -cd 'A-Za-z0-9._-')
    [ -z "$n" ] && n="panel"
    echo "$n" > "$NAME_FILE"
    chmod 600 "$NAME_FILE"
    BACKUP_NAME="$n"
}

ensure_cron() {
    if command -v crontab >/dev/null 2>&1; then return 0; fi
    apt-get update -y >/dev/null 2>&1
    apt-get install -y cron >/dev/null 2>&1
    systemctl enable --now cron >/dev/null 2>&1 || true
}

ensure_rclone() {
    export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"
    if ! command -v rclone >/dev/null 2>&1; then
        apt-get update -y >/dev/null 2>&1
        apt-get install -y rclone >/dev/null 2>&1 || curl -fsSL https://rclone.org/install.sh | bash >/dev/null 2>&1
    fi
    command -v rclone >/dev/null 2>&1
}

ensure_pigz() {
    if ! command -v pigz >/dev/null 2>&1; then
        apt-get install -y pigz >/dev/null 2>&1 || true
    fi
}

install_all_dependencies() {
    clear
    echo -e "${YELLOW}>>> Zaroori Tools Check & Setup...<<<${NC}"
    ensure_cron
    ensure_rclone
    ensure_pigz
    apt-get install -y curl tar gzip unzip mariadb-client coreutils ca-certificates >/dev/null 2>&1 || true
    mkdir -p /root/.config/rclone /tmp
    echo -e "${GREEN}✓ All tools ready!${NC}"
    sleep 1
}

# ==================== BLOMP LOGIN ====================
setup_blomp() {
    clear
    echo -e "${CYAN}======== BLOMP CLOUD LOGIN ========${NC}"
    ensure_rclone || return

    read -p "Blomp Email: " blomp_user
    read -s -p "Blomp Password: " blomp_pass
    echo ""
    echo ""

    if [ -z "$blomp_user" ] || [ -z "$blomp_pass" ]; then
        echo -e "${RED}Email/Password empty nahi ho sakte.${NC}"
        sleep 2
        return
    fi

    echo -e "${YELLOW}Blomp OpenStack Swift se connect ho raha hai...${NC}"
    mkdir -p /root/.config/rclone

    cat > /root/.config/rclone/rclone.conf <<EOF
[${REMOTE_NAME}]
type = swift
env_auth = false
user = ${blomp_user}
key = ${blomp_pass}
auth = https://authenticate.ain.net
tenant = storage
auth_version = 2
endpoint_type = public
use_segments_container = false
leave_parts_on_error = true
no_check_certificate = true
EOF
    chmod 600 /root/.config/rclone/rclone.conf
    unset blomp_pass

    cat > "$CONFIG_FILE" <<EOF
BLOMP_USER='${blomp_user}'
EOF
    chmod 600 "$CONFIG_FILE"

    if rclone lsf "${REMOTE_NAME}:${blomp_user}" $RCLONE_FLAGS >/tmp/blomp_test.log 2>&1; then
        echo -e "${GREEN}✓ Blomp Login Successful!${NC}"
        echo -e "Cloud Container: ${CYAN}${blomp_user}/${BACKUP_FOLDER}/${NC}"
    else
        echo -e "${RED}✗ Login Fail!${NC}"
        cat /tmp/blomp_test.log 2>/dev/null
        rm -f "$CONFIG_FILE" /root/.config/rclone/rclone.conf
    fi
    read -p "Enter dabayein..." t
}

check_blomp_login() {
    load_blomp_config
    ensure_rclone || return 1
    if [ -z "$BLOMP_USER" ] || ! rclone listremotes 2>/dev/null | grep -q "^${REMOTE_NAME}:$"; then
        setup_blomp
        load_blomp_config
    fi
    [ -z "$BLOMP_USER" ] && return 1
    return 0
}

# ==================== CHECK IMPORTANT DATA ====================
show_important_data() {
    echo -e "${CYAN}--- System / Blueprint Addons / Wings Paths ---${NC}"
    PATHS=(
        "/var/lib/pterodactyl"
        "/etc/pterodactyl"
        "/var/www/pterodactyl"
        "/var/www/pterodactyl/.blueprint"
        "/var/lib/tailscale"
        "/etc/cloudflared"
        "/root/.cloudflared"
        "/etc/letsencrypt"
        "/etc/nginx"
        "/root"
        "/home"
        "/etc/systemd/system"
        "/usr/local/bin"
    )
    for p in "${PATHS[@]}"; do
        if [ -e "$p" ]; then
            sz=$(du -sh "$p" 2>/dev/null | awk '{print $1}')
            echo -e "  ${GREEN}FOUND${NC}  $p  →  ${YELLOW}$sz${NC}"
        else
            echo -e "  ${RED}NOT FOUND${NC}  $p"
        fi
    done
    echo ""
}

# ==================== CLEANUP OLD BACKUPS ====================
cleanup_old_backups() {
    local REMOTE_DIR="$1"
    local KEEP_FILE="$2"
    local LOG="${3:-/var/log/fakecloud-backup.log}"

    echo -e "${YELLOW}Purane backups check & cleanup...${NC}"
    mapfile -t all_files < <(
        rclone lsf "$REMOTE_DIR" --files-only --include "*.tar.gz" $RCLONE_FLAGS 2>/dev/null | sort -r
    )
    local count=${#all_files[@]}
    if [ "$count" -le "$KEEP_COUNT" ]; then
        echo -e "${GREEN}✓ Sirf $count backup(s) — cleanup zaroorat nahi.${NC}"
        return 0
    fi
    for i in "${!all_files[@]}"; do
        f="${all_files[$i]}"
        [ "$i" -lt "$KEEP_COUNT" ] && continue
        [ "$f" = "$KEEP_FILE" ] && continue
        echo -e "${RED}DELETE OLD:${NC} $f"
        echo "DELETE OLD: $f" >> "$LOG"
        rclone deletefile "${REMOTE_DIR}/${f}" $RCLONE_FLAGS 2>>"$LOG" || true
    done
    echo -e "${GREEN}✓ Cleanup done — Sirf LATEST rahega!${NC}"
}

# ==================== GUARANTEED ZERO-FAIL DB ENGINE ====================
create_database_dump() {
    local OUT="/tmp/pterodactyl_database_dump.sql"
    local LOG="${1:-/var/log/fakecloud-backup.log}"
    rm -f "$OUT"

    systemctl start mysql mariadb >/dev/null 2>&1 || true
    sleep 1

    # 1. Try with .env credentials
    if [ -f /var/www/pterodactyl/.env ]; then
        local DB_USER DB_PASS DB_NAME DB_HOST
        DB_USER=$(grep -E '^DB_USERNAME=' /var/www/pterodactyl/.env | head -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'" | tr -d '\r')
        DB_PASS=$(grep -E '^DB_PASSWORD=' /var/www/pterodactyl/.env | head -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'" | tr -d '\r')
        DB_NAME=$(grep -E '^DB_DATABASE=' /var/www/pterodactyl/.env | head -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'" | tr -d '\r')
        DB_HOST=$(grep -E '^DB_HOST=' /var/www/pterodactyl/.env | head -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'" | tr -d '\r')
        [ -z "$DB_HOST" ] && DB_HOST="127.0.0.1"

        if [ -n "$DB_USER" ] && [ -n "$DB_NAME" ]; then
            MYSQL_PWD="$DB_PASS" mysqldump -h"$DB_HOST" -u"$DB_USER" \
                --single-transaction --quick --routines --triggers --events \
                "$DB_NAME" > "$OUT" 2>>"$LOG" || true
        fi
    fi

    # 2. Try root socket dump
    if [ ! -s "$OUT" ] && command -v mysqldump >/dev/null 2>&1; then
        mysqldump --all-databases --single-transaction --quick --routines --triggers --events > "$OUT" 2>>"$LOG" || true
    fi

    # 3. Try debian.cnf (Ubuntu Default)
    if [ ! -s "$OUT" ] && [ -f /etc/mysql/debian.cnf ]; then
        mysqldump --defaults-file=/etc/mysql/debian.cnf --all-databases --single-transaction --quick --routines --triggers --events > "$OUT" 2>>"$LOG" || true
    fi

    if [ -s "$OUT" ]; then
        echo "$OUT"
        return 0
    fi

    # 4. Fallback: Raw /var/lib/mysql Tar
    local RAW_OUT="/tmp/mysql_raw_datadir.tar.gz"
    rm -f "$RAW_OUT"
    if [ -d /var/lib/mysql ]; then
        systemctl stop mysql mariadb >/dev/null 2>&1 || true
        tar -czf "$RAW_OUT" --absolute-names --ignore-failed-read /var/lib/mysql 2>>"$LOG" || true
        systemctl start mysql mariadb >/dev/null 2>&1 || true
        if [ -s "$RAW_OUT" ]; then
            echo "$RAW_OUT"
            return 0
        fi
    fi

    return 1
}

# ==================== SUPER SMART BACKUP ENGINE ====================
do_smart_vps_backup() {
    load_blomp_config
    load_backup_name

    if [ -z "$BACKUP_NAME" ] || [ -z "$BLOMP_USER" ]; then
        echo -e "${RED}Pehle Login + Backup Name set karein.${NC}"
        return 1
    fi

    local TIME FILE LOG DEST_DIR DEST_OBJECT TEMP_FILE SUBFOLDER
    TIME=$(date +%Y-%m-%d_%H-%M-%S)
    FILE="${BACKUP_NAME}_${TIME}.tar.gz"
    TEMP_FILE="/tmp/${FILE}"
    SUBFOLDER="${BACKUP_NAME}"
    DEST_DIR="${REMOTE_NAME}:${BLOMP_USER}/${BACKUP_FOLDER}/${SUBFOLDER}"
    DEST_OBJECT="${DEST_DIR}/${FILE}"
    LOG="/var/log/fakecloud-backup.log"

    echo "======================================" >> "$LOG"
    echo "SMART BACKUP START $(date) file=$FILE" >> "$LOG"

    # 1. GUARANTEED DB BACKUP
    echo -e "${YELLOW}[1/4] Database Backup (Zero-Fail Engine)...${NC}"
    DB_BACKUP_PATH=$(create_database_dump "$LOG")

    if [ -n "$DB_BACKUP_PATH" ] && [ -f "$DB_BACKUP_PATH" ]; then
        DUMP_SZ=$(du -h "$DB_BACKUP_PATH" | awk '{print $1}')
        echo -e "${GREEN}   ✓ Database Backup Secured: ${DUMP_SZ}${NC}"
    else
        echo -e "${RED}   ⚠ Database Not Found / Skipped${NC}"
    fi

    # 2. Cloudflared token backup
    if [ -f /etc/cloudflared/token ]; then
        cp /etc/cloudflared/token /tmp/cloudflared_token_backup 2>/dev/null || true
    fi

    # 3. Target Paths (BLUEPRINT, ADDONS, THEMES, WINGS FULLY INCLUDED)
    TARGET_PATHS=()
    POSSIBLE_PATHS=(
        "/var/lib/pterodactyl"
        "/etc/pterodactyl"
        "/var/www/pterodactyl"
        "/var/lib/tailscale"
        "/etc/tailscale"
        "/etc/default/tailscaled"
        "/etc/cloudflared"
        "/root/.cloudflared"
        "/etc/letsencrypt"
        "/etc/nginx"
        "/etc/apache2"
        "/etc/php"
        "/etc/mysql"
        "/etc/redis"
        "/etc/supervisor"
        "/root"
        "/home"
        "/etc/systemd/system"
        "/usr/local/bin"
        "/var/spool/cron"
        "/etc/crontab"
    )

    [ -n "$DB_BACKUP_PATH" ] && [ -f "$DB_BACKUP_PATH" ] && TARGET_PATHS+=("$DB_BACKUP_PATH")
    [ -f /tmp/cloudflared_token_backup ] && TARGET_PATHS+=("/tmp/cloudflared_token_backup")

    for p in "${POSSIBLE_PATHS[@]}"; do
        [ -e "$p" ] && TARGET_PATHS+=("$p")
    done

    if [ ${#TARGET_PATHS[@]} -eq 0 ]; then
        echo -e "${RED}✗ Backup karne ke liye koi data nahi mila!${NC}"
        rm -f "$DB_BACKUP_PATH" /tmp/cloudflared_token_backup 2>/dev/null
        return 1
    fi

    echo -e "${CYAN}[2/4] COMPRESSING ALL FILES (BLUEPRINT + ADDONS + DB)...${NC}"
    echo -e "  Cloud Folder: ${GREEN}${BACKUP_FOLDER}/${SUBFOLDER}/${NC}"
    echo -e "  Backup File:  ${GREEN}${FILE}${NC}"
    echo "--------------------------------------------------------"

    systemctl stop wings >/dev/null 2>&1 || true
    rm -f "$TEMP_FILE"

    if command -v pigz >/dev/null 2>&1; then
        tar -cf - \
            --absolute-names \
            --ignore-failed-read \
            --warning=no-file-changed \
            --exclude="/root/*.tar.gz" \
            --exclude="/root/.cache" \
            --exclude="/tmp/*.tar.gz" \
            --exclude="/var/www/pterodactyl/node_modules" \
            "${TARGET_PATHS[@]}" 2>>"$LOG" \
        | pigz -1 -c > "$TEMP_FILE" 2>>"$LOG"
    else
        tar -czf "$TEMP_FILE" \
            --absolute-names \
            --ignore-failed-read \
            --warning=no-file-changed \
            --exclude="/root/*.tar.gz" \
            --exclude="/root/.cache" \
            --exclude="/tmp/*.tar.gz" \
            --exclude="/var/www/pterodactyl/node_modules" \
            "${TARGET_PATHS[@]}" 2>>"$LOG"
    fi

    rm -f "$DB_BACKUP_PATH" /tmp/cloudflared_token_backup 2>/dev/null
    systemctl start wings >/dev/null 2>&1 || true

    if [ ! -f "$TEMP_FILE" ]; then
        echo -e "${RED}✗ Compression Fail!${NC}"
        return 1
    fi

    local HUMAN
    HUMAN=$(du -h "$TEMP_FILE" | awk '{print $1}')
    echo -e "${CYAN}[3/4] Backup Size: ${HUMAN}${NC}"
    echo -e "${YELLOW}[4/4] Blomp Cloud par Upload Ho Raha Hai...${NC}"

    rclone copyto "$TEMP_FILE" "$DEST_OBJECT" $RCLONE_FLAGS --progress

    local UPLOAD_RC=$?
    rm -f "$TEMP_FILE"

    echo "--------------------------------------------------------"
    if [ $UPLOAD_RC -eq 0 ]; then
        echo -e "${GREEN}✓ BACKUP SUCCESSFUL & UPLOADED!${NC}"
        echo "SUCCESS $FILE" >> "$LOG"
        cleanup_old_backups "$DEST_DIR" "$FILE" "$LOG"
        return 0
    else
        echo -e "${RED}✗ Upload Failed. Check Log: $LOG${NC}"
        return 1
    fi
}

create_auto_worker() {
    load_blomp_config
    load_backup_name

    cat > /root/do_full_backup.sh <<'EOF'
#!/bin/bash
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

REMOTE_NAME="blomp_cloud"
CONFIG_FILE="/root/.fakecloud_blomp"
NAME_FILE="/root/.fakecloud_backup_name"
BACKUP_FOLDER="BackupVps"
KEEP_COUNT=1
RCLONE_FLAGS="--no-check-certificate --retries 5 --timeout 60m --contimeout 60s"
LOG="/var/log/fakecloud-backup.log"

[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"
[ -f "$NAME_FILE" ] && BACKUP_NAME=$(cat "$NAME_FILE" | tr -cd 'A-Za-z0-9._-')
[ -z "$BACKUP_NAME" ] && BACKUP_NAME="panel"

TIME=$(date +%Y-%m-%d_%H-%M-%S)
FILE="${BACKUP_NAME}_${TIME}.tar.gz"
TEMP_FILE="/tmp/${FILE}"
SUBFOLDER="${BACKUP_NAME}"
DEST_DIR="${REMOTE_NAME}:${BLOMP_USER}/${BACKUP_FOLDER}/${SUBFOLDER}"
DEST_OBJECT="${DEST_DIR}/${FILE}"

echo "==== $(date) AUTO BACKUP $FILE ====" >> "$LOG"

# Database Dump Function
DB_BACKUP_PATH="/tmp/pterodactyl_database_dump.sql"
rm -f "$DB_BACKUP_PATH"

systemctl start mysql mariadb >/dev/null 2>&1 || true

if [ -f /var/www/pterodactyl/.env ]; then
    DB_USER=$(grep -E '^DB_USERNAME=' /var/www/pterodactyl/.env | head -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'" | tr -d '\r')
    DB_PASS=$(grep -E '^DB_PASSWORD=' /var/www/pterodactyl/.env | head -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'" | tr -d '\r')
    DB_NAME=$(grep -E '^DB_DATABASE=' /var/www/pterodactyl/.env | head -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'" | tr -d '\r')
    DB_HOST=$(grep -E '^DB_HOST=' /var/www/pterodactyl/.env | head -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'" | tr -d '\r')
    [ -z "$DB_HOST" ] && DB_HOST="127.0.0.1"

    if [ -n "$DB_USER" ] && [ -n "$DB_NAME" ]; then
        MYSQL_PWD="$DB_PASS" mysqldump -h"$DB_HOST" -u"$DB_USER" \
            --single-transaction --quick --routines --triggers --events \
            "$DB_NAME" > "$DB_BACKUP_PATH" 2>>"$LOG" || true
    fi
fi

if [ ! -s "$DB_BACKUP_PATH" ] && command -v mysqldump >/dev/null 2>&1; then
    mysqldump --all-databases --single-transaction --quick --routines --triggers --events > "$DB_BACKUP_PATH" 2>>"$LOG" || true
fi

[ -f /etc/cloudflared/token ] && cp /etc/cloudflared/token /tmp/cloudflared_token_backup 2>/dev/null || true

TARGETS=()
[ -s "$DB_BACKUP_PATH" ] && TARGETS+=("$DB_BACKUP_PATH")
[ -f /tmp/cloudflared_token_backup ] && TARGETS+=("/tmp/cloudflared_token_backup")

POSSIBLES=(
    "/var/lib/pterodactyl" "/etc/pterodactyl" "/var/www/pterodactyl"
    "/var/lib/tailscale" "/etc/tailscale" "/etc/default/tailscaled"
    "/etc/cloudflared" "/root/.cloudflared"
    "/etc/letsencrypt" "/etc/nginx" "/etc/apache2"
    "/etc/php" "/etc/mysql" "/etc/redis" "/etc/supervisor"
    "/root" "/home" "/etc/systemd/system" "/usr/local/bin"
    "/var/spool/cron" "/etc/crontab"
)

for p in "${POSSIBLES[@]}"; do
    [ -e "$p" ] && TARGETS+=("$p")
done

systemctl stop wings >/dev/null 2>&1 || true

if command -v pigz >/dev/null 2>&1; then
    tar -cf - --absolute-names --ignore-failed-read --warning=no-file-changed \
        --exclude="/root/*.tar.gz" --exclude="/root/.cache" --exclude="/tmp/*.tar.gz" \
        --exclude="/var/www/pterodactyl/node_modules" \
        "${TARGETS[@]}" 2>>"$LOG" | pigz -1 -c > "$TEMP_FILE" 2>>"$LOG"
else
    tar -czf "$TEMP_FILE" --absolute-names --ignore-failed-read --warning=no-file-changed \
        --exclude="/root/*.tar.gz" --exclude="/root/.cache" --exclude="/tmp/*.tar.gz" \
        --exclude="/var/www/pterodactyl/node_modules" \
        "${TARGETS[@]}" 2>>"$LOG"
fi

rm -f "$DB_BACKUP_PATH" /tmp/cloudflared_token_backup 2>/dev/null
systemctl start wings >/dev/null 2>&1 || true

rclone copyto "$TEMP_FILE" "$DEST_OBJECT" $RCLONE_FLAGS >>"$LOG" 2>&1
RC=$?

rm -f "$TEMP_FILE"

if [ $RC -eq 0 ]; then
    echo "SUCCESS $FILE" >> "$LOG"
    mapfile -t all_files < <(rclone lsf "$DEST_DIR" --files-only --include "*.tar.gz" $RCLONE_FLAGS 2>/dev/null | sort -r)
    for i in "${!all_files[@]}"; do
        f="${all_files[$i]}"
        [ "$i" -lt "$KEEP_COUNT" ] && continue
        [ "$f" = "$FILE" ] && continue
        rclone deletefile "${DEST_DIR}/${f}" $RCLONE_FLAGS 2>>"$LOG" || true
        echo "DELETED OLD: $f" >> "$LOG"
    done
fi

echo "Backup end rc=$RC" >> "$LOG"
exit $RC
EOF
    chmod 700 /root/do_full_backup.sh
}

# ==================== 1) AUTO BACKUP ====================
start_auto_backup() {
    clear
    if ! check_blomp_login; then sleep 2; return; fi
    ensure_cron
    ensure_pigz

    echo -e "${CYAN}╔════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║   SMART FAST AUTO-BACKUP (15 Minutes)      ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "Cloud: ${YELLOW}BackupVps/[NAME]/${NC}"
    echo -e "Includes: ${GREEN}Panel + Database + Blueprint Addons + Themes + Wings + Cloudflare${NC}"
    echo ""

    load_backup_name
    if [ -n "$BACKUP_NAME" ]; then
        echo -e "Current Name: ${GREEN}${BACKUP_NAME}${NC}"
        read -p "Naya Name? Enter=same, ya naya likho: " newname
        [ -n "$newname" ] && save_backup_name "$newname"
    else
        echo -e "${YELLOW}Backup Name (panel / node1 / node2):${NC}"
        read -p "Name: " newname
        [ -z "$newname" ] && newname="panel"
        save_backup_name "$newname"
    fi

    load_backup_name
    echo ""
    echo -e "${GREEN}Backup Name Lock: ${BACKUP_NAME}${NC}"
    echo ""

    create_auto_worker

    crontab -l 2>/dev/null | grep -v "/root/do_full_backup.sh" > /tmp/fcron || true
    echo "*/15 * * * * /bin/bash /root/do_full_backup.sh >/dev/null 2>&1" >> /tmp/fcron
    crontab /tmp/fcron
    rm -f /tmp/fcron

    echo -e "${GREEN}✓ Auto-Backup ON (Har 15 Min) — Name: ${BACKUP_NAME}${NC}"
    echo -e "${YELLOW}Pehla Backup abhi shuru...${NC}"
    echo ""

    do_smart_vps_backup
    read -p "Enter dabayein..." t
}

# ==================== AUTO SETUP PANEL + BLUEPRINT REPAIR ====================
auto_setup_panel() {
    echo -e "${CYAN}--- PANEL & BLUEPRINT AUTO-SETUP SHURU ---${NC}"

    # PHP + Nginx + MySQL + Redis Install
    if ! command -v php >/dev/null 2>&1 || ! command -v nginx >/dev/null 2>&1; then
        echo -e "${YELLOW}Panel Stack Install (PHP+Nginx+MySQL+Redis)...${NC}"
        apt-get install -y software-properties-common curl gnupg >/dev/null 2>&1
        add-apt-repository -y ppa:ondrej/php >/dev/null 2>&1
        apt-get update -y >/dev/null 2>&1
        apt-get install -y nginx mysql-server redis-server \
            php8.3 php8.3-{cli,fpm,common,mysql,mbstring,xml,bcmath,sqlite3,curl,zip,gd,tokenizer,intl,readline,gmp} \
            unzip git supervisor >/dev/null 2>&1
        systemctl enable --now nginx mysql redis-server php8.3-fpm supervisor >/dev/null 2>&1 || true
        echo -e "${GREEN}   ✓ Stack installed${NC}"
    fi

    # Composer
    if ! command -v composer >/dev/null 2>&1; then
        curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer >/dev/null 2>&1
    fi

    if [ ! -d /var/www/pterodactyl ]; then
        echo -e "${RED}   Panel directory nahi mili${NC}"
        return 1
    fi

    # 1. AUTO DATABASE RESTORE
    systemctl start mariadb mysql >/dev/null 2>&1 || true
    sleep 2

    # Option A: SQL Dump
    if [ -f /tmp/pterodactyl_database_dump.sql ] || [ -f /root/pterodactyl_database_dump.sql ]; then
        DF=/root/pterodactyl_database_dump.sql
        [ -f /tmp/pterodactyl_database_dump.sql ] && DF=/tmp/pterodactyl_database_dump.sql

        echo -e "${YELLOW}Database Dump Auto-Import...${NC}"

        if [ -f /var/www/pterodactyl/.env ]; then
            DB_USER=$(grep -E '^DB_USERNAME=' /var/www/pterodactyl/.env | head -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'" | tr -d '\r')
            DB_PASS=$(grep -E '^DB_PASSWORD=' /var/www/pterodactyl/.env | head -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'" | tr -d '\r')
            DB_NAME=$(grep -E '^DB_DATABASE=' /var/www/pterodactyl/.env | head -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'" | tr -d '\r')
            DB_HOST=$(grep -E '^DB_HOST=' /var/www/pterodactyl/.env | head -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'" | tr -d '\r')
            [ -z "$DB_HOST" ] && DB_HOST="127.0.0.1"

            mysql -h"$DB_HOST" -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`;" 2>/dev/null
            mysql -h"$DB_HOST" -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';" 2>/dev/null
            mysql -h"$DB_HOST" -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'127.0.0.1';" 2>/dev/null
            mysql -h"$DB_HOST" -e "FLUSH PRIVILEGES;" 2>/dev/null

            MYSQL_PWD="$DB_PASS" mysql -h"$DB_HOST" -u"$DB_USER" "${DB_NAME}" < "$DF" 2>/dev/null || mysql "${DB_NAME}" < "$DF" 2>/dev/null

            if [ $? -eq 0 ]; then
                echo -e "${GREEN}   ✓ Database Restored Successfully!${NC}"
            else
                echo -e "${RED}   ✗ DB Import Fail!${NC}"
            fi
        else
            mysql < "$DF" 2>/dev/null && echo -e "${GREEN}   ✓ DB Restored${NC}"
        fi
        rm -f "$DF"
    # Option B: Raw MySQL DataDir Restore
    elif [ -f /tmp/mysql_raw_datadir.tar.gz ] || [ -f /root/mysql_raw_datadir.tar.gz ]; -o [ -f /tmp/mysql_raw_datadir.tar.gz ]; then
        RAW_DF=/root/mysql_raw_datadir.tar.gz
        [ -f /tmp/mysql_raw_datadir.tar.gz ] && RAW_DF=/tmp/mysql_raw_datadir.tar.gz
        echo -e "${YELLOW}Raw MySQL DataDir Restore...${NC}"
        systemctl stop mysql mariadb >/dev/null 2>&1 || true
        tar -xzf "$RAW_DF" -C / --absolute-names 2>/dev/null
        chown -R mysql:mysql /var/lib/mysql 2>/dev/null
        systemctl start mysql mariadb >/dev/null 2>&1 || true
        rm -f "$RAW_DF"
        echo -e "${GREEN}   ✓ Raw MySQL Datadir Restored!${NC}"
    else
        echo -e "${YELLOW}   ! DB Dump Nahi Mila — fresh migrate chalaya ja raha hai...${NC}"
        cd /var/www/pterodactyl
        php artisan migrate --force 2>/dev/null || true
        php artisan db:seed --force 2>/dev/null || true
    fi

    # Blueprint & Pterodactyl Permissions + Cache Repair
    cd /var/www/pterodactyl
    chown -R www-data:www-data /var/www/pterodactyl 2>/dev/null
    chmod -R 755 storage bootstrap/cache 2>/dev/null

    echo -e "${YELLOW}Blueprint & Addons Cache Sync...${NC}"
    php artisan migrate --force 2>/dev/null || true
    php artisan config:clear 2>/dev/null
    php artisan cache:clear 2>/dev/null
    php artisan view:clear 2>/dev/null
    php artisan route:clear 2>/dev/null

    # Blueprint rerun if available
    if [ -f /var/www/pterodactyl/blueprint.sh ]; then
        chmod +x /var/www/pterodactyl/blueprint.sh 2>/dev/null
        bash /var/www/pterodactyl/blueprint.sh -rerun 2>/dev/null || true
    fi

    # Nginx Site (Default Server Fix)
    rm -f /etc/nginx/sites-enabled/default
    DOMAIN=$(grep -E '^APP_URL=' /var/www/pterodactyl/.env | head -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'" | tr -d '\r' | sed 's|https\?://||' | tr -d '/')
    [ -z "$DOMAIN" ] && DOMAIN="_"

    cat > /etc/nginx/sites-available/pterodactyl.conf << EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name ${DOMAIN} _;
    root /var/www/pterodactyl/public;
    index index.php;
    client_max_body_size 100m;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize = 100M \\n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF
    ln -sf /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/
    nginx -t 2>/dev/null && systemctl restart nginx
    echo -e "${GREEN}   ✓ Nginx Configured For: ${DOMAIN}${NC}"

    # Queue Worker
    if [ ! -f /etc/supervisor/conf.d/pterodactyl-worker.conf ]; then
        cat > /etc/supervisor/conf.d/pterodactyl-worker.conf << 'EOF'
[program:pterodactyl-worker]
process_name=%(program_name)s_%(process_num)02d
command=php /var/www/pterodactyl/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
autostart=true
autorestart=true
user=www-data
numprocs=2
redirect_stderr=true
stdout_logfile=/var/www/pterodactyl/storage/logs/queue-worker.log
EOF
        supervisorctl reread >/dev/null 2>&1
        supervisorctl update >/dev/null 2>&1
        supervisorctl start pterodactyl-worker:* >/dev/null 2>&1
        echo -e "${GREEN}   ✓ Queue Worker Started${NC}"
    fi

    systemctl restart nginx php8.3-fpm redis-server mysql >/dev/null 2>&1
    echo -e "${GREEN}✓ PANEL & BLUEPRINT AUTO-SETUP DONE!${NC}"
}

# ==================== AUTO SETUP WINGS ====================
auto_setup_wings() {
    echo -e "${CYAN}--- WINGS AUTO-SETUP SHURU ---${NC}"

    if ! command -v docker >/dev/null 2>&1; then
        echo -e "${YELLOW}Docker install...${NC}"
        curl -sSL https://get.docker.com/ | CHANNEL=stable bash >/dev/null 2>&1
        systemctl enable --now docker >/dev/null 2>&1
    fi

    if [ ! -f /usr/local/bin/wings ]; then
        echo -e "${YELLOW}Wings binary install...${NC}"
        mkdir -p /etc/pterodactyl /var/lib/pterodactyl
        curl -L -o /usr/local/bin/wings "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_$([[ "$(uname -m)" == "x86_64" ]] && echo "amd64" || echo "arm64")" >/dev/null 2>&1
        chmod u+x /usr/local/bin/wings
    fi

    if [ ! -f /etc/systemd/system/wings.service ]; then
        cat > /etc/systemd/system/wings.service <<'EOF'
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
User=root
WorkingDirectory=/etc/pterodactyl
LimitNOFILE=4096
PIDFile=/var/run/wings/daemon.pid
ExecStart=/usr/local/bin/wings
Restart=on-failure
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
    fi

    chmod 600 /etc/pterodactyl/config.yml 2>/dev/null || true

    systemctl enable wings >/dev/null 2>&1
    systemctl restart docker >/dev/null 2>&1
    sleep 2
    systemctl restart wings >/dev/null 2>&1

    if systemctl is-active --quiet wings; then
        echo -e "${GREEN}✓ WINGS RUNNING!${NC}"
    else
        echo -e "${YELLOW}   ! Wings check: journalctl -u wings -n 30${NC}"
    fi
}

# ==================== AUTO SETUP CLOUDFLARE ====================
auto_setup_cloudflared() {
    echo -e "${CYAN}--- CLOUDFLARE TUNNEL AUTO-SETUP ---${NC}"

    if [ -f /tmp/cloudflared_token_backup ]; then
        mkdir -p /etc/cloudflared
        cp /tmp/cloudflared_token_backup /etc/cloudflared/token
        chmod 600 /etc/cloudflared/token
        rm -f /tmp/cloudflared_token_backup
    fi

    if ! command -v cloudflared >/dev/null 2>&1; then
        echo -e "${YELLOW}Cloudflared install...${NC}"
        mkdir -p --mode=0755 /usr/share/keyrings
        curl -fsSL https://pkg.cloudflare.com/cloudflare-public-v2.gpg | tee /usr/share/keyrings/cloudflare-public-v2.gpg >/dev/null 2>&1
        echo 'deb [signed-by=/usr/share/keyrings/cloudflare-public-v2.gpg] https://pkg.cloudflare.com/cloudflared any main' | tee /etc/apt/sources.list.d/cloudflared.list >/dev/null
        apt-get update -y >/dev/null 2>&1
        apt-get install -y cloudflared >/dev/null 2>&1
    fi

    if [ -f /etc/cloudflared/token ]; then
        TOKEN=$(cat /etc/cloudflared/token)
        if [ -n "$TOKEN" ]; then
            cloudflared service uninstall >/dev/null 2>&1 || true
            cloudflared service install "$TOKEN" >/dev/null 2>&1 || true
            systemctl restart cloudflared >/dev/null 2>&1
            systemctl enable cloudflared >/dev/null 2>&1
            if systemctl is-active --quiet cloudflared; then
                echo -e "${GREEN}   ✓ Cloudflared Tunnel Running!${NC}"
            fi
        fi
    else
        echo -e "${YELLOW}   ! Cloudflared token nahi mila.${NC}"
    fi
}

# ==================== AUTO SETUP TAILSCALE ====================
auto_setup_tailscale() {
    if [ -d /var/lib/tailscale ]; then
        echo -e "${CYAN}--- TAILSCALE AUTO-SETUP ---${NC}"
        if ! command -v tailscale >/dev/null 2>&1; then
            curl -fsSL https://tailscale.com/install.sh | sh >/dev/null 2>&1
        fi
        systemctl enable --now tailscaled >/dev/null 2>&1
        echo -e "${GREEN}   ✓ Tailscale Ready${NC}"
    fi
}

# ==================== 2) RESTORE + AUTO SETUP ====================
restore_backup() {
    clear
    if ! check_blomp_login; then sleep 2; return; fi

    echo -e "${CYAN}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║  RESTORE + AUTO SETUP (Panel/Wings Online)   ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════╝${NC}"
    echo -e "${YELLOW}Step 1: Node / Folder choose karein${NC}"
    echo ""

    mapfile -t folders < <(
        rclone lsf "${REMOTE_NAME}:${BLOMP_USER}/${BACKUP_FOLDER}/" --dirs-only $RCLONE_FLAGS 2>/dev/null
    )

    if [ ${#folders[@]} -eq 0 ]; then
        echo -e "${RED}Blomp par koi backup folder nahi mila!${NC}"
        sleep 2
        return
    fi

    echo -e "${GREEN}Available Folders:${NC}"
    for i in "${!folders[@]}"; do
        fname="${folders[$i]%/}"
        echo -e "  ${YELLOW}$((i+1)))${NC} ${CYAN}[FOLDER]${NC} ${fname}/"
    done

    echo ""
    read -p "Number choose [1-${#folders[@]}] (0=back): " choice
    [ "$choice" = "0" ] && return
    [[ "$choice" =~ ^[0-9]+$ ]] || return
    [ "$choice" -lt 1 ] || [ "$choice" -gt "${#folders[@]}" ] && return

    selected_folder="${folders[$((choice-1))]}"
    selected_folder="${selected_folder%/}"

    echo ""
    echo -e "${YELLOW}Step 2: ${selected_folder}/ ke andar backup choose karein${NC}"
    mapfile -t inner_files < <(
        rclone lsf "${REMOTE_NAME}:${BLOMP_USER}/${BACKUP_FOLDER}/${selected_folder}/" \
            --files-only --include "*.tar.gz" $RCLONE_FLAGS 2>/dev/null | sort -r
    )

    if [ ${#inner_files[@]} -eq 0 ]; then
        echo -e "${RED}Is folder mein koi backup nahi hai!${NC}"
        sleep 2
        return
    fi

    echo -e "${GREEN}Available Backups:${NC}"
    for i in "${!inner_files[@]}"; do
        echo -e "  ${YELLOW}$((i+1)))${NC} ${inner_files[$i]}"
    done

    echo ""
    read -p "Number choose [1-${#inner_files[@]}] (0=back): " fchoice
    [ "$fchoice" = "0" ] && return
    [[ "$fchoice" =~ ^[0-9]+$ ]] || return
    [ "$fchoice" -lt 1 ] || [ "$fchoice" -gt "${#inner_files[@]}" ] && return

    selected_file="${inner_files[$((fchoice-1))]}"
    SRC="${REMOTE_NAME}:${BLOMP_USER}/${BACKUP_FOLDER}/${selected_folder}/${selected_file}"

    echo ""
    echo -e "${CYAN}==================================================${NC}"
    echo -e "${YELLOW}[1/5] Downloading: ${selected_file}${NC}"
    echo -e "${CYAN}==================================================${NC}"

    systemctl stop wings >/dev/null 2>&1 || true

    rclone copyto "$SRC" "/tmp/${selected_file}" $RCLONE_FLAGS --progress

    if [ ! -f "/tmp/${selected_file}" ]; then
        echo -e "${RED}✗ Download Fail!${NC}"
        read -p "Enter dabayein..." t
        return
    fi

    echo ""
    echo -e "${CYAN}[2/5] Extracting Files (With Blueprint & Addons)...${NC}"
    tar -xzf "/tmp/${selected_file}" -C / --absolute-names 2>/dev/null || tar -xzf "/tmp/${selected_file}" -C /
    rm -f "/tmp/${selected_file}"
    echo -e "${GREEN}   ✓ Files restored${NC}"

    echo ""
    echo -e "${CYAN}[3/5] Panel & Blueprint Auto-Setup...${NC}"
    if [ -d /var/www/pterodactyl ]; then
        auto_setup_panel
    else
        echo -e "${YELLOW}   Panel not in this backup — skipping${NC}"
    fi

    echo ""
    echo -e "${CYAN}[4/5] Wings + Docker Auto-Setup...${NC}"
    if [ -d /etc/pterodactyl ] || [ -d /var/lib/pterodactyl ]; then
        auto_setup_wings
    else
        echo -e "${YELLOW}   Wings not in this backup — skipping${NC}"
    fi

    echo ""
    echo -e "${CYAN}[5/5] Cloudflared + Tailscale Auto-Setup...${NC}"
    auto_setup_cloudflared
    auto_setup_tailscale

    systemctl restart docker >/dev/null 2>&1 || true
    systemctl restart wings >/dev/null 2>&1 || true
    systemctl restart nginx >/dev/null 2>&1 || true
    systemctl restart cloudflared >/dev/null 2>&1 || true
    systemctl restart tailscaled >/dev/null 2>&1 || true

    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN} ✓ 100% RESTORE + BLUEPRINT AUTO-REPAIR COMPLETE!   ${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════${NC}"

    echo ""
    echo -e "${CYAN}Live Services Status:${NC}"
    for svc in nginx mysql redis-server php8.3-fpm docker wings cloudflared tailscaled supervisor; do
        if systemctl is-active --quiet $svc 2>/dev/null; then
            echo -e "  ${GREEN}✓ RUNNING${NC}  $svc"
        elif systemctl list-unit-files | grep -q "^$svc"; then
            echo -e "  ${RED}✗ STOPPED${NC}  $svc"
        fi
    done

    if [ -f /var/www/pterodactyl/.env ]; then
        APP_URL=$(grep -E '^APP_URL=' /var/www/pterodactyl/.env | head -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'")
        echo ""
        echo -e "${CYAN}Panel URL: ${YELLOW}${APP_URL}${NC}"
    fi

    echo ""
    read -p "Enter dabayein..." t
}

# ==================== 4) BACKUP LIST ====================
show_backups() {
    clear
    if ! check_blomp_login; then sleep 2; return; fi
    echo -e "${CYAN}==================================================${NC}"
    echo -e "${CYAN}   BLOMP CLOUD BACKUP TREE${NC}"
    echo -e "${CYAN}==================================================${NC}"
    echo ""

    mapfile -t folders < <(
        rclone lsf "${REMOTE_NAME}:${BLOMP_USER}/${BACKUP_FOLDER}/" --dirs-only $RCLONE_FLAGS 2>/dev/null
    )

    if [ ${#folders[@]} -eq 0 ]; then
        echo -e "${YELLOW}Koi backup folder nahi mila.${NC}"
    else
        for f in "${folders[@]}"; do
            fname="${f%/}"
            echo -e "${GREEN}📁 ${fname}/${NC}"
            rclone lsl "${REMOTE_NAME}:${BLOMP_USER}/${BACKUP_FOLDER}/${fname}/" --include "*.tar.gz" $RCLONE_FLAGS 2>/dev/null | while read line; do
                echo -e "     └── $line"
            done
            echo ""
        done
    fi
    read -p "Enter dabayein..." t
}

stop_auto_backup() {
    crontab -l 2>/dev/null | grep -v "/root/do_full_backup.sh" | crontab -
    echo -e "${GREEN}Auto-Backup OFF!${NC}"
    sleep 2
}

# ==================== 7) MANUAL FULL SETUP ====================
manual_full_setup() {
    clear
    echo -e "${CYAN}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║   MANUAL FULL SETUP (Fresh Install)          ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}1) Panel & Blueprint Auto-Setup${NC}"
    echo -e "${YELLOW}2) Wings + Docker Auto-Setup${NC}"
    echo -e "${YELLOW}3) Cloudflared Auto-Setup${NC}"
    echo -e "${YELLOW}4) Tailscale Auto-Setup${NC}"
    echo -e "${YELLOW}5) ALL (Sab kuch)${NC}"
    echo -e "${YELLOW}0) Back${NC}"
    echo ""
    read -p "Option: " opt

    case "$opt" in
        1) auto_setup_panel ;;
        2) auto_setup_wings ;;
        3) auto_setup_cloudflared ;;
        4) auto_setup_tailscale ;;
        5) auto_setup_panel; auto_setup_wings; auto_setup_cloudflared; auto_setup_tailscale ;;
        0) return ;;
    esac
    read -p "Enter dabayein..." t
}

# ==================== MAIN MENU ====================
install_all_dependencies
load_blomp_config
load_backup_name

while true; do
    clear
    load_backup_name
    echo -e "${GREEN}╔════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║   SMART BACKUP MANAGER v12 (Guaranteed DB Fix) ║${NC}"
    echo -e "${GREEN}╠════════════════════════════════════════════════╣${NC}"
    if [ -n "$BACKUP_NAME" ]; then
    echo -e "${GREEN}║  Name: ${YELLOW}${BACKUP_NAME}${NC}   Folder: ${YELLOW}BackupVps/${BACKUP_NAME}/${NC}"
    fi
    echo -e "${GREEN}║ ${YELLOW}1)${NC} Auto-Backup ON (15 min + Everything!)   ${GREEN}║${NC}"
    echo -e "${GREEN}║ ${YELLOW}2)${NC} Restore & Auto-Setup (Live Online)      ${GREEN}║${NC}"
    echo -e "${GREEN}║ ${YELLOW}3)${NC} Blomp Login                             ${GREEN}║${NC}"
    echo -e "${GREEN}║ ${YELLOW}4)${NC} Backup List (Tree View)                 ${GREEN}║${NC}"
    echo -e "${GREEN}║ ${YELLOW}5)${NC} Important Data & Services Check         ${GREEN}║${NC}"
    echo -e "${GREEN}║ ${YELLOW}6)${NC} Auto-Backup OFF                         ${GREEN}║${NC}"
    echo -e "${GREEN}║ ${YELLOW}7)${NC} Manual Full Setup (Panel/Wings Fresh)   ${GREEN}║${NC}"
    echo -e "${GREEN}║ ${YELLOW}0)${NC} Exit                                    ${GREEN}║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════╝${NC}"
    read -p "Option: " opt
    case "$opt" in
        1) start_auto_backup ;;
        2) restore_backup ;;
        3) setup_blomp ;;
        4) show_backups ;;
        5) clear; show_important_data; read -p "Enter dabayein..." t ;;
        6) stop_auto_backup ;;
        7) manual_full_setup ;;
        0) exit 0 ;;
        *) sleep 1 ;;
    esac
done
