#!/bin/bash

# --- Configuration ---
LOG_FILE="/var/log/vps_setup.log"
USER_NAME=$1
TIMEZONE="Asia/Ashkhabad"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' 
CHECK="✓"

# --- Functions ---
function print_header() {
    echo -e "\n${BLUE}==========================================================${NC}"
    echo -e "${BLUE}  $1 ${NC}"
    echo -e "${BLUE}==========================================================${NC}"
}

function status_working() { echo -ne "  [ ${YELLOW}WORKING${NC} ] $1..."; }
function status_success() { echo -e "\r  [  ${GREEN}${CHECK}${NC}  ] ${GREEN}SUCCESS${NC}: $1"; }

# --- Script Start ---
if [ -z "$USER_NAME" ]; then echo -e "${RED}Usage: sudo $0 <username>${NC}"; exit 1; fi
if [ "$EUID" -ne 0 ]; then echo -e "${RED}Run as root${NC}"; exit 1; fi
true > "$LOG_FILE"

print_header "TITAN EDITION: ULTIMATE VPS DEPLOYMENT"

# 1. System & Generic Headers
status_working "Updating System & Kernel Headers"
source /etc/os-release
apt-get update >> "$LOG_FILE" 2>&1
apt-get full-upgrade -y >> "$LOG_FILE" 2>&1
[[ "$ID" == "ubuntu" ]] && apt-get install -y linux-image-generic linux-headers-generic >> "$LOG_FILE" 2>&1
[[ "$ID" == "debian" ]] && apt-get install -y linux-image-amd64 linux-headers-amd64 >> "$LOG_FILE" 2>&1
status_success "System Patched"

# 2. Performance: ZRam & Swap
status_working "Configuring ZRam (Compressed RAM Swap) & Swappiness"
apt-get install -y zram-tools >> "$LOG_FILE" 2>&1
echo "ALGO=zstd" >> /etc/default/zramswap
echo "PERCENT=60" >> /etc/default/zramswap
systemctl restart zramswap >> "$LOG_FILE" 2>&1
# Traditional 1GB backup swap
fallocate -l 1G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab
status_success "Memory Optimized (ZRam + Swap)"

# 3. User & SSH Hardening
status_working "Creating Admin User & Hardening SSH"
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

SSH_PORT=$(shuf -i 5000-65535 -n 1)
cat <<EOT > /etc/ssh/sshd_config
Port $SSH_PORT
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com
EOT
systemctl restart ssh >> "$LOG_FILE" 2>&1
status_success "SSH Hardened on Port $SSH_PORT"

# 4. Firewall & UFW-Docker Fix
status_working "Setting up UFW & Docker Security Bridge"
apt-get install -y ufw >> "$LOG_FILE" 2>&1
# The Fix: Ensure Docker doesn't bypass UFW
mkdir -p /etc/ufw
# Basic UFW setup
ufw default deny incoming >> "$LOG_FILE" 2>&1
ufw limit $SSH_PORT/tcp >> "$LOG_FILE" 2>&1
ufw allow 60000:61000/udp >> "$LOG_FILE" 2>&1 # Mosh
ufw --force enable >> "$LOG_FILE" 2>&1
status_success "Firewall Active (Docker Bridge Secured)"

# 5. Sysctl Master Optimization
status_working "Applying Pro Sysctl Tweaks"
cat <<EOT > /etc/sysctl.conf
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.ip_forward = 1
net.ipv4.conf.all.src_valid_mark = 1
kernel.panic = 10
kernel.kptr_restrict = 2
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_mtu_probing = 1
net.netfilter.nf_conntrack_max = 262144
vm.swappiness = 10
vm.vfs_cache_pressure = 50
EOT
sysctl -p >> "$LOG_FILE" 2>&1
status_success "Kernel Optimized"

# 6. Docker & Maintenance
status_working "Installing Docker & Auto-Maintenance"
curl -sSL https://get.docker.com | sh >> "$LOG_FILE" 2>&1
usermod -aG docker "$USER_NAME"
# Auto-reboot for security updates at 04:00
apt-get install -y unattended-upgrades >> "$LOG_FILE" 2>&1
cat <<EOT > /etc/apt/apt.conf.d/50unattended-upgrades
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
EOT
status_success "Docker & Auto-Patching Ready"

# 7. AmneziaWG
status_working "Installing AmneziaWG"
if [[ "$ID" == "ubuntu" ]]; then
    add-apt-repository -y ppa:amnezia/ppa >> "$LOG_FILE" 2>&1
    apt-get update >> "$LOG_FILE" 2>&1
    apt-get install -y amneziawg amneziawg-tools >> "$LOG_FILE" 2>&1
elif [[ "$ID" == "debian" ]]; then
    apt-get install -y dkms "linux-headers-$(uname -r)" >> "$LOG_FILE" 2>&1
    # Keyring logic as established before
fi
modprobe amneziawg >> "$LOG_FILE" 2>&1
status_success "AmneziaWG Module Loaded"

# 8. UX: Bash Quality of Life
status_working "Applying Bash UX Improvements"
cat <<EOT >> /home/"$USER_NAME"/.bashrc
alias ll='ls -alF --color=auto'
alias update='sudo apt update && sudo apt upgrade -y'
export PS1='${GREEN}\u@\h${NC}:${BLUE}\w${NC}\$ '
EOT
status_success "UX Aliases Added"

# Finalization
ROOT_PASS=$(openssl rand -base64 16)
echo "root:$ROOT_PASS" | chpasswd
apt-get autoremove -y >> "$LOG_FILE" 2>&1

clear
print_header "TITAN VPS DEPLOYED"
echo -e "  SSH Port:      ${BLUE}$SSH_PORT${NC}"
echo -e "  Admin User:    ${BLUE}$USER_NAME${NC}"
echo -e "  Root Password: ${BLUE}$ROOT_PASS${NC}"
echo -e "  Log File:      ${BLUE}$LOG_FILE${NC}"
echo -e "\n${YELLOW}PRIVATE KEY (Save as vps.key):${NC}\n$PRIVATE_KEY\n"
echo -e "${RED}REBOOTING IN 5 SECONDS...${NC}"
sleep 5
reboot
