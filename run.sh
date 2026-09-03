#!/bin/bash

GREEN='\033[0;32m'
CYAN='\033[0;36m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

install_all_dependencies() {
    clear
    echo -e "${YELLOW}>>> Tools install/check ho rahe hain...<<<${NC}"
    apt-get update -y >/dev/null 2>&1
    apt-get install -y curl tar unzip rclone docker.io >/dev/null 2>&1
    systemctl start docker >/dev/null 2>&1
    systemctl enable docker >/dev/null 2>&1

    if [ ! -f /usr/local/bin/wings ]; then
        mkdir -p /etc/pterodactyl /var/lib/pterodactyl
        curl -L -o /usr/local/bin/wings \
            "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_amd64" >/dev/null 2>&1
        chmod u+x /usr/local/bin/wings
    fi
    echo -e "${GREEN}✓ Tools ready${NC}\n"
}

# ========== BLOMP LOGIN (SSL BYPASS ZABARDASTI) ==========
setup_blomp() {
    echo -e "${CYAN}======================================${NC}"
    echo -e "${CYAN}   BLOMP CLOUD LOGIN SETUP (FIXED)    ${NC}"
    echo -e "${CYAN}======================================${NC}"

    read -p "Blomp Email: " blomp_user
    read -p "Blomp Password: " blomp_pass
    echo ""

    echo -e "${YELLOW}Configuring Blomp for Rclone...${NC}"
    mkdir -p ~/.config/rclone

    OBS_PASS=$(rclone obscure "$blomp_pass" 2>/dev/null)
    
    # WebDAV Config
    cat > ~/.config/rclone/rclone.conf <<EOF
[blomp]
type = webdav
url = https://dav.blomp.com
vendor = other
user = ${blomp_user}
pass = ${OBS_PASS}
EOF

    echo -e "${YELLOW}Connection test (Bypassing SSL Certificate)...${NC}"

    # Adding --no-check-certificate to the command directly
    if rclone mkdir blomp:FullServerBackup --no-check-certificate 2>/tmp/blomp_err.log; then
        echo -e "${GREEN}======================================${NC}"
        echo -e "${GREEN}✓ SUCCESS: Blomp Cloud Connect Ho Gaya!${NC}"
        echo -e "${GREEN}======================================${NC}"
    else
        echo -e "${RED}======================================${NC}"
        echo -e "${RED}✗ LOGIN FAIL — Error Detail:${NC}"
        echo -e "${RED}======================================${NC}"
        cat /tmp/blomp_err.log
        echo -e "${YELLOW}Trying alternate URL...${NC}"
        
        # Alternate URL check
        sed -i 's/dav.blomp.com/webdav.blomp.com/' ~/.config/rclone/rclone.conf
        if rclone lsf blomp: --no-check-certificate >/dev/null 2>&1; then
             echo -e "${GREEN}✓ SUCCESS (with alternate URL)!${NC}"
        else
             echo -e "${RED}Abhi bhi connect nahi ho raha. Check Email/Password.${NC}"
             rm -f ~/.config/rclone/rclone.conf
        fi
    fi

    echo ""
    read -p "Enter dabayein menu ke liye..." t
}

check_blomp_login() {
    if ! rclone listremotes 2>/dev/null | grep -q "blomp:"; then
        echo -e "${YELLOW}Pehle Blomp login zaroori hai${NC}"
        setup_blomp
    fi
}

# ========== FULL AUTO BACKUP (15 MIN) ==========
start_auto_backup() {
    check_blomp_login
    if ! rclone listremotes 2>/dev/null | grep -q "blomp:"; then
        return
    fi

    echo -e "${CYAN}=== FULL AUTO BACKUP (Har 15 Min) ===${NC}"

    cat > /root/do_full_backup.sh << 'EOF'
#!/bin/bash
TIME=$(date +%Y-%m-%d_%H-%M)
FILE="FULL_BACKUP_${TIME}.tar.gz"
tar -czf "/root/${FILE}" /var/lib/pterodactyl /etc/pterodactyl /etc/letsencrypt 2>/dev/null
# Force SSL bypass during upload
rclone copy "/root/${FILE}" blomp:FullServerBackup/ --no-check-certificate --retries 5
rm -f "/root/${FILE}"
EOF
    chmod +x /root/do_full_backup.sh

    crontab -l 2>/dev/null | grep -v "do_full_backup" | crontab -
    (crontab -l 2>/dev/null; echo "*/15 * * * * /root/do_full_backup.sh >/dev/null 2>&1") | crontab -

    echo -e "${GREEN}✓ Scheduler ON (15 min)${NC}"
    echo -e "${YELLOW}Pehla FULL backup shuru...${NC}"
    /root/do_full_backup.sh
    echo -e "${GREEN}✓ Process complete.${NC}"
    sleep 2
}

# ========== FULL RESTORE ==========
restore_backup() {
    check_blomp_login
    if ! rclone listremotes 2>/dev/null | grep -q "blomp:"; then
        return
    fi

    echo -e "${CYAN}=== FULL SYSTEM RESTORE FROM BLOMP ===${NC}"
    echo -e "${YELLOW}Loading backups list...${NC}"

    # Force SSL bypass during list
    mapfile -t files < <(rclone lsf blomp:FullServerBackup/ --include "*.tar.gz" --no-check-certificate 2>/dev/null)

    if [ ${#files[@]} -eq 0 ]; then
        echo -e "${RED}✗ Koi backup nahi mila!${NC}"
        sleep 2
        return
    fi

    echo -e "${GREEN}Available Backups:${NC}"
    echo "--------------------------------------------------------"
    for i in "${!files[@]}"; do
        echo -e "${YELLOW}$((i+1)))${NC} ${files[$i]}"
    done
    echo "--------------------------------------------------------"

    read -p "Backup number chunein: " choice

    if [[ "$choice" -ge 1 && "$choice" -le "${#files[@]}" ]] 2>/dev/null; then
        selected="${files[$((choice-1))]}"
        echo -e "${YELLOW}Downloading (SSL Bypass): ${selected}${NC}"
        rclone copy "blomp:FullServerBackup/${selected}" /root/ --no-check-certificate --retries 5

        echo -e "${YELLOW}Restoring data...${NC}"
        tar -xzf "/root/${selected}" -C / 2>/dev/null
        rm -f "/root/${selected}"

        systemctl restart docker >/dev/null 2>&1
        systemctl restart wings >/dev/null 2>&1

        echo -e "${GREEN}✓ FULL RESTORE SUCCESSFUL!${NC}"
    else
        echo -e "${RED}Galat option!${NC}"
    fi
    sleep 2
}

# ========== MENU ==========
install_all_dependencies

while true; do
    clear
    echo -e "${GREEN}╔═════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║   PTERODACTYL FULL CLOUD MANAGER (SSL FIXED)    ║${NC}"
    echo -e "${GREEN}╠═════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║  ${YELLOW}1)${NC} FULL Auto-Backup ON (Har 15 Min)           ${GREEN}║${NC}"
    echo -e "${GREEN}║  ${YELLOW}2)${NC} FULL Restore (1, 2, 3 List Se Choose)     ${GREEN}║${NC}"
    echo -e "${GREEN}║  ${YELLOW}3)${NC} Blomp Cloud Login / Setup                  ${GREEN}║${NC}"
    echo -e "${GREEN}║  ${YELLOW}4)${NC} Exit                                       ${GREEN}║${NC}"
    echo -e "${GREEN}╚═════════════════════════════════════════════════╝${NC}"
    read -p "Option [1-4]: " opt

    case $opt in
        1) start_auto_backup ;;
        2) restore_backup ;;
        3) setup_blomp ;;
        4) exit 0 ;;
        *) echo -e "${RED}Sahi number daalein!${NC}"; sleep 1 ;;
    esac
done
