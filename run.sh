#!/bin/bash

GREEN='\033[0;32m'
CYAN='\033[0;36m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

REMOTE_NAME="blomp_cloud"
CONFIG_FILE="/root/.fakecloud_blomp"
NAME_FILE="/root/.fakecloud_backup_name"
BACKUP_FOLDER="Backup vps"
KEEP_COUNT=1  # Sirf 1 latest backup rahega

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
    echo -e "${YELLOW}Cron scheduler install ho raha hai...${NC}"
    apt-get update -y >/dev/null 2>&1
    apt-get install -y cron >/dev/null 2>&1
    systemctl enable --now cron >/dev/null 2>&1 || true
}

ensure_rclone() {
    if command -v rclone >/dev/null 2>&1; then return 0; fi
    echo -e "${YELLOW}rclone install ho raha hai...${NC}"
    apt-get update -y >/dev/null 2>&1
    apt-get install -y rclone >/dev/null 2>&1 || curl -fsSL https://rclone.org/install.sh | bash >/dev/null 2>&1
    hash -r 2>/dev/null || true
    export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"
}

ensure_pigz() {
    if ! command -v pigz >/dev/null 2>&1; then
        apt-get install -y pigz >/dev/null 2>&1 || true
    fi
}

install_all_dependencies() {
    clear
    echo -e "${YELLOW}>>> Zaroori Tools Check & Fast Setup Ho Raha Hai...<<<${NC}"
    ensure_cron
    ensure_rclone
    ensure_pigz
    apt-get install -y curl tar gzip unzip mariadb-client coreutils ca-certificates >/dev/null 2>&1 || true
    echo -e "${GREEN}✓ All tools 100% ready!${NC}"
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
    rclone config delete "$REMOTE_NAME" >/dev/null 2>&1 || true

    rclone config create "$REMOTE_NAME" swift \
        env_auth=false \
        user="$blomp_user" \
        key="$blomp_pass" \
        auth="https://authenticate.ain.net" \
        tenant="storage" \
        auth_version="2" \
        endpoint_type="public" \
        use_segments_container=false \
        leave_parts_on_error=true \
        >/tmp/blomp_config.log 2>&1

    unset blomp_pass

    cat > "$CONFIG_FILE" <<EOF
BLOMP_USER='$blomp_user'
EOF
    chmod 600 "$CONFIG_FILE"

    rclone mkdir "${REMOTE_NAME}:${blomp_user}/${BACKUP_FOLDER}" >/dev/null 2>&1

    if rclone lsf "${REMOTE_NAME}:${blomp_user}" >/tmp/blomp_test.log 2>&1; then
        echo -e "${GREEN}✓ Blomp Login Successful!${NC}"
        echo -e "Cloud Folder: ${CYAN}${blomp_user}/${BACKUP_FOLDER}/${NC}"
    else
        echo -e "${RED}✗ Login fail:${NC}"
        cat /tmp/blomp_test.log 2>/dev/null
        rm -f "$CONFIG_FILE"
    fi
    read -p "Enter dabayein..." t
}

check_blomp_login() {
    load_blomp_config
    if ! rclone listremotes 2>/dev/null | grep -q "^${REMOTE_NAME}:$"; then
        setup_blomp
        load_blomp_config
    fi
    [ -z "$BLOMP_USER" ] && return 1
    return 0
}

# ==================== CHECK IMPORTANT DATA ====================
show_important_data() {
    echo -e "${CYAN}--- Important System & App Paths Check ---${NC}"

    PATHS=(
        "/var/lib/pterodactyl"
        "/etc/pterodactyl"
        "/var/www/pterodactyl"
        "/var/lib/tailscale"
        "/etc/cloudflared"
        "/root/.cloudflared"
        "/etc/letsencrypt"
        "/etc/nginx"
        "/etc/apache2"
        "/root"
        "/home"
        "/etc/systemd/system"
        "/usr/local/bin"
        "/var/spool/cron"
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

    echo -e "${YELLOW}Purane backups check aur cleanup ho raha hai...${NC}"

    mapfile -t all_files < <(
        rclone lsf "$REMOTE_DIR" --files-only --include "*.tar.gz" 2>/dev/null | sort -r
    )

    local count=${#all_files[@]}

    if [ "$count" -le "$KEEP_COUNT" ]; then
        echo -e "${GREEN}Sirf $count backup hain — delete zaroorat nahi.${NC}"
        return 0
    fi

    local deleted=0
    for i in "${!all_files[@]}"; do
        f="${all_files[$i]}"
        if [ "$i" -lt "$KEEP_COUNT" ]; then
            continue
        fi
        if [ "$f" = "$KEEP_FILE" ]; then
            continue
        fi
        echo -e "${RED}DELETE OLD:${NC} $f"
        echo "DELETE: $f" >> "$LOG"
        rclone deletefile "${REMOTE_DIR}/${f}" 2>>"$LOG" || \
        rclone delete "${REMOTE_DIR}/${f}" 2>>"$LOG" || true
        deleted=$((deleted+1))
    done

    echo -e "${GREEN}✓ Cleanup done — deleted old backups, kept latest!${NC}"
}

# ==================== FAST SMART BACKUP (FIXED FOR BLOMP) ====================
do_smart_vps_backup() {
    load_blomp_config
    load_backup_name

    if [ -z "$BACKUP_NAME" ] || [ -z "$BLOMP_USER" ]; then
        echo -e "${RED}Pehle Blomp Login + Backup Name set karein.${NC}"
        return 1
    fi

    local TIME FILE LOG DEST_DIR TEMP_FILE SUBFOLDER
    TIME=$(date +%Y-%m-%d_%H-%M-%S)
    FILE="${BACKUP_NAME}_${TIME}.tar.gz"
    TEMP_FILE="/tmp/${FILE}"
    SUBFOLDER="${BACKUP_NAME}"
    DEST_DIR="${REMOTE_NAME}:${BLOMP_USER}/${BACKUP_FOLDER}/${SUBFOLDER}"
    LOG="/var/log/fakecloud-backup.log"

    echo "======================================" >> "$LOG"
    echo "SMART BACKUP START $(date) file=$FILE" >> "$LOG"

    # Auto Database Dump
    DB_DUMP_FILE=""
    if command -v mysqldump >/dev/null 2>&1 && (systemctl is-active --quiet mariadb || systemctl is-active --quiet mysql); then
        echo -e "${YELLOW}Database ka auto-dump liya ja raha hai...${NC}"
        DB_DUMP_FILE="/root/pterodactyl_database_dump.sql"
        mysqldump --all-databases --single-transaction --quick > "$DB_DUMP_FILE" 2>>"$LOG" || true
    fi

    # Auto Find Active Important Paths
    TARGET_PATHS=()
    POSSIBLE_PATHS=(
        "/var/lib/pterodactyl"
        "/etc/pterodactyl"
        "/var/www/pterodactyl"
        "/var/lib/tailscale"
        "/etc/cloudflared"
        "/root/.cloudflared"
        "/etc/letsencrypt"
        "/etc/nginx"
        "/etc/apache2"
        "/root"
        "/home"
        "/etc/systemd/system"
        "/usr/local/bin"
        "/var/spool/cron"
    )

    [ -n "$DB_DUMP_FILE" ] && [ -f "$DB_DUMP_FILE" ] && TARGET_PATHS+=("$DB_DUMP_FILE")

    for p in "${POSSIBLE_PATHS[@]}"; do
        [ -e "$p" ] && TARGET_PATHS+=("$p")
    done

    if [ ${#TARGET_PATHS[@]} -eq 0 ]; then
        echo -e "${RED}✗ Backup karne ke liye koi data nahi mila!${NC}"
        rm -f "$DB_DUMP_FILE" 2>/dev/null
        return 1
    fi

    # Create Cloud Folder
    rclone mkdir "$DEST_DIR" >/dev/null 2>&1

    echo -e "${CYAN}⚡ SUPER FAST SMART BACKUP & UPLOAD SHURU...${NC}"
    echo -e "Cloud Path:       ${GREEN}${BACKUP_FOLDER}/${SUBFOLDER}/${NC}"
    echo -e "Backup File:      ${GREEN}${FILE}${NC}"
    echo "--------------------------------------------------------"

    systemctl stop wings >/dev/null 2>&1 || true

    # Fast Multi-Core Compression
    if command -v pigz >/dev/null 2>&1; then
        tar -cf - \
            --absolute-names \
            --ignore-failed-read \
            --warning=no-file-changed \
            --exclude="/root/*.tar.gz" \
            --exclude="/root/.cache" \
            --exclude="/var/lib/pterodactyl/volumes/*/.git" \
            "${TARGET_PATHS[@]}" 2>>"$LOG" \
        | pigz -1 -c > "$TEMP_FILE" 2>>"$LOG"
    else
        tar -czf "$TEMP_FILE" \
            --absolute-names \
            --ignore-failed-read \
            --warning=no-file-changed \
            --exclude="/root/*.tar.gz" \
            --exclude="/root/.cache" \
            --exclude="/var/lib/pterodactyl/volumes/*/.git" \
            "${TARGET_PATHS[@]}" 2>>"$LOG"
    fi

    rm -f "$DB_DUMP_FILE" 2>/dev/null
    systemctl start wings >/dev/null 2>&1 || true

    # Check Temp Archive Size
    local BYTES HUMAN
    BYTES=$(stat -c%s "$TEMP_FILE" 2>/dev/null || echo 0)
    HUMAN=$(du -h "$TEMP_FILE" | awk '{print $1}')
    echo -e "${CYAN}Smart Backup Size: ${HUMAN}${NC}"

    echo -e "${YELLOW}Blomp Cloud par Upload Ho Raha Hai...${NC}"

    # Blomp Compatible Copy
    rclone copy "$TEMP_FILE" "$DEST_DIR/" \
        --progress \
        --stats 1s \
        --timeout 60m \
        2>>"$LOG"

    local UPLOAD_RC=$?

    # Immediately delete local temp file
    rm -f "$TEMP_FILE"

    echo "--------------------------------------------------------"
    if [ $UPLOAD_RC -eq 0 ]; then
        echo -e "${GREEN}✓ SMART BACKUP UPLOADED: ${SUBFOLDER}/${FILE}${NC}"
        echo "SUCCESS $FILE" >> "$LOG"
        # Purane backups cleanup
        cleanup_old_backups "$DEST_DIR" "$FILE" "$LOG"
        return 0
    else
        echo -e "${RED}✗ Upload Failed. Check Log: $LOG${NC}"
        echo "FAIL UPLOAD $FILE" >> "$LOG"
        return 1
    fi
}

create_auto_worker() {
    load_blomp_config
    load_backup_name

    cat > /root/do_full_backup.sh <<EOF
#!/bin/bash
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

REMOTE_NAME="${REMOTE_NAME}"
BLOMP_USER="${BLOMP_USER}"
BACKUP_FOLDER="${BACKUP_FOLDER}"
BACKUP_NAME="${BACKUP_NAME}"
KEEP_COUNT=${KEEP_COUNT}
LOG="/var/log/fakecloud-backup.log"

TIME=\$(date +%Y-%m-%d_%H-%M-%S)
FILE="\${BACKUP_NAME}_\${TIME}.tar.gz"
TEMP_FILE="/tmp/\${FILE}"
SUBFOLDER="\${BACKUP_NAME}"
DEST_DIR="\${REMOTE_NAME}:\${BLOMP_USER}/\${BACKUP_FOLDER}/\${SUBFOLDER}"

echo "==== \$(date) AUTO BACKUP \$FILE ====" >> "\$LOG"

DB_DUMP=""
if command -v mysqldump >/dev/null 2>&1 && (systemctl is-active --quiet mariadb || systemctl is-active --quiet mysql); then
    DB_DUMP="/root/pterodactyl_database_dump.sql"
    mysqldump --all-databases --single-transaction --quick > "\$DB_DUMP" 2>>"\$LOG" || true
fi

TARGETS=()
[ -n "\$DB_DUMP" ] && [ -f "\$DB_DUMP" ] && TARGETS+=("\$DB_DUMP")

POSSIBLES=(
    "/var/lib/pterodactyl" "/etc/pterodactyl" "/var/www/pterodactyl"
    "/var/lib/tailscale" "/etc/cloudflared" "/root/.cloudflared"
    "/etc/letsencrypt" "/etc/nginx" "/etc/apache2"
    "/root" "/home" "/etc/systemd/system" "/usr/local/bin" "/var/spool/cron"
)

for p in "\${POSSIBLES[@]}"; do
    [ -e "\$p" ] && TARGETS+=("\$p")
done

rclone mkdir "\$DEST_DIR" >/dev/null 2>&1

systemctl stop wings >/dev/null 2>&1 || true

if command -v pigz >/dev/null 2>&1; then
    tar -cf - --absolute-names --ignore-failed-read --warning=no-file-changed \\
        --exclude="/root/*.tar.gz" --exclude="/root/.cache" \\
        "\${TARGETS[@]}" 2>>"\$LOG" | pigz -1 -c > "\$TEMP_FILE" 2>>"\$LOG"
else
    tar -czf "\$TEMP_FILE" --absolute-names --ignore-failed-read --warning=no-file-changed \\
        --exclude="/root/*.tar.gz" --exclude="/root/.cache" \\
        "\${TARGETS[@]}" 2>>"\$LOG"
fi

rm -f "\$DB_DUMP" 2>/dev/null
systemctl start wings >/dev/null 2>&1 || true

rclone copy "\$TEMP_FILE" "\$DEST_DIR/" --timeout 60m >>"\$LOG" 2>&1
RC=\$?

rm -f "\$TEMP_FILE"

if [ \$RC -eq 0 ]; then
    echo "SUCCESS \$FILE" >> "\$LOG"
    mapfile -t all_files < <(rclone lsf "\$DEST_DIR" --files-only --include "*.tar.gz" 2>/dev/null | sort -r)
    for i in "\${!all_files[@]}"; do
        f="\${all_files[\$i]}"
        if [ "\$i" -lt "\$KEEP_COUNT" ]; then continue; fi
        if [ "\$f" = "\$FILE" ]; then continue; fi
        rclone deletefile "\${DEST_DIR}/\${f}" 2>>"\$LOG" || true
        echo "DELETED OLD: \$f" >> "\$LOG"
    done
fi

echo "Backup end rc=\$RC" >> "\$LOG"
exit \$RC
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
    echo -e "Cloud Folder: ${YELLOW}Backup vps/[NAME]/${NC}"
    echo -e "Rule:         ${GREEN}Naya backup → Purana auto delete${NC}"
    echo -e "Includes:     ${GREEN}Panel, Wings, DB, Tailscale, Cloudflare, SSL${NC}"
    echo ""

    load_backup_name
    if [ -n "$BACKUP_NAME" ]; then
        echo -e "Current Name: ${GREEN}${BACKUP_NAME}${NC}"
        read -p "Naya Name set karein? Enter=wahi rehne do, ya naya likho: " newname
        if [ -n "$newname" ]; then
            save_backup_name "$newname"
        fi
    else
        echo -e "${YELLOW}Backup ka NAAM likho (example: panel / node1 / node2)${NC}"
        read -p "Backup Name: " newname
        [ -z "$newname" ] && newname="panel"
        save_backup_name "$newname"
    fi

    load_backup_name
    echo ""
    echo -e "${GREEN}Backup Name Lock: ${BACKUP_NAME}${NC}"
    echo -e "Cloud Path:      ${CYAN}Backup vps/${BACKUP_NAME}/${BACKUP_NAME}_TIME.tar.gz${NC}"
    echo ""

    create_auto_worker

    crontab -l 2>/dev/null | grep -v "/root/do_full_backup.sh" > /tmp/fcron || true
    echo "*/15 * * * * /bin/bash /root/do_full_backup.sh >/dev/null 2>&1" >> /tmp/fcron
    crontab /tmp/fcron
    rm -f /tmp/fcron

    echo -e "${GREEN}✓ Auto-Backup Scheduler Active (Har 15 Min) — Name: ${BACKUP_NAME}${NC}"
    echo -e "${YELLOW}Pehla Smart Backup abhi shuru ho raha hai...${NC}"
    echo ""

    do_smart_vps_backup
    read -p "Enter dabayein..." t
}

# ==================== 2) SMART RESTORE ====================
restore_backup() {
    clear
    if ! check_blomp_login; then sleep 2; return; fi

    echo -e "${CYAN}=== SMART RESTORE FROM BLOMP ===${NC}"
    echo -e "${YELLOW}Step 1: Node folder choose karein${NC}"
    echo ""

    mapfile -t folders < <(
        rclone lsf "${REMOTE_NAME}:${BLOMP_USER}/${BACKUP_FOLDER}/" --dirs-only 2>/dev/null
    )

    mapfile -t flat_files < <(
        rclone lsf "${REMOTE_NAME}:${BLOMP_USER}/${BACKUP_FOLDER}/" --files-only --include "*.tar.gz" 2>/dev/null | sort -r
    )

    if [ ${#folders[@]} -eq 0 ] && [ ${#flat_files[@]} -eq 0 ]; then
        echo -e "${RED}Blomp par koi backup nahi mila!${NC}"
        sleep 2
        return
    fi

    OPTIONS=()
    OPTION_TYPES=()

    if [ ${#folders[@]} -gt 0 ]; then
        echo -e "${GREEN}Available Nodes / Folders:${NC}"
        for i in "${!folders[@]}"; do
            fname="${folders[$i]%/}"
            OPTIONS+=("$fname")
            OPTION_TYPES+=("folder")
            echo -e "  ${YELLOW}$((${#OPTIONS[@]}))${NC} ${CYAN}[FOLDER]${NC} ${fname}/"
        done
    fi

    if [ ${#flat_files[@]} -gt 0 ]; then
        echo -e "${GREEN}Legacy Backups (Old Structure):${NC}"
        for i in "${!flat_files[@]}"; do
            fname="${flat_files[$i]}"
            OPTIONS+=("$fname")
            OPTION_TYPES+=("file")
            echo -e "  ${YELLOW}$((${#OPTIONS[@]}))${NC} [FILE]   ${fname}"
        done
    fi

    echo ""
    read -p "Number choose [1-${#OPTIONS[@]}] (0=back): " choice
    [ "$choice" = "0" ] && return
    [[ "$choice" =~ ^[0-9]+$ ]] || return
    [ "$choice" -lt 1 ] || [ "$choice" -gt "${#OPTIONS[@]}" ] && return

    selected="${OPTIONS[$((choice-1))]}"
    seltype="${OPTION_TYPES[$((choice-1))]}"

    local SRC=""
    local TEMP_RESTORE="/tmp/restore_temp.tar.gz"

    if [ "$seltype" = "folder" ]; then
        echo ""
        echo -e "${YELLOW}Step 2: ${selected}/ ke andar backup choose karein${NC}"
        mapfile -t inner_files < <(
            rclone lsf "${REMOTE_NAME}:${BLOMP_USER}/${BACKUP_FOLDER}/${selected}/" \
                --files-only --include "*.tar.gz" 2>/dev/null | sort -r
        )

        if [ ${#inner_files[@]} -eq 0 ]; then
            echo -e "${RED}Is folder mein koi backup nahi hai!${NC}"
            sleep 2
            return
        fi

        echo -e "${GREEN}Available Backups in ${selected}/:${NC}"
        for i in "${!inner_files[@]}"; do
            echo -e "  ${YELLOW}$((i+1)))${NC} ${inner_files[$i]}"
        done
        echo ""
        read -p "Number choose [1-${#inner_files[@]}] (0=back): " fchoice
        [ "$fchoice" = "0" ] && return
        [[ "$fchoice" =~ ^[0-9]+$ ]] || return
        [ "$fchoice" -lt 1 ] || [ "$fchoice" -gt "${#inner_files[@]}" ] && return

        selected_file="${inner_files[$((fchoice-1))]}"
        SRC="${REMOTE_NAME}:${BLOMP_USER}/${BACKUP_FOLDER}/${selected}/${selected_file}"
        echo -e "${GREEN}Selected: ${selected}/${selected_file}${NC}"
    else
        SRC="${REMOTE_NAME}:${BLOMP_USER}/${BACKUP_FOLDER}/${selected}"
        echo -e "${GREEN}Selected (legacy): ${selected}${NC}"
    fi

    echo ""
    echo -e "${YELLOW}Blomp Cloud se Download aur Restore Ho Raha Hai...${NC}"

    systemctl stop wings >/dev/null 2>&1 || true

    rclone copy "$SRC" /tmp/ --progress

    # Find the downloaded file in /tmp
    DOWNLOADED_FILE="/tmp/$(basename "$SRC")"

    if [ -f "$DOWNLOADED_FILE" ]; then
        tar -xzf "$DOWNLOADED_FILE" -C / --absolute-names 2>/dev/null || tar -xzf "$DOWNLOADED_FILE" -C /
        rm -f "$DOWNLOADED_FILE"
    else
        echo -e "${RED}✗ Download Fail Ho Gaya!${NC}"
        read -p "Enter dabayein..." t
        return
    fi

    # Auto Import DB
    if [ -f /root/pterodactyl_database_dump.sql ]; then
        echo -e "${YELLOW}Database Dump wapas import ho raha hai...${NC}"
        systemctl start mariadb >/dev/null 2>&1 || systemctl start mysql >/dev/null 2>&1 || true
        mysql < /root/pterodactyl_database_dump.sql 2>/dev/null || true
        rm -f /root/pterodactyl_database_dump.sql
    fi

    chmod 600 /etc/pterodactyl/config.yml 2>/dev/null || true

    # Wings Service Auto Fix
    if [ ! -f /etc/systemd/system/wings.service ] && [ -f /usr/local/bin/wings ]; then
        cat > /etc/systemd/system/wings.service <<'EOF'
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service
Requires=docker.service
[Service]
User=root
WorkingDirectory=/etc/pterodactyl
LimitNOFILE=4096
ExecStart=/usr/local/bin/wings
Restart=on-failure
RestartSec=5s
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
    fi

    systemctl enable --now docker >/dev/null 2>&1 || true
    systemctl restart docker >/dev/null 2>&1 || true
    systemctl restart wings >/dev/null 2>&1 || true
    systemctl restart tailscaled >/dev/null 2>&1 || true
    systemctl restart cloudflared >/dev/null 2>&1 || true
    systemctl restart nginx >/dev/null 2>&1 || true

    echo -e "\n${GREEN}====================================================${NC}"
    echo -e "${GREEN} ✓ SMART RESTORE 100% COMPLETE!                    ${NC}"
    echo -e "${GREEN} ✓ Panel, Wings, DB, Tailscale, Cloudflare Live!  ${NC}"
    echo -e "${GREEN}====================================================${NC}"
    read -p "Enter dabayein..." t
}

# ==================== 4) BACKUP LIST ====================
show_backups() {
    clear
    if ! check_blomp_login; then sleep 2; return; fi
    echo -e "${CYAN}==================================================${NC}"
    echo -e "${CYAN}   BLOMP CLOUD BACKUP TREE: ${BLOMP_USER}/${BACKUP_FOLDER}/${NC}"
    echo -e "${CYAN}==================================================${NC}"
    echo ""

    mapfile -t folders < <(
        rclone lsf "${REMOTE_NAME}:${BLOMP_USER}/${BACKUP_FOLDER}/" --dirs-only 2>/dev/null
    )

    if [ ${#folders[@]} -eq 0 ]; then
        echo -e "${YELLOW}Koi node folder nahi mila.${NC}"
        rclone lsl "${REMOTE_NAME}:${BLOMP_USER}/${BACKUP_FOLDER}/" --include "*.tar.gz" 2>/dev/null
    else
        for f in "${folders[@]}"; do
            fname="${f%/}"
            echo -e "${GREEN}📁 ${fname}/${NC}"
            rclone lsl "${REMOTE_NAME}:${BLOMP_USER}/${BACKUP_FOLDER}/${fname}/" --include "*.tar.gz" 2>/dev/null | while read line; do
                echo -e "     └── $line"
            done
            echo ""
        done
    fi

    echo ""
    read -p "Enter dabayein..." t
}

stop_auto_backup() {
    crontab -l 2>/dev/null | grep -v "/root/do_full_backup.sh" | crontab -
    echo -e "${GREEN}Auto-Backup OFF kar diya gaya.${NC}"
    sleep 2
}

# ==================== MENU ====================
install_all_dependencies
load_blomp_config
load_backup_name

while true; do
    clear
    load_backup_name
    echo -e "${GREEN}╔════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║   SMART BACKUP MANAGER v7 (Blomp Fixed)        ║${NC}"
    echo -e "${GREEN}╠════════════════════════════════════════════════╣${NC}"
    if [ -n "$BACKUP_NAME" ]; then
    echo -e "${GREEN}║  Name: ${YELLOW}${BACKUP_NAME}${NC}   Folder: ${YELLOW}Backup vps/${BACKUP_NAME}/${NC}"
    fi
    echo -e "${GREEN}║ ${YELLOW}1)${NC} Auto-Backup ON (15 min + Custom Name)   ${GREEN}║${NC}"
    echo -e "${GREEN}║ ${YELLOW}2)${NC} Restore (Node → File Select)            ${GREEN}║${NC}"
    echo -e "${GREEN}║ ${YELLOW}3)${NC} Blomp Login                             ${GREEN}║${NC}"
    echo -e "${GREEN}║ ${YELLOW}4)${NC} Backup List (Tree View)                 ${GREEN}║${NC}"
    echo -e "${GREEN}║ ${YELLOW}5)${NC} Important Data Check                    ${GREEN}║${NC}"
    echo -e "${GREEN}║ ${YELLOW}6)${NC} Auto-Backup OFF                         ${GREEN}║${NC}"
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
        0) exit 0 ;;
        *) sleep 1 ;;
    esac
done
