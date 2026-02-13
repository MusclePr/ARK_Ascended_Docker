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
export MAINTENANCE_REQUEST_FILE="${SIGNALS_DIR}/maintenance.request"
export REQUEST_JSON="${SIGNALS_DIR}/request.json"
export LOCK_FILE="${SIGNALS_DIR}/maintenance.lock"
export WAITING_FILE="${SIGNALS_DIR}/waiting_${SERVER_PORT}.flag"
export ALLOWED_FILE="${SIGNALS_DIR}/ready.flag"
export MASTER_LOCK_DIR="${SIGNALS_DIR}/master.lock"
export MASTER_LOCK_OWNER_FILE="${MASTER_LOCK_DIR}/owner"
export UPDATING_FLAG="${SIGNALS_DIR}/updating.lock"
export RESUME_FLAG="${SIGNALS_DIR}/autoresume_${SERVER_PORT}.flag"
export STATUS_FILE="${SIGNALS_DIR}/status_${SERVER_PORT}"
export SESSION_NAME_LOCK="${SIGNALS_DIR}/session_name.lock"

RCON_CMDLINE=( rcon -a "127.0.0.1:${RCON_PORT}" -p "${ARK_ADMIN_PASSWORD}" )

CLUSTER_MASTER="${CLUSTER_MASTER:-false}"
if [[ -n "${SLAVE_PORTS:-}" ]]; then
    CLUSTER_MASTER=true
fi

# JSON request helpers
# Write JSON atomically into destination (validates JSON with jq)
json_atomic_write() {
    local dest="$1"
    local src="$2"
    mkdir -p "${SIGNALS_DIR}" 2>/dev/null || true
    local tmp
    tmp=$(mktemp "${SIGNALS_DIR}/.tmp.XXXXXX") || return 1
    if [[ -n "$src" && -f "$src" ]]; then
        cat "$src" > "$tmp"
    else
        # read from stdin
        cat - > "$tmp"
    fi
    # Validate JSON
    if ! jq -S . "$tmp" >/dev/null 2>&1; then
        LogError "Invalid JSON for $dest"
        rm -f "$tmp"
        return 1
    fi
    mv -f "$tmp" "$dest"
    return 0
}

# Create a JSON request file atomically. Usage: create_request_json <name> <json_file>
create_request_json() {
    # Unified single request file: ${REQUEST_JSON}
    local _name="$1" jsonfile="$2"
    mkdir -p "${SIGNALS_DIR}" 2>/dev/null || true
    # If a request already exists, reject to avoid overwriting
    if [[ -e "${REQUEST_JSON}" ]]; then
        LogError "A request already exists: ${REQUEST_JSON}"
        return 1
    fi
    json_atomic_write "${REQUEST_JSON}" "$jsonfile" || return 1
    return 0
}

# Move a processing request to done/failed with timestamped filename
# Usage: mark_request_status <request_path> <status>
mark_request_status() {
    local reqpath="$1"
    local status="$2"
    local base
    base=$(basename "$reqpath")
    local dest
    if [[ "$status" == "done" ]]; then
        dest="${SIGNALS_DIR}/${base%%.*}.done.json"
    else
        dest="${SIGNALS_DIR}/${base%%.*}.failed.json"
    fi
    mv -f "$reqpath" "$dest" 2>/dev/null || return 1

    # Delete files older than 7 days with .done or .failed extensions
    find "${SIGNALS_DIR}" -maxdepth 1 -type f \( -name "request.*.done.json" -o -name "request.*.failed.json" \) -mtime +7 -delete 2>/dev/null || true

    return 0
}

# Convenience wrapper: write a response JSON file atomically
# Usage: write_response_json <dest_path> <src_json_file>
write_response_json() {
    local dest="$1"
    local src="$2"
    json_atomic_write "$dest" "$src"
}

check_request_status() {
    local req_id="$1"
    local status_file
    status_file=$(find "${SIGNALS_DIR}" -maxdepth 1 -type f -name "request-${req_id}.*.json" 2>/dev/null | head -n 1)
    if [[ -z "$status_file" ]]; then
        echo "pending"
        return 0
    fi
    if [[ "$status_file" == *".done.json" ]]; then
        echo "done"
    elif [[ "$status_file" == *".failed.json" ]]; then
        echo "failed"
    else
        echo "unknown"
    fi
    return 0
}

wait_for_response() {
    # Wait for result
    LogInfo "Waiting for result to be processed..."
    local wait_interval=5 status
    while true; do
        sleep "$wait_interval"
        status=$(check_request_status "$req_id")
        case "$status" in
            done)
                echo "" 1>&2
                LogSuccess "Request completed successfully!"
                return 0
                ;;
            failed)
                echo "" 1>&2
                LogError "Request failed."
                return 1
                ;;
            pending)
                echo -n "." 1>&2
                ;;
            *)
                echo "" 1>&2
                LogInfo "Request status: $status."
                return 2
                ;;
        esac
    done
    return 0
}

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
    local prefix="${3:-}"
    local suffix="${4:-}"
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
    local path=$1 fname
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
    local CLEAN
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

    LogInfo "Waiting up to 120s for slave servers to ACK stop: ${targets[*]}"

    local all_ack=false
    local -a missing
    while true; do
        local now_epoch
        now_epoch=$(date +%s)

        if (( now_epoch - start_epoch >= 120 )); then
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
# Usage: enter_maintenance [stop|save] [--no-wait] [<start_epoch>]
# shellcheck disable=SC2120
enter_maintenance() {
    local action="stop"
    local no_wait=false
    local start_epoch=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            stop|save)
                action="$1"
                ;;
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
    LogInfo "Requesting Cluster Maintenance (${action})..."
    # Remove any previous ALLOWED_FILE to avoid immediate resume from stale state
    rm -f "$ALLOWED_FILE" 2>/dev/null || true
    # Remove stale waiting flags
    rm -f "${SIGNALS_DIR}/waiting_"*.flag 2>/dev/null || true
    
    # content: action (atomic write)
    local tmp_req
    tmp_req=$(mktemp "${SIGNALS_DIR}/maintenance.request.XXXXXX") && echo "$action" > "$tmp_req" && mv -f "$tmp_req" "$MAINTENANCE_REQUEST_FILE"

    LogInfo "Initiating Cluster Maintenance..."
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
    rm -f "$MAINTENANCE_REQUEST_FILE" 2>/dev/null || true
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
    enter_maintenance "$@"
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
    manager start

    if [[ -n "${SLAVE_PORTS}" ]]; then
        local waited=0
        local wait_interval=5
        LogInfo "Waiting for cluster allowed signal (ALLOWED_FILE)..."
        while [ "$waited" -lt "$wait_timeout" ]; do
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


get_pid() {
    local pid
    pid=$(pgrep GameThread)
    if [[ -z $pid ]]; then
        return 1
    fi
    echo "$pid"
    return 0
}

get_health() {
    local server_pid steam_pid
    server_pid=$(get_pid)
    steam_pid=$(pidof steamcmd)
    if [[ "${steam_pid:-0}" != 0 ]]; then
        echo "STARTING"
        return 0
    fi
    if [[ "${server_pid:-0}" != 0 ]]; then
        echo "UP"
        return 0
    else
        echo "DOWN"
        return 1
    fi
}

custom_rcon() {
    if ! get_health >/dev/null ; then
        return 1
    fi
    "${RCON_CMDLINE[@]}" "${@}" 2>/dev/null
    return 0
}

saveworld() {
    if ! get_health >/dev/null ; then
        LogWarn "Unable to save... Server not up"
        return 1
    fi

    LogInfo "Saving world..."
    local out res
    out=$(custom_rcon SaveWorld)
    res=$?
    if [[ $res == 0 && "$out" == "World Saved" ]]; then
        LogSuccess "Success!"
    else
        LogError "Failed."
        return 1
    fi
    # sleep is nessecary because the server seems to write save files after the saveworld function ends.
    sleep 5
}


acquire_session_name_lock() {
    LogInfo "Acquiring session name lock..."
    while ! mkdir "${SESSION_NAME_LOCK}" 2>/dev/null; do
        sleep 1
    done
    LogInfo "Session name lock acquired."
}

release_session_name_lock() {
    LogInfo "Releasing session name lock..."
    rmdir "${SESSION_NAME_LOCK}" 2>/dev/null
    LogInfo "Session name lock released."
}

wait_rcon_ready_and_release_lock() {
    LogInfo "Waiting for server to be ready for RCON to release session name lock..."
    # Wait for RCON to respond
    while ! "${RCON_CMDLINE[@]}" "ListPlayers" > /dev/null 2>&1; do
        sleep 10
    done
    LogSuccess "Server is ready. Releasing session name lock."
    release_session_name_lock
}
