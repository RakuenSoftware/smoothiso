#!/bin/bash
# smoothiso Generic First Boot Setup
# Runs once on the first boot after install.
#
# Reads product config from /usr/local/lib/smoothiso/config.sh if present.
# Product-specific steps are in /usr/local/lib/smoothiso/firstboot-ext.sh
# (installed by the project's configure hook).
set -euo pipefail

# Load product config written by the installer.
PRODUCT_ID="${PRODUCT_ID:-linux}"
DATA_DIR="${DATA_DIR:-/var/lib/${PRODUCT_ID}}"

if [ -f /usr/local/lib/smoothiso/config.sh ]; then
    . /usr/local/lib/smoothiso/config.sh
fi

MARKER="${DATA_DIR}/.firstboot-done"

if [ -f "$MARKER" ]; then
    echo "First boot already completed."
    exit 0
fi

echo "============================================="
echo "  First Boot Setup"
echo "============================================="

# --- Reconfigure packages deferred from install ---
echo "Completing package configuration..."
DEBIAN_FRONTEND=noninteractive dpkg --configure --pending 2>/dev/null || true
update-ca-certificates --fresh 2>/dev/null || true
echo "Package configuration complete."

# --- Configure and enable SSH ---
if [ ! -f /etc/ssh/sshd_config ]; then
    cat > /etc/ssh/sshd_config << 'SSHD'
Include /etc/ssh/sshd_config.d/*.conf
PermitRootLogin yes
PasswordAuthentication yes
SSHD
    echo "Created sshd_config."
fi
ssh-keygen -A 2>/dev/null || true
mkdir -p /run/sshd
systemctl enable ssh.service 2>/dev/null || true
systemctl start ssh.service 2>/dev/null || true
echo "SSH configured and started."

# --- Product-specific first boot steps ---
if [ -f /usr/local/lib/smoothiso/firstboot-ext.sh ]; then
    echo "Running product first boot extension..."
    . /usr/local/lib/smoothiso/firstboot-ext.sh
fi

# --- Mark first boot as done ---
mkdir -p "$DATA_DIR"
touch "$MARKER"
echo "First boot setup complete."
