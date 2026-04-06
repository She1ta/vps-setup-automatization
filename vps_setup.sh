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
status_working "Configuring ZRam (Compressed RAM Swap)"
apt-get install -y zram-tools >> "$LOG_FILE" 2>&1
echo -e "ALGO=zstd\nPERCENT=60" > /etc/default/zramswap
systemctl restart zramswap >> "$LOG_FILE" 2>&1
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

# 4. Firewall (UFW)
status_working "Setting up Firewall & ICMP Drop"
apt-get install -y ufw >> "$LOG_FILE" 2>&1
BEFORE_RULES="/etc/ufw/before.rules"
# Apply ICMP Drop (Screenshot Logic)
sed -i 's/icmp-type destination-unreachable -j ACCEPT/icmp-type destination-unreachable -j DROP/' $BEFORE_RULES
sed -i 's/icmp-type echo-request -j ACCEPT/icmp-type echo-request -j DROP/' $BEFORE_RULES
sed -i 's/icmp-type time-exceeded -j ACCEPT/icmp-type time-exceeded -j DROP/' $BEFORE_RULES
sed -i 's/icmp-type parameter-problem -j ACCEPT/icmp-type parameter-problem -j DROP/' $BEFORE_RULES
sed -i 's/icmp-type source-quench -j ACCEPT/icmp-type source-quench -j DROP/' $BEFORE_RULES

ufw default deny incoming >> "$LOG_FILE" 2>&1
ufw limit $SSH_PORT/tcp >> "$LOG_FILE" 2>&1
ufw allow 60000:61000/udp >> "$LOG_FILE" 2>&1 # Mosh
ufw --force enable >> "$LOG_FILE" 2>&1
status_success "Firewall Active (Stealth Mode)"

# 5. THE MASTER SYSCTL (Categorized & Refined)
status_working "Applying Titan-Level Sysctl Optimizations"
cat <<EOT > /etc/sysctl.conf
# --- Network Core (BBR + Speed) ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1

# --- Network Memory (High Bandwidth/VPN) ---
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.core.netdev_max_backlog = 16384
net.core.somaxconn = 8192
net.ipv4.tcp_max_syn_backlog = 8192

# --- Virtual Memory (Stability & ZRam Optimization) ---
vm.swappiness = 180
vm.vfs_cache_pressure = 50
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5

# --- Security & Anti-Exploit ---
kernel.panic = 10
kernel.panic_on_oops = 1
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.perf_event_paranoid = 3
kernel.unprivileged_bpf_disabled = 1
kernel.yama.ptrace_scope = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.icmp_echo_ignore_all = 1

# --- IPv6 Hardening (Kept for AmneziaWG) ---
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.default.accept_ra = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# --- AmneziaWG & Docker Specifics ---
net.ipv4.ip_forward = 1
net.ipv4.conf.all.src_valid_mark = 1
net.netfilter.nf_conntrack_max = 262144
fs.file-max = 1000000
fs.inotify.max_user_watches = 524288
EOT
sysctl -p >> "$LOG_FILE" 2>&1
status_success "Kernel Optimizations Applied"

# 6. Docker, Maintenance & Utilities
status_working "Installing Docker, AmneziaWG & Utils"
curl -sSL https://get.docker.com | sh >> "$LOG_FILE" 2>&1
usermod -aG docker "$USER_NAME"
# Docker log capping
cat <<EOT > /etc/docker/daemon.json
{ "log-driver": "json-file", "log-opts": { "max-size": "10m", "max-file": "3" } }
EOT
systemctl restart docker >> "$LOG_FILE" 2>&1

# AmneziaWG
if [[ "$ID" == "ubuntu" ]]; then
    add-apt-repository -y ppa:amnezia/ppa >> "$LOG_FILE" 2>&1
    apt-get update >> "$LOG_FILE" 2>&1
    apt-get install -y amneziawg amneziawg-tools >> "$LOG_FILE" 2>&1
elif [[ "$ID" == "debian" ]]; then
    apt-get install -y gnupg curl dkms "linux-headers-$(uname -r)" >> "$LOG_FILE" 2>&1
    mkdir -p /etc/apt/keyrings
    curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x75C9DD72C799870E310542E24166F2C257290828" | gpg --dearmor > /etc/apt/keyrings/amneziawg.gpg
    echo "deb[signed-by=/etc/apt/keyrings/amneziawg.gpg] https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu focal main" > /etc/apt/sources.list.d/amneziawg.list
    apt-get update >> "$LOG_FILE" 2>&1
    apt-get install -y amneziawg amneziawg-tools >> "$LOG_FILE" 2>&1
fi
modprobe amneziawg >> "$LOG_FILE" 2>&1

# Utilities & Auto-Maintenance
apt-get install -y fail2ban unattended-upgrades git btop haveged >> "$LOG_FILE" 2>&1
echo -e "Unattended-Upgrade::Automatic-Reboot \"true\";\nUnattended-Upgrade::Automatic-Reboot-Time \"04:00\";" > /etc/apt/apt.conf.d/50unattended-upgrades
(crontab -l 2>/dev/null; echo "0 3 * * 0 /usr/bin/docker system prune -af --volumes") | crontab -
status_success "Docker & AmneziaWG Ready"

# 7. UX: Bash Aliases
cat <<EOT >> /home/"$USER_NAME"/.bashrc
alias ll='ls -alF --color=auto'
alias update='sudo apt update && sudo apt upgrade -y'
export PS1='${GREEN}\u@\h${NC}:${BLUE}\w${NC}\$ '
EOT

# Finalization
ROOT_PASS=$(openssl rand -base64 16)
echo "root:$ROOT_PASS" | chpasswd
apt-get autoremove -y >> "$LOG_FILE" 2>&1

clear
print_header "TITAN VPS DEPLOYED"
echo -e "  SSH Port:      ${BLUE}$SSH_PORT${NC}"
echo -e "  Admin User:    ${BLUE}$USER_NAME${NC}"
echo -e "  Root Password: ${BLUE}$ROOT_PASS${NC}"
echo -e "\n${YELLOW}PRIVATE KEY (Save as vps.key):${NC}\n$PRIVATE_KEY\n"
echo -e "${RED}REBOOTING IN 5 SECONDS...${NC}"
sleep 5
reboot
