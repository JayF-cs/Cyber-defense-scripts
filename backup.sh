#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'
umask 077

# ==================================
#             CONFIG
# ==================================
OUTDIR="${OUTDIR:-/.backups}"                                   # local backup dir
TARGETS_STR="${TARGETS:-/etc /var /opt /home /root /srv /usr/local}"  # space-separated
EXTRA_EXCLUDES_STR="${EXTRA_EXCLUDES:-}"                        # space-separated absolute paths
MIN_FREE_MB="${MIN_FREE_MB:-200}"                               # floor for the free-space check
KEEP="${KEEP:-5}"                                               # number of backup sets to retain
IMMUTABLE="${IMMUTABLE:-true}"                                  # chattr +i results when done
MYSQL_DUMP="${MYSQL_DUMP:-true}"                                # dump MySQL/MariaDB if mysqldump exists
STATE_SNAPSHOT="${STATE_SNAPSHOT:-true}"                        # save users/ports/cron/etc. listing
LOCKFILE="${LOCKFILE:-/run/system-backup.lock}"

# Remote copy (use a restricted, write-only account on the receiving side)
REMOTE_COPY="${REMOTE_COPY:-true}"
REMOTE_USER="${REMOTE_USER:-backup_transfer}"
REMOTE_HOST="${REMOTE_HOST:-generator.team6.plinko.horse}"
REMOTE_DIR="${REMOTE_DIR:-/safe/backups}"
REMOTE_KEY="${REMOTE_KEY:-/root/.ssh/backup_key}"               # used only if the file exists
REMOTE_STRICT="${REMOTE_STRICT:-yes}"                           # host key checking; pre-populate known_hosts
# ==================================

# --- Pre-checks ---
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Must run as root or with sudo to access all system files." >&2
    exit 2
fi

TAR_BIN=$(command -v tar || true)
CHATTR_BIN=$(command -v chattr || true)
SCP_BIN=$(command -v scp || true)

if [ -z "$TAR_BIN" ]; then
    echo "ERROR: tar not found. Please install the package." >&2
    exit 3
fi

# Only one backup at a time
if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCKFILE"
    if ! flock -n 9; then
        echo "ERROR: another backup is already running." >&2
        exit 1
    fi
fi

# --- Names ---
TIMESTAMP=$(date +%F_%H%M%S)
ARCHIVE_BASE="system_backup_${TIMESTAMP}"
ARCHIVE_NAME="${ARCHIVE_BASE}.tar.gz"
ARCHIVE_PATH="${OUTDIR}/${ARCHIVE_NAME}"
LOGFILE="${OUTDIR}/${ARCHIVE_BASE}.log"
SUMS_NAME="${ARCHIVE_BASE}.sha256"
MYSQL_NAME="${ARCHIVE_BASE}.mysql.sql.gz"
STATE_NAME="${ARCHIVE_BASE}.state.txt"

# --- Lock down results on ANY exit (success or failure) ---
lock_down() {
    if [ "$IMMUTABLE" = true ] && [ -n "$CHATTR_BIN" ] && [ -d "$OUTDIR" ]; then
        "$CHATTR_BIN" +i "$OUTDIR/${ARCHIVE_BASE}".* 2>/dev/null || true
        "$CHATTR_BIN" +i "$OUTDIR" 2>/dev/null || true
        echo "Immutable flag applied to this run's files and $OUTDIR."
    fi
}
trap lock_down EXIT

log() { printf '%s\n' "$1" | tee -a "$LOGFILE"; }

# --- Prepare output dir (unlock BEFORE chmod: chmod fails on immutable dirs) ---
mkdir -p "$OUTDIR"
if [ -n "$CHATTR_BIN" ]; then
    "$CHATTR_BIN" -i "$OUTDIR" 2>/dev/null || true
fi
chmod 700 "$OUTDIR"

log "==== Backup started: $(date -u) ===="

# --- Resolve targets (skip ones that don't exist on this host) ---
IFS=' ' read -r -a REQUESTED <<< "$TARGETS_STR"
BACKUP_TARGETS=()
for t in "${REQUESTED[@]}"; do
    if [ -e "$t" ]; then
        BACKUP_TARGETS+=("$t")
    else
        log "NOTE: skipping missing target $t"
    fi
done
if [ "${#BACKUP_TARGETS[@]}" -eq 0 ]; then
    log "ERROR: none of the backup targets exist."
    exit 3
fi
log "Targets: $(printf '%s ' "${BACKUP_TARGETS[@]}")"

# --- Free space check (rough: assumes ~2:1 compression, with a floor) ---
free_kb=$(df -Pk "$OUTDIR" | awk 'NR==2 {print $4}')
free_mb=$(( free_kb / 1024 ))
est_kb=$(du -sk "${BACKUP_TARGETS[@]}" 2>/dev/null | awk '{s+=$1} END {print s+0}' || true)
need_mb=$(( est_kb / 1024 / 2 ))
if [ "$need_mb" -lt "$MIN_FREE_MB" ]; then
    need_mb=$MIN_FREE_MB
fi
if [ "$free_mb" -lt "$need_mb" ]; then
    log "ERROR: ${free_mb}MB free, estimated need ~${need_mb}MB."
    exit 4
fi
log "Free space check: OK (${free_mb}MB free, ~${need_mb}MB needed)."

OUT_FILES=("$ARCHIVE_NAME")

# --- System state snapshot (handy for spotting what changed after an intrusion) ---
snapshot() {
    section() { echo; echo "### $1"; shift; "$@" 2>&1 || true; }

    section "date (UTC)" date -u
    section "hostname" hostname
    section "users" getent passwd
    section "privileged groups" getent group sudo wheel admin
    section "listening sockets" ss -tulpn
    section "ufw" ufw status verbose
    section "iptables" iptables-save
    section "sshd effective config" sshd -T
    section "logged-in users" who
    echo; echo "### system crontabs"
    cat /etc/crontab /etc/cron.d/* 2>/dev/null
    echo; echo "### user crontabs"
    while IFS=: read -r u _; do
        crontab -l -u "$u" 2>/dev/null | sed "s/^/[$u] /"
    done < <(getent passwd)
    if command -v dpkg >/dev/null 2>&1; then
        section "packages (dpkg)" dpkg --get-selections
    elif command -v rpm >/dev/null 2>&1; then
        section "packages (rpm)" rpm -qa
    fi
    echo; echo "### key file hashes"
    sha256sum /etc/passwd /etc/shadow /etc/group /etc/sudoers /etc/sudoers.d/* \
        /etc/ssh/sshd_config /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys 2>&1
    section "SUID files" find / -xdev -perm -4000 -type f
}

if [ "$STATE_SNAPSHOT" = true ]; then
    log "Collecting system state snapshot..."
    snapshot > "${OUTDIR}/${STATE_NAME}" 2>&1 || true
    OUT_FILES+=("$STATE_NAME")
fi

# --- tar options: probe for optional flags this tar supports ---
tar_help=$("$TAR_BIN" --help 2>&1 || true)
TAR_EXTRA=()
for flag in --xattrs --acls --selinux; do
    if grep -q -- "$flag" <<< "$tar_help"; then
        TAR_EXTRA+=("$flag")
    fi
done

EXCLUDES=(--exclude="$OUTDIR" --exclude=/var/log/journal --exclude=/var/cache --exclude=/var/tmp)
IFS=' ' read -r -a EXTRA_EX <<< "$EXTRA_EXCLUDES_STR"
for p in ${EXTRA_EX[@]+"${EXTRA_EX[@]}"}; do
    EXCLUDES+=(--exclude="$p")
done

# --- MySQL/MariaDB dump (a live copy of /var/lib/mysql may not restore cleanly) ---
if [ "$MYSQL_DUMP" = true ] && command -v mysqldump >/dev/null 2>&1; then
    log "Dumping MySQL databases (uses /root/.my.cnf for credentials)..."
    if mysqldump --single-transaction --routines --events --all-databases 2>>"$LOGFILE" \
         | gzip > "${OUTDIR}/${MYSQL_NAME}"; then
        log "MySQL dump OK."
        OUT_FILES+=("$MYSQL_NAME")
        EXCLUDES+=(--exclude=/var/lib/mysql)   # dump replaces the raw data dir
    else
        rm -f "${OUTDIR}/${MYSQL_NAME}"
        log "WARNING: mysqldump failed; falling back to raw /var/lib/mysql in the archive."
    fi
fi

# --- Create archive ---
log "Creating archive at: $ARCHIVE_PATH"
set +e
"$TAR_BIN" ${TAR_EXTRA[@]+"${TAR_EXTRA[@]}"} -czpf "$ARCHIVE_PATH" "${EXCLUDES[@]}" \
    "${BACKUP_TARGETS[@]}" 2>>"$LOGFILE"
tar_rc=$?
set -e
# tar exit 1 = "file changed as we read it" (normal on a live system); 2+ = real failure
if [ "$tar_rc" -gt 1 ]; then
    rm -f "$ARCHIVE_PATH"
    log "ERROR: tar failed (exit $tar_rc). See $LOGFILE."
    exit 5
elif [ "$tar_rc" -eq 1 ]; then
    log "WARNING: some files changed during archiving (tar exit 1); archive is still usable."
fi
log "Archive creation successful."

# --- Verify ---
log "Verifying archive integrity..."
if "$TAR_BIN" -tzf "$ARCHIVE_PATH" > /dev/null 2>>"$LOGFILE"; then
    log "Archive verification: OK"
else
    log "ERROR: Archive verification failed. See $LOGFILE."
    exit 6
fi

# --- Checksums (relative names so `sha256sum -c` works anywhere) ---
( cd "$OUTDIR" && sha256sum "${OUT_FILES[@]}" > "$SUMS_NAME" )
OUT_FILES+=("$SUMS_NAME")
log "Checksums written to $SUMS_NAME"

# --- Optional remote copy ---
REMOTE_OK=true
if [ "$REMOTE_COPY" = true ]; then
    if [ -z "$SCP_BIN" ]; then
        log "WARNING: scp not found, cannot copy to remote."
        REMOTE_OK=false
    else
        SCP_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o "StrictHostKeyChecking=${REMOTE_STRICT}")
        if [ -f "$REMOTE_KEY" ]; then
            SCP_OPTS+=(-i "$REMOTE_KEY")
        fi
        log "Copying to remote ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}..."
        if "$SCP_BIN" "${SCP_OPTS[@]}" "${OUT_FILES[@]/#/$OUTDIR/}" \
              "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}/" 2>>"$LOGFILE"; then
            log "Remote copy succeeded."
        else
            log "WARNING: Remote copy failed (check ufw egress, DNS, key, known_hosts)."
            REMOTE_OK=false
        fi
    fi
fi

# --- Retention: keep the newest $KEEP backup sets ---
prune_old() {
    local archives=() old_count i base
    mapfile -t archives < <(ls -1 "$OUTDIR"/system_backup_*.tar.gz 2>/dev/null | sort || true)
    old_count=$(( ${#archives[@]} - KEEP ))
    if [ "$old_count" -gt 0 ]; then
        for (( i = 0; i < old_count; i++ )); do
            base="${archives[$i]%.tar.gz}"
            log "Pruning old backup set: $(basename "$base")"
            if [ -n "$CHATTR_BIN" ]; then
                "$CHATTR_BIN" -i "${base}".* 2>/dev/null || true
            fi
            rm -f "${base}".*
        done
    fi
}
prune_old

log "==== Backup completed: $(date -u) ===="
echo "Final Archive: $ARCHIVE_PATH"
echo "Log File: $LOGFILE"

if [ "$REMOTE_OK" = false ]; then
    exit 10
fi
