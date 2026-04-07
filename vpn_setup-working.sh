#!/bin/bash

# --- 1. CONFIGURATION & PRE-FLIGHT ---
LOG_FILE="/var/log/vps_setup.log"
USER_NAME=$1
TIMEZONE="Asia/Ashkhabad"

# Colors for visual markers
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' 
CHECK="✓"

function status_working() { echo -ne "  [ ${YELLOW}WORKING${NC} ] $1..."; }
function status_success() { echo -e "\r  [  ${GREEN}${CHECK}${NC}  ] ${GREEN}SUCCESS${NC}: $1"; }
function status_error() { echo -e "\r  [  ${RED}ERROR${NC}  ] $1. Check $LOG_FILE"; exit 1; }

# Basic Checks
[[ -z "$USER_NAME" ]] && { echo -e "${RED}Error: Provide a username (e.g., ./setup.sh admin)${NC}"; exit 1; }
[[ "$EUID" -ne 0 ]] && { echo -e "${RED}Error: Run as root${NC}"; exit 1; }
true > "$LOG_FILE"

print_header() {
    echo -e "\n${BLUE}==========================================================${NC}"
    echo -e "${BLUE}  $1 ${NC}"
    echo -e "${BLUE}==========================================================${NC}"
}

print_header "GOD-MODE VPS DEPLOYMENT: VERIFIED VERSION"

# --- 2. SYSTEM UPDATES & KERNEL ---
status_working "Upgrading System & Installing Meta-Headers"
source /etc/os-release
apt-get update >> "$LOG_FILE" 2>&1
apt-get full-upgrade -y >> "$LOG_FILE" 2>&1

if [[ "$ID" == "ubuntu" ]]; then
    apt-get install -y linux-image-generic linux-headers-generic >> "$LOG_FILE" 2>&1
elif [[ "$ID" == "debian" ]]; then
    apt-get install -y linux-image-amd64 linux-headers-amd64 >> "$LOG_FILE" 2>&1
fi
status_success "System & Headers Updated"

# --- 3. PERFORMANCE: ZRAM & RESOURCE LIMITS ---
status_working "Optimizing RAM (ZRam) & System Limits"
apt-get install -y zram-tools >> "$LOG_FILE" 2>&1
echo -e "ALGO=zstd\nPERCENT=60" > /etc/default/zramswap
systemctl restart zramswap >> "$LOG_FILE" 2>&1

# Raise file limits for high-load Docker/VPN
cat <<EOT > /etc/security/limits.d/99-godmode.conf
* soft nofile 65535
* hard nofile 65535
root soft nofile 65535
root hard nofile 65535
EOT
status_success "Resources Optimized"

# --- 4. USER & SSH (VERIFIED CIPHERS) ---
status_working "Creating User & Hardening SSH"
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
SSHD_CONFIG="/etc/ssh/sshd_config"
cp $SSHD_CONFIG "${SSHD_CONFIG}.bak"

# Apply hardening while keeping system includes
sed -i 's/^#\?Port.*/Port '$SSH_PORT'/' $SSHD_CONFIG
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' $SSHD_CONFIG
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' $SSHD_CONFIG
sed -i 's/^#\?LogLevel.*/LogLevel VERBOSE/' $SSHD_CONFIG

cat <<EOT >> $SSHD_CONFIG
# God-Mode Cipher Hardening
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com
EOT

systemctl restart ssh >> "$LOG_FILE" 2>&1
status_success "SSH Hardened on Port $SSH_PORT"

# --- 5. FIREWALL & DOCKER-UFW BRIDGE ---
status_working "Configuring UFW & Docker-Firewall Bridge"
apt-get install -y ufw >> "$LOG_FILE" 2>&1
# Install Docker-UFW Bridge
curl -s https://raw.githubusercontent.com/chaifeng/ufw-docker/master/ufw-docker -o /usr/local/bin/ufw-docker
chmod +x /usr/local/bin/ufw-docker
/usr/local/bin/ufw-docker install >> "$LOG_FILE" 2>&1

# Apply ICMP Drops to before.rules (Robust sed)
BEFORE_RULES="/etc/ufw/before.rules"
sed -i 's/-A ufw-before-input -p icmp --icmp-type echo-request -j ACCEPT/-A ufw-before-input -p icmp --icmp-type echo-request -j DROP/' $BEFORE_RULES
sed -i 's/-A ufw-before-input -p icmp --icmp-type destination-unreachable -j ACCEPT/-A ufw-before-input -p icmp --icmp-type destination-unreachable -j DROP/' $BEFORE_RULES

ufw default deny incoming >> "$LOG_FILE" 2>&1
ufw limit $SSH_PORT/tcp >> "$LOG_FILE" 2>&1
ufw allow 60000:61000/udp >> "$LOG_FILE" 2>&1
ufw --force enable >> "$LOG_FILE" 2>&1
status_success "Firewall Bridge Active"

# --- 6. SYSCTL GOD-MODE ---
status_working "Applying Advanced Sysctl Tweaks"
cat <<EOT > /etc/sysctl.d/99-godmode.conf
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_mtu_probing = 1
kernel.panic = 10
net.ipv4.ip_forward = 1
net.ipv4.conf.all.src_valid_mark = 1
net.netfilter.nf_conntrack_max = 262144
vm.swappiness = 180
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
EOT
sysctl --system >> "$LOG_FILE" 2>&1
status_success "Kernel Tuned"

# --- 7. DOCKER & AMNEZIAWG ---
status_working "Installing Docker & AmneziaWG"
curl -sSL https://get.docker.com | sh >> "$LOG_FILE" 2>&1
usermod -aG docker "$USER_NAME"

if [[ "$ID" == "ubuntu" ]]; then
    add-apt-repository -y ppa:amnezia/ppa >> "$LOG_FILE" 2>&1
    apt-get update >> "$LOG_FILE" 2>&1
    apt-get install -y amneziawg amneziawg-tools >> "$LOG_FILE" 2>&1
elif [[ "$ID" == "debian" ]]; then
    apt-get install -y gnupg curl dkms linux-headers-amd64 >> "$LOG_FILE" 2>&1
    mkdir -p /etc/apt/keyrings
    curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x75C9DD72C799870E310542E24166F2C257290828" | gpg --dearmor > /etc/apt/keyrings/amneziawg.gpg
    echo "deb[signed-by=/etc/apt/keyrings/amneziawg.gpg] https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu focal main" > /etc/apt/sources.list.d/amneziawg.list
    apt-get update >> "$LOG_FILE" 2>&1
    apt-get install -y amneziawg amneziawg-tools >> "$LOG_FILE" 2>&1
fi
modprobe amneziawg >> "$LOG_FILE" 2>&1
status_success "Services Installed"

# --- 8. LOGS, MAINTENANCE & UTILS ---
status_working "Finalizing Maintenance & Aliases"
apt-get install -y fail2ban unattended-upgrades git btop haveged >> "$LOG_FILE" 2>&1
# Cap Journald
echo -e "[Journal]\nSystemMaxUse=100M" > /etc/systemd/journald.conf.d/cap.conf
systemctl restart systemd-journald

# Bash Aliases for the new user
cat <<EOT >> /home/"$USER_NAME"/.bashrc
alias ll='ls -alF --color=auto'
alias update='sudo apt update && sudo apt upgrade -y'
export PS1='\[\e[32m\]\u@\h\[\e[m\]:\[\e[34m\]\w\[\e[m\]\$ '
EOT

ROOT_PASS=$(openssl rand -base64 16)
echo "root:$ROOT_PASS" | chpasswd
status_success "Maintenance Configured"

# --- 9. FINAL OUTPUT ---
clear
print_header "GOD-MODE VPS DEPLOYED SUCCESSFULLY"
echo -e "  ${GREEN}${CHECK}${NC} SSH Port:      ${BLUE}$SSH_PORT${NC}"
echo -e "  ${GREEN}${CHECK}${NC} Admin User:    ${BLUE}$USER_NAME${NC}"
echo -e "  ${GREEN}${CHECK}${NC} Root Password: ${BLUE}$ROOT_PASS${NC}"
echo -e "\n${YELLOW}SAVE THIS PRIVATE KEY TO YOUR PC AS vps.key:${NC}"
echo -e "${BLUE}----------------------------------------------------------${NC}"
echo "$PRIVATE_KEY"
echo -e "${BLUE}----------------------------------------------------------${NC}"
echo -e "\n${RED}REBOOTING IN 5 SECONDS TO APPLY KERNEL CHANGES...${NC}"
sleep 5
reboot
