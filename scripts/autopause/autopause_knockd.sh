#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=./scripts/manager/helper.sh
source "/opt/manager/helper.sh"

KNOCKD_CONF="${AUTO_PAUSE_KNOCKD_CONF}"
KNOCKD_PID_FILE="${AUTO_PAUSE_KNOCKD_PID_FILE}"
AUTO_PAUSE_DISABLED_LOCK="${AUTO_PAUSE_DISABLED_LOCK:-${AUTO_PAUSE_WORK_DIR}/disabled.lock}"
ACTION="${1:-start}"

if [[ "$(id -un 2>/dev/null || true)" != "arkuser" ]]; then
    echo "ERROR: autopause_knockd.sh must be executed as arkuser." >&2
    exit 1
fi

if [[ "$ACTION" != "start" && "$ACTION" != "stop" ]]; then
    echo "ERROR: invalid action '$ACTION' (expected: start|stop)." >&2
    exit 2
fi

mkdir -p "$AUTO_PAUSE_WORK_DIR" 2>/dev/null || true

is_knockd_running() {
    local pid="${1:-}"
    [[ -n "$pid" ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    ps -p "$pid" -o args= 2>/dev/null | grep -q "knockd"
}

stop_knockd() {
    if [[ ! -f "$KNOCKD_PID_FILE" ]]; then
        return 0
    fi

    local old_pid
    old_pid=$(cat "$KNOCKD_PID_FILE" 2>/dev/null || echo "")
    if is_knockd_running "$old_pid"; then
        kill "$old_pid" 2>/dev/null || true
    fi

    rm -f "$KNOCKD_PID_FILE" 2>/dev/null || true
    return 0
}

if [[ "$ACTION" == "stop" ]]; then
    stop_knockd
    exit 0
fi

if [[ -f "$AUTO_PAUSE_DISABLED_LOCK" ]]; then
    stop_knockd
    exit 0
fi

if [[ -f "$KNOCKD_PID_FILE" ]]; then
    old_pid=$(cat "$KNOCKD_PID_FILE" 2>/dev/null || echo "")
    if is_knockd_running "$old_pid"; then
        exit 0
    fi
    rm -f "$KNOCKD_PID_FILE" 2>/dev/null || true
fi

cat > "$KNOCKD_CONF" <<EOF
[autopause_server_${SERVER_PORT}]
    sequence = ${SERVER_PORT}:udp
    seq_cooldown = 5
    command = manager unpause --apply

EOF

knockd -c "$KNOCKD_CONF" &
echo "$!" > "$KNOCKD_PID_FILE"
