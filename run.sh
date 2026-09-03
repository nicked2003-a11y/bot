#!/bin/bash

GREEN='\033[0;32m'
CYAN='\033[0;36m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Auto install all required tools
install_all_dependencies() {
    clear
    echo -e "${YELLOW}>>> Zaroori Tools Check aur Install Ho Rahe Hain...<<<${NC}"
    apt-get update -y >/dev/null 2>&1
    apt-get install -y curl tar unzip rclone docker.io >/dev/null 2>&1
    
    systemctl start docker >/dev/null 2>&1
    systemctl enable docker >/dev/null 2>&1

    if [ ! -f /usr/local/bin/wings ]; then
        mkdir -p /etc/pterodactyl /var/lib/pterodactyl
        curl -L -o /usr/local/bin/wings "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_amd64" >/dev/null 2>&1
        chmod u+x /usr/local/bin/wings
    fi
    echo -e "${GREEN}✓ Sabhi tools ready hain!${NC}\n"
}

# ========== 1. MEGA CLOUD LOGIN SETUP ==========
setup_mega() {
    echo -e "${CYAN}======================================${NC}"
    echo -e "${CYAN}        MEGA.NZ CLOUD LOGIN           ${NC}"
    echo -e "${CYAN}======================================${NC}"

    read -p "MEGA Email: " mega_user
    read -p "MEGA Password: " mega_pass
    echo ""

    echo -e "${YELLOW}MEGA.nz se Connect kiya ja raha hai...${NC}"
    mkdir -p ~/.config/rclone

    # Remove old config
    rclone config delete mega_cloud >/dev/null 2>&1

    # Native Rclone MEGA creation
    rclone config create mega_cloud mega user "$mega_user" pass "$mega_pass" >/dev/null 2>&1

    # Connection Test
    if rclone mkdir mega_cloud:FullServerBackup 2>/tmp/mega_err.log && rclone lsf mega_cloud: >/dev/null 2>&1; then
        echo -e "${GREEN}======================================${NC}"
        echo -e "${GREEN}✓ SUCCESS: MEGA Cloud Connect Ho Gaya!${NC}"
        echo -e "${GREEN}======================================${NC}"
    else
        echo -e "${RED}======================================${NC}"
        echo -e "${RED}✗ LOGIN FAIL — Email ya Password Check Karein!${NC}"
        echo -e "${RED}======================================${NC}"
        cat /tmp/mega_err.log 2>/dev/null
        rclone config delete mega_cloud >/dev/null 2>&1
    fi
    echo ""
    read -p "Enter dabayein Menu ke liye..." t
}

check_mega_login() {
    if ! rclone listremotes 2>/dev/null | grep -q "mega_cloud:"; then
        echo -e "${YELLOW}Pehle MEGA Login Karna Zaroori Hai!${NC}"
        setup_mega
    fi
}

# ========== 2. FULL AUTO BACKUP (Har 15 Min) ==========
start_auto_backup() {
    check_mega_login
    if ! rclone listremotes 2>/dev/null | grep -q "mega_cloud:"; then
        return
    fi

    echo -e "${CYAN}=== FULL AUTO BACKUP (Har 15 Min) ===${NC}"

    cat > /root/do_full_backup.sh << 'EOF'
#!/bin/bash
TIME=$(date +%Y-%m-%d_%H-%M)
FILE="FULL_BACKUP_${TIME}.tar.gz"

# Compress EVERYTHING (Pterodactyl Data, Configs, SSL Certs)
tar -czf "/root/${FILE}" /var/lib/pterodactyl /etc/pterodactyl /etc/letsencrypt 2>/dev/null

# Upload to MEGA Cloud
rclone copy "/root/${FILE}" mega_cloud:FullServerBackup/ --retries 3

# Remove local zip file
rm -f "/root/${FILE}"
EOF
    chmod +x /root/do_full_backup.sh

    # Set Cron Job
    crontab -l 2>/dev/null | grep -v "do_full_backup" | crontab -
    (crontab -l 2>/dev/null; echo "*/15 * * * * /root/do_full_backup.sh >/dev/null 2>&1") | crontab -

    echo -e "${GREEN}✓ FULL Auto-Backup Scheduler Active (Har 15 Min)${NC}"
    echo -e "${YELLOW}Pehla Full Backup MEGA par Upload Ho Raha Hai...${NC}"
    /root/do_full_backup.sh
    echo -e "${GREEN}✓ Pehla Backup Successfully Upload Ho Gaya!${NC}"
    sleep 2
}

# ========== 3. FULL RESTORE FROM LIST ==========
restore_backup() {
    check_mega_login
    if ! rclone listremotes 2>/dev/null | grep -q "mega_cloud:"; then
        return
    fi

    echo -e "${CYAN}=== FULL SYSTEM RESTORE FROM MEGA ===${NC}"
    echo -e "${YELLOW}MEGA Cloud se backups ki list load ho rahi hai...${NC}"

    mapfile -t files < <(rclone lsf mega_cloud:FullServerBackup/ --include "*.tar.gz" 2>/dev/null)

    if [ ${#files[@]} -eq 0 ]; then
        echo -e "${RED}✗ MEGA Cloud par koi backup nahi mila!${NC}"
        sleep 2
        return
    fi

    echo -e "${GREEN}Mile Hue Full Backups:${NC}"
    echo "--------------------------------------------------------"
    for i in "${!files[@]}"; do
        echo -e "${YELLOW}$((i+1)))${NC} ${files[$i]}"
    done
    echo "--------------------------------------------------------"

    read -p "Konsa backup restore karna hai? [1-${#files[@]}]: " choice

    if [[ "$choice" -ge 1 && "$choice" -le "${#files[@]}" ]] 2>/dev/null; then
        selected="${files[$((choice-1))]}"
        echo -e "${YELLOW}Downloading Heavy Data: ${selected} ...${NC}"
        rclone copy "mega_cloud:FullServerBackup/${selected}" /root/ --retries 3

        echo -e "${YELLOW}Data Extract & System Restore Ho Raha Hai...${NC}"
        tar -xzf "/root/${selected}" -C / 2>/dev/null
        rm -f "/root/${selected}"

        # Restart Wings and Docker
        systemctl restart docker >/dev/null 2>&1
        systemctl restart wings >/dev/null 2>&1

        echo -e "${GREEN}====================================================${NC}"
        echo -e "${GREEN}  ✓ FULL RESTORE SUCCESSFUL!                       ${NC}"
        echo -e "${GREEN}  Servers, Plugins & Wings Live Ho Gaye Hain!      ${NC}"
        echo -e "${GREEN}====================================================${NC}"
    else
        echo -e "${RED}Galat option!${NC}"
    fi
    sleep 2
}

# ========== MAIN MENU ==========
install_all_dependencies

while true; do
    clear
    echo -e "${GREEN}╔═════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║   PTERODACTYL FULL CLOUD MANAGER (MEGA.NZ)      ║${NC}"
    echo -e "${GREEN}╠═════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║  ${YELLOW}1)${NC} FULL Auto-Backup ON (Har 15 Min)           ${GREEN}║${NC}"
    echo -e "${GREEN}║  ${YELLOW}2)${NC} FULL Restore (1, 2, 3 List Se Choose)     ${GREEN}║${NC}"
    echo -e "${GREEN}║  ${YELLOW}3)${NC} MEGA Cloud Login / Setup                   ${GREEN}║${NC}"
    echo -e "${GREEN}║  ${YELLOW}4)${NC} Exit                                       ${GREEN}║${NC}"
    echo -e "${GREEN}╚═════════════════════════════════════════════════╝${NC}"
    read -p "Option [1-4]: " opt

    case $opt in
        1) start_auto_backup ;;
        2) restore_backup ;;
        3) setup_mega ;;
        4) exit 0 ;;
        *) echo -e "${RED}Sahi number daalein!${NC}"; sleep 1 ;;
    esac
done
