#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=./scripts/manager/helper.sh
source "/opt/manager/helper.sh"

COMMAND="${1:-}"
IP="${2:-}"
COMMENT="${*:3}"
WHITELIST_PATH="${AUTO_PAUSE_KNOCKD_WHITELIST_PATH:-/opt/arkserver/knockd_whitelist.txt}"
BLACKLIST_PATH="${AUTO_PAUSE_KNOCKD_BLACKLIST_PATH:-/opt/arkserver/knockd_blacklist.txt}"
GREYLIST_PATH="${AUTO_PAUSE_KNOCKD_GREYLIST_PATH:-/opt/arkserver/knockd_greylist.txt}"
GREYLIST_APPEND_SCRIPT="${AUTO_PAUSE_KNOCKD_GREYLIST_APPEND_SCRIPT:-/opt/autopause/knockd_greylist_append.sh}"

show_usage() {
        cat <<EOF
Usage:
    knockd_ip_filter.sh
    knockd_ip_filter.sh unpause <ipv4> [comment]
    knockd_ip_filter.sh check <ipv4>
    knockd_ip_filter.sh white <ipv4> [comment]
    knockd_ip_filter.sh black <ipv4> [comment]

Notes:
    - IPv4 only.
    - Legacy mode is supported: if the first argument is an IPv4 address,
        it is handled as unpause <ipv4> for knockd backward compatibility.
    - white/black enforce exclusive membership across whitelist/blacklist/greylist.
EOF
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

list_has_ip() {
    local list_file="$1"
    local ip="$2"
    [[ -f "$list_file" ]] || return 1
    grep -Eq "^[[:space:]]*${ip}([[:space:]]*(#.*)?)?$" "$list_file"
}

json_escape() {
    local s="$1"
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/ }
    s=${s//$'\r'/ }
    s=${s//$'\t'/ }
    printf '%s' "$s"
}

sanitize_comment() {
    local s="$1"
    s=${s//$'\n'/ }
    s=${s//$'\r'/ }
    s=${s//$'|'/ }
    printf '%s' "$s" | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
}

ensure_list_files() {
    mkdir -p "$(dirname "$WHITELIST_PATH")" 2>/dev/null || true
    mkdir -p "$(dirname "$BLACKLIST_PATH")" 2>/dev/null || true
    mkdir -p "$(dirname "$GREYLIST_PATH")" 2>/dev/null || true

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

    if [[ ! -f "$GREYLIST_PATH" ]]; then
        {
            echo "# knockd greylist"
            echo "# format: ip|hostname|first_seen|last_seen|hit_count|last_reason"
        } > "$GREYLIST_PATH"
    fi

    chown arkuser:arkuser "$WHITELIST_PATH" "$BLACKLIST_PATH" "$GREYLIST_PATH" 2>/dev/null || true
    chmod 664 "$WHITELIST_PATH" "$BLACKLIST_PATH" "$GREYLIST_PATH" 2>/dev/null || true
}

remove_ip_from_plain_list() {
    local list_file="$1"
    local ip="$2"
    [[ -f "$list_file" ]] || return 0

    local tmp_file
    tmp_file="${list_file}.tmp.$$"
    awk -v ip="$ip" '
        !match($0, "^[[:space:]]*" ip "([[:space:]]*(#.*)?)?$") { print }
    ' "$list_file" > "$tmp_file"
    mv -f "$tmp_file" "$list_file"
}

remove_ip_from_greylist() {
    local ip="$1"
    [[ -f "$GREYLIST_PATH" ]] || return 0

    local tmp_file
    tmp_file="${GREYLIST_PATH}.tmp.$$"
    awk -F'|' -v ip="$ip" '
        /^#/ { print; next }
        NF == 0 { print; next }
        $1 != ip { print }
    ' "$GREYLIST_PATH" > "$tmp_file"
    mv -f "$tmp_file" "$GREYLIST_PATH"
}

get_plain_list_entry() {
    local list_file="$1"
    local ip="$2"
    [[ -f "$list_file" ]] || return 1
    grep -E "^[[:space:]]*${ip}([[:space:]]*(#.*)?)?$" "$list_file" | tail -n 1
}

get_greylist_payload() {
    local ip="$1"
    [[ -f "$GREYLIST_PATH" ]] || return 1
    awk -F'|' -v ip="$ip" '
        $1 == ip {
            print $2 "|" $3 "|" $4 "|" $5 "|" $6
            found = 1
        }
        END { exit(found ? 0 : 1) }
    ' "$GREYLIST_PATH" | tail -n 1
}

upsert_plain_list_entry() {
    local list_file="$1"
    local ip="$2"
    local raw_comment="$3"
    local comment
    comment=$(sanitize_comment "$raw_comment")

    remove_ip_from_plain_list "$list_file" "$ip"
    if [[ -n "$comment" ]]; then
        printf '%s # %s\n' "$ip" "$comment" >> "$list_file"
    else
        printf '%s\n' "$ip" >> "$list_file"
    fi
}

append_greylist() {
    local ip="$1"
    local reason="$2"
    if [[ -x "$GREYLIST_APPEND_SCRIPT" ]]; then
        "$GREYLIST_APPEND_SCRIPT" "$ip" "$reason" || true
    fi
}

do_unpause() {
    local ip="$1"
    local reason="${2:-by console}"

    if ! is_valid_ipv4 "$ip"; then
        LogWarn "Ignoring knockd trigger with invalid IP format: ${ip:-empty}"
        return 0
    fi

    if list_has_ip "$BLACKLIST_PATH" "$ip"; then
        LogInfo "Blocked knockd unpause trigger from blacklisted IP: $ip"
        return 0
    fi

    if list_has_ip "$WHITELIST_PATH" "$ip"; then
        LogInfo "Accepted knockd unpause trigger from whitelisted IP: $ip"
        manager unpause --apply "knockd connection from $ip"
        return $?
    fi

    append_greylist "$ip" "$reason"
    LogInfo "Accepted knockd unpause trigger from unknown IP (not blacklisted): $ip"
    manager unpause --apply "knockd connection from $ip"
    return $?
}

do_check() {
    local ip="$1"
    if ! is_valid_ipv4 "$ip"; then
        LogError "Invalid IPv4 address: ${ip:-empty}"
        return 1
    fi

    local in_whitelist=false
    local in_blacklist=false
    local in_greylist=false
    local whitelist_entry=""
    local blacklist_entry=""
    local grey_payload=""
    local grey_host=""
    local grey_first=""
    local grey_last=""
    local grey_hits=""
    local grey_reason=""

    if list_has_ip "$WHITELIST_PATH" "$ip"; then
        in_whitelist=true
        whitelist_entry=$(get_plain_list_entry "$WHITELIST_PATH" "$ip" || true)
    fi

    if list_has_ip "$BLACKLIST_PATH" "$ip"; then
        in_blacklist=true
        blacklist_entry=$(get_plain_list_entry "$BLACKLIST_PATH" "$ip" || true)
    fi

    if grey_payload=$(get_greylist_payload "$ip" 2>/dev/null); then
        in_greylist=true
        IFS='|' read -r grey_host grey_first grey_last grey_hits grey_reason <<< "$grey_payload"
    fi

    printf '{\n'
    printf '  "ip": "%s",\n' "$(json_escape "$ip")"
    printf '  "valid_ipv4": true,\n'
    printf '  "in_whitelist": %s,\n' "$in_whitelist"
    printf '  "in_blacklist": %s,\n' "$in_blacklist"
    printf '  "in_greylist": %s,\n' "$in_greylist"

    if [[ -n "$whitelist_entry" ]]; then
        printf '  "whitelist_entry": "%s",\n' "$(json_escape "$whitelist_entry")"
    else
        printf '  "whitelist_entry": null,\n'
    fi

    if [[ -n "$blacklist_entry" ]]; then
        printf '  "blacklist_entry": "%s",\n' "$(json_escape "$blacklist_entry")"
    else
        printf '  "blacklist_entry": null,\n'
    fi

    if [[ "$in_greylist" == "true" ]]; then
        printf '  "greylist": {\n'
        printf '    "hostname": "%s",\n' "$(json_escape "$grey_host")"
        printf '    "first_seen": "%s",\n' "$(json_escape "$grey_first")"
        printf '    "last_seen": "%s",\n' "$(json_escape "$grey_last")"
        printf '    "hit_count": "%s",\n' "$(json_escape "$grey_hits")"
        printf '    "last_reason": "%s"\n' "$(json_escape "$grey_reason")"
        printf '  }\n'
    else
        printf '  "greylist": null\n'
    fi
    printf '}\n'
}

do_mark() {
    local target="$1"
    local ip="$2"
    local comment="${3:-}"

    if ! is_valid_ipv4 "$ip"; then
        LogError "Invalid IPv4 address: ${ip:-empty}"
        return 1
    fi

    ensure_list_files

    if [[ -z "$comment" ]]; then
        comment=$(get_greylist_payload "$ip" 2>/dev/null || true)
    fi
    if [[ -z "$comment" ]]; then
        comment="manual $(date -Is)"
    fi

    case "$target" in
        white)
            upsert_plain_list_entry "$WHITELIST_PATH" "$ip" "$comment"
            remove_ip_from_plain_list "$BLACKLIST_PATH" "$ip"
            remove_ip_from_greylist "$ip"
            LogInfo "Updated whitelist for IP: $ip"
            ;;
        black)
            upsert_plain_list_entry "$BLACKLIST_PATH" "$ip" "$comment"
            remove_ip_from_plain_list "$WHITELIST_PATH" "$ip"
            remove_ip_from_greylist "$ip"
            LogInfo "Updated blacklist for IP: $ip"
            ;;
        *)
            LogError "Unsupported list target: $target"
            return 1
            ;;
    esac

    chown arkuser:arkuser "$WHITELIST_PATH" "$BLACKLIST_PATH" "$GREYLIST_PATH" 2>/dev/null || true
    chmod 664 "$WHITELIST_PATH" "$BLACKLIST_PATH" "$GREYLIST_PATH" 2>/dev/null || true
}

# Backward compatibility: knockd currently calls this script with only `%IP%`.
if [[ -n "$COMMAND" && -z "$IP" && "$COMMAND" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    IP="$COMMAND"
    COMMAND="unpause"
fi

case "$COMMAND" in
    "")
        show_usage
        exit 0
        ;;
    unpause)
        if [[ -z "$IP" ]]; then
            LogError "Usage: knockd_ip_filter.sh unpause <ipv4> [comment]"
            exit 1
        fi
        do_unpause "$IP" "$COMMENT"
        exit $?
        ;;
    check)
        if [[ -z "$IP" ]]; then
            LogError "Usage: knockd_ip_filter.sh check <ipv4>"
            exit 1
        fi
        do_check "$IP"
        exit $?
        ;;
    white)
        if [[ -z "$IP" ]]; then
            LogError "Usage: knockd_ip_filter.sh white <ipv4> [comment]"
            exit 1
        fi
        do_mark "white" "$IP" "$COMMENT"
        exit $?
        ;;
    black)
        if [[ -z "$IP" ]]; then
            LogError "Usage: knockd_ip_filter.sh black <ipv4> [comment]"
            exit 1
        fi
        do_mark "black" "$IP" "$COMMENT"
        exit $?
        ;;
    *)
        LogError "Unknown command: $COMMAND"
        show_usage
        exit 1
        ;;
esac
