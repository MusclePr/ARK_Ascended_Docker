#!/bin/bash
#
# Log Definitions
#
export LINE='\n'
export RESET='\033[0m'       # Text Reset
export WhiteText='\033[0;37m'        # White

# Bold
export RedBoldText='\033[1;31m'         # Red
export GreenBoldText='\033[1;32m'       # Green
export YellowBoldText='\033[1;33m'      # Yellow
export CyanBoldText='\033[1;36m'        # Cyan

export LOG_PATH="${LOG_DIR}/${LOG_FILE:-ShooterGame.log}"

# Cluster signals common definitions
export SIGNALS_DIR="/opt/arkserver/.signals"
export REQUEST_FILE="${SIGNALS_DIR}/update.request"
export LOCK_FILE="${SIGNALS_DIR}/maintenance.lock"
export WAITING_FILE="${SIGNALS_DIR}/waiting_${SERVER_PORT}.flag"
export ALLOWED_FILE="${SIGNALS_DIR}/ready.flag"
export MASTER_LOCK_DIR="${SIGNALS_DIR}/master.lock"
export MASTER_LOCK_OWNER_FILE="${MASTER_LOCK_DIR}/owner"
export UPDATING_FLAG="${SIGNALS_DIR}/updating.lock"
export RESUME_FLAG="${SIGNALS_DIR}/autoresume_${SERVER_PORT}.flag"
export STATUS_FILE="${SIGNALS_DIR}/status_${SERVER_PORT}"

LogInfo() {
    Log "$1" "$WhiteText"
}
LogWarn() {
    Log "$1" "$YellowBoldText"
}
LogError() {
    Log "$1" "$RedBoldText"
}
LogSuccess() {
    Log "$1" "$GreenBoldText"
}
LogAction() {
    Log "$1" "$CyanBoldText" "<------- " " ------->"
}
Log() {
    local message="$1"
    local color="$2"
    local prefix="$3"
    local suffix="$4"
    printf "$color%s$RESET$LINE" "$prefix$message$suffix"
}

set_server_status() {
    local status="$1"
    mkdir -p "$(dirname "$STATUS_FILE")"
    echo -n "$status" > "$STATUS_FILE"
}

# Send Discord Message
# Level is optional variable defaulting to info
DiscordMessage() {
    local title="$1"
    local message="$2"
    local level="$3"
    local enabled="$4"
    local webhook_url="$5"
    if [ -z "$level" ]; then
        level="info"
    fi
    if [ -n "${DISCORD_WEBHOOK_URL}" ]; then
        /opt/manager/discord.sh "$title" "$message" "$level" "$enabled" "$webhook_url"
    fi
}

SelectArchive() {
    set -e
    path=$1
    select fname in $path/*; do
        echo "$fname"
        break;
    done
    if [[ $REPLY == "" ]]; then
        LogError "Invalid input. Please enter a valid number."
        return 1
    fi
    return 0
}

sanitize() {
CLEAN=${1//_/}
CLEAN=${CLEAN// /_}
CLEAN=${CLEAN//[^a-zA-Z0-9_]/}
CLEAN=$(echo -n "$CLEAN" | tr '[:upper:]' '[:lower:]')
echo "$CLEAN"
return 0
}

wait_for_slave_acks() {
    local start_epoch="$1"

    if [[ -z "${SLAVE_PORTS:-}" ]]; then
        LogInfo "SLAVE_PORTS is not set. Skipping ACK wait."
        return 0
    fi

    local -a ports
    IFS=',' read -r -a ports <<< "${SLAVE_PORTS}" || true

    local -a targets
    local p
    for p in "${ports[@]}"; do
        p="${p//[[:space:]]/}"
        [[ -z "$p" ]] && continue
        [[ "$p" == "${SERVER_PORT}" ]] && continue
        targets+=("$p")
    done

    if [[ ${#targets[@]} -eq 0 ]]; then
        LogInfo "SLAVE_PORTS is empty after filtering. Skipping ACK wait."
        return 0
    fi

    LogInfo "Waiting up to 70s for slave servers to ACK stop: ${targets[*]}"

    local all_ack=false
    local -a missing
    while true; do
        local now_epoch
        now_epoch=$(date +%s)

        if (( now_epoch - start_epoch >= 70 )); then
            break
        fi

        all_ack=true
        missing=()

        for p in "${targets[@]}"; do
            if [[ ! -f "${SIGNALS_DIR}/waiting_${p}.flag" ]]; then
                all_ack=false
                missing+=("$p")
            fi
        done

        if [[ "$all_ack" == true ]]; then
            LogInfo "All slave servers ACKed."
            return 0
        fi

        sleep 2
    done

    LogWarn "Timed out waiting for ACKs. Proceeding without: ${missing[*]:-unknown}"
    return 0
}


# Enter maintenance mode: request cluster maintenance and (optionally) wait for slaves to ACK
# Usage: enter_maintenance [--no-wait] [<start_epoch>]
enter_maintenance() {
    local no_wait=false
    local start_epoch
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-wait)
                no_wait=true
                ;;
            *)
                start_epoch="$1"
                ;;
        esac
        shift
    done

    mkdir -p "${SIGNALS_DIR}" 2>/dev/null || true
    LogInfo "Requesting Cluster Maintenance..."
    # Remove any previous ALLOWED_FILE to avoid immediate resume from stale state
    rm -f "$ALLOWED_FILE" 2>/dev/null || true
    touch "$REQUEST_FILE" 2>/dev/null || true

    LogInfo "Initiating Cluster Maintenance..."
    touch "$LOCK_FILE" 2>/dev/null || true

    if [[ "$no_wait" == false ]]; then
        if [[ -z "$start_epoch" ]]; then
            start_epoch=$(date +%s)
        fi
        wait_for_slave_acks "$start_epoch"
    else
        LogInfo "Skipping wait for slave ACKs (--no-wait)"
    fi
}


# Exit maintenance mode: remove maintenance locks and flags
# Does NOT create ALLOWED_FILE; that file is created by the master when RCON is ready
exit_maintenance() {
    LogInfo "Releasing cluster maintenance locks..."
    rm -f "$UPDATING_FLAG" 2>/dev/null || true
    rm -f "$LOCK_FILE" 2>/dev/null || true
    rm -f "$REQUEST_FILE" 2>/dev/null || true
    rm -f "$WAITING_FILE" 2>/dev/null || true
}


# Convenience wrapper: run an action while in maintenance mode.
# Usage: with_maintenance <command...>
# Behavior: enters maintenance, runs the command, on success exits maintenance.
# On failure, it keeps the locks in place for manual intervention and returns non-zero.
with_maintenance() {
    if [[ $# -eq 0 ]]; then
        LogError "with_maintenance: no command provided"
        return 2
    fi
    local cmd
    cmd="$*"
    enter_maintenance
    if ! bash -c "$cmd"; then
        LogError "Command inside maintenance failed: $cmd"
        LogError "Keeping maintenance locks for manual inspection."
        return 1
    fi
    exit_maintenance
    return 0
}


# Master release helper: start master, wait for RCON readiness (ALLOWED_FILE), then exit maintenance
# Usage: master_release_after_start [wait_timeout_seconds]
master_release_after_start() {
    local wait_timeout=${1:-900}

    LogInfo "Master releasing: starting server and waiting for cluster readiness (timeout ${wait_timeout}s)"
    start

    if [[ -n "${SLAVE_PORTS}" ]]; then
        local waited=0
        local wait_interval=5
        LogInfo "Waiting for cluster allowed signal (ALLOWED_FILE)..."
        while [ $waited -lt $wait_timeout ]; do
            if [[ -f "$ALLOWED_FILE" ]]; then
                LogSuccess "ALLOWED_FILE detected. Proceeding to release maintenance locks."
                break
            fi
            sleep $wait_interval
            waited=$((waited + wait_interval))
        done
        if [[ ! -f "$ALLOWED_FILE" ]]; then
            LogWarn "Timeout waiting for ALLOWED_FILE (${wait_timeout}s). Proceeding to release locks to avoid prolonged downtime."
        fi
    else
        LogInfo "Single-node mode or no SLAVE_PORTS configured; skipping ALLOWED_FILE wait."
    fi

    exit_maintenance
}

