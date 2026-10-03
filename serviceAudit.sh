#!/bin/bash
# -------------------------------------------------
# service_audit.sh — Audit running services/processes
# -------------------------------------------------

RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
RESET="\e[0m"

echo -e "${YELLOW}[*] Starting service and process audit...${RESET}\n"

#List active services
echo -e "${GREEN}--- Running systemd services ---${RESET}"
sudo systemctl list-units --type=service --state=running --no-pager | awk '{print $1}' | tail -n +2 | grep -v "UNIT" > /tmp/services.txt

while read -r svc; do
if [[ "$svc" =~ (ssh|systemd|dbus|cron|NetworkManager|rsyslog|polkit|nginx|apache|mysql|postgres|firewalld|ufw) ]]; then
        echo -e "${GREEN}[OK]${RESET} $svc"
    else
        echo -e "${RED}[?] Suspicious or uncommon service:${RESET} $svc"
    fi
done < /tmp/services.txt

KNOWN='^(ssh|sshd|cron|dbus|rsyslog|NetworkManager|polkit|nginx|apache3|ufw|console-getty|getty@[a-z0-9]+|user@[0-9]+|systemd-[a-z-]+)\.service$'

while read -r svc; do
    if [[ $svc =~ $KNOWN ]]; then
        printf '%b[OK]%b %s\n' "$GREEN" "$RESET" "$svc"
    else
        printf '%b[?] Uncommon service:%b %s\n' "$RED" "$RESET" "$svc"
    fi
done < <(systemctl list-units --type=service --state=running \
            --no-legend --plain --no-pager | awk '{print $1}')

while read -r proto addr; do
    port=${addr##*:}     # strip everything up to the last colon
    host=${addr%:*}      # strip the last colon and the port
    case $host in
        127.*|\[::1\]|*%lo) scope="local only" ;;
        *)                  scope="EXPOSED" ;;
    esac
    printf '%s port %s (%s, bound to %s)\n' "$proto" "$port" "$scope" "$host"
done < <(ss -tuln | awk 'NR>1 {print $1, $5}')
