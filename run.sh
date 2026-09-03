#!/bin/bash

GREEN='\033[0;32m'
CYAN='\033[0;36m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

REMOTE_NAME="blomp_cloud"
CONFIG_FILE="/root/.fakecloud_blomp"
BACKUP_FOLDER="FullServerBackup"

# ============================================
# ROOT CHECK
# ============================================
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Ye script ROOT user se run karein.${NC}"
    exit 1
fi

# ============================================
# LOAD SAVED BLOMP ACCOUNT
# ============================================
load_blomp_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    fi
}

# ============================================
# INSTALL REQUIRED TOOLS
# ============================================
install_all_dependencies() {
    clear
    echo -e "${YELLOW}>>> Zaroori Tools Check aur Install Ho Rahe Hain... <<<${NC}"

    apt-get update -y >/dev/null 2>&1

    apt-get install -y \
        curl \
        tar \
        gzip \
        unzip \
        rclone \
        docker.io \
        cron \
        ca-certificates >/dev/null 2>&1

    systemctl enable --now docker >/dev/null 2>&1
    systemctl enable --now cron >/dev/null 2>&1

    # Wings install if missing
    if [ ! -f /usr/local/bin/wings ]; then
        mkdir -p /etc/pterodactyl
        mkdir -p /var/lib/pterodactyl

        echo -e "${YELLOW}Pterodactyl Wings download ho raha hai...${NC}"

        curl -L \
            -o /usr/local/bin/wings \
            "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_amd64" \
            >/dev/null 2>&1

        chmod u+x /usr/local/bin/wings
    fi

    mkdir -p /root/.config/rclone

    echo -e "${GREEN}✓ Sabhi tools ready hain!${NC}"
    sleep 1
}

# ============================================
# 1. BLOMP LOGIN / SETUP
# ============================================
setup_blomp() {
    clear

    echo -e "${CYAN}==========================================${NC}"
    echo -e "${CYAN}           BLOMP CLOUD LOGIN              ${NC}"
    echo -e "${CYAN}==========================================${NC}"
    echo ""

    read -p "Blomp Email: " blomp_user

    read -s -p "Blomp Password: " blomp_pass
    echo ""
    echo ""

    if [ -z "$blomp_user" ] || [ -z "$blomp_pass" ]; then
        echo -e "${RED}Email aur password blank nahi ho sakte.${NC}"
        sleep 2
        return
    fi

    echo -e "${YELLOW}Blomp OpenStack Swift se connect kiya ja raha hai...${NC}"

    # Delete old remote
    rclone config delete "$REMOTE_NAME" >/dev/null 2>&1 || true

    # Create Blomp Swift Remote
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

    # Save account email locally
    cat > "$CONFIG_FILE" <<EOF
BLOMP_USER='$blomp_user'
EOF

    chmod 600 "$CONFIG_FILE"

    echo -e "${YELLOW}Connection test ho raha hai...${NC}"

    # Blomp Swift container is normally account email
    if rclone lsf "${REMOTE_NAME}:${blomp_user}" \
        >/tmp/blomp_test.log 2>&1; then

        echo ""
        echo -e "${GREEN}==========================================${NC}"
        echo -e "${GREEN}✓ SUCCESS: Blomp Cloud Connect Ho Gaya!${NC}"
        echo -e "${GREEN}==========================================${NC}"

        echo ""
        echo -e "${CYAN}Cloud Container:${NC}"
        echo "$blomp_user"

        echo ""
        echo -e "${CYAN}Backup Location:${NC}"
        echo "${blomp_user}/${BACKUP_FOLDER}/"

    else

        echo ""
        echo -e "${RED}==========================================${NC}"
        echo -e "${RED}✗ BLOMP LOGIN / CONNECTION FAILED${NC}"
        echo -e "${RED}==========================================${NC}"

        echo ""
        cat /tmp/blomp_test.log 2>/dev/null

        rclone config delete "$REMOTE_NAME" >/dev/null 2>&1 || true
        rm -f "$CONFIG_FILE"
    fi

    echo ""
    read -p "Enter dabayein Menu ke liye..." temp
}

# ============================================
# CHECK BLOMP LOGIN
# ============================================
check_blomp_login() {
    load_blomp_config

    if ! rclone listremotes 2>/dev/null | grep -q "^${REMOTE_NAME}:$"; then

        echo -e "${YELLOW}Pehle Blomp Login Karna Zaroori Hai!${NC}"

        sleep 1
        setup_blomp

        load_blomp_config
    fi

    if [ -z "$BLOMP_USER" ]; then
        return 1
    fi

    if ! rclone lsf "${REMOTE_NAME}:${BLOMP_USER}" \
        >/dev/null 2>&1; then

        echo -e "${RED}Blomp connection available nahi hai.${NC}"
        return 1
    fi

    return 0
}

# ============================================
# CREATE BACKUP SCRIPT
# ============================================
create_backup_worker() {

    load_blomp_config

    cat > /root/do_full_backup.sh <<EOF
#!/bin/bash

REMOTE_NAME="${REMOTE_NAME}"
BLOMP_USER="${BLOMP_USER}"
BACKUP_FOLDER="${BACKUP_FOLDER}"

TIME=\$(date +%Y-%m-%d_%H-%M-%S)

FILE="FULL_BACKUP_\${TIME}.tar.gz"

LOCAL_FILE="/root/\${FILE}"

LOG="/var/log/fakecloud-backup.log"

echo "======================================" >> "\$LOG"
echo "Backup Started: \$(date)" >> "\$LOG"

# --------------------------------------------
# Create archive
# --------------------------------------------

BACKUP_PATHS=""

if [ -d /var/lib/pterodactyl ]; then
    BACKUP_PATHS="\$BACKUP_PATHS /var/lib/pterodactyl"
fi

if [ -d /etc/pterodactyl ]; then
    BACKUP_PATHS="\$BACKUP_PATHS /etc/pterodactyl"
fi

if [ -d /etc/letsencrypt ]; then
    BACKUP_PATHS="\$BACKUP_PATHS /etc/letsencrypt"
fi

if [ -z "\$BACKUP_PATHS" ]; then
    echo "ERROR: Backup karne ke liye Pterodactyl data nahi mila." >> "\$LOG"
    exit 1
fi

echo "Creating archive..." >> "\$LOG"

tar -czf "\$LOCAL_FILE" \$BACKUP_PATHS 2>> "\$LOG"

if [ \$? -ne 0 ]; then
    echo "ERROR: Archive create nahi hua." >> "\$LOG"
    rm -f "\$LOCAL_FILE"
    exit 1
fi

SIZE=\$(du -h "\$LOCAL_FILE" | cut -f1)

echo "Backup Size: \$SIZE" >> "\$LOG"

# --------------------------------------------
# Upload to Blomp
# --------------------------------------------

echo "Uploading to Blomp..." >> "\$LOG"

rclone copy \
    "\$LOCAL_FILE" \
    "\${REMOTE_NAME}:\${BLOMP_USER}/\${BACKUP_FOLDER}/" \
    --retries 5 \
    --low-level-retries 10 \
    --timeout 10m \
    --contimeout 60s \
    --stats 30s \
    >> "\$LOG" 2>&1

RESULT=\$?

if [ \$RESULT -eq 0 ]; then

    echo "SUCCESS: \${FILE}" >> "\$LOG"

    rm -f "\$LOCAL_FILE"

    exit 0

else

    echo "ERROR: Blomp upload failed." >> "\$LOG"

    echo "Local backup retained: \$LOCAL_FILE" >> "\$LOG"

    exit 1
fi
EOF

    chmod 700 /root/do_full_backup.sh
}

# ============================================
# 2. AUTO BACKUP EVERY 15 MINUTES
# ============================================
start_auto_backup() {

    clear

    if ! check_blomp_login; then
        sleep 2
        return
    fi

    echo -e "${CYAN}==========================================${NC}"
    echo -e "${CYAN}     FULL AUTO BACKUP - EVERY 15 MIN      ${NC}"
    echo -e "${CYAN}==========================================${NC}"
    echo ""

    create_backup_worker

    # Remove old cron entry
    crontab -l 2>/dev/null \
        | grep -v "/root/do_full_backup.sh" \
        > /tmp/fakecloud_cron || true

    echo "*/15 * * * * /root/do_full_backup.sh >/dev/null 2>&1" \
        >> /tmp/fakecloud_cron

    crontab /tmp/fakecloud_cron

    rm -f /tmp/fakecloud_cron

    echo -e "${GREEN}✓ Auto Backup Scheduler Active${NC}"
    echo -e "${GREEN}✓ Backup Interval: Har 15 Minute${NC}"

    echo ""
    echo -e "${YELLOW}Pehla backup abhi create aur upload ho raha hai...${NC}"
    echo ""

    if /root/do_full_backup.sh; then

        echo ""
        echo -e "${GREEN}==========================================${NC}"
        echo -e "${GREEN}✓ BACKUP SUCCESSFULLY BLOMP PAR UPLOAD!${NC}"
        echo -e "${GREEN}==========================================${NC}"

    else

        echo ""
        echo -e "${RED}==========================================${NC}"
        echo -e "${RED}✗ BACKUP FAILED${NC}"
        echo -e "${RED}==========================================${NC}"

        echo ""
        echo "Log check karein:"
        echo "cat /var/log/fakecloud-backup.log"

    fi

    echo ""
    read -p "Enter dabayein Menu ke liye..." temp
}

# ============================================
# 3. LIST + RESTORE BACKUP
# ============================================
restore_backup() {

    clear

    if ! check_blomp_login; then
        sleep 2
        return
    fi

    echo -e "${CYAN}==========================================${NC}"
    echo -e "${CYAN}        FULL RESTORE FROM BLOMP           ${NC}"
    echo -e "${CYAN}==========================================${NC}"

    echo ""
    echo -e "${YELLOW}Blomp Cloud se backup list load ho rahi hai...${NC}"
    echo ""

    mapfile -t files < <(
        rclone lsf \
            "${REMOTE_NAME}:${BLOMP_USER}/${BACKUP_FOLDER}/" \
            --files-only \
            --include "FULL_BACKUP_*.tar.gz" \
            2>/dev/null \
        | sort -r
    )

    if [ ${#files[@]} -eq 0 ]; then

        echo -e "${RED}✗ Blomp Cloud par koi backup nahi mila!${NC}"

        sleep 2
        return
    fi

    echo -e "${GREEN}Available Backups:${NC}"

    echo "------------------------------------------------------------"

    for i in "${!files[@]}"; do

        FILE_NAME="${files[$i]}"

        SIZE=$(rclone size \
            "${REMOTE_NAME}:${BLOMP_USER}/${BACKUP_FOLDER}/${FILE_NAME}" \
            --json 2>/dev/null \
            | grep -o '"bytes":[0-9]*' \
            | cut -d':' -f2)

        if [ -n "$SIZE" ]; then
            HUMAN_SIZE=$(numfmt --to=iec "$SIZE" 2>/dev/null)
        else
            HUMAN_SIZE="Unknown"
        fi

        echo -e "${YELLOW}$((i+1)))${NC} ${FILE_NAME} (${HUMAN_SIZE})"

    done

    echo "------------------------------------------------------------"
    echo ""

    read -p "Konsa backup restore karna hai? [1-${#files[@]}] (0 Back): " choice

    if [ "$choice" = "0" ]; then
        return
    fi

    if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Galat option!${NC}"
        sleep 2
        return
    fi

    if [ "$choice" -lt 1 ] || [ "$choice" -gt "${#files[@]}" ]; then
        echo -e "${RED}Galat option!${NC}"
        sleep 2
        return
    fi

    selected="${files[$((choice-1))]}"

    LOCAL_FILE="/root/${selected}"

    echo ""
    echo -e "${YELLOW}Selected:${NC}"
    echo "$selected"

    echo ""
    echo -e "${YELLOW}Blomp se backup download ho raha hai...${NC}"
    echo ""

    if ! rclone copyto \
        "${REMOTE_NAME}:${BLOMP_USER}/${BACKUP_FOLDER}/${selected}" \
        "$LOCAL_FILE" \
        --retries 5 \
        --low-level-retries 10 \
        --timeout 10m \
        --contimeout 60s \
        --progress; then

        echo ""
        echo -e "${RED}✗ Backup download FAILED!${NC}"

        rm -f "$LOCAL_FILE"

        read -p "Enter dabayein..." temp
        return
    fi

    echo ""
    echo -e "${YELLOW}Backup verify kiya ja raha hai...${NC}"

    if ! tar -tzf "$LOCAL_FILE" >/dev/null 2>&1; then

        echo -e "${RED}✗ Backup corrupt hai ya incomplete download hua.${NC}"

        rm -f "$LOCAL_FILE"

        read -p "Enter dabayein..." temp
        return
    fi

    echo -e "${GREEN}✓ Backup archive valid hai.${NC}"

    echo ""
    echo -e "${YELLOW}Wings temporarily stop kiya ja raha hai...${NC}"

    systemctl stop wings >/dev/null 2>&1 || true

    echo -e "${YELLOW}Data restore ho raha hai...${NC}"

    if tar -xzf "$LOCAL_FILE" -C /; then

        rm -f "$LOCAL_FILE"

        # Permissions
        chmod 600 /etc/pterodactyl/config.yml >/dev/null 2>&1 || true

        # Docker
        systemctl enable --now docker >/dev/null 2>&1 || true

        # Wings service create if missing
        if [ ! -f /etc/systemd/system/wings.service ]; then

            cat > /etc/systemd/system/wings.service <<'SERVICEEOF'
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service
Requires=docker.service

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
SERVICEEOF

        fi

        systemctl daemon-reload

        systemctl enable wings >/dev/null 2>&1 || true
        systemctl restart docker >/dev/null 2>&1 || true

        sleep 2

        systemctl restart wings >/dev/null 2>&1 || true

        echo ""
        echo -e "${GREEN}====================================================${NC}"
        echo -e "${GREEN} ✓ FULL RESTORE SUCCESSFUL                         ${NC}"
        echo -e "${GREEN} ✓ Pterodactyl Volumes Restored                   ${NC}"
        echo -e "${GREEN} ✓ Wings Configuration Restored                   ${NC}"
        echo -e "${GREEN} ✓ SSL Data Restored                              ${NC}"
        echo -e "${GREEN}====================================================${NC}"

        echo ""

        if systemctl is-active --quiet wings; then
            echo -e "${GREEN}✓ Wings: RUNNING${NC}"
        else
            echo -e "${YELLOW}! Wings abhi running nahi hai.${NC}"
            echo "Check:"
            echo "journalctl -u wings -n 50 --no-pager"
        fi

    else

        echo -e "${RED}✗ Restore ke time error aaya.${NC}"

    fi

    echo ""
    read -p "Enter dabayein Menu ke liye..." temp
}

# ============================================
# SHOW BLOMP BACKUPS
# ============================================
show_backups() {

    clear

    if ! check_blomp_login; then
        sleep 2
        return
    fi

    echo -e "${CYAN}==========================================${NC}"
    echo -e "${CYAN}          BLOMP BACKUP LIST               ${NC}"
    echo -e "${CYAN}==========================================${NC}"
    echo ""

    rclone lsl \
        "${REMOTE_NAME}:${BLOMP_USER}/${BACKUP_FOLDER}/" \
        --include "*.tar.gz" \
        2>/dev/null

    echo ""
    read -p "Enter dabayein Menu ke liye..." temp
}

# ============================================
# STOP AUTO BACKUP
# ============================================
stop_auto_backup() {

    crontab -l 2>/dev/null \
        | grep -v "/root/do_full_backup.sh" \
        | crontab -

    echo -e "${GREEN}✓ Auto Backup OFF kar diya gaya.${NC}"

    sleep 2
}

# ============================================
# MAIN
# ============================================

install_all_dependencies
load_blomp_config

while true; do

    clear

    echo -e "${GREEN}╔════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║       PTERODACTYL CLOUD MANAGER - BLOMP           ║${NC}"
    echo -e "${GREEN}╠════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║ ${YELLOW}1)${NC} FULL Auto-Backup ON (Har 15 Min)              ${GREEN}║${NC}"
    echo -e "${GREEN}║ ${YELLOW}2)${NC} FULL Restore From Blomp                       ${GREEN}║${NC}"
    echo -e "${GREEN}║ ${YELLOW}3)${NC} Blomp Cloud Login / Setup                     ${GREEN}║${NC}"
    echo -e "${GREEN}║ ${YELLOW}4)${NC} Blomp Backup List                              ${GREEN}║${NC}"
    echo -e "${GREEN}║ ${YELLOW}5)${NC} Auto-Backup OFF                                ${GREEN}║${NC}"
    echo -e "${GREEN}║ ${YELLOW}0)${NC} Exit                                           ${GREEN}║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════╝${NC}"

    echo ""

    read -p "Option [0-5]: " opt

    case "$opt" in

        1)
            start_auto_backup
            ;;

        2)
            restore_backup
            ;;

        3)
            setup_blomp
            ;;

        4)
            show_backups
            ;;

        5)
            stop_auto_backup
            ;;

        0)
            exit 0
            ;;

        *)
            echo -e "${RED}Sahi number daalein!${NC}"
            sleep 1
            ;;

    esac

done
