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

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}ROOT se run karein.${NC}"
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
    if command -v crontab >/dev/null 2>&1; then
        return 0
    fi

    echo -e "${YELLOW}Cron scheduler install ho raha hai...${NC}"
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y >/dev/null 2>&1
        apt-get install -y cron >/dev/null 2>&1
        systemctl enable --now cron >/dev/null 2>&1 || true
    elif command -v yum >/dev/null 2>&1; then
        yum install -y cronie >/dev/null 2>&1
        systemctl enable --now crond >/dev/null 2>&1 || true
    fi
}

ensure_rclone() {
    if command -v rclone >/dev/null 2>&1; then
        return 0
    fi

    echo -e "${YELLOW}rclone install ho raha hai...${NC}"
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y >/dev/null 2>&1
        apt-get install -y rclone >/dev/null 2>&1
    fi

    if ! command -v rclone >/dev/null 2>&1; then
        curl -fsSL https://rclone.org/install.sh | bash >/dev/null 2>&1
    fi

    hash -r 2>/dev/null || true
    export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"
}

install_all_dependencies() {
    clear
    echo -e "${YELLOW}>>> Zaroori Tools Check & Install Ho Rahe Hain...<<<${NC}"
    
    ensure_cron
    ensure_rclone

    if command -v apt-get >/dev/null 2>&1; then
        apt-get install -y curl tar gzip unzip docker.io coreutils ca-certificates >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl tar gzip unzip docker coreutils ca-certificates >/dev/null 2>&1
    fi

    systemctl enable --now docker >/dev/null 2>&1 || true

    if [ ! -f /usr/local/bin/wings ]; then
        mkdir -p /etc/pterodactyl /var/lib/pterodactyl
        curl -L -o /usr/local/bin/wings \
            "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_amd64" >/dev/null 2>&1
        chmod u+x /usr/local/bin/wings
    fi
    mkdir -p /root/.config/rclone
    echo -e "${GREEN}✓ Sabhi tools ready hain!${NC}"
    sleep 1
}

# ==================== BLOMP LOGIN ====================
setup_blomp() {
    clear
    echo -e "${CYAN}======== BLOMP LOGIN ========${NC}"
    ensure_rclone || return

    read -p "Blomp Email: " blomp_user
    read -s -p "Blomp Password: " blomp_pass
    echo ""
    echo ""

    if [ -z "$blomp_user" ] || [ -z "$blomp_pass" ]; then
        echo -e "${RED}Email/Password blank nahi ho sakte.${NC}"
        sleep 2
        return
    fi

    echo -e "${YELLOW}Connecting Blomp...${NC}"
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
        echo -e "${GREEN}✓ Blomp Connect OK${NC}"
        echo -e "Cloud folder: ${CYAN}${blomp_user}/${BACKUP_FOLDER}/${NC}"
    else
        echo -e "${RED}✗ Login fail${NC}"
        cat /tmp/blomp_test.log 2>/dev/null
        rclone config delete "$REMOTE_NAME" >/dev/null 2>&1 || true
        rm -f "$CONFIG_FILE"
    fi
    read -p "Enter..." t
}

check_blomp_login() {
    load_blomp_config
    if ! rclone listremotes 2>/dev/null | grep -q "^${REMOTE_NAME}:$"; then
        setup_blomp
        load_blomp_config
    fi
    [ -z "$BLOMP_USER" ] && return 1
    rclone lsf "${REMOTE_NAME}:${BLOMP_USER}" >/dev/null 2>&1 || return 1
    return 0
}

# ==================== SIZE CHECK ====================
show_local_data() {
    echo -e "${CYAN}--- Pura VPS Disk Usage ---${NC}"
    df -h / 2>/dev/null | tail -1 | awk '{print "  Disk /  Used="$3"  Free="$4"  Total="$2}'
    echo ""
    for p in / /root /home /var /var/lib /var/lib/pterodactyl /etc /opt /usr/local; do
        if [ -e "$p" ]; then
            sz=$(du -sh "$p" 2>/dev/null | awk '{print $1}')
            echo -e "  ${GREEN}OK${NC}  $p  →  $sz"
        fi
    done
    echo ""
}

# ==================== DIRECT STREAM BACKUP (NO LOCAL ZIP) ====================
do_full_vps_backup() {
    load_blomp_config
    load_backup_name

    if [ -z "$BACKUP_NAME" ]; then
        echo -e "${RED}Pehle Auto-Backup ON karke backup name set karein.${NC}"
        return 1
    fi
    if [ -z "$BLOMP_USER" ]; then
        echo -e "${RED}Pehle Blomp login karein.${NC}"
        return 1
    fi

    local TIME FILE LOG DEST
    TIME=$(date +%Y-%m-%d_%H-%M-%S)
    FILE="${BACKUP_NAME}_${TIME}.tar.gz"
    LOG="/var/log/fakecloud-backup.log"
    DEST="${REMOTE_NAME}:${BLOMP_USER}/${BACKUP_FOLDER}/${FILE}"

    echo "======================================" >> "$LOG"
    echo "STREAM BACKUP START $(date) file=$FILE" >> "$LOG"

    echo -e "${CYAN}⚡ NO-ZIP DIRECT STREAMING UPLOAD SHURU...${NC}"
    echo -e "Disk Space Used: ${GREEN}0 MB (Disk full nahi hoga!)${NC}"
    echo -e "File Name:       ${GREEN}${FILE}${NC}"
    echo -e "Cloud Destination: ${GREEN}${BLOMP_USER}/${BACKUP_FOLDER}/${NC}"
    echo "--------------------------------------------------------"

    systemctl stop wings >/dev/null 2>&1 || true

    # DIRECT PIPE: Tar Stream -> Rclone Rcat (Direct Cloud Upload)
    tar -czf - \
        --absolute-names \
        --ignore-failed-read \
        --warning=no-file-changed \
        --exclude="/proc" \
        --exclude="/sys" \
        --exclude="/dev" \
        --exclude="/run" \
        --exclude="/tmp" \
        --exclude="/mnt" \
        --exclude="/media" \
        --exclude="/lost+found" \
        --exclude="/var/tmp" \
        --exclude="/var/cache" \
        --exclude="/var/lib/docker/overlay2" \
        --exclude="/var/lib/docker/tmp" \
        --exclude="/snap" \
        -C / . 2>>"$LOG" \
    | rclone rcat "$DEST" \
        --progress \
        --stats 1s \
        --timeout 60m \
        --contimeout 60s \
        2>>"$LOG"

    local STREAM_RC=$?
    systemctl start wings >/dev/null 2>&1 || true

    echo "--------------------------------------------------------"
    if [ $STREAM_RC -eq 0 ]; then
        echo -e "${GREEN}✓ STREAM UPLOAD 100% SUCCESSFUL!${NC}"
        echo -e "${GREEN}  File: ${FILE} Blomp Cloud par save ho gaya.${NC}"
        echo "SUCCESS $FILE" >> "$LOG"
        return 0
    else
        echo -e "${RED}✗ Upload stream mein problem aayi.${NC}"
        echo "FAIL STREAM $FILE" >> "$LOG"
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
LOG="/var/log/fakecloud-backup.log"

TIME=\$(date +%Y-%m-%d_%H-%M-%S)
FILE="\${BACKUP_NAME}_\${TIME}.tar.gz"
DEST="\${REMOTE_NAME}:\${BLOMP_USER}/\${BACKUP_FOLDER}/\${FILE}"

echo "==== \$(date) AUTO STREAM \$FILE ====" >> "\$LOG"

systemctl stop wings >/dev/null 2>&1 || true

# Direct Pipe Stream Upload in Cron
tar -czf - \
  --absolute-names \
  --ignore-failed-read \
  --warning=no-file-changed \
  --exclude="/proc" \
  --exclude="/sys" \
  --exclude="/dev" \
  --exclude="/run" \
  --exclude="/tmp" \
  --exclude="/mnt" \
  --exclude="/media" \
  --exclude="/lost+found" \
  --exclude="/var/tmp" \
  --exclude="/var/cache" \
  --exclude="/var/lib/docker/overlay2" \
  --exclude="/var/lib/docker/tmp" \
  --exclude="/snap" \
  -C / . 2>>"\$LOG" \
| rclone rcat "\$DEST" --timeout 60m >>"\$LOG" 2>&1

RC=\$?
systemctl start wings >/dev/null 2>&1 || true

echo "Stream end rc=\$RC" >> "\$LOG"
exit \$RC
EOF
    chmod 700 /root/do_full_backup.sh
}

# ==================== 1) AUTO BACKUP ====================
start_auto_backup() {
    clear
    if ! check_blomp_login; then sleep 2; return; fi
    ensure_cron

    echo -e "${CYAN}╔════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║  DIRECT STREAM AUTO-BACKUP (15 Minutes)    ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "Cloud Folder: ${YELLOW}Backup vps${NC}"
    echo -e "Feature:      ${GREEN}0% Local Disk Use (Direct Streaming)${NC}"
    echo ""
    load_backup_name
    if [ -n "$BACKUP_NAME" ]; then
        echo -e "Current Name: ${GREEN}${BACKUP_NAME}${NC}"
        read -p "Naya Name set karein? Enter=wahi rehne do, ya naya likho: " newname
        if [ -n "$newname" ]; then
            save_backup_name "$newname"
        fi
    else
        echo -e "${YELLOW}Backup ka NAAM likho (example: panel / node1)${NC}"
        read -p "Backup Name: " newname
        [ -z "$newname" ] && newname="panel"
        save_backup_name "$newname"
    fi

    load_backup_name
    echo ""
    echo -e "${GREEN}Backup Name Lock: ${BACKUP_NAME}${NC}"
    echo -e "Files format:    ${CYAN}${BACKUP_NAME}_TARIKH_TIME.tar.gz${NC}"
    echo ""

    create_auto_worker

    crontab -l 2>/dev/null | grep -v "/root/do_full_backup.sh" > /tmp/fcron || true
    echo "*/15 * * * * /bin/bash /root/do_full_backup.sh >/dev/null 2>&1" >> /tmp/fcron
    crontab /tmp/fcron
    rm -f /tmp/fcron

    echo -e "${GREEN}✓ Auto-Backup Scheduler Active — har 15 min — Name: ${BACKUP_NAME}${NC}"
    echo -e "${YELLOW}Pehla Direct Stream Backup abhi shuru ho raha hai...${NC}"
    echo ""

    do_full_vps_backup
    read -p "Enter..." t
}

# ==================== 2) DIRECT STREAM RESTORE ====================
restore_backup() {
    clear
    if ! check_blomp_login; then sleep 2; return; fi

    echo -e "${CYAN}=== STREAM RESTORE FROM BLOMP (NO DISK ZIP) ===${NC}"
    echo -e "${RED}Warning: Restore pura system overwrite karega.${NC}"
    echo ""

    mapfile -t files < <(
        rclone lsf "${REMOTE_NAME}:${BLOMP_USER}/${BACKUP_FOLDER}/" \
            --files-only --include "*.tar.gz" 2>/dev/null | sort -r
    )

    if [ ${#files[@]} -eq 0 ]; then
        echo -e "${RED}Koi backup nahi mila!${NC}"
        sleep 2
        return
    fi

    echo -e "${GREEN}Available Backups:${NC}"
    echo "------------------------------------------------"
    for i in "${!files[@]}"; do
        echo -e "  ${YELLOW}$((i+1)))${NC} ${files[$i]}"
    done
    echo "------------------------------------------------"
    read -p "Number choose [1-${#files[@]}] (0=back): " choice
    [ "$choice" = "0" ] && return
    [[ "$choice" =~ ^[0-9]+$ ]] || return
    [ "$choice" -lt 1 ] || [ "$choice" -gt "${#files[@]}" ] && return

    selected="${files[$((choice-1))]}"
    SRC="${REMOTE_NAME}:${BLOMP_USER}/${BACKUP_FOLDER}/${selected}"

    echo -e "${YELLOW}⚡ Direct Stream Restore Shuru: ${selected} ...${NC}"
    echo -e "${CYAN}Cloud se direct read hokar extract ho raha hai (0 MB local disk needed)${NC}"

    systemctl stop wings >/dev/null 2>&1 || true

    # Direct Pipe: Rclone Cat Stream -> Tar Extract
    rclone cat "$SRC" --progress | tar -xzf - -C / --absolute-names 2>/dev/null || rclone cat "$SRC" | tar -xzf - -C /

    chmod 600 /etc/pterodactyl/config.yml 2>/dev/null || true

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
    systemctl restart docker wings >/dev/null 2>&1 || true

    echo -e "${GREEN}✓ DIRECT STREAM RESTORE COMPLETE!${NC}"
    read -p "Enter..." t
}

show_backups() {
    clear
    if ! check_blomp_login; then sleep 2; return; fi
    echo -e "${CYAN}Blomp Cloud: ${BLOMP_USER}/${BACKUP_FOLDER}/${NC}"
    echo ""
    rclone lsl "${REMOTE_NAME}:${BLOMP_USER}/${BACKUP_FOLDER}/" --include "*.tar.gz" 2>/dev/null
    echo ""
    read -p "Enter..." t
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
    echo -e "${GREEN}║   DIRECT STREAM VPS BACKUP (NO DISK FULL)      ║${NC}"
    echo -e "${GREEN}╠════════════════════════════════════════════════╣${NC}"
    if [ -n "$BACKUP_NAME" ]; then
    echo -e "${GREEN}║  Name: ${YELLOW}${BACKUP_NAME}${NC}   Folder: ${YELLOW}Backup vps${NC}"
    fi
    echo -e "${GREEN}║ ${YELLOW}1)${NC} Auto-Backup ON (15 min + Custom Name)   ${GREEN}║${NC}"
    echo -e "${GREEN}║ ${YELLOW}2)${NC} Restore (Direct Stream From Cloud)      ${GREEN}║${NC}"
    echo -e "${GREEN}║ ${YELLOW}3)${NC} Blomp Login                             ${GREEN}║${NC}"
    echo -e "${GREEN}║ ${YELLOW}4)${NC} Backup List (Cloud)                     ${GREEN}║${NC}"
    echo -e "${GREEN}║ ${YELLOW}6)${NC} Local Disk Size Check                   ${GREEN}║${NC}"
    echo -e "${GREEN}║ ${YELLOW}7)${NC} Auto-Backup OFF                         ${GREEN}║${NC}"
    echo -e "${GREEN}║ ${YELLOW}0)${NC} Exit                                    ${GREEN}║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════╝${NC}"
    read -p "Option: " opt
    case "$opt" in
        1) start_auto_backup ;;
        2) restore_backup ;;
        3) setup_blomp ;;
        4) show_backups ;;
        6) clear; show_local_data; read -p "Enter..." t ;;
        7) stop_auto_backup ;;
        0) exit 0 ;;
        *) sleep 1 ;;
    esac
done
