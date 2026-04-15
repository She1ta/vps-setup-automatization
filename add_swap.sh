#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Default swap size is 2G, but you can pass a size as an argument (e.g., ./setup_swap.sh 4G)
SWAP_SIZE=${1:-2G}
SWAP_FILE="/swapfile"

# 1. Check for root privileges
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root. Please run with sudo."
   exit 1
fi

echo "Starting Swap File Setup ($SWAP_SIZE)..."

# 2. Check if a swap file already exists and is active
if swapon --show | grep -q "$SWAP_FILE"; then
    echo "Swap is already active on $SWAP_FILE. Nothing to do."
    swapon --show
    exit 0
fi

# 3. Create the swap file
if [ -f "$SWAP_FILE" ]; then
    echo "A file at $SWAP_FILE already exists but is not active. Overwriting..."
else
    echo "Creating $SWAP_SIZE swap file at $SWAP_FILE (this may take a moment)..."
fi

# We use fallocate because it is instant. (Safe on default Ubuntu ext4/LVM setups)
fallocate -l "$SWAP_SIZE" "$SWAP_FILE"

# 4. Secure the swap file (Critical: only root should read/write)
echo "Setting restrictive permissions (600)..."
chmod 600 "$SWAP_FILE"

# 5. Format the file as swap space
echo "Formatting the file as swap..."
mkswap "$SWAP_FILE"

# 6. Enable the swap file
echo "Enabling the swap space..."
swapon "$SWAP_FILE"

# 7. Make it permanent in /etc/fstab
echo "Checking /etc/fstab for persistence..."
if grep -q "$SWAP_FILE none swap sw 0 0" /etc/fstab; then
    echo "Swap entry already exists in /etc/fstab."
else
    echo "Adding swap entry to /etc/fstab..."
    echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
fi

echo "Swap setup complete!"
echo "------------------------------------------------"
# Show the current active swap
swapon --show
echo "------------------------------------------------"
