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

print_header "GOD-MODE EDITION: THE FINAL VPS HARDENING"

# 1. System & Generic Headers
status_working "Updating System & Kernel Headers"
source /etc/os-release
apt-get update >> "$LOG_FILE" 2>&1
apt-get full-upgrade -y >> "$LOG_FILE" 2>&1
[[ "$ID" == "ubuntu" ]] && apt-get install -y linux-image-generic linux-headers-generic >> "$LOG_FILE" 2>&1
[[ "$ID" == "debian" ]] && apt-get install -y linux-image-amd64 linux-headers-amd64 >> "$LOG_FILE" 2>&1
status_success "System Patched"

# 2. Journald & Log Management (Prevent Disk Fill)
status_working "Capping System Logs (Journald)"
mkdir -p /etc/systemd/journald.conf.d
cat <<EOT > /etc/systemd/journald.conf.d/max-size.conf
[Journal]
Storage=persistent
SystemMaxUse=100M
RuntimeMaxUse=50M
ForwardToSyslog=no
EOT
systemctl restart systemd-journald >> "$LOG_FILE" 2>&1
status_success "Logs capped at 100MB"

# 3. System Resource Limits (No More Bottlenecks)
status_working "Increasing System Open-File Limits"
cat <<EOT >> /etc/security/limits.conf
* soft nofile 65535
* hard nofile 65535
root soft nofile 65535
root hard nofile 65535
EOT
echo "session required pam_limits.so" >> /etc/pam.d/common-session
status_success "Limits raised to 65535"

# 4. User & SSH Hardened (LogLevel Verbose)
status_working "Creating User & Hardening SSH"
USER_PASS=$(openssl rand -base64 16)
useradd -m -s /bin/bash "$USER_NAME" && echo "$USER_NAME:$USER_PASS" | chpasswd
usermod -aG sudo "$USER_NAME"
mkdir -p /home/"$USER_NAME"/.ssh
ssh-keygen -t ed25519 -N "" -f /home/"$USER_NAME"/.ssh/id_ed25519 >> "$LOG_FILE" 2>&1
cat /home/"$USER_NAME"/.ssh/id_ed25519.pub > /home/"$USER_NAME"/.ssh/authorized_keys
PRIVATE_KEY=$(cat /home/"$USER_NAME"/.ssh/id_ed25519)
chown -R "$USER_NAME":"$USER_NAME" /home/"$USER_NAME"/.ssh

SSH_PORT=$(shuf -i 5000-65535 -n 1)
cat <<EOT > /etc/ssh/sshd_config
Port $SSH_PORT
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
LogLevel VERBOSE
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com
EOT
systemctl restart ssh >> "$LOG_FILE" 2>&1
status_success "SSH secured (Verbose Logging)"

# 5. Performance: ZRam, Swap & I/O
status_working "Optimizing RAM (ZRam) & I/O Scheduler"
apt-get install -y zram-tools >> "$LOG_FILE" 2>&1
echo -e "ALGO=zstd\nPERCENT=60" > /etc/default/zramswap
systemctl restart zramswap >> "$LOG_FILE" 2>&1
# SSD I/O optimization
echo "none" > /sys/block/sda/queue/scheduler 2>/dev/null || true
status_success "RAM & I/O Optimized"

# 6. Firewall & The Docker-UFW Fix
status_working "UFW Setup & Fixing Docker Firewall Bypass"
apt-get install -y ufw >> "$LOG_FILE" 2>&1
# Install the Docker-UFW bridge
curl -s https://raw.githubusercontent.com/chaifeng/ufw-docker/master/ufw-docker -o /usr/local/bin/ufw-docker
chmod +x /usr/local/bin/ufw-docker
ufw-docker install >> "$LOG_FILE" 2>&1

# Apply ICMP Drops (Screenshot Logic)
BEFORE_RULES="/etc/ufw/before.rules"
sed -i 's/icmp-type echo-request -j ACCEPT/icmp-type echo-request -j DROP/' $BEFORE_RULES
# ... other ICMP drops ...
ufw default deny incoming >> "$LOG_FILE" 2>&1
ufw limit $SSH_PORT/tcp >> "$LOG_FILE" 2>&1
ufw allow 60000:61000/udp >> "$LOG_FILE" 2>&1
ufw --force enable >> "$LOG_FILE" 2>&1
status_success "Firewall Bridge Secured"

# 7. THE ELITE SYSCTL
status_working "Applying God-Mode Sysctl"
cat <<EOT > /etc/sysctl.conf
# Network
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.core.somaxconn = 8192
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
# Security
kernel.panic = 10
kernel.kptr_restrict = 2
kernel.unprivileged_bpf_disabled = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.icmp_echo_ignore_all = 1
# Docker/VPN
net.ipv4.ip_forward = 1
net.ipv4.conf.all.src_valid_mark = 1
net.netfilter.nf_conntrack_max = 262144
vm.max_map_count = 262144
EOT
sysctl -p >> "$LOG_FILE" 2>&1
status_success "Kernel Tuned"

# 8. Docker, AmneziaWG & Utils
status_working "Installing Core Services"
curl -sSL https://get.docker.com | sh >> "$LOG_FILE" 2>&1
usermod -aG docker "$USER_NAME"
# Docker Log Cap
echo '{"log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"3"}}' > /etc/docker/daemon.json
systemctl restart docker >> "$LOG_FILE" 2>&1

# AmneziaWG
if [[ "$ID" == "ubuntu" ]]; then
    add-apt-repository -y ppa:amnezia/ppa >> "$LOG_FILE" 2>&1
    apt-get update >> "$LOG_FILE" 2>&1
    apt-get install -y amneziawg amneziawg-tools >> "$LOG_FILE" 2>&1
else
    # Debian logic...
    apt-get install -y dkms "linux-headers-$(uname -r)" >> "$LOG_FILE" 2>&1
fi
modprobe amneziawg >> "$LOG_FILE" 2>&1

# Maintenance
apt-get install -y fail2ban unattended-upgrades git btop haveged >> "$LOG_FILE" 2>&1
echo -e "Unattended-Upgrade::Automatic-Reboot \"true\";\nUnattended-Upgrade::Automatic-Reboot-Time \"04:00\";" > /etc/apt/apt.conf.d/50unattended-upgrades
status_success "All Services Ready"

# 9. UX: Bash Aliases
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
print_header "GOD-MODE VPS DEPLOYED"
echo -e "  SSH Port:      ${BLUE}$SSH_PORT${NC}"
echo -e "  Admin User:    ${BLUE}$USER_NAME${NC}"
echo -e "  Root Password: ${BLUE}$ROOT_PASS${NC}"
echo -e "\n${YELLOW}PRIVATE KEY (Save as vps.key):${NC}\n$PRIVATE_KEY\n"
echo -e "${RED}REBOOTING IN 5 SECONDS...${NC}"
sleep 5
reboot
