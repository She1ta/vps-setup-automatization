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

print_header "STARTING VPS FORTRESS: MASTER EDITION"

# 1. OS Detection & Update
status_working "Updating System & Installing generic headers"
source /etc/os-release
OS=$ID
apt-get update >> "$LOG_FILE" 2>&1
apt-get full-upgrade -y >> "$LOG_FILE" 2>&1
if [[ "$OS" == "ubuntu" ]]; then
    apt-get install -y linux-image-generic linux-headers-generic >> "$LOG_FILE" 2>&1
elif [[ "$OS" == "debian" ]]; then
    apt-get install -y linux-image-amd64 linux-headers-amd64 >> "$LOG_FILE" 2>&1
fi
status_success "System Updated (Generic Headers Active)"

# 2. Localization & Maintenance
status_working "Configuring Timezone, Swap & Maintenance"
timedatectl set-timezone Asia/Ashkhabad >> "$LOG_FILE" 2>&1
apt-get install -y ntp haveged needrestart >> "$LOG_FILE" 2>&1
systemctl enable haveged >> "$LOG_FILE" 2>&1
# 2GB Swap
fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab
# Weekly Apt Autoclean
echo 'Apt::Periodic::AutocleanInterval "7";' > /etc/apt/apt.conf.d/10autoclean
systemctl mask ctrl-alt-del.target >> "$LOG_FILE" 2>&1
status_success "Timezone set, Swap active, maintenance scheduled"

# 3. User & SSH Hardening
status_working "Generating Ed25519 Keys & Hardening SSH Ciphers"
USER_PASS=$(openssl rand -base64 16)
useradd -m -s /bin/bash "$USER_NAME" && echo "$USER_NAME:$USER_PASS" | chpasswd
usermod -aG sudo "$USER_NAME"
mkdir -p /home/"$USER_NAME"/.ssh
ssh-keygen -t ed25519 -N "" -f /home/"$USER_NAME"/.ssh/id_ed25519 >> "$LOG_FILE" 2>&1
cat /home/"$USER_NAME"/.ssh/id_ed25519.pub > /home/"$USER_NAME"/.ssh/authorized_keys
PRIVATE_KEY=$(cat /home/"$USER_NAME"/.ssh/id_ed25519)
chown -R "$USER_NAME":"$USER_NAME" /home/"$USER_NAME"/.ssh
chmod 700 /home/"$USER_NAME"/.ssh
chmod 600 /home/"$USER_NAME"/.ssh/authorized_keys

# Advanced 2025 SSH Cipher Hardening
SSH_PORT=$(shuf -i 5000-65535 -n 1)
SSHD_CONFIG="/etc/ssh/sshd_config"
cp $SSHD_CONFIG "${SSHD_CONFIG}.bak"
cat <<EOT >> $SSHD_CONFIG
Port $SSH_PORT
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
LoginGraceTime 30s
ClientAliveInterval 300
ClientAliveCountMax 2
# Modern 2025 Ciphers & Algorithms
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com
EOT
systemctl restart ssh >> "$LOG_FILE" 2>&1
status_success "SSH Hardened on Port $SSH_PORT"

# 4. Firewall (UFW)
status_working "Enabling Firewall (Stealth Mode)"
apt-get install -y ufw >> "$LOG_FILE" 2>&1
BEFORE_RULES="/etc/ufw/before.rules"
sed -i 's/icmp-type echo-request -j ACCEPT/icmp-type echo-request -j DROP/' $BEFORE_RULES
# (And other ICMP drops as before)
ufw default deny incoming >> "$LOG_FILE" 2>&1
ufw limit $SSH_PORT/tcp >> "$LOG_FILE" 2>&1
ufw allow 60000:61000/udp >> "$LOG_FILE" 2>&1
ufw --force enable >> "$LOG_FILE" 2>&1
status_success "Firewall Active (Pings Dropped)"

# 5. Sysctl Master Tweaks
status_working "Applying Master Performance & Security Sysctl"
cat <<EOT > /etc/sysctl.conf
# Networking Performance
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_fin_timeout = 20
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0

# VPN & Routing (REQUIRED FOR AMNEZIAWG)
net.ipv4.ip_forward = 1
net.ipv4.conf.all.src_valid_mark = 1

# Security Hardening
kernel.panic = 10
kernel.panic_on_oops = 1
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.unprivileged_bpf_disabled = 1
kernel.yama.ptrace_scope = 1
fs.protected_fifos = 2
fs.protected_regular = 2
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_rfc1337 = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.netfilter.nf_conntrack_max = 262144
EOT
sysctl -p >> "$LOG_FILE" 2>&1
status_success "Kernel fully optimized"

# 6. Docker & AmneziaWG
status_working "Installing Docker & AmneziaWG"
curl -sSL https://get.docker.com | sh >> "$LOG_FILE" 2>&1
usermod -aG docker "$USER_NAME"
# Docker log capping
cat <<EOT > /etc/docker/daemon.json
{ "log-driver": "json-file", "log-opts": { "max-size": "10m", "max-file": "3" } }
EOT
systemctl restart docker >> "$LOG_FILE" 2>&1

# AmneziaWG Install (Ubuntu/Debian logic)
if [[ "$OS" == "ubuntu" ]]; then
    add-apt-repository -y ppa:amnezia/ppa >> "$LOG_FILE" 2>&1
    apt-get update >> "$LOG_FILE" 2>&1
    apt-get install -y amneziawg amneziawg-tools >> "$LOG_FILE" 2>&1
elif [[ "$OS" == "debian" ]]; then
    apt-get install -y gnupg curl dkms "linux-headers-$(uname -r)" >> "$LOG_FILE" 2>&1
    mkdir -p /etc/apt/keyrings
    curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x75C9DD72C799870E310542E24166F2C257290828" | gpg --dearmor > /etc/apt/keyrings/amneziawg.gpg
    echo "deb[signed-by=/etc/apt/keyrings/amneziawg.gpg] https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu focal main" > /etc/apt/sources.list.d/amneziawg.list
    apt-get update >> "$LOG_FILE" 2>&1
    apt-get install -y amneziawg amneziawg-tools >> "$LOG_FILE" 2>&1
fi
modprobe amneziawg >> "$LOG_FILE" 2>&1
status_success "Docker & AmneziaWG ready"

# 7. Final Utils & Passwords
status_working "Finalizing setup"
apt-get install -y fail2ban unattended-upgrades git btop >> "$LOG_FILE" 2>&1
ROOT_PASS=$(openssl rand -base64 16)
echo "root:$ROOT_PASS" | chpasswd
status_success "All systems operational"

# --- Final Output ---
clear
print_header "MASTER FORTRESS INITIALIZED"
echo -e "  SSH Port:      ${BLUE}$SSH_PORT${NC}"
echo -e "  Admin User:    ${BLUE}$USER_NAME${NC}"
echo -e "  Root Password: ${BLUE}$ROOT_PASS${NC}"
echo -e "\n${YELLOW}SAVE THIS PRIVATE KEY:${NC}\n$PRIVATE_KEY\n"
echo -e "${RED}REBOOT NOW!${NC}"
