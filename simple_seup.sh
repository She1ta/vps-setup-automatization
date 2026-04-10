#!/bin/bash
LOG_FILE="/var/log/vps_setup.log"
USER_NAME=$1

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' 

function status_working() { echo -ne "  [ .. ] $1..."; }
function status_success() { echo -e "\r  [ ${GREEN}SUCCESS${NC} ] $1                                "; }
function status_error()   { echo -e "\r  [  ${RED}FAIL${NC}   ] $1. Check log: $LOG_FILE              "; exit 1; }

[[ -z "$USER_NAME" ]] && { echo -e "${RED}Error: Provide a username (e.g., ./setup.sh admin)${NC}"; exit 1; }
[[ "$EUID" -ne 0 ]] && { echo -e "${RED}Error: Run as root${NC}"; exit 1; }
true > "$LOG_FILE"

echo -e "\n${BLUE}==========================================================${NC}"
echo -e "${BLUE}  SIMPLIFIED VPS DEPLOYMENT ${NC}"
echo -e "${BLUE}==========================================================${NC}"

status_working "Upgrading System & Installing Headers"
source /etc/os-release
{
    apt-get update
    apt-get full-upgrade -y
    if [[ "$ID" == "ubuntu" ]]; then
        apt-get install -y linux-image-generic linux-headers-generic
    elif [[ "$ID" == "debian" ]]; then
        apt-get install -y linux-image-amd64 linux-headers-amd64
    fi
} >> "$LOG_FILE" 2>&1 && status_success "System & Headers Updated" || status_error "System Update Failed"
status_working "Creating User & Hardening SSH"
{
    USER_PASS=$(openssl rand -base64 16)
    useradd -m -s /bin/bash "$USER_NAME"
    echo "$USER_NAME:$USER_PASS" | chpasswd
    usermod -aG sudo "$USER_NAME"
    
    mkdir -p /home/"$USER_NAME"/.ssh
    ssh-keygen -t ed25519 -N "" -f /home/"$USER_NAME"/.ssh/id_ed25519
    cat /home/"$USER_NAME"/.ssh/id_ed25519.pub > /home/"$USER_NAME"/.ssh/authorized_keys
    PRIVATE_KEY=$(cat /home/"$USER_NAME"/.ssh/id_ed25519)
    
    chown -R "$USER_NAME":"$USER_NAME" /home/"$USER_NAME"/.ssh
    chmod 700 /home/"$USER_NAME"/.ssh
    chmod 600 /home/"$USER_NAME"/.ssh/authorized_keys

    SSH_PORT=$(shuf -i 5000-65535 -n 1)
    SSHD_CONFIG="/etc/ssh/sshd_config"
    cp $SSHD_CONFIG "${SSHD_CONFIG}.bak"

    sed -i 's/^#\?Port.*/Port '$SSH_PORT'/' $SSHD_CONFIG
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' $SSHD_CONFIG
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' $SSHD_CONFIG
    sed -i 's/^#\?LogLevel.*/LogLevel VERBOSE/' $SSHD_CONFIG

    cat <<EOT >> $SSHD_CONFIG
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com
EOT

    systemctl restart ssh
} >> "$LOG_FILE" 2>&1 && status_success "SSH Hardened on Port $SSH_PORT" || status_error "SSH Setup Failed"
status_working "Configuring Firewall (UFW)"
{
    apt-get install -y ufw
    ufw default deny incoming
    ufw default allow outgoing
    ufw limit $SSH_PORT/tcp
    ufw allow 60000:61000/udp
    ufw --force enable
} >> "$LOG_FILE" 2>&1 && status_success "Firewall Active" || status_error "Firewall Failed"

status_working "Installing AmneziaWG"
{
    if [[ "$ID" == "ubuntu" ]]; then
        add-apt-repository -y ppa:amnezia/ppa
        apt-get update
        apt-get install -y amneziawg amneziawg-tools
    elif [[ "$ID" == "debian" ]]; then
        apt-get install -y gnupg curl dkms
        mkdir -p /etc/apt/keyrings
        curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x75C9DD72C799870E310542E24166F2C257290828" | gpg --dearmor --yes -o /etc/apt/keyrings/amneziawg.gpg
        echo "deb [signed-by=/etc/apt/keyrings/amneziawg.gpg] https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu focal main" > /etc/apt/sources.list.d/amneziawg.list
        apt-get update
        apt-get install -y amneziawg amneziawg-tools
    fi
    modprobe amneziawg
} >> "$LOG_FILE" 2>&1 && status_success "AmneziaWG Installed" || status_error "AmneziaWG Failed"
status_working "Finalizing Maintenance & Terminal Colors"
{
    apt-get install -y fail2ban unattended-upgrades git btop haveged

    # Terminal Colors Setup (Cyan User, Yellow Directory)
    BASHRC_SNIPPET="
alias ll='ls -alF --color=auto'
alias update='sudo apt update && sudo apt upgrade -y'
export PS1='\[\e[1;36m\]\u@\h\[\e[m\]:\[\e[1;33m\]\w\[\e[m\]\$ '
"
    echo "$BASHRC_SNIPPET" >> /home/"$USER_NAME"/.bashrc
    echo "$BASHRC_SNIPPET" >> /root/.bashrc

    ROOT_PASS=$(openssl rand -base64 16)
    echo "root:$ROOT_PASS" | chpasswd
} >> "$LOG_FILE" 2>&1 && status_success "Maintenance & Colors Configured" || status_error "Maintenance Config Failed"

clear
echo -e "\n${BLUE}==========================================================${NC}"
echo -e "${GREEN}  VPS DEPLOYED SUCCESSFULLY ${NC}"
echo -e "${BLUE}==========================================================${NC}"
echo -e "  SSH Port:      ${YELLOW}$SSH_PORT${NC}"
echo -e "  Admin User:    ${YELLOW}$USER_NAME${NC}"
echo -e "  Admin Pass:    ${YELLOW}$USER_PASS${NC}"
echo -e "  Root Password: ${YELLOW}$ROOT_PASS${NC}"
echo -e "\n${YELLOW}SAVE THIS PRIVATE KEY TO YOUR PC AS vps.key:${NC}"
echo -e "${BLUE}----------------------------------------------------------${NC}"
echo "$PRIVATE_KEY"
echo -e "${BLUE}----------------------------------------------------------${NC}"
echo -e "\n${RED}REBOOTING IN 5 SECONDS TO APPLY CHANGES...${NC}"
sleep 5
reboot
