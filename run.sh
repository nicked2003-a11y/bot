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

    # Wings install agar exist nahi karta
    if [ ! -f /usr/local/bin/wings ]; then
        mkdir -p /etc/pterodactyl /var/lib/pterodactyl/volumes
        curl -L -o /usr/local/bin/wings "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_amd64" >/dev/null 2>&1
        chmod u+x /usr/local/bin/wings
    fi
    echo -e "${GREEN}✓ Sabhi tools ready hain!${NC}\n"
}

# 1. Blomp Login Setup
setup_blomp() {
    echo -e "${CYAN}======================================${NC}"
    echo -e "${CYAN}      BLOMP CLOUD LOGIN SETUP         ${NC}"
    echo -e "${CYAN}======================================${NC}"
    read -p "Blomp Email: " blomp_user < /dev/tty
    read -s -p "Blomp Password: " blomp_pass < /dev/tty
    echo ""

    mkdir -p ~/.config/rclone/
    cat <<EOF > ~/.config/rclone/rclone.conf
[blomp]
type = swift
env_auth = false
user = ${blomp_user}
key = ${blomp_pass}
auth = https://authenticate.blomp.com
tenant = ${blomp_user}
auth_version = 1
EOF

    echo -e "${YELLOW}Connecting...${NC}"
    if rclone lsd blomp: >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Blomp Storage Successfully Connect Ho Gaya!${NC}"
    else
        echo -e "${RED}✗ Login Failed! Email/Password check karein.${NC}"
    fi
    sleep 2
}

# Check Blomp Login
check_blomp_login() {
    if ! rclone listremotes 2>/dev/null | grep -q "blomp:"; then
        echo -e "${RED}Pehle Blomp Login karna zaroori hai!${NC}"
        setup_blomp
    fi
}

# 2. Auto Backup (Every 15 mins)
start_auto_backup() {
    check_blomp_login
    echo -e "${CYAN}======================================${NC}"
    echo -e "${CYAN}   AUTO BACKUP SETUP (Har 15 Min)     ${NC}"
    echo -e "${CYAN}======================================${NC}"

    # Background auto-backup script
    cat << 'EOF' > /root/do_backup.sh
#!/bin/bash
TIME=$(date +%Y-%m-%d_%H-%M)
FILE="backup_${TIME}.tar.gz"

# Compress Pterodactyl Data
tar -czf "/root/${FILE}" /var/lib/pterodactyl/volumes /etc/pterodactyl 2>/dev/null

# Upload to Blomp Cloud
rclone copy "/root/${FILE}" blomp:MinecraftBackup/

# Remove local file
rm -f "/root/${FILE}"
EOF

    chmod +x /root/do_backup.sh

    # Setup 15-min cron
    crontab -l 2>/dev/null | grep -v "do_backup" | crontab -
    (crontab -l 2>/dev/null; echo "*/15 * * * * /root/do_backup.sh >/dev/null 2>&1") | crontab -

    echo -e "${GREEN}✓ Auto Backup Scheduler ON ho gaya hai (Har 15 min).${NC}"
    echo -e "${YELLOW}Abhi Pehla Backup lia ja raha hai (Wait karein)...${NC}"
    /root/do_backup.sh
    echo -e "${GREEN}✓ Pehla backup Blomp par save ho gaya!${NC}"
    sleep 2
}

# 3. Restore Backup from List
restore_backup() {
    check_blomp_login
    echo -e "${CYAN}======================================${NC}"
    echo -e "${CYAN}   BLOMP SE BACKUP RESTORE KAREIN     ${NC}"
    echo -e "${CYAN}======================================${NC}"
    echo -e "${YELLOW}Backups list load ho rahi hai...${NC}"

    mapfile -t files < <(rclone lsf blomp:MinecraftBackup/ --include "*.tar.gz" 2>/dev/null)

    if [ ${#files[@]} -eq 0 ]; then
        echo -e "${RED}✗ Blomp Cloud par koi backup nahi mila!${NC}"
        sleep 2
        return
    fi

    echo -e "${GREEN}Available Backups:${NC}"
    echo "----------------------------------------"
    for i in "${!files[@]}"; do
        echo -e "${YELLOW}$((i+1)))${NC} ${files[$i]}"
    done
    echo "----------------------------------------"
    
    read -p "Konsa backup restore karna hai? [1-${#files[@]}]: " choice < /dev/tty

    if [[ "$choice" -ge 1 && "$choice" -le "${#files[@]}" ]] 2>/dev/null; then
        selected="${files[$((choice-1))]}"
        echo -e "\n${YELLOW}Downloading: ${selected} ...${NC}"
        rclone copy "blomp:MinecraftBackup/${selected}" /root/

        echo -e "${YELLOW}Data Extract aur Wings mein Restore ho raha hai...${NC}"
        tar -xzf "/root/${selected}" -C / 2>/dev/null
        rm -f "/root/${selected}"

        # Restart Wings
        systemctl restart wings >/dev/null 2>&1

        echo -e "${GREEN}======================================${NC}"
        echo -e "${GREEN}  ✓ RESTORE 100% SUCCESSFUL!         ${NC}"
        echo -e "${GREEN}  Minecraft Server & Wings Online!    ${NC}"
        echo -e "${GREEN}======================================${NC}"
    else
        echo -e "${RED}Galat option chuna!${NC}"
    fi
    sleep 3
}

# Main Execution Flow
install_all_dependencies

while true; do
    clear
    echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║   PTERODACTYL & MINECRAFT CLOUD MANAGER  ║${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║                                          ║${NC}"
    echo -e "${GREEN}║  ${YELLOW}1)${NC} Auto-Backup ON (Har 15 Minutes)        ${GREEN}║${NC}"
    echo -e "${GREEN}║  ${YELLOW}2)${NC} Restore Backup (1, 2, 3 List)          ${GREEN}║${NC}"
    echo -e "${GREEN}║  ${YELLOW}3)${NC} Blomp Cloud Login / Re-login           ${GREEN}║${NC}"
    echo -e "${GREEN}║  ${YELLOW}4)${NC} Exit                                   ${GREEN}║${NC}"
    echo -e "${GREEN}║                                          ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
    read -p "Option chunein [1-4]: " opt < /dev/tty

    case $opt in
        1) start_auto_backup ;;
        2) restore_backup ;;
        3) setup_blomp ;;
        4) echo "Goodbye!"; exit 0 ;;
        *) echo -e "${RED}Sahi number daalein!${NC}"; sleep 1 ;;
    esac
done
