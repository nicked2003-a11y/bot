#!/bin/bash

GREEN='\033[0;32m'
CYAN='\033[0;36m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

REMOTE_NAME="blomp_cloud"
CONFIG_FILE="/root/.fakecloud_blomp"
# Cloud folder name (aap jo chahte the)
BACKUP_FOLDER="Backup vps"

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}ROOT se run karein.${NC}"
    exit 1
fi

load_blomp_config() {
    [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"
}

install_all_dependencies() {
    clear
    echo -e "${YELLOW}>>> Tools install/check...${NC}"
    apt-get update -y >/dev/null 2>&1
    apt-get install -y curl tar gzip unzip rclone docker.io cron coreutils ca-certificates >/dev/null 2>&1
    systemctl enable --now docker >/dev/null 2>&1
    systemctl enable --now cron >/dev/null 2>&1

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

# ---------- BLOMP LOGIN ----------
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

    echo -e "${YELLOW}Connecting...${NC}"
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

    # Folder "Backup vps" banao
    rclone mkdir "${REMOTE_NAME}:${blomp_user}/${BACKUP_FOLDER}" >/dev/null 2>&1

    if rclone lsf "${REMOTE_NAME}:${blomp_user}" >/tmp/blomp_test.log 2>&1; then
        echo -e "${GREEN}✓ Blomp Connect OK${NC}"
        echo -e "Folder: ${CYAN}${blomp_user}/${BACKUP_FOLDER}/${NC}"
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

# ---------- DATA KYA HAI (debug empty backup) ----------
show_local_data() {
    echo -e "${CYAN}--- Local Pterodactyl data check ---${NC}"
    for p in /var/lib/pterodactyl /var/lib/pterodactyl/volumes /etc/pterodactyl /etc/letsencrypt; do
        if [ -e "$p" ]; then
            sz=$(du -sh "$p" 2>/dev/null | awk '{print $1}')
            echo -e "  ${GREEN}OK${NC} $p  →  $sz"
        else
            echo -e "  ${RED}MISSING${NC} $p"
        fi
    done
    echo ""
}

# ---------- EK BAAR FULL BACKUP (custom name) ----------
# $1 = backup name (optional)
do_one_backup() {
    load_blomp_config
    local NAME="$1"

    if [ -z "$NAME" ]; then
        NAME="FULL_$(date +%Y-%m-%d_%H-%M-%S)"
    fi
    # Safe filename
    NAME=$(echo "$NAME" | tr -cd 'A-Za-z0-9._-')
    [ -z "$NAME" ] && NAME="FULL_$(date +%Y-%m-%d_%H-%M-%S)"

    local FILE="${NAME}.tar.gz"
    local LOCAL="/root/${FILE}"
    local LOG="/var/log/fakecloud-backup.log"
    local DEST="${REMOTE_NAME}:${BLOMP_USER}/${BACKUP_FOLDER}/"

    echo "======================================" >> "$LOG"
    echo "Backup start: $(date) name=$NAME" >> "$LOG"

    show_local_data

    # Paths jo exist karte hain
    local PATHS=()
    [ -d /var/lib/pterodactyl ] && PATHS+=(/var/lib/pterodactyl)
    [ -d /etc/pterodactyl ] && PATHS+=(/etc/pterodactyl)
    [ -d /etc/letsencrypt ] && PATHS+=(/etc/letsencrypt)

    if [ ${#PATHS[@]} -eq 0 ]; then
        echo -e "${RED}✗ Koi Pterodactyl folder nahi mila. Pehle Wings/servers lagao.${NC}"
        echo "ERROR: no paths" >> "$LOG"
        return 1
    fi

    # Optional: consistent backup
    systemctl stop wings >/dev/null 2>&1 || true

    echo -e "${YELLOW}Compress ho raha hai: ${FILE}${NC}"
    echo "Paths: ${PATHS[*]}" >> "$LOG"

    # Absolute paths, verbose errors
    if ! tar -czf "$LOCAL" --absolute-names "${PATHS[@]}" 2>>"$LOG"; then
        echo -e "${RED}✗ tar fail${NC}"
        systemctl start wings >/dev/null 2>&1 || true
        rm -f "$LOCAL"
        return 1
    fi

    systemctl start wings >/dev/null 2>&1 || true

    local BYTES
    BYTES=$(stat -c%s "$LOCAL" 2>/dev/null || echo 0)
    local HUMAN
    HUMAN=$(du -h "$LOCAL" | awk '{print $1}')

    echo -e "${CYAN}Local archive size: ${HUMAN} (${BYTES} bytes)${NC}"
    echo "Size: $HUMAN ($BYTES)" >> "$LOG"

    if [ "$BYTES" -lt 1024 ]; then
        echo -e "${RED}⚠ WARNING: Backup bahut chhota hai (<1KB). Data empty ho sakta hai.${NC}"
        echo -e "${YELLOW}Check: kya /var/lib/pterodactyl/volumes mein servers hain?${NC}"
        ls -la /var/lib/pterodactyl/volumes 2>/dev/null | head -20
        echo ""
        read -p "Phir bhi upload karein? (y/N): " conf
        if [[ ! "$conf" =~ ^[Yy]$ ]]; then
            rm -f "$LOCAL"
            return 1
        fi
    fi

    # Ensure remote folder
    rclone mkdir "${DEST}" >/dev/null 2>&1

    echo -e "${YELLOW}Upload → Blomp: ${BLOMP_USER}/${BACKUP_FOLDER}/${FILE}${NC}"
    if rclone copy "$LOCAL" "$DEST" \
        --retries 5 \
        --low-level-retries 10 \
        --timeout 30m \
        --contimeout 60s \
        --progress \
        2>>"$LOG"; then
        echo -e "${GREEN}✓ Upload OK: ${FILE}${NC}"
        echo "SUCCESS $FILE" >> "$LOG"
        rm -f "$LOCAL"
        return 0
    else
        echo -e "${RED}✗ Upload fail. Local file: $LOCAL${NC}"
        echo "UPLOAD FAIL" >> "$LOG"
        return 1
    fi
}

# ---------- MENU: Manual backup with NAME ----------
manual_backup_named() {
    clear
    if ! check_blomp_login; then sleep 2; return; fi

    echo -e "${CYAN}=== MANUAL FULL BACKUP (Custom Name) ===${NC}"
    echo -e "Cloud folder: ${YELLOW}${BACKUP_FOLDER}${NC}"
    echo ""
    show_local_data
    echo ""
    read -p "Backup ka naam (e.g. survival_day1) [Enter=auto]: " bname
    do_one_backup "$bname"
    echo ""
    read -p "Enter..." t
}

# ---------- AUTO every 15 min ----------
start_auto_backup() {
    clear
    if ! check_blomp_login; then sleep 2; return; fi

    echo -e "${CYAN}=== AUTO BACKUP 15 MIN ===${NC}"
    echo -e "Folder: ${BACKUP_FOLDER}"
    read -p "Auto backups ka prefix naam (e.g. auto_mc) [default=AUTO]: " prefix
    prefix=${prefix:-AUTO}
    prefix=$(echo "$prefix" | tr -cd 'A-Za-z0-9._-')

    # Worker script with fixed prefix + folder
    cat > /root/do_full_backup.sh <<EOF
#!/bin/bash
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
REMOTE_NAME="${REMOTE_NAME}"
BLOMP_USER="${BLOMP_USER}"
BACKUP_FOLDER="${BACKUP_FOLDER}"
PREFIX="${prefix}"
LOG="/var/log/fakecloud-backup.log"
TIME=\$(date +%Y-%m-%d_%H-%M-%S)
NAME="\${PREFIX}_\${TIME}"
FILE="\${NAME}.tar.gz"
LOCAL="/root/\${FILE}"
DEST="\${REMOTE_NAME}:\${BLOMP_USER}/\${BACKUP_FOLDER}/"

echo "==== \$(date) auto \$NAME ====" >> "\$LOG"

PATHS=""
[ -d /var/lib/pterodactyl ] && PATHS="\$PATHS /var/lib/pterodactyl"
[ -d /etc/pterodactyl ] && PATHS="\$PATHS /etc/pterodactyl"
[ -d /etc/letsencrypt ] && PATHS="\$PATHS /etc/letsencrypt"

if [ -z "\$PATHS" ]; then
  echo "NO PATHS" >> "\$LOG"
  exit 1
fi

systemctl stop wings >/dev/null 2>&1 || true
tar -czf "\$LOCAL" --absolute-names \$PATHS 2>>"\$LOG"
systemctl start wings >/dev/null 2>&1 || true

BYTES=\$(stat -c%s "\$LOCAL" 2>/dev/null || echo 0)
echo "bytes=\$BYTES" >> "\$LOG"

# 159 byte jaisi empty backup upload mat karo
if [ "\$BYTES" -lt 1024 ]; then
  echo "SKIP empty backup" >> "\$LOG"
  rm -f "\$LOCAL"
  exit 1
fi

rclone mkdir "\$DEST" >/dev/null 2>&1
rclone copy "\$LOCAL" "\$DEST" --retries 5 --timeout 30m >>"\$LOG" 2>&1
RC=\$?
[ \$RC -eq 0 ] && rm -f "\$LOCAL"
exit \$RC
EOF
    chmod 700 /root/do_full_backup.sh

    crontab -l 2>/dev/null | grep -v "/root/do_full_backup.sh" > /tmp/fcron || true
    echo "*/15 * * * * /bin/bash /root/do_full_backup.sh >/dev/null 2>&1" >> /tmp/fcron
    crontab /tmp/fcron
    rm -f /tmp/fcron

    echo -e "${GREEN}✓ Auto ON (15 min), prefix=${prefix}${NC}"
    echo -e "${YELLOW}Pehla backup abhi...${NC}"
    do_one_backup "${prefix}_$(date +%Y-%m-%d_%H-%M-%S)"
    read -p "Enter..." t
}

restore_backup() {
    clear
    if ! check_blomp_login; then sleep 2; return; fi

    echo -e "${CYAN}=== RESTORE (folder: ${BACKUP_FOLDER}) ===${NC}"
    mapfile -t files < <(
        rclone lsf "${REMOTE_NAME}:${BLOMP_USER}/${BACKUP_FOLDER}/" \
            --files-only --include "*.tar.gz" 2>/dev/null | sort -r
    )

    if [ ${#files[@]} -eq 0 ]; then
        echo -e "${RED}Koi backup nahi${NC}"
        sleep 2
        return
    fi

    echo -e "${GREEN}List:${NC}"
    for i in "${!files[@]}"; do
        echo -e "  ${YELLOW}$((i+1)))${NC} ${files[$i]}"
    done
    read -p "Number (0=back): " choice
    [ "$choice" = "0" ] && return
    [[ "$choice" =~ ^[0-9]+$ ]] || return
    [ "$choice" -lt 1 ] || [ "$choice" -gt "${#files[@]}" ] && return

    selected="${files[$((choice-1))]}"
    LOCAL="/root/${selected}"

    echo -e "${YELLOW}Download $selected ...${NC}"
    rclone copyto \
        "${REMOTE_NAME}:${BLOMP_USER}/${BACKUP_FOLDER}/${selected}" \
        "$LOCAL" --retries 5 --progress || {
        echo -e "${RED}Download fail${NC}"
        rm -f "$LOCAL"
        read -p "Enter..." t
        return
    }

    if ! tar -tzf "$LOCAL" >/dev/null 2>&1; then
        echo -e "${RED}Corrupt archive${NC}"
        rm -f "$LOCAL"
        read -p "Enter..." t
        return
    fi

    systemctl stop wings >/dev/null 2>&1 || true
    # Archives with --absolute-names extract to /
    tar -xzf "$LOCAL" -C / 2>/dev/null || tar -xzf "$LOCAL" -C /
    rm -f "$LOCAL"

    chmod 600 /etc/pterodactyl/config.yml 2>/dev/null || true

    if [ ! -f /etc/systemd/system/wings.service ]; then
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
    fi
    systemctl daemon-reload
    systemctl enable --now docker wings >/dev/null 2>&1 || true
    systemctl restart docker wings >/dev/null 2>&1 || true

    echo -e "${GREEN}✓ RESTORE DONE${NC}"
    systemctl is-active --quiet wings && echo -e "${GREEN}Wings RUNNING${NC}" || echo -e "${YELLOW}Wings check: journalctl -u wings -n 30${NC}"
    read -p "Enter..." t
}

show_backups() {
    clear
    if ! check_blomp_login; then sleep 2; return; fi
    echo -e "${CYAN}Blomp → ${BLOMP_USER}/${BACKUP_FOLDER}/${NC}"
    rclone lsl "${REMOTE_NAME}:${BLOMP_USER}/${BACKUP_FOLDER}/" --include "*.tar.gz" 2>/dev/null
    read -p "Enter..." t
}

stop_auto_backup() {
    crontab -l 2>/dev/null | grep -v "/root/do_full_backup.sh" | crontab -
    echo -e "${GREEN}Auto OFF${NC}"
    sleep 2
}

# ---------- MAIN ----------
install_all_dependencies
load_blomp_config

while true; do
    clear
    echo -e "${GREEN}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║   PTERODACTYL + BLOMP  (Backup vps folder)   ║${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║ ${YELLOW}1)${NC} Auto-Backup ON (15 min + prefix name)   ${GREEN}║${NC}"
    echo -e "${GREEN}║ ${YELLOW}2)${NC} Restore (list 1,2,3)                    ${GREEN}║${NC}"
    echo -e "${GREEN}║ ${YELLOW}3)${NC} Blomp Login                             ${GREEN}║${NC}"
    echo -e "${GREEN}║ ${YELLOW}4)${NC} Backup list (cloud)                     ${GREEN}║${NC}"
    echo -e "${GREEN}║ ${YELLOW}5)${NC} Manual backup (APNA NAAM set karo)      ${GREEN}║${NC}"
    echo -e "${GREEN}║ ${YELLOW}6)${NC} Local data size check (159 byte fix)    ${GREEN}║${NC}"
    echo -e "${GREEN}║ ${YELLOW}7)${NC} Auto-Backup OFF                         ${GREEN}║${NC}"
    echo -e "${GREEN}║ ${YELLOW}0)${NC} Exit                                    ${GREEN}║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}"
    read -p "Option: " opt
    case "$opt" in
        1) start_auto_backup ;;
        2) restore_backup ;;
        3) setup_blomp ;;
        4) show_backups ;;
        5) manual_backup_named ;;
        6) clear; show_local_data; read -p "Enter..." t ;;
        7) stop_auto_backup ;;
        0) exit 0 ;;
        *) sleep 1 ;;
    esac
done
