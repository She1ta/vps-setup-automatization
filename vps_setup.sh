#!/bin/bash

# --- Configuration & Colors ---
LOG_FILE="/var/log/vps_setup.log"
USER_NAME=$1

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' 
CHECK="✓"
CROSS="✘"

# --- Helper Functions ---
function print_header() {
    echo -e "\n${BLUE}==========================================================${NC}"
    echo -e "${BLUE}  $1 ${NC}"
    echo -e "${BLUE}==========================================================${NC}"
}

function status_working() {
    echo -ne "  [ ${YELLOW}WORKING${NC} ] $1..."
}

function status_success() {
    echo -e "\r  [  ${GREEN}${CHECK}${NC}  ] ${GREEN}SUCCESS${NC}: $1"
}

function status_error() {
    echo -e "\r  [  ${RED}${CROSS}${NC}  ] ${RED}ERROR${NC}: $1"
    echo -e "      Check $LOG_FILE for details."
}

# --- Pre-flight Checks ---
if [ -z "$USER_NAME" ]; then
    echo -e "${RED}Usage: sudo $0 <username>${NC}"
    exit 1
fi

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run as root (sudo)${NC}"
    exit 1
fi

# Initialize Log
true > "$LOG_FILE"

print_header "STARTING ULTIMATE VPS HARDENING"

# 1. OS Detection & Update
status_working "Detecting OS & Updating Packages"
source /etc/os-release
OS=$ID
apt-get update >> "$LOG_FILE" 2>&1
apt-get full-upgrade -y >> "$LOG_FILE" 2>&1
if [[ "$OS" == "ubuntu" ]]; then
    apt-get install -y linux-image-generic linux-headers-generic >> "$LOG_FILE" 2>&1
elif [[ "$OS" == "debian" ]]; then
    apt-get install -y linux-image-amd64 linux-headers-amd64 >> "$LOG_FILE" 2>&1
fi
status_success "OS: $PRETTY_NAME | System Updated"

# 2. Localization, Swap & Safety
status_working "Configuring Timezone, Swap & System Safety"
timedatectl set-timezone Asia/Ashkhabad >> "$LOG_FILE" 2>&1
apt-get install -y ntp >> "$LOG_FILE" 2>&1
fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab
systemctl mask ctrl-alt-del.target >> "$LOG_FILE" 2>&1
status_success "Timezone set, 2GB Swap active, Ctrl-Alt-Del masked"

# 3. User Creation & SSH Key Generation
status_working "Creating User & Generating Ed25519 Keys"
USER_PASS=$(openssl rand -base64 16)
useradd -m -s /bin/bash "$USER_NAME"
echo "$USER_NAME:$USER_PASS" | chpasswd
usermod -aG sudo "$USER_NAME"
mkdir -p /home/"$USER_NAME"/.ssh
ssh-keygen -t ed25519 -N "" -f /home/"$USER_NAME"/.ssh/id_ed25519 >> "$LOG_FILE" 2>&1
cat /home/"$USER_NAME"/.ssh/id_ed25519.pub > /home/"$USER_NAME"/.ssh/authorized_keys
PRIVATE_KEY=$(cat /home/"$USER_NAME"/.ssh/id_ed25519)
chown -R "$USER_NAME":"$USER_NAME" /home/"$USER_NAME"/.ssh
chmod 700 /home/"$USER_NAME"/.ssh
chmod 600 /home/"$USER_NAME"/.ssh/authorized_keys
status_success "User $USER_NAME created with SSH Keys"

# 4. SSH & Mosh Hardening
status_working "Configuring SSH (Random Port) & Mosh"
SSH_PORT=$(shuf -i 5000-65535 -n 1)
apt-get install -y mosh >> "$LOG_FILE" 2>&1
SSHD_CONFIG="/etc/ssh/sshd_config"
BANNER_FILE="/etc/ssh/banner.txt"
echo "WARNING: Authorized Access Only. All actions logged." > $BANNER_FILE
cp $SSHD_CONFIG "${SSHD_CONFIG}.bak"
sed -i "s/^#\?Port.*/Port $SSH_PORT/" $SSHD_CONFIG
sed -i "s/^#\?Banner.*/Banner $BANNER_FILE/" $SSHD_CONFIG
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' $SSHD_CONFIG
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' $SSHD_CONFIG
sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' $SSHD_CONFIG
systemctl restart ssh >> "$LOG_FILE" 2>&1
status_success "SSH secured on Port $SSH_PORT (Passwords Disabled)"

# 5. Firewall (UFW) & ICMP Drop
status_working "Setting up UFW, ICMP Drop & Rate Limiting"
apt-get install -y ufw >> "$LOG_FILE" 2>&1
BEFORE_RULES="/etc/ufw/before.rules"
sed -i 's/icmp-type destination-unreachable -j ACCEPT/icmp-type destination-unreachable -j DROP/' $BEFORE_RULES
sed -i 's/icmp-type echo-request -j ACCEPT/icmp-type echo-request -j DROP/' $BEFORE_RULES
sed -i 's/icmp-type time-exceeded -j ACCEPT/icmp-type time-exceeded -j DROP/' $BEFORE_RULES
sed -i 's/icmp-type parameter-problem -j ACCEPT/icmp-type parameter-problem -j DROP/' $BEFORE_RULES
sed -i 's/icmp-type source-quench -j ACCEPT/icmp-type source-quench -j DROP/' $BEFORE_RULES
ufw default deny incoming >> "$LOG_FILE" 2>&1
ufw default allow outgoing >> "$LOG_FILE" 2>&1
ufw limit $SSH_PORT/tcp >> "$LOG_FILE" 2>&1
ufw allow 60000:61000/udp >> "$LOG_FILE" 2>&1
ufw --force enable >> "$LOG_FILE" 2>&1
status_success "Firewall Active with Stealth ICMP & Mosh Support"

# 6. Security Apps (Fail2Ban, Unattended Upgrades, Haveged)
status_working "Installing Security Apps (Fail2Ban, Entropy, Auto-patch)"
apt-get install -y fail2ban unattended-upgrades haveged >> "$LOG_FILE" 2>&1
systemctl enable haveged >> "$LOG_FILE" 2>&1
cat <<EOT > /etc/fail2ban/jail.local
[sshd]
enabled = true
port = $SSH_PORT
maxretry = 3
bantime = 1h
EOT
systemctl restart fail2ban >> "$LOG_FILE" 2>&1
echo 'APT::Periodic::Update-Package-Lists "1";' > /etc/apt/apt.conf.d/20auto-upgrades
echo 'APT::Periodic::Unattended-Upgrade "1";' >> /etc/apt/apt.conf.d/20auto-upgrades
status_success "Security Apps active (Haveged entropy enabled)"

# 7. Sysctl Tweaks (BBR + Panic Reboot)
status_working "Optimizing Kernel (BBR & Panic Recovery)"
curl -s https://raw.githubusercontent.com/klaver/sysctl/refs/heads/master/sysctl.conf -o /tmp/sysctl_base
sed -i '/net.ipv4.ip_local_port_range/d' /tmp/sysctl_base
sed -i '/kernel.exec-shield/d' /tmp/sysctl_base
sed -i '/kernel.maps_protect/d' /tmp/sysctl_base
sed -i '/net.ipv4.tcp_tw_recycle/d' /tmp/sysctl_base
cat <<EOT >> /tmp/sysctl_base
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
kernel.panic = 10
kernel.panic_on_oops = 1
net.ipv4.conf.all.log_martians = 1
EOT
mv /tmp/sysctl_base /etc/sysctl.conf
sysctl -p >> "$LOG_FILE" 2>&1
status_success "Network & Kernel recovery optimized"

# 8. Docker, Log Rotation & Auto-Prune
status_working "Installing Docker & Setting up Log Rotation"
curl -sSL https://get.docker.com | sh >> "$LOG_FILE" 2>&1
usermod -aG docker "$USER_NAME"
chmod 660 /var/run/docker.sock
cat <<EOT > /etc/docker/daemon.json
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOT
systemctl restart docker >> "$LOG_FILE" 2>&1
(crontab -l 2>/dev/null; echo "0 3 * * 0 /usr/bin/docker system prune -af --volumes") | crontab -
status_success "Docker ready with Log Rotation & Weekly Pruning"

# 9. Utils (btop, git)
status_working "Installing Utilities (btop, git)"
apt-get install -y git btop >> "$LOG_FILE" 2>&1
status_success "Utilities installed"

# 10. AmneziaWG
status_working "Installing AmneziaWG Kernel Module"
if [[ ${OS} == 'ubuntu' ]]; then
    apt-get install -y software-properties-common >> "$LOG_FILE" 2>&1
    add-apt-repository -y ppa:amnezia/ppa >> "$LOG_FILE" 2>&1
    apt-get update >> "$LOG_FILE" 2>&1
    apt-get install -y "linux-headers-$(uname -r)" dkms amneziawg amneziawg-tools >> "$LOG_FILE" 2>&1
elif [[ ${OS} == 'debian' ]]; then
    apt-get install -y gnupg curl dkms "linux-headers-$(uname -r)" >> "$LOG_FILE" 2>&1
    mkdir -p /etc/apt/keyrings
    curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x75C9DD72C799870E310542E24166F2C257290828" | gpg --dearmor > /etc/apt/keyrings/amneziawg.gpg
    echo "deb[signed-by=/etc/apt/keyrings/amneziawg.gpg] https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu focal main" > /etc/apt/sources.list.d/amneziawg.list
    apt-get update >> "$LOG_FILE" 2>&1
    apt-get install -y amneziawg amneziawg-tools >> "$LOG_FILE" 2>&1
fi
dkms autoinstall -k "$(uname -r)" >> "$LOG_FILE" 2>&1
depmod -a >> "$LOG_FILE" 2>&1
modprobe amneziawg >> "$LOG_FILE" 2>&1
status_success "AmneziaWG Module Loaded"

# 11. Final Cleanup & Root Pass
status_working "Finalizing Setup"
ROOT_PASS=$(openssl rand -base64 16)
echo "root:$ROOT_PASS" | chpasswd
apt-get autoremove -y >> "$LOG_FILE" 2>&1
status_success "Setup Complete"

# --- Final Output ---
clear
print_header "VPS FORTRESS INITIALIZED"
echo -e "  ${GREEN}${CHECK}${NC} SSH Port:      ${BLUE}$SSH_PORT${NC}"
echo -e "  ${GREEN}${CHECK}${NC} Mosh:          ${BLUE}Enabled (UDP 60000-61000)${NC}"
echo -e "  ${GREEN}${CHECK}${NC} Admin User:    ${BLUE}$USER_NAME${NC}"
echo -e "  ${GREEN}${CHECK}${NC} Root Password: ${BLUE}$ROOT_PASS${NC}"
echo -e "  ${GREEN}${CHECK}${NC} Log File:      ${BLUE}$LOG_FILE${NC}"
echo -e "\n${YELLOW}!!! COPY THIS PRIVATE KEY TO A FILE ON YOUR PC (e.g. vps.key) !!!${NC}"
echo -e "${BLUE}----------------------------------------------------------${NC}"
echo "$PRIVATE_KEY"
echo -e "${BLUE}----------------------------------------------------------${NC}"
echo -e "\n${YELLOW}TO CONNECT:${NC}"
echo -e "ssh -i vps.key $USER_NAME@your_ip -p $SSH_PORT"
echo -e "\n${RED}REBOOT YOUR VPS NOW TO APPLY KERNEL UPDATES!${NC}"
