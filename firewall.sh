#!/bin/bash

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
	echo "run with sudo"
	exit 1
fi

# Set to the IP of your MySQL server.
# If MySQL runs on THIS host, leave as 127.0.0.1 and the rule below is a no-op.
# If MySQL is remote, replace with its IP or the web app will be blocked by the deny-out policy.
DB_IP="127.0.0.1" # <------ Change this database IP

if [[ "$DB_IP" == "127.0.0.1" ]]; then
    echo "NOTE: DB_IP is 127.0.0.1 (localhost)."
    echo "      If your MySQL server is on another host, edit DB_IP or the web app will not connect."
    read -rp "Continue anyway? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || exit 1
fi

tools=("ufw" "tmux" "git" "curl" "debsums")
missing=()

for tool in "${tools[@]}"; do
	if ! command -v "$tool" &> /dev/null; then
		missing+=("$tool")
	fi
done

if [ ${#missing[@]} -gt 0 ]; then
	apt update
	apt install -y "${missing[@]}"
fi

debsums --all --changed
echo "Run sudo apt install --reinnstall <package> any changed packages"

ufw default deny incoming
ufw default deny outgoing

ufw limit 22/tcp

ufw allow 80/tcp
ufw allow 443/tcp

ufw allow out to "$DB_IP" port 3306 proto tcp
ufw allow out 53/tcp
ufw allow out 53/udp
ufw allow out 123/udp


ufw --force enable
ufw status verbose

echo "Double check ssh is allowed"
