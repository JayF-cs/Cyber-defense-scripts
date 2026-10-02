#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

PROTECTED_USERS=("debian" "jmoney" "plinktern") # <---- Change this as need

if [ "$(id -u)" -ne 0 ]; then
    echo "Must be run as root"
    exit 1
fi


# -----------------------------
# 1. Remove all existing authorized_keys
# -----------------------------
echo "[*] Removing existing authorized_keys for non-protected users..."

# Always delete root's keys since PermitRootLogin is set to 'no' later
sudo rm -f /root/.ssh/authorized_keys
echo "[*] Cleared /root/.ssh/authorized_keys (PermitRootLogin is 'no')."

for userdir in /home/*; do
    if [ -d "$userdir/.ssh" ]; then
        username=$(basename "$userdir")

        # Check if the current user is in the protected list
        if [[ " ${PROTECTED_USERS[@]} " =~ " ${username} " ]]; then
            echo "SKIPPING: $username is a protected user. Keys retained."
        else
            # Delete keys for all other (non-protected) users
            sudo rm -f "$userdir/.ssh/authorized_keys"
            echo "Cleared $userdir/.ssh/authorized_keys"
        fi
    fi
done

# -----------------------------
# 2. Create hardened SSH config with JMONEY and PLINKTERN password exception
# -----------------------------
HARDEN_CONF="/etc/ssh/sshd_config.d/10-hardening.conf"
echo "Creating hardened SSH config at $HARDEN_CONF..."

sudo mkdir -p /etc/ssh/sshd_config.d

# Join the array of protected users into a space-separated string for AllowUsers
ALLOWED_USERS_LIST="${PROTECTED_USERS[*]}"

sudo tee "$HARDEN_CONF" > /dev/null <<EOF
# SSH Hardening for Horse Plinko
PermitRootLogin no
MaxAuthTries 3
AllowUsers ${ALLOWED_USERS_LIST}
PubkeyAuthentication yes

# GLOBAL SETTING: Disable password authentication for everyone by default
PasswordAuthentication no

ClientAliveInterval 300
AllowTcpForwarding no

# *** EXCEPTION FOR JMONEY AND PLINKTERN ***
# The Match block overrides the global 'PasswordAuthentication no' setting
# for jmoney and plinktern, allowing them to use passwords.
Match User jmoney plinktern
    # Allow these users to use a password.
    PasswordAuthentication yes
Match all
EOF

echo "[*] Hardened SSH config written."

# -----------------------------
# 3. Test SSH config before restart
# -----------------------------
echo "Testing SSH configuration..."
sudo sshd -t
if [ $? -eq 0 ]; then
    echo "SSH config syntax OK."
else
    echo "SSH config has errors. Fix before restart!"
    exit 1
fi

# -----------------------------
# 4. Restart SSH service
# -----------------------------
echo "Restarting SSH service..."
if systemctl list-units --type=service | grep -q sshd; then
    sudo systemctl restart sshd
else
    sudo systemctl restart ssh
fi

echo "SSH hardening complete."
echo "Users allowed: ${ALLOWED_USERS_LIST}."
echo "Password authentication is now allowed ONLY for jmoney and plinktern. All others must use keys."
