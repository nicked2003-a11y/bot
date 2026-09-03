#!/bin/bash

# Colors
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
    
    # Docker start & enable
    systemctl start docker >/dev/null 2>&1
    systemctl enable docker >/dev/null 2>&1

    # Wings install
    if [ ! -f /usr/local/bin/wings ]; then
        mkdir -p /etc/pterodactyl /var/lib/pterodactyl
        curl -L -o /usr/local/bin/wings "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_amd64" >/dev/null 2>&1
        chmod u+x /usr/local/bin/wings
    fi
    echo -e "${GREEN}✓ Sabhi tools ready hain!${NC}\n"
}

# 1. Blomp Login Setup (100% FIXED)
setup_blomp() {
    echo -e "${CYAN}======================================${NC}"
    echo -e "${CYAN}      BLOMP CLOUD LOGIN SETUP         ${NC}"
    echo -e "${CYAN}======================================${NC}"
    
    read -p "Blomp Registered Email: " blomp_user
    read -p "Blomp Password: " blomp_pass
    echo ""

    echo -e "${YELLOW}Configuring Blomp for Rclone...${NC}"

    mkdir -p ~/.config/rclone/
    
    # Direct Exact Swift Config for Blomp
    cat <<EOF > ~/.config/rclone/rclone.conf
[blomp]
type = swift
user = ${blomp_user}
key = ${blomp_pass}
auth = https://authenticate.blomp.com
auth_version = 1
EOF

    echo -e "${YELLOW}Connection Test Ho Raha Hai...${NC}"
    
    # Test Connection
    if rclone lsf blomp: >/dev/null 2>&1; then
        echo -e "${GREEN}======================================${NC}"
        echo -e "${GREEN}✓ SUCCESS: Blomp Cloud Connect Ho Gaya!${NC}"
        echo -e "${GREEN}======================================${NC}"
        rclone mkdir blomp:FullServerBackup >/dev/null 2>&1
    else
        echo -e "${RED}======================================${NC}"
        echo -e "${RED}✗ LOGIN FAIL! Error Detail Neeche Dekhein:${NC}"
        echo -e "${RED}======================================${NC}"
        rclone lsf blomp:
        echo -e "${YELLOW}--------------------------------------${NC}"
        echo -e "${YELLOW}Note: Agar Blomp par Password badla hai ya Email galat hai to check karein.${NC}"
        rm -f ~/.config/rclone/rclone.conf
    fi
    echo ""
    read -p "Enter dabayein Continue karne ke liye..." temp
}

# Check Blomp Login Status
check_blomp_login() {
    if ! rclone listremotes 2>/dev/null | grep -q "blomp:"; then
        echo -e "${YELLOW}Pehle Blomp Login karna zaroori hai!${NC}"
        setup_blomp
    fi
}

# 2. Full Auto Backup (Har 15 Min)
start_auto_backup() {
    check_blomp_login
    
    if ! rclone listremotes 2>/dev/null | grep -q "blomp:"; then
        return
    fi

    echo -e "${CYAN}======================================${NC}"
    echo -e "${CYAN}   FULL AUTO BACKUP SETUP (Har 15 Min) ${NC}"
    echo -e "${CYAN}======================================${NC}"

    cat << 'EOF' > /root/do_full_backup.sh
#!/bin/bash
TIME=$(date +%Y-%m-%d_%H-%M)
FILE="FULL_BACKUP_${TIME}.tar.gz"

# Pack EVERYTHING
tar -czf "/root/${FILE}" /var/lib/pterodactyl /etc/pterodactyl /etc/letsencrypt 2>/dev/null

# Upload to Blomp
rclone copy "/root/${FILE}" blomp:FullServerBackup/

# Delete local copy
rm -f "/root/${FILE}"
EOF

    chmod +x /root/do_full_backup.sh

    crontab -l 2>/dev/null | grep -v "do_full_backup" | crontab -
    (crontab -l 2>/dev/null; echo "*/15 * * * * /root/do_full_backup.sh >/dev/null 2>&1") | crontab -

    echo -e "${GREEN}✓ FULL Auto Backup Active (Har 15 min).${NC}"
    echo -e "${YELLOW}Pehla Full Backup abhi lia ja raha hai...${NC}"
    /root/do_full_backup.sh
    echo -e "${GREEN}✓ Full Backup Blomp par successfully Upload ho gaya!${NC}"
    sleep 2
}

# 3. Full Restore Backup from List
restore_backup() {
    check_blomp_login

    if ! rclone listremotes 2>/dev/null | grep -q "blomp:"; then
        return
    fi

    echo -e "${CYAN}======================================${NC}"
    echo -e "${CYAN}   FULL SYSTEM RESTORE FROM BLOMP     ${NC}"
    echo -e "${CYAN}======================================${NC}"
    echo -e "${YELLOW}Backups list load ho rahi hai...${NC}"

    mapfile -t files < <(rclone lsf blomp:FullServerBackup/ --include "*.tar.gz" 2>/dev/null)

    if [ ${#files[@]} -eq 0 ]; then
        echo -e "${RED}✗ Blomp Cloud par koi backup nahi mila!${NC}"
        sleep 2
        return
    fi

    echo -e "${GREEN}Mile hue Backups:${NC}"
    echo "--------------------------------------------------------"
    for i in "${!files[@]}"; do
        echo -e "${YELLOW}$((i+1)))${NC} ${files[$i]}"
    done
    echo "--------------------------------------------------------"
    
    read -p "Konsa Backup Restore karna hai? [1-${#files[@]}]: " choice

    if [[ "$choice" -ge 1 && "$choice" -le "${#files[@]}" ]] 2>/dev/null; then
        selected="${files[$((choice-1))]}"
        echo -e "\n${YELLOW}Downloading: ${selected} ...${NC}"
        rclone copy "blomp:FullServerBackup/${selected}" /root/

        echo -e "${YELLOW}Extracting & Restoring...${NC}"
        tar -xzf "/root/${selected}" -C / 2>/dev/null
        rm -f "/root/${selected}"

        systemctl restart docker >/dev/null 2>&1
        systemctl restart wings >/dev/null 2>&1

        echo -e "${GREEN}====================================================${NC}"
        echo -e "${GREEN}  ✓ FULL RESTORE SUCCESSFUL!                       ${NC}"
        echo -e "${GREEN}====================================================${NC}"
    else
        echo -e "${RED}Galat option chuna!${NC}"
    fi
    sleep 2
}

# Main Execution Flow
install_all_dependencies

while true; do
    clear
    echo -e "${GREEN}╔═════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  PTERODACTYL & MINECRAFT FULL CLOUD MANAGER v3  ║${NC}"
    echo -e "${GREEN}╠═════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║                                                 ║${NC}"
    echo -e "${GREEN}║  ${YELLOW}1)${NC} FULL Auto-Backup ON (Har 15 Minutes)       ║${NC}"
    echo -e "${GREEN}║  ${YELLOW}2)${NC} FULL Restore (1, 2, 3 List Se Choose)     ║${NC}"
    echo -e "${GREEN}║  ${YELLOW}3)${NC} Blomp Cloud Login / Setup                 ║${NC}"
    echo -e "${GREEN}║  ${YELLOW}4)${NC} Exit                                          ║${NC}"
    echo -e "${GREEN}║                                                 ║${NC}"
    echo -e "${GREEN}╚═════════════════════════════════════════════════╝${NC}"
    read -p "Option chunein [1-4]: " opt

    case $opt in
        1) start_auto_backup ;;
        2) restore_backup ;;
        3) setup_blomp ;;
        4) echo "Goodbye!"; exit 0 ;;
        *) echo -e "${RED}Sahi number daalein!${NC}"; sleep 1 ;;
    esac
done
