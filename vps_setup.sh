#!/bin/bash

# Exit script immediately if any command fails
set -e

# Define colors for beautiful terminal output
GREEN='\033[0;32m'
BLUE='\033[1;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# --- CONFIGURATION ---
NEW_USER="sysadmin" # Change this to your desired username
# ---------------------

echo -e "${BLUE}[*] Starting Automated VPS Setup...${NC}"

# 1. Check for Root privileges
if[ "$EUID" -ne 0 ]; then
  echo -e "${YELLOW}[!] Please run this script as root.${NC}"
  exit 1
fi
echo -e "${GREEN}[+] Running as root verified.${NC}"

# 2. Generate secure passwords
echo -e "${BLUE}[*] Generating secure passwords for root and $NEW_USER...${NC}"
ROOT_PASS=$(openssl rand -base64 16)
USER_PASS=$(openssl rand -base64 16)

# Apply root password
echo "root:$ROOT_PASS" | chpasswd
echo -e "${GREEN}[+] Root password successfully changed.${NC}"

# 3. Create the new sudo user
echo -e "${BLUE}[*] Creating new user: $NEW_USER...${NC}"
if id "$NEW_USER" &>/dev/null; then
    echo -e "${YELLOW}[!] User $NEW_USER already exists. Skipping creation.${NC}"
else
    useradd -m -s /bin/bash -G sudo "$NEW_USER"
    echo "$NEW_USER:$USER_PASS" | chpasswd
    echo -e "${GREEN}[+] User '$NEW_USER' created and added to sudo group.${NC}"
fi

# 4. Update system and install required packages (No haveged)
echo -e "${BLUE}[*] Updating system repositories and upgrading packages...${NC}"
apt-get update -y && apt-get upgrade -y
echo -e "${GREEN}[+] System updated successfully.${NC}"

echo -e "${BLUE}[*] Installing essential packages (ufw, fail2ban, curl, wget)...${NC}"
apt-get install -y ufw fail2ban curl wget
echo -e "${GREEN}[+] Packages installed successfully.${NC}"

# 5. Fix sysctl for Docker (Ensuring IP forwarding is ON)
echo -e "${BLUE}[*] Configuring sysctl for Docker compatibility...${NC}"
sed -i '/net.ipv4.ip_forward/d' /etc/sysctl.conf
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p > /dev/null
echo -e "${GREEN}[+] IPv4 forwarding enabled (Docker containers will now have internet access).${NC}"

# 6. Setup UFW Firewall
echo -e "${BLUE}[*] Configuring UFW Firewall...${NC}"
ufw --force reset > /dev/null
ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
# Note: Docker bypasses UFW by default. This is NORMAL and required for Docker to work properly.
echo "y" | ufw enable > /dev/null
echo -e "${GREEN}[+] UFW Firewall enabled and SSH port allowed.${NC}"

# 7. Setup Fail2Ban
echo -e "${BLUE}[*] Starting and enabling Fail2Ban...${NC}"
systemctl enable fail2ban > /dev/null 2>&1
systemctl restart fail2ban
echo -e "${GREEN}[+] Fail2Ban is active and protecting SSH.${NC}"

echo -e "\n=================================================="
echo -e "${GREEN}      VPS SETUP COMPLETED SUCCESSFULLY!      ${NC}"
echo -e "=================================================="
echo -e "Keep these credentials safe. They will not be shown again."
echo -e ""
echo -e "Username: ${YELLOW}root${NC}"
echo -e "Password: ${YELLOW}${ROOT_PASS}${NC}"
echo -e ""
echo -e "Username: ${YELLOW}${NEW_USER}${NC}"
echo -e "Password: ${YELLOW}${USER_PASS}${NC}"
echo -e "=================================================="
