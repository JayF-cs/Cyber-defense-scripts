#!/bin/bash

set -euo pipefail

if [[$EUID -ne 0]]; then
	echo "run with sudo"
	exit 1
fi

DB_IP = "127.0.0.1" # <------ Change this database IP

tools=("ufw" "tmux" "git" "curl")
missing=()
set -euo pipefail
for tool in "${tools[@]}"; do
	if ! command -v "$tool" &> /dev/null; then
		missing_tools+=("$tool")
	fi
done

if [${#missing[@]} -gt 0]; then
	sudo apt update
	sudo apt isntall -y "${missing[@]}"

ufw limit 22/tcp

ufw default deny incoming
ufw default deny outgoing

ufw allow 80/tcp
ufw allow 443/tcp

ufw allow out to "$DB_IP" port 3306 proto tcp
ufw allow out 53
