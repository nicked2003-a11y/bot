#!/bin/bash
# SMART BACKUP v8 — Blomp: copy only (no rcat) + TLS skip

GREEN='\033[0;32m'
CYAN='\033[0;36m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

REMOTE_NAME="blomp_cloud"
CONFIG_FILE="/root/.fakecloud_blomp"
NAME_FILE="/root/.fakecloud_backup_name"
BACKUP_FOLDER="Backup vps"
KEEP_COUNT=1
RCLONE_FLAGS="--no-check-certificate --retries 5 --timeout 60m --contimeout 60s"

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}ROOT se run karein.${NC}"
    exit 1
fi

load_blomp_config() { [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"; }

load_backup_name() {
    if [ -f "$NAME_FILE" ]; then
        BACKUP_NAME=$(cat "$NAME_FILE" | tr -cd 'A-Za-z0-9._-')
    else
        BACKUP_NAME=""
    fi
}

save_backup_name() {
    local n; n=$(echo "$1" | tr -cd 'A-Za-z0-9._-')
    [ -z "$n" ] && n="panel"
    echo "$n" > "$NAME_FILE"
    chmod 600 "$NAME_FILE"
    BACKUP_NAME="$n"
}

ensure_cron() {
    command -v crontab >/dev/null 2>&1 && return 0
    apt-get update -y >/dev/null 2>&1
    apt-get install -y cron >/dev/null 2>&1
    systemctl enable --now cron >/dev/null 2>&1 || true
}

ensure_rclone() {
    export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"
    if ! command -v rclone >/dev/null 2>&1; then
        apt-get update -y >/dev/null 2>&1
        apt-get install -y rclone >/dev/null 2>&1 || curl -fsSL https://rclone.org/install.sh | bash
    fi
    command -v rclone >/dev/null 2>&1
}

ensure_pigz() {
    command -v pigz >/dev/null 2>&1 || apt-get install -y pigz >/dev/null 2>&1 || true
}

install_all_dependencies() {
    clear
    echo -e "${YELLOW}>>> Tools install...${NC}"
    ensure_cron
    ensure_rclone
    ensure_pigz
    apt-get install -y curl tar gzip unzip mariadb-client coreutils ca-certificates >/dev/null 2>&1 || true
    mkdir -p /root/.config/rclone /tmp
    echo -e "${GREEN}✓ Tools ready${NC}"
    sleep 1
}

# ---------- BLOMP LOGIN (TLS FIX) ----------
setup_blomp() {
    clear
    echo -e "${CYAN}======== BLOMP CLOUD LOGIN ========${NC}"
    ensure_rclone || { echo -e "${RED}rclone missing${NC}"; read -p "Enter..." t; return; }

    read -p "Blomp Email: " blomp_user
    read -s -p "Blomp Password: " blomp_pass
    echo ""
    echo ""

    if [ -z "$blomp_user" ] || [ -z "$blomp_pass" ]; then
        echo -e "${RED}Email/Password empty nahi.${NC}"
        sleep 2
        return
    fi

    echo -e "${YELLOW}Connecting (TLS skip + Swift)...${NC}"
    mkdir -p /root/.config/rclone
    rclone config delete "$REMOTE_NAME" >/dev/null 2>&1 || true

    # Direct conf — no_check_certificate (ain.net cert = blomp.com)
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

    # Test
    if rclone lsf "${REMOTE_NAME}:" $RCLONE_FLAGS >/tmp/blomp_test.log 2>&1; then
        rclone mkdir "${REMOTE_NAME}:${blomp_user}/${BACKUP_FOLDER}" $RCLONE_FLAGS >/dev/null 2>&1
        echo -e "${GREEN}✓ Blomp Login OK${NC}"
        echo -e "Folder: ${CYAN}${blomp_user}/${BACKUP_FOLDER}/${NC}"
    else
        echo -e "${RED}✗ Login fail — detail:${NC}"
        cat /tmp/blomp_test.log
        # Fallback auth host
        echo -e "${YELLOW}Trying authenticate.blomp.com ...${NC}"
        sed -i 's|auth = .*|auth = https://authenticate.blomp.com|' /root/.config/rclone/rclone.conf
        if rclone lsf "${REMOTE_NAME}:" $RCLONE_FLAGS >/tmp/blomp_test2.log 2>&1; then
            echo -e "${GREEN}✓ Login OK (blomp.com auth)${NC}"
            rclone mkdir "${REMOTE_NAME}:${blomp_user}/${BACKUP_FOLDER}" $RCLONE_FLAGS >/dev/null 2>&1
        else
            cat /tmp/blomp_test2.log
            rm -f "$CONFIG_FILE"
            rclone config delete "$REMOTE_NAME" >/dev/null 2>&1 || true
        fi
    fi
    read -p "Enter dabayein..." t
}

check_blomp_login() {
    load_blomp_config
    ensure_rclone || return 1
    if ! rclone listremotes 2>/dev/null | grep -q "^${REMOTE_NAME}:$"; then
        setup_blomp
        load_blomp_config
    fi
    [ -z "$BLOMP_USER" ] && return 1
    rclone lsf "${REMOTE_NAME}:" $RCLONE_FLAGS >/dev/null 2>&1 || {
        echo -e "${YELLOW}Session fail — dubara login...${NC}"
        setup_blomp
        load_blomp_config
    }
    [ -z "$BLOMP_USER" ] && return 1
    return 0
}

show_important_data() {
    echo -e "${CYAN}--- Important paths ---${NC}"
    for p in /var/lib/pterodactyl /etc/pterodactyl /var/www/pterodactyl \
             /var/lib/tailscale /etc/cloudflared /root/.cloudflared \
             /etc/letsencrypt /etc/nginx /etc/apache2 /root /home \
             /etc/systemd/system /usr/local/bin /var/spool/cron; do
        if [ -e "$p" ]; then
            echo -e "  ${GREEN}FOUND${NC} $p → $(du -sh "$p" 2>/dev/null | awk '{print $1}')"
        else
            echo -e "  ${RED}--${NC} $p"
        fi
    done
}

cleanup_old_backups() {
    local REMOTE_DIR="$1" KEEP_FILE="$2" LOG="${3:-/var/log/fakecloud-backup.log}"
    echo -e "${YELLOW}Purane backup cleanup...${NC}"
    mapfile -t all_files < <(
        rclone lsf "$REMOTE_DIR" --files-only --include "*.tar.gz" $RCLONE_FLAGS 2>/dev/null | sort -r
    )
    [ ${#all_files[@]} -le "$KEEP_COUNT" ] && {
        echo -e "${GREEN}Sirf ${#all_files[@]} file — OK${NC}"
        return 0
    }
    for i in "${!all_files[@]}"; do
        f="${all_files[$i]}"
        [ "$i" -lt "$KEEP_COUNT" ] && continue
        [ "$f" = "$KEEP_FILE" ] && continue
        echo -e "${RED}DELETE:${NC} $f"
        rclone deletefile "${REMOTE_DIR}/${f}" $RCLONE_FLAGS 2>>"$LOG" || true
    done
    echo -e "${GREEN}✓ Cleanup done (keep $KEEP_COUNT)${NC}"
}

# ---------- BACKUP: tar → /tmp → rclone COPY (NO rcat) ----------
do_smart_vps_backup() {
    load_blomp_config
    load_backup_name
    ensure_rclone || return 1

    if [ -z "$BACKUP_NAME" ] || [ -z "$BLOMP_USER" ]; then
        echo -e "${RED}Login + backup name zaroori${NC}"
        return 1
    fi

    local TIME FILE TEMP_FILE SUBFOLDER DEST_DIR LOG
    TIME=$(date +%Y-%m-%d_%H-%M-%S)
    FILE="${BACKUP_NAME}_${TIME}.tar.gz"
    TEMP_FILE="/tmp/${FILE}"
    SUBFOLDER="${BACKUP_NAME}"
    DEST_DIR="${REMOTE_NAME}:${BLOMP_USER}/${BACKUP_FOLDER}/${SUBFOLDER}"
    LOG="/var/log/fakecloud-backup.log"

    echo "==== BACKUP START $(date) $FILE ====" >> "$LOG"

    DB_DUMP_FILE=""
    if command -v mysqldump >/dev/null 2>&1 && \
       (systemctl is-active --quiet mariadb || systemctl is-active --quiet mysql); then
        echo -e "${YELLOW}Database dump...${NC}"
        DB_DUMP_FILE="/tmp/pterodactyl_database_dump.sql"
        mysqldump --all-databases --single-transaction --quick > "$DB_DUMP_FILE" 2>>"$LOG" || true
    fi

    TARGET_PATHS=()
    [ -n "$DB_DUMP_FILE" ] && [ -f "$DB_DUMP_FILE" ] && TARGET_PATHS+=("$DB_DUMP_FILE")
    for p in /var/lib/pterodactyl /etc/pterodactyl /var/www/pterodactyl \
             /var/lib/tailscale /etc/cloudflared /root/.cloudflared \
             /etc/letsencrypt /etc/nginx /etc/apache2 /root /home \
             /etc/systemd/system /usr/local/bin /var/spool/cron; do
        [ -e "$p" ] && TARGET_PATHS+=("$p")
    done

    if [ ${#TARGET_PATHS[@]} -eq 0 ]; then
        echo -e "${RED}Koi data nahi${NC}"
        return 1
    fi

    rclone mkdir "$DEST_DIR" $RCLONE_FLAGS >/dev/null 2>&1

    echo -e "${CYAN}⚡ SMART BACKUP (temp /tmp + rclone copy)${NC}"
    echo -e "Path: ${GREEN}${BACKUP_FOLDER}/${SUBFOLDER}/${FILE}${NC}"
    echo "--------------------------------------------------------"

    systemctl stop wings >/dev/null 2>&1 || true
    rm -f "$TEMP_FILE"

    if command -v pigz >/dev/null 2>&1; then
        tar -cf - --absolute-names --ignore-failed-read --warning=no-file-changed \
            --exclude="/root/*.tar.gz" --exclude="/root/.cache" --exclude="/tmp/*" \
            "${TARGET_PATHS[@]}" 2>>"$LOG" \
        | pigz -1 -c > "$TEMP_FILE" 2>>"$LOG"
    else
        tar -czf "$TEMP_FILE" --absolute-names --ignore-failed-read --warning=no-file-changed \
            --exclude="/root/*.tar.gz" --exclude="/root/.cache" --exclude="/tmp/*" \
            "${TARGET_PATHS[@]}" 2>>"$LOG"
    fi

    systemctl start wings >/dev/null 2>&1 || true
    rm -f "$DB_DUMP_FILE" 2>/dev/null

    if [ ! -f "$TEMP_FILE" ]; then
        echo -e "${RED}✗ tar fail${NC}"
        echo "TAR FAIL" >> "$LOG"
        return 1
    fi

    local HUMAN
    HUMAN=$(du -h "$TEMP_FILE" | awk '{print $1}')
    echo -e "${CYAN}Local temp size: ${HUMAN} (upload ke baad delete)${NC}"
    echo "size=$HUMAN" >> "$LOG"

    echo -e "${YELLOW}Blomp upload (rclone copy)...${NC}"
    # IMPORTANT: copy — NOT rcat
    if rclone copy "$TEMP_FILE" "$DEST_DIR/" $RCLONE_FLAGS --progress --stats 1s 2>>"$LOG"; then
        rm -f "$TEMP_FILE"
        echo -e "${GREEN}✓ UPLOADED: ${SUBFOLDER}/${FILE}${NC}"
        echo "SUCCESS $FILE" >> "$LOG"
        cleanup_old_backups "$DEST_DIR" "$FILE" "$LOG"
        return 0
    else
        echo -e "${RED}✗ Upload fail. Temp: $TEMP_FILE | log: $LOG${NC}"
        echo "UPLOAD FAIL" >> "$LOG"
        tail -15 "$LOG"
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
RCLONE_FLAGS="${RCLONE_FLAGS}"
LOG="/var/log/fakecloud-backup.log"
TIME=\$(date +%Y-%m-%d_%H-%M-%S)
FILE="\${BACKUP_NAME}_\${TIME}.tar.gz"
TEMP_FILE="/tmp/\${FILE}"
SUBFOLDER="\${BACKUP_NAME}"
DEST_DIR="\${REMOTE_NAME}:\${BLOMP_USER}/\${BACKUP_FOLDER}/\${SUBFOLDER}"

echo "==== \$(date) AUTO COPY \$FILE ====" >> "\$LOG"

DB_DUMP=""
if command -v mysqldump >/dev/null 2>&1 && (systemctl is-active --quiet mariadb || systemctl is-active --quiet mysql); then
  DB_DUMP="/tmp/pterodactyl_database_dump.sql"
  mysqldump --all-databases --single-transaction --quick > "\$DB_DUMP" 2>>"\$LOG" || true
fi

TARGETS=()
[ -n "\$DB_DUMP" ] && [ -f "\$DB_DUMP" ] && TARGETS+=("\$DB_DUMP")
for p in /var/lib/pterodactyl /etc/pterodactyl /var/www/pterodactyl /var/lib/tailscale \\
  /etc/cloudflared /root/.cloudflared /etc/letsencrypt /etc/nginx /etc/apache2 \\
  /root /home /etc/systemd/system /usr/local/bin /var/spool/cron; do
  [ -e "\$p" ] && TARGETS+=("\$p")
done

rclone mkdir "\$DEST_DIR" \$RCLONE_FLAGS >/dev/null 2>&1
systemctl stop wings >/dev/null 2>&1 || true

if command -v pigz >/dev/null 2>&1; then
  tar -cf - --absolute-names --ignore-failed-read --warning=no-file-changed \\
    --exclude="/root/*.tar.gz" --exclude="/root/.cache" --exclude="/tmp/*" \\
    "\${TARGETS[@]}" 2>>"\$LOG" | pigz -1 -c > "\$TEMP_FILE" 2>>"\$LOG"
else
  tar -czf "\$TEMP_FILE" --absolute-names --ignore-failed-read --warning=no-file-changed \\
    --exclude="/root/*.tar.gz" --exclude="/root/.cache" --exclude="/tmp/*" \\
    "\${TARGETS[@]}" 2>>"\$LOG"
fi

systemctl start wings >/dev/null 2>&1 || true
rm -f "\$DB_DUMP"

# COPY only — never rcat
rclone copy "\$TEMP_FILE" "\$DEST_DIR/" \$RCLONE_FLAGS >>"\$LOG" 2>&1
RC=\$?
rm -f "\$TEMP_FILE"

if [ \$RC -eq 0 ]; then
  echo "SUCCESS \$FILE" >> "\$LOG"
  mapfile -t all_files < <(rclone lsf "\$DEST_DIR" --files-only --include "*.tar.gz" \$RCLONE_FLAGS 2>/dev/null | sort -r)
  for i in "\${!all_files[@]}"; do
    f="\${all_files[\$i]}"
    [ "\$i" -lt "\$KEEP_COUNT" ] && continue
    [ "\$f" = "\$FILE" ] && continue
    rclone deletefile "\${DEST_DIR}/\${f}" \$RCLONE_FLAGS 2>>"\$LOG" || true
    echo "DELETED \$f" >> "\$LOG"
  done
fi
echo "end rc=\$RC" >> "\$LOG"
exit \$RC
EOF
    chmod 700 /root/do_full_backup.sh
}

start_auto_backup() {
    clear
    if ! check_blomp_login; then sleep 2; return; fi
    ensure_cron
    ensure_pigz

    echo -e "${CYAN}╔════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║  SMART AUTO-BACKUP (copy, no rcat)         ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════╝${NC}"
    echo -e "Folder: ${YELLOW}Backup vps/[NAME]/${NC} | ${GREEN}Naya→purana delete${NC}"
    echo ""

    load_backup_name
    if [ -n "$BACKUP_NAME" ]; then
        echo -e "Current: ${GREEN}$BACKUP_NAME${NC}"
        read -p "Naya name? Enter=same: " newname
        [ -n "$newname" ] && save_backup_name "$newname"
    else
        read -p "Backup Name (panel/node1): " newname
        [ -z "$newname" ] && newname="panel"
        save_backup_name "$newname"
    fi
    load_backup_name

    create_auto_worker
    crontab -l 2>/dev/null | grep -v "/root/do_full_backup.sh" > /tmp/fcron || true
    echo "*/15 * * * * /bin/bash /root/do_full_backup.sh >/dev/null 2>&1" >> /tmp/fcron
    crontab /tmp/fcron
    rm -f /tmp/fcron

    echo -e "${GREEN}✓ Cron ON — name: $BACKUP_NAME${NC}"
    echo -e "${YELLOW}Pehla backup (COPY method)...${NC}"
    do_smart_vps_backup
    read -p "Enter..." t
}

restore_backup() {
    clear
    if ! check_blomp_login; then sleep 2; return; fi

    echo -e "${CYAN}=== RESTORE ===${NC}"
    mapfile -t folders < <(
        rclone lsf "${REMOTE_NAME}:${BLOMP_USER}/${BACKUP_FOLDER}/" --dirs-only $RCLONE_FLAGS 2>/dev/null
    )
    mapfile -t flat_files < <(
        rclone lsf "${REMOTE_NAME}:${BLOMP_USER}/${BACKUP_FOLDER}/" --files-only --include "*.tar.gz" $RCLONE_FLAGS 2>/dev/null | sort -r
    )

    if [ ${#folders[@]} -eq 0 ] && [ ${#flat_files[@]} -eq 0 ]; then
        echo -e "${RED}Koi backup nahi${NC}"; sleep 2; return
    fi

    OPTIONS=(); OPTION_TYPES=()
    for f in "${folders[@]}"; do
        OPTIONS+=("${f%/}"); OPTION_TYPES+=("folder")
        echo -e "  ${YELLOW}${#OPTIONS[@]})${NC} [FOLDER] ${f%/}/"
    done
    for f in "${flat_files[@]}"; do
        OPTIONS+=("$f"); OPTION_TYPES+=("file")
        echo -e "  ${YELLOW}${#OPTIONS[@]})${NC} [FILE] $f"
    done

    read -p "Choose [1-${#OPTIONS[@]}] 0=back: " choice
    [ "$choice" = "0" ] && return
    [[ "$choice" =~ ^[0-9]+$ ]] || return
    selected="${OPTIONS[$((choice-1))]}"
    seltype="${OPTION_TYPES[$((choice-1))]}"

    local SRC
    if [ "$seltype" = "folder" ]; then
        mapfile -t inner < <(
            rclone lsf "${REMOTE_NAME}:${BLOMP_USER}/${BACKUP_FOLDER}/${selected}/" \
                --files-only --include "*.tar.gz" $RCLONE_FLAGS 2>/dev/null | sort -r
        )
        [ ${#inner[@]} -eq 0 ] && { echo "Empty folder"; sleep 2; return; }
        for i in "${!inner[@]}"; do echo -e "  ${YELLOW}$((i+1)))${NC} ${inner[$i]}"; done
        read -p "File #: " fchoice
        selected_file="${inner[$((fchoice-1))]}"
        SRC="${REMOTE_NAME}:${BLOMP_USER}/${BACKUP_FOLDER}/${selected}/${selected_file}"
    else
        SRC="${REMOTE_NAME}:${BLOMP_USER}/${BACKUP_FOLDER}/${selected}"
    fi

    echo -e "${YELLOW}Download + restore...${NC}"
    systemctl stop wings >/dev/null 2>&1 || true
    local BN; BN=$(basename "$SRC")
    rclone copy "$SRC" /tmp/ $RCLONE_FLAGS --progress
    if [ -f "/tmp/$BN" ]; then
        tar -xzf "/tmp/$BN" -C / --absolute-names 2>/dev/null || tar -xzf "/tmp/$BN" -C /
        rm -f "/tmp/$BN"
    else
        echo -e "${RED}Download fail${NC}"; read -p "Enter..." t; return
    fi

    if [ -f /tmp/pterodactyl_database_dump.sql ] || [ -f /root/pterodactyl_database_dump.sql ]; then
        DF=/root/pterodactyl_database_dump.sql
        [ -f /tmp/pterodactyl_database_dump.sql ] && DF=/tmp/pterodactyl_database_dump.sql
        systemctl start mariadb mysql 2>/dev/null || true
        mysql < "$DF" 2>/dev/null || true
        rm -f "$DF"
    fi

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
    systemctl enable --now docker 2>/dev/null || true
    systemctl restart docker wings tailscaled cloudflared nginx 2>/dev/null || true
    echo -e "${GREEN}✓ RESTORE DONE${NC}"
    read -p "Enter..." t
}

show_backups() {
    clear
    if ! check_blomp_login; then sleep 2; return; fi
    echo -e "${CYAN}Tree: ${BLOMP_USER}/${BACKUP_FOLDER}/${NC}"
    mapfile -t folders < <(
        rclone lsf "${REMOTE_NAME}:${BLOMP_USER}/${BACKUP_FOLDER}/" --dirs-only $RCLONE_FLAGS 2>/dev/null
    )
    if [ ${#folders[@]} -eq 0 ]; then
        rclone lsl "${REMOTE_NAME}:${BLOMP_USER}/${BACKUP_FOLDER}/" --include "*.tar.gz" $RCLONE_FLAGS 2>/dev/null
    else
        for f in "${folders[@]}"; do
            echo -e "${GREEN}📁 ${f%/}/${NC}"
            rclone lsl "${REMOTE_NAME}:${BLOMP_USER}/${BACKUP_FOLDER}/${f%/}/" --include "*.tar.gz" $RCLONE_FLAGS 2>/dev/null | sed 's/^/   /'
        done
    fi
    read -p "Enter..." t
}

stop_auto_backup() {
    crontab -l 2>/dev/null | grep -v "/root/do_full_backup.sh" | crontab -
    echo -e "${GREEN}Auto OFF${NC}"
    sleep 2
}

# ---------- MENU ----------
install_all_dependencies
load_blomp_config
load_backup_name

while true; do
    clear
    load_backup_name
    echo -e "${GREEN}╔════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║   SMART BACKUP v8 (Blomp copy + TLS fix)       ║${NC}"
    echo -e "${GREEN}╠════════════════════════════════════════════════╣${NC}"
    [ -n "$BACKUP_NAME" ] && echo -e "${GREEN}║  Name: ${YELLOW}${BACKUP_NAME}${NC} → Backup vps/${BACKUP_NAME}/"
    echo -e "${GREEN}║ ${YELLOW}1)${NC} Auto-Backup ON (15 min)                  ${GREEN}║${NC}"
    echo -e "${GREEN}║ ${YELLOW}2)${NC} Restore                                  ${GREEN}║${NC}"
    echo -e "${GREEN}║ ${YELLOW}3)${NC} Blomp Login                              ${GREEN}║${NC}"
    echo -e "${GREEN}║ ${YELLOW}4)${NC} Backup List                              ${GREEN}║${NC}"
    echo -e "${GREEN}║ ${YELLOW}5)${NC} Important Data Check                     ${GREEN}║${NC}"
    echo -e "${GREEN}║ ${YELLOW}6)${NC} Auto-Backup OFF                          ${GREEN}║${NC}"
    echo -e "${GREEN}║ ${YELLOW}0)${NC} Exit                                     ${GREEN}║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════╝${NC}"
    read -p "Option: " opt
    case "$opt" in
        1) start_auto_backup ;;
        2) restore_backup ;;
        3) setup_blomp ;;
        4) show_backups ;;
        5) clear; show_important_data; read -p "Enter..." t ;;
        6) stop_auto_backup ;;
        0) exit 0 ;;
        *) sleep 1 ;;
    esac
done
