#!/bin/bash
LOG_FILE="/var/log/vps_setup.log"
USER_NAME=$1

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' 

function status_working() { echo -ne " [ .. ] $1..."; }
function status_success() { echo -e "\r[ ${GREEN}SUCCESS${NC} ] $1 "; }
function status_error() { echo -e "\r[ ${RED}FAIL${NC} ] $1. Check log: $LOG_FILE "; exit 1; }

[[ -z "$USER_NAME" ]] && { echo -e "${RED}Error: Provide a username (e.g., ./setup.sh admin)${NC}"; exit 1; }
[[ "$EUID" -ne 0 ]] && { echo -e "${RED}Error: Run as root${NC}"; exit 1; }
true > "$LOG_FILE"

echo -e "\n${BLUE}==========================================================${NC}"
echo -e "${BLUE} SIMPLIFIED VPS DEPLOYMENT (MAXIMUM STEALTH + DKMS AWG) ${NC}"
echo -e "${BLUE}==========================================================${NC}"

status_working "Fixing APT Sources & Upgrading System"
{
    export DEBIAN_FRONTEND=noninteractive
    
    # Disable service restart prompts on Ubuntu
    if [ -f /etc/needrestart/needrestart.conf ]; then
        sed -i "s/^#\$nrconf{restart} = 'i';/\$nrconf{restart} = 'a';/g" /etc/needrestart/needrestart.conf
    fi

    # Fix Ubuntu 24.04 duplicate sources warning
    if [[ -f "/etc/apt/sources.list.d/ubuntu.sources" ]] && [[ -f "/etc/apt/sources.list" ]]; then
        sed -i 's/^deb /#deb /g' /etc/apt/sources.list
        sed -i 's/^deb-src /#deb-src /g' /etc/apt/sources.list
    fi

    source /etc/os-release
    apt-get update
    apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" full-upgrade
    
    if [[ "$ID" == "ubuntu" ]]; then
        apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install linux-image-generic linux-headers-generic
    elif [[ "$ID" == "debian" ]]; then
        apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install linux-image-amd64 linux-headers-amd64
    fi
} >> "$LOG_FILE" 2>&1 && status_success "System & Headers Updated" || status_error "System Update Failed"

status_working "Creating User & Hardening SSH"
{
    USER_PASS=$(openssl rand -base64 16)
    useradd -m -s /bin/bash "$USER_NAME"
    echo "$USER_NAME:$USER_PASS" | chpasswd
    usermod -aG sudo "$USER_NAME"
    
    # Fix missing .Xauthority warning
    touch /home/"$USER_NAME"/.Xauthority
    chown "$USER_NAME":"$USER_NAME" /home/"$USER_NAME"/.Xauthority

    mkdir -p /home/"$USER_NAME"/.ssh
    ssh-keygen -t ed25519 -N "" -f /home/"$USER_NAME"/.ssh/id_ed25519
    cat /home/"$USER_NAME"/.ssh/id_ed25519.pub > /home/"$USER_NAME"/.ssh/authorized_keys
    PRIVATE_KEY=$(cat /home/"$USER_NAME"/.ssh/id_ed25519)
    
    chown -R "$USER_NAME":"$USER_NAME" /home/"$USER_NAME"/.ssh
    chmod 700 /home/"$USER_NAME"/.ssh
    chmod 600 /home/"$USER_NAME"/.ssh/authorized_keys

    SSH_PORT=$(shuf -i 50000-65535 -n 1)
    
    # Define the modern drop-in directory and file
    DROPIN_DIR="/etc/ssh/sshd_config.d"
    SSHD_CONF_FILE="$DROPIN_DIR/99-vps-hardening.conf"

    # Ensure the drop-in directory exists
    mkdir -p "$DROPIN_DIR"

    # Write our strict settings to the drop-in file. 
    cat <<EOT > "$SSHD_CONF_FILE"
Port $SSH_PORT
LogLevel VERBOSE
LoginGraceTime 20
PermitRootLogin no
MaxAuthTries 2
MaxSessions 2
PasswordAuthentication no
PermitEmptyPasswords no
KerberosAuthentication no
GSSAPIAuthentication no
AllowAgentForwarding no
AllowTcpForwarding no
X11Forwarding no
PermitTunnel no
UseDNS no
DebianBanner no
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
EOT

    # Safety Check: Ensure the main sshd_config is actually including drop-in files.
    if ! grep -q "^Include /etc/ssh/sshd_config.d/\*.conf" /etc/ssh/sshd_config; then
        sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
    fi

    systemctl restart ssh
} >> "$LOG_FILE" 2>&1 && status_success "SSH Hardened on Port $SSH_PORT" || status_error "SSH Setup Failed"

status_working "Configuring Firewall (UFW)"
{
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y ufw

    # Disable Ping (ICMP Echo Requests) for IPv4 & IPv6
    sed -i 's/-A ufw-before-input -p icmp --icmp-type echo-request -j ACCEPT/-A ufw-before-input -p icmp --icmp-type echo-request -j DROP/' /etc/ufw/before.rules
    sed -i 's/-A ufw6-before-input -p icmpv6 --icmpv6-type echo-request -j ACCEPT/-A ufw6-before-input -p icmpv6 --icmpv6-type echo-request -j DROP/' /etc/ufw/before6.rules

    ufw default deny incoming
    ufw default allow outgoing
    
    # NOTE: SSH Port is intentionally NOT allowed here. fwknop will handle it.
    # NOTE: 8080 and 3000 removed to hide server. Access them via VPN.
    
    ufw allow 60000:61000/udp
    ufw allow 51821/udp
    ufw --force enable
} >> "$LOG_FILE" 2>&1 && status_success "Firewall Active (Stealth Mode)" || status_error "Firewall Failed"

status_working "Configuring fwknop (SPA)"
{
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y fwknop-server fwknop-client
    
    # Auto-detect the primary network interface (e.g., eth0, ens3)
    PUB_IF=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
    
    # Generate secure cryptographic keys
    FWKNOP_KEYS=$(fwknop --key-gen)
    KEY_BASE64=$(echo "$FWKNOP_KEYS" | grep "KEY_BASE64" | cut -d ' ' -f 2)
    HMAC_KEY_BASE64=$(echo "$FWKNOP_KEYS" | grep "HMAC_KEY_BASE64" | cut -d ' ' -f 2)
    
    # Configure fwknopd.conf to listen on the correct interface
    sed -i "s/^PCAP_INTF.*/PCAP_INTF                   $PUB_IF;/" /etc/fwknop/fwknopd.conf
    
    # Configure access.conf with our newly generated keys
    cat <<EOT > /etc/fwknop/access.conf
SOURCE              ANY
KEY_BASE64          $KEY_BASE64
HMAC_KEY_BASE64     $HMAC_KEY_BASE64
FW_ACCESS_TIMEOUT   30
EOT

    systemctl enable fwknop-server
    systemctl restart fwknop-server
} >> "$LOG_FILE" 2>&1 && status_success "fwknop (SPA) Configured" || status_error "fwknop Setup Failed"

status_working "Installing AmneziaWG (Wiresock Logic)"
{
    set -e
    export DEBIAN_FRONTEND=noninteractive
    if [[ "$ID" == "ubuntu" ]]; then
        if [[ -e /etc/apt/sources.list.d/ubuntu.sources ]]; then
            echo "# Managed by amneziawg-install" > /etc/apt/sources.list.d/amneziawg.sources
            cat /etc/apt/sources.list.d/ubuntu.sources >> /etc/apt/sources.list.d/amneziawg.sources
            sed -i 's/^Types: .*/Types: deb-src/' /etc/apt/sources.list.d/amneziawg.sources
        elif ! grep -q "^deb-src" /etc/apt/sources.list; then
            echo "# Managed by amneziawg-install" > /etc/apt/sources.list.d/amneziawg.sources.list
            cat /etc/apt/sources.list >> /etc/apt/sources.list.d/amneziawg.sources.list
            sed -i 's/^deb[[:space:]]\+/deb-src /' /etc/apt/sources.list.d/amneziawg.sources.list
        fi
        apt-get update
        apt-get install -y software-properties-common
        add-apt-repository -y ppa:amnezia/ppa
        apt-get update
        for HEADER_PKG in "linux-headers-$(uname -r)" "raspberrypi-kernel-headers" "linux-headers-generic"; do
            apt-get install -y "${HEADER_PKG}" && break
        done
        apt-get install -y dkms iptables amneziawg amneziawg-tools qrencode
    elif [[ "$ID" == "debian" ]]; then
        if ! grep -q "^deb-src" /etc/apt/sources.list; then
            echo "# Managed by amneziawg-install" > /etc/apt/sources.list.d/amneziawg.sources.list
            cat /etc/apt/sources.list >> /etc/apt/sources.list.d/amneziawg.sources.list
            sed -i -E '/^[[:space:]]*deb-src[[:space:]]/!s/^[[:space:]]*deb[[:space:]]+/deb-src /' /etc/apt/sources.list.d/amneziawg.sources.list
        fi
        apt-get update
        apt-get install -y gnupg curl
        mkdir -p /etc/apt/keyrings
        curl -4 -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x75C9DD72C799870E310542E24166F2C257290828" | gpg --dearmor --yes -o /etc/apt/keyrings/amneziawg.gpg
        if [[ ! -f /etc/apt/sources.list.d/amneziawg.sources.list ]]; then
            echo "# Managed by amneziawg-install" > /etc/apt/sources.list.d/amneziawg.sources.list
        fi
        if ! grep -q 'ppa.launchpadcontent.net/amnezia/ppa' /etc/apt/sources.list.d/amneziawg.sources.list; then
            echo "deb[signed-by=/etc/apt/keyrings/amneziawg.gpg] https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu focal main" >> /etc/apt/sources.list.d/amneziawg.sources.list
            echo "deb-src[signed-by=/etc/apt/keyrings/amneziawg.gpg] https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu focal main" >> /etc/apt/sources.list.d/amneziawg.sources.list
        fi
        apt-get update
        DEB_ARCH=$(dpkg --print-architecture 2>/dev/null)
        for HEADER_PKG in "linux-headers-$(uname -r)" "raspberrypi-kernel-headers" "linux-headers-${DEB_ARCH}"; do
            apt-get install -y "${HEADER_PKG}" && break
        done
        apt-get install -y dkms amneziawg amneziawg-tools qrencode iptables
    fi

    # DKMS module build and cache rebuild
    for AWG_DKMS_CONF in /var/lib/dkms/amneziawg/*/source/dkms.conf; do
        [[ -f "${AWG_DKMS_CONF}" ]] && sed -i '/^REMAKE_INITRD=/d' "${AWG_DKMS_CONF}"
    done
    dkms autoinstall -k "$(uname -r)" || true
    depmod -a || true

    mkdir -p /etc/modules-load.d
    if ! grep -qx "amneziawg" /etc/modules-load.d/amneziawg.conf 2>/dev/null; then
        echo "amneziawg" >> /etc/modules-load.d/amneziawg.conf
    fi
    modprobe amneziawg || true
} >> "$LOG_FILE" 2>&1 && status_success "AmneziaWG Installed" || status_error "AmneziaWG Failed"

status_working "Installing Docker"
{
    export DEBIAN_FRONTEND=noninteractive
    curl -sSL https://get.docker.com | sh
    usermod -aG docker "$USER_NAME"
} >> "$LOG_FILE" 2>&1 && status_success "Docker Installed" || status_error "Docker Failed"

status_working "Finalizing Maintenance & Security"
{
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y fail2ban unattended-upgrades git btop haveged

    # Configure Fail2Ban
    cat <<EOT > /etc/fail2ban/jail.local
[DEFAULT]
bantime = 1d
findtime = 10m
maxretry = 3

[sshd]
enabled = true
port = $SSH_PORT
logpath = %(sshd_log)s
backend = %(sshd_backend)s
EOT

    systemctl enable fail2ban
    systemctl restart fail2ban

    # Terminal Colors Setup
    BASHRC_SNIPPET="
alias ll='ls -alF --color=auto'
alias update='sudo apt update && sudo apt upgrade -y'
export PS1='\[\e[1;36m\]\u@\h\[\e[m\]:\[\e[1;33m\]\w\[\e[m\]\$ '
"
    echo "$BASHRC_SNIPPET" >> /home/"$USER_NAME"/.bashrc
    echo "$BASHRC_SNIPPET" >> /root/.bashrc

    ROOT_PASS=$(openssl rand -base64 16)
    echo "root:$ROOT_PASS" | chpasswd
} >> "$LOG_FILE" 2>&1 && status_success "Maintenance & Security Configured" || status_error "Maintenance Config Failed"

clear
echo -e "\n${BLUE}==========================================================${NC}"
echo -e "${GREEN} VPS DEPLOYED SUCCESSFULLY (STEALTH MODE ACTIVE) ${NC}"
echo -e "${BLUE}==========================================================${NC}"
echo -e " SSH Port: ${YELLOW}$SSH_PORT${NC}"
echo -e " Admin User: ${YELLOW}$USER_NAME${NC}"
echo -e " Admin Pass: ${YELLOW}$USER_PASS${NC}"
echo -e " Root Password: ${YELLOW}$ROOT_PASS${NC}"

echo -e "\n${RED}==========================================================${NC}"
echo -e "${RED} CRITICAL: SAVE THESE FWKNOP KEYS TO ACCESS SSH! ${NC}"
echo -e "${RED}==========================================================${NC}"
echo -e "KEY_BASE64:      ${YELLOW}${KEY_BASE64}${NC}"
echo -e "HMAC_KEY_BASE64: ${YELLOW}${HMAC_KEY_BASE64}${NC}"

echo -e "\n${YELLOW}SAVE THIS PRIVATE SSH KEY TO YOUR PC AS vps.key:${NC}"
echo -e "${BLUE}----------------------------------------------------------${NC}"
echo "$PRIVATE_KEY"
echo -e "${BLUE}----------------------------------------------------------${NC}"
echo -e "\n${RED}REBOOTING IN 5 SECONDS TO APPLY CHANGES...${NC}"
sleep 5
reboot
