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

install_all_dependencies() {
    clear
    echo -e "${YELLOW}>>> Tools install/check...${NC}"
    apt-get update -y >/dev/null 2>&1
    apt-get install -y curl tar gzip unzip rclone docker.io cron coreutils ca-certificates >/dev/null 2>&1
    systemctl enable --now docker cron >/dev/null 2>&1 || true

    if [ ! -f /usr/local/bin/wings ]; then
        mkdir -p /etc/pterodactyl /var/lib/pterodactyl
        curl -L -o /usr/local/bin/wings \
            "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_amd64" >/dev/null 2>&1
        chmod u+x /usr/local/bin/wings
    fi
    mkdir -p /root/.config/rclone
    echo -e "${GREEN}✓ Tools ready${NC}"
    sleep 1
}

# ==================== BLOMP LOGIN ====================
setup_blomp() {
    clear
    echo -e "${CYAN}======== BLOMP LOGIN ========${NC}"
    read -p "Blomp Email: " blomp_user
    read -s -p "Blomp Password: " blomp_pass
    echo ""
    echo ""

    if [ -z "$blomp_user" ] || [ -z "$blomp_pass" ]; then
        echo -e "${RED}Email/Password blank nahi.${NC}"
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

# ==================== LOCAL / VPS SIZE ====================
show_local_data() {
    echo -e "${CYAN}--- Pura VPS disk / important paths ---${NC}"
    df -h / 2>/dev/null | tail -1 | awk '{print "  Disk /  used="$3"  free="$4"  total="$2}'
    echo ""
    for p in / /root /home /var /var/lib /var/lib/pterodactyl /var/lib/pterodactyl/volumes /etc /etc/pterodactyl /opt /usr/local; do
        if [ -e "$p" ]; then
            sz=$(du -sh "$p" 2>/dev/null | awk '{print $1}')
            echo -e "  ${GREEN}OK${NC}  $p  →  $sz"
        else
            echo -e "  ${RED}--${NC}  $p"
        fi
    done
    echo ""
    echo -e "${YELLOW}Note: Full backup ~ used disk jitna bada ho sakta hai (excludes ke baad kam).${NC}"
}

# ==================== FULL VPS BACKUP ENGINE ====================
# Uses BACKUP_NAME from file. Creates: NAME_TIMESTAMP.tar.gz
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

    local TIME FILE LOCAL LOG DEST
    TIME=$(date +%Y-%m-%d_%H-%M-%S)
    FILE="${BACKUP_NAME}_${TIME}.tar.gz"
    LOCAL="/root/${FILE}"
    LOG="/var/log/fakecloud-backup.log"
    DEST="${REMOTE_NAME}:${BLOMP_USER}/${BACKUP_FOLDER}/"

    echo "======================================" >> "$LOG"
    echo "FULL VPS backup start $(date) file=$FILE" >> "$LOG"

    # Free space rough check
    local FREE_KB
    FREE_KB=$(df -Pk / | awk 'NR==2{print $4}')
    echo -e "${CYAN}Free disk: $((FREE_KB/1024/1024)) GB approx${NC}"
    echo -e "${YELLOW}FULL VPS compress shuru (time lag sakta hai)...${NC}"
    echo -e "Name: ${GREEN}${FILE}${NC}"
    echo -e "Cloud: ${GREEN}${BLOMP_USER}/${BACKUP_FOLDER}/${FILE}${NC}"

    # Stop wings briefly for consistent game files (optional but good)
    systemctl stop wings >/dev/null 2>&1 || true

    # FULL / backup with safe excludes (A-Z system data)
    # --ignore-failed-read = locked files pe crash nahi
    tar -czf "$LOCAL" \
        --absolute-names \
        --ignore-failed-read \
        --warning=no-file-changed \
        --exclude="$LOCAL" \
        --exclude="/root/${BACKUP_NAME}_*.tar.gz" \
        --exclude="/root/*.tar.gz" \
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
        --exclude="/proc/*" \
        --exclude="/sys/*" \
        --exclude="/dev/*" \
        --exclude="/run/*" \
        -C / \
        . \
        2>>"$LOG"

    local TAR_RC=$?
    systemctl start wings >/dev/null 2>&1 || true

    # tar exit 1 often = file changed during read (OK-ish)
    if [ ! -f "$LOCAL" ]; then
        echo -e "${RED}✗ Archive nahi bana${NC}"
        echo "TAR FAIL rc=$TAR_RC" >> "$LOG"
        return 1
    fi

    local BYTES HUMAN
    BYTES=$(stat -c%s "$LOCAL" 2>/dev/null || echo 0)
    HUMAN=$(du -h "$LOCAL" | awk '{print $1}')
    echo -e "${CYAN}Archive size: ${HUMAN} (${BYTES} bytes)${NC}"
    echo "size=$HUMAN bytes=$BYTES" >> "$LOG"

    if [ "$BYTES" -lt 1048576 ]; then
        echo -e "${RED}⚠ Backup 1MB se chhota hai — shayad incomplete.${NC}"
        read -p "Phir bhi upload? (y/N): " conf
        [[ ! "$conf" =~ ^[Yy]$ ]] && rm -f "$LOCAL" && return 1
    fi

    rclone mkdir "$DEST" >/dev/null 2>&1
    echo -e "${YELLOW}Blomp par upload...${NC}"

    if rclone copy "$LOCAL" "$DEST" \
        --retries 5 \
        --low-level-retries 10 \
        --timeout 60m \
        --contimeout 60s \
        --progress \
        2>>"$LOG"; then
        echo -e "${GREEN}✓ FULL VPS BACKUP UPLOADED: ${FILE}${NC}"
        echo "SUCCESS $FILE" >> "$LOG"
        rm -f "$LOCAL"
        return 0
    else
        echo -e "${RED}✗ Upload fail. File local: $LOCAL${NC}"
        echo "UPLOAD FAIL" >> "$LOG"
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
LOCAL="/root/\${FILE}"
DEST="\${REMOTE_NAME}:\${BLOMP_USER}/\${BACKUP_FOLDER}/"

echo "==== \$(date) FULL VPS \$FILE ====" >> "\$LOG"

systemctl stop wings >/dev/null 2>&1 || true

tar -czf "\$LOCAL" \
  --absolute-names \
  --ignore-failed-read \
  --warning=no-file-changed \
  --exclude="\$LOCAL" \
  --exclude="/root/\${BACKUP_NAME}_*.tar.gz" \
  --exclude="/root/*.tar.gz" \
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
  -C / \
  . \
  2>>"\$LOG"

systemctl start wings >/dev/null 2>&1 || true

if [ ! -f "\$LOCAL" ]; then
  echo "NO FILE" >> "\$LOG"
  exit 1
fi

BYTES=\$(stat -c%s "\$LOCAL" 2>/dev/null || echo 0)
echo "bytes=\$BYTES" >> "\$LOG"

# Skip tiny broken backups
if [ "\$BYTES" -lt 1048576 ]; then
  echo "SKIP too small" >> "\$LOG"
  rm -f "\$LOCAL"
  exit 1
fi

rclone mkdir "\$DEST" >/dev/null 2>&1
rclone copy "\$LOCAL" "\$DEST" --retries 5 --timeout 60m >>"\$LOG" 2>&1
RC=\$?
[ \$RC -eq 0 ] && rm -f "\$LOCAL"
echo "done rc=\$RC" >> "\$LOG"
exit \$RC
EOF
    chmod 700 /root/do_full_backup.sh
}

# ==================== 1) AUTO BACKUP ====================
start_auto_backup() {
    clear
    if ! check_blomp_login; then sleep 2; return; fi

    echo -e "${CYAN}╔════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║   FULL VPS AUTO-BACKUP (Har 15 Minutes)    ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "Cloud folder: ${YELLOW}Backup vps${NC}"
    echo -e "Backup hoga:  ${YELLOW}PURA VPS (A-Z)${NC} — system, home, var, panel, docker data (safe excludes)"
    echo ""
    load_backup_name
    if [ -n "$BACKUP_NAME" ]; then
        echo -e "Pehle se name: ${GREEN}${BACKUP_NAME}${NC}"
        read -p "Naya name set karein? Enter=wahi rehne do, ya naya likho: " newname
        if [ -n "$newname" ]; then
            save_backup_name "$newname"
        fi
    else
        echo -e "${YELLOW}Backup ka NAAM likho (example: panel)${NC}"
        echo "Files aise banegi: panel_2025-01-15_14-30-00.tar.gz"
        read -p "Backup name: " newname
        if [ -z "$newname" ]; then
            newname="panel"
        fi
        save_backup_name "$newname"
    fi

    load_backup_name
    echo ""
    echo -e "${GREEN}Backup name lock: ${BACKUP_NAME}${NC}"
    echo -e "Har file: ${CYAN}${BACKUP_NAME}_TARIKH_TIME.tar.gz${NC}"
    echo ""

    create_auto_worker

    crontab -l 2>/dev/null | grep -v "/root/do_full_backup.sh" > /tmp/fcron || true
    echo "*/15 * * * * /bin/bash /root/do_full_backup.sh >/dev/null 2>&1" >> /tmp/fcron
    crontab /tmp/fcron
    rm -f /tmp/fcron

    echo -e "${GREEN}✓ Auto-Backup ON — har 15 min — name: ${BACKUP_NAME}${NC}"
    echo -e "${YELLOW}Pehla FULL VPS backup abhi start (wait — bada ho sakta hai)...${NC}"
    echo ""

    if do_full_vps_backup; then
        echo -e "${GREEN}✓ Pehla backup Blomp → Backup vps / mein OK${NC}"
    else
        echo -e "${RED}✗ Pehla backup fail — log: cat /var/log/fakecloud-backup.log${NC}"
    fi
    read -p "Enter..." t
}

# ==================== 2) RESTORE ====================
restore_backup() {
    clear
    if ! check_blomp_login; then sleep 2; return; fi

    echo -e "${CYAN}=== FULL VPS RESTORE (Backup vps) ===${NC}"
    echo -e "${RED}Warning: Restore pura system overwrite karega jahan tar mein files hain.${NC}"
    echo ""

    mapfile -t files < <(
        rclone lsf "${REMOTE_NAME}:${BLOMP_USER}/${BACKUP_FOLDER}/" \
            --files-only --include "*.tar.gz" 2>/dev/null | sort -r
    )

    if [ ${#files[@]} -eq 0 ]; then
        echo -e "${RED}Koi backup nahi mila${NC}"
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
    LOCAL="/root/restore_${selected}"

    echo -e "${YELLOW}Download: $selected${NC}"
    if ! rclone copyto \
        "${REMOTE_NAME}:${BLOMP_USER}/${BACKUP_FOLDER}/${selected}" \
        "$LOCAL" --retries 5 --timeout 60m --progress; then
        echo -e "${RED}Download fail${NC}"
        rm -f "$LOCAL"
        read -p "Enter..." t
        return
    fi

    if ! tar -tzf "$LOCAL" >/dev/null 2>&1; then
        echo -e "${RED}Corrupt archive${NC}"
        rm -f "$LOCAL"
        read -p "Enter..." t
        return
    fi

    echo -e "${YELLOW}Extract FULL VPS (overwrite)...${NC}"
    systemctl stop wings >/dev/null 2>&1 || true

    # Extract to /
    tar -xzf "$LOCAL" -C / --absolute-names 2>/dev/null || tar -xzf "$LOCAL" -C /
    rm -f "$LOCAL"

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
    systemctl restart docker >/dev/null 2>&1 || true
    systemctl restart wings >/dev/null 2>&1 || true

    echo -e "${GREEN}✓ FULL VPS RESTORE DONE${NC}"
    echo -e "${YELLOW}Naya VPS IP ho to Panel → Node mein IP update karna.${NC}"
    read -p "Enter..." t
}

show_backups() {
    clear
    if ! check_blomp_login; then sleep 2; return; fi
    echo -e "${CYAN}Blomp: ${BLOMP_USER}/${BACKUP_FOLDER}/${NC}"
    echo ""
    rclone lsl "${REMOTE_NAME}:${BLOMP_USER}/${BACKUP_FOLDER}/" --include "*.tar.gz" 2>/dev/null
    echo ""
    read -p "Enter..." t
}

# ==================== MENU (jaise aapne kaha) ====================
install_all_dependencies
load_blomp_config
load_backup_name

while true; do
    clear
    load_backup_name
    echo -e "${GREEN}╔════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║     FULL VPS BACKUP MANAGER → BLOMP            ║${NC}"
    echo -e "${GREEN}╠════════════════════════════════════════════════╣${NC}"
    if [ -n "$BACKUP_NAME" ]; then
    echo -e "${GREEN}║  Name: ${YELLOW}${BACKUP_NAME}${NC}   Folder: ${YELLOW}Backup vps${NC}"
    fi
    echo -e "${GREEN}║ ${YELLOW}1)${NC} Auto-Backup ON (15 min + prefix name)   ${GREEN}║${NC}"
    echo -e "${GREEN}║ ${YELLOW}2)${NC} Restore (list 1,2,3)                    ${GREEN}║${NC}"
    echo -e "${GREEN}║ ${YELLOW}3)${NC} Blomp Login                             ${GREEN}║${NC}"
    echo -e "${GREEN}║ ${YELLOW}4)${NC} Backup list (cloud)                     ${GREEN}║${NC}"
    echo -e "${GREEN}║ ${YELLOW}6)${NC} Local / VPS size check                  ${GREEN}║${NC}"
    echo -e "${GREEN}║ ${YELLOW}0)${NC} Exit                                    ${GREEN}║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════╝${NC}"
    read -p "Option: " opt
    case "$opt" in
        1) start_auto_backup ;;
        2) restore_backup ;;
        3) setup_blomp ;;
        4) show_backups ;;
        6) clear; show_local_data; read -p "Enter..." t ;;
        0) exit 0 ;;
        *) sleep 1 ;;
    esac
done
