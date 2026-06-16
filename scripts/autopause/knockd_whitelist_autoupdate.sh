#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=./scripts/manager/helper.sh
source "/opt/manager/helper.sh"

WHITELIST_PATH="${AUTO_PAUSE_KNOCKD_WHITELIST_PATH:-/opt/arkserver/knockd_whitelist.txt}"
BLACKLIST_PATH="${AUTO_PAUSE_KNOCKD_BLACKLIST_PATH:-/opt/arkserver/knockd_blacklist.txt}"
SOURCE_LOG_PATH="${LOG_PATH:-/opt/arkserver/ShooterGame/Saved/Logs/ShooterGame.log}"
LOOKBACK_LINES="${AUTO_PAUSE_KNOCKD_LOG_LOOKBACK_LINES:-5000}"
LOCK_DIR="${AUTO_PAUSE_WORK_DIR:-/tmp}/knockd_iplists.lock"

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

list_has_ip() {
    local list_file="$1"
    local ip="$2"
    [[ -f "$list_file" ]] || return 1
    grep -Eq "^[[:space:]]*${ip}([[:space:]]*(#.*)?)?$" "$list_file"
}

mkdir -p "$(dirname "$WHITELIST_PATH")" 2>/dev/null || true
mkdir -p "${AUTO_PAUSE_WORK_DIR:-/tmp}" 2>/dev/null || true

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

if [[ ! -f "$WHITELIST_PATH" ]]; then
    {
        echo "# knockd whitelist"
        echo "# one IPv4 per line, comments are allowed"
    } > "$WHITELIST_PATH"
fi

if [[ ! -f "$BLACKLIST_PATH" ]]; then
    {
        echo "# knockd blacklist"
        echo "# one IPv4 per line, comments are allowed"
    } > "$BLACKLIST_PATH"
fi

if [[ ! -f "$SOURCE_LOG_PATH" ]]; then
    exit 0
fi

mapfile -t extracted_ips < <(
    tail -n "$LOOKBACK_LINES" "$SOURCE_LOG_PATH" 2>/dev/null \
        | sed -n 's/.*IP for incoming account .* - IP \([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' \
        | sort -u
)

if (( ${#extracted_ips[@]} == 0 )); then
    exit 0
fi

now=$(date -Is)
source_log_name=$(basename "$SOURCE_LOG_PATH")
added=0
for ip in "${extracted_ips[@]}"; do
    if ! is_valid_ipv4 "$ip"; then
        continue
    fi
    if list_has_ip "$BLACKLIST_PATH" "$ip"; then
        continue
    fi
    if list_has_ip "$WHITELIST_PATH" "$ip"; then
        continue
    fi

    printf '%s # auto from %s %s\n' "$ip" "$source_log_name" "$now" >> "$WHITELIST_PATH"
    added=$((added + 1))
done

if (( added > 0 )); then
    LogInfo "Updated knockd whitelist: +${added} IP(s)"
fi

chown arkuser:arkuser "$WHITELIST_PATH" "$BLACKLIST_PATH" 2>/dev/null || true
chmod 664 "$WHITELIST_PATH" "$BLACKLIST_PATH" 2>/dev/null || true
