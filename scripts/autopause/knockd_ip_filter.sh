#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=./scripts/manager/helper.sh
source "/opt/manager/helper.sh"

IP="${1:-}"
WHITELIST_PATH="${AUTO_PAUSE_KNOCKD_WHITELIST_PATH:-/opt/arkserver/knockd_whitelist.txt}"
BLACKLIST_PATH="${AUTO_PAUSE_KNOCKD_BLACKLIST_PATH:-/opt/arkserver/knockd_blacklist.txt}"
WHITELIST_AUTOUPDATE_SCRIPT="${AUTO_PAUSE_KNOCKD_WHITELIST_AUTOUPDATE_SCRIPT:-/opt/autopause/knockd_whitelist_autoupdate.sh}"
GREYLIST_APPEND_SCRIPT="${AUTO_PAUSE_KNOCKD_GREYLIST_APPEND_SCRIPT:-/opt/autopause/knockd_greylist_append.sh}"

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

append_greylist() {
    local reason="$1"
    if [[ -x "$GREYLIST_APPEND_SCRIPT" ]]; then
        "$GREYLIST_APPEND_SCRIPT" "$IP" "$reason" || true
    fi
}

if ! is_valid_ipv4 "$IP"; then
    LogWarn "Ignoring knockd trigger with invalid IP format: ${IP:-empty}"
    exit 0
fi

if [[ -x "$WHITELIST_AUTOUPDATE_SCRIPT" ]]; then
    "$WHITELIST_AUTOUPDATE_SCRIPT" || true
fi

if list_has_ip "$BLACKLIST_PATH" "$IP"; then
    append_greylist "blacklist_block"
    LogInfo "Blocked knockd unpause trigger from blacklisted IP: $IP"
    exit 0
fi

if list_has_ip "$WHITELIST_PATH" "$IP"; then
    LogInfo "Accepted knockd unpause trigger from whitelisted IP: $IP"
    manager unpause --apply "knockd connection from $IP"
    exit $?
fi

append_greylist "unknown_knockd_source"
LogInfo "Accepted knockd unpause trigger from unknown IP (not blacklisted): $IP"
manager unpause --apply "knockd connection from $IP"
exit $?
