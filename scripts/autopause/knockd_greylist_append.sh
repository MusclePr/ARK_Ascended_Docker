#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=./scripts/manager/helper.sh
source "/opt/manager/helper.sh"

IP="${1:-}"
REASON="${2:-knockd attempt}"

GREYLIST_PATH="${AUTO_PAUSE_KNOCKD_GREYLIST_PATH:-/opt/arkserver/knockd_greylist.txt}"
LOCK_DIR="${AUTO_PAUSE_WORK_DIR:-/tmp}/knockd_greylist.lock"
LOOKUP_TIMEOUT_SEC="${AUTO_PAUSE_KNOCKD_RDNS_TIMEOUT_SEC:-2}"

sanitize_field() {
    echo "$1" | tr '\n\r|' '   '
}

is_valid_ipv4() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local IFS='.'
    local -a parts=()
    read -r -a parts <<< "$ip"
    local p
    for p in "${parts[@]}"; do
        [[ "$p" =~ ^[0-9]+$ ]] || return 1
        if (( 10#$p < 0 || 10#$p > 255 )); then
            return 1
        fi
    done
    return 0
}

reverse_lookup() {
    local ip="$1"
    local host=""

    if command -v getent >/dev/null 2>&1; then
        host=$(timeout "$LOOKUP_TIMEOUT_SEC" getent hosts "$ip" 2>/dev/null | awk 'NR==1{print $2}' || true)
    fi

    if [[ -z "$host" ]] && command -v nslookup >/dev/null 2>&1; then
        host=$(timeout "$LOOKUP_TIMEOUT_SEC" nslookup "$ip" 2>/dev/null | awk -F'= ' '/name = /{print $2; exit}' | sed 's/\.$//' || true)
    fi

    if [[ -z "$host" ]]; then
        host="unknown"
    fi

    sanitize_field "$host"
}

if ! is_valid_ipv4 "$IP"; then
    exit 0
fi

mkdir -p "$(dirname "$GREYLIST_PATH")" 2>/dev/null || true
mkdir -p "${AUTO_PAUSE_WORK_DIR:-/tmp}" 2>/dev/null || true

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    # Another writer is updating the file; this event is non-critical.
    exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

if [[ ! -f "$GREYLIST_PATH" ]]; then
    {
        echo "# knockd greylist"
        echo "# format: ip|hostname|first_seen|last_seen|hit_count|last_reason"
    } > "$GREYLIST_PATH"
fi

REASON=$(sanitize_field "$REASON")
NOW=$(date -Is)
HOSTNAME=$(reverse_lookup "$IP")
TMP_FILE=$(mktemp "$(dirname "$GREYLIST_PATH")/.greylist.XXXXXX")

awk -F'|' -v OFS='|' -v ip="$IP" -v host="$HOSTNAME" -v now="$NOW" -v reason="$REASON" '
BEGIN { updated=0 }
/^#/ || NF==0 { print $0; next }
{
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1)
    if ($1 == ip) {
        local_host=$2
        if (local_host == "" || local_host == "unknown") {
            local_host=host
        }
        count=$5
        if (count !~ /^[0-9]+$/) {
            count=0
        }
        count=count+1
        print ip, local_host, $3, now, count, reason
        updated=1
        next
    }
    print $0
}
END {
    if (!updated) {
        print ip, host, now, now, 1, reason
    }
}
' "$GREYLIST_PATH" > "$TMP_FILE"

mv -f "$TMP_FILE" "$GREYLIST_PATH"
chown arkuser:arkuser "$GREYLIST_PATH" 2>/dev/null || true
chmod 664 "$GREYLIST_PATH" 2>/dev/null || true
