#!/usr/bin/env bash
# -------------------------------------------------
# service_audit.sh — Audit running services/processes
# -------------------------------------------------

RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
RESET="\e[0m"

echo -e "${YELLOW}[*] Starting service and process audit...${RESET}\n"

# 1️⃣ List active services
echo -e "${GREEN}--- Running systemd services ---${RESET}"
sudo systemctl list-units --type=service --state=running --no-pager | awk '{print $1}' | tail -n +2 | grep -v "UNIT" > /tmp/services.txt

while read -r svc; do
if [[ "$svc" =~ (ssh|systemd|dbus|cron|NetworkManager|rsyslog|polkit|nginx|apache|mysql|postgres|firewalld|ufw) ]]; then
        echo -e "${GREEN}[OK]${RESET} $svc"
    else
        echo -e "${RED}[?] Suspicious or uncommon service:${RESET} $svc"
    fi
done < /tmp/services.txt

# 2️⃣ Check processes for suspicious names or paths
echo -e "\n${GREEN}--- Checking running processes ---${RESET}"
sudo ps -eo pid,user,comm,args --sort=-%mem | head -n 20 | while read -r line; do
    if echo "$line" | grep -Eiq 'nc|ncat|socat|bash -i|/dev/tcp|curl|wget|perl|python|ruby'; then
        echo -e "${RED}Suspicious process:${RESET} $line"
    elif echo "$line" | grep -Eiq '/tmp/|/dev/shm/'; then
        echo -e "${YELLOW}Process running from temp dir:${RESET} $line"
    fi
done

# 3️⃣ Show open ports
echo -e "\n${GREEN}--- Open listening ports ---${RESET}"
sudo ss -tuln | awk 'NR>1 {print $1, $5}' | while read -r proto addr; do
    port=$(echo "$addr" | awk -F':' '{print $NF}')
    if [[ "$port" =~ ^(22|80|443|3306|5432)$ ]]; then
        echo -e "${GREEN}[OK]${RESET} $proto port $port"
    else
        echo -e "${RED}Unusual open port:${RESET} $proto port $port"
    fi
done

# 4️⃣ Check enabled-on-boot services
echo -e "\n${GREEN}--- Enabled-on-boot services ---${RESET}"
sudo systemctl list-unit-files --type=service --no-pager | grep enabled | while read -r line; do
    if echo "$line" | grep -Eq 'ssh|network|firewalld|ufw|rsyslog|systemd|cron|nginx|apache|mysql|postgres'; then
        echo -e "${GREEN}[OK]${RESET} $line"
    else
        echo -e "${YELLOW}[?] May not need on boot:${RESET} $line"
    fi
done

echo -e "\n${GREEN}Audit complete.${RESET}"
echo -e "Review red or yellow lines for potential issues.\n"
