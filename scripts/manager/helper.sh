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
export SERVER_SIGNALS_DIR="${SIGNALS_DIR}/server_${SERVER_PORT}"
export CLUSTER_SIGNALS_DIR="${SIGNALS_DIR}/cluster"
export MAINTENANCE_REQUEST_FILE="${CLUSTER_SIGNALS_DIR}/maintenance.request"
export REQUEST_JSON="${SERVER_SIGNALS_DIR}/request.json"
export CLUSTER_REQUEST_JSON="${CLUSTER_SIGNALS_DIR}/request.json"
export LOCK_FILE="${CLUSTER_SIGNALS_DIR}/maintenance.lock"
export WAITING_FILE="${SERVER_SIGNALS_DIR}/waiting.flag"
export MASTER_READY_FILE="${CLUSTER_SIGNALS_DIR}/master_ready.flag"
export MASTER_LOCK_DIR="${CLUSTER_SIGNALS_DIR}/master.lock"
export MASTER_LOCK_OWNER_FILE="${MASTER_LOCK_DIR}/owner"
export UPDATING_FLAG="${CLUSTER_SIGNALS_DIR}/updating.lock"
export STATUS_FILE="${SERVER_SIGNALS_DIR}/status"
export SESSION_NAME_LOCK="${CLUSTER_SIGNALS_DIR}/session_name.lock"

# shellcheck source=./scripts/autopause/helper.sh
source "/opt/autopause/helper.sh"

RCON_CMDLINE=( rcon -a "127.0.0.1:${RCON_PORT}" -p "${ARK_ADMIN_PASSWORD}" )

server_signals_dir_for_port() {
    local port="$1"
    echo "${SIGNALS_DIR}/server_${port}"
}

waiting_file_for_port() {
    local port="$1"
    local dir
    dir=$(server_signals_dir_for_port "$port")
    echo "${dir}/waiting.flag"
}

CLUSTER_MASTER="${CLUSTER_MASTER:-false}"
CLUSTER_NODES="${CLUSTER_NODES:-1}"
CLUSTER_PORTS_INITIALIZED=false
declare -a CLUSTER_PORTS=()

port_is_valid() {
    local port="$1"
    if [[ ! "$port" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    if (( 10#$port < 1 || 10#$port > 65535 )); then
        return 1
    fi
    return 0
}

initialize_cluster_ports() {
    if [[ "$CLUSTER_PORTS_INITIALIZED" == "true" ]]; then
        return 0
    fi

    if ! port_is_valid "$SERVER_PORT"; then
        LogError "SERVER_PORT is invalid: ${SERVER_PORT:-<empty>}"
        return 1
    fi

    mkdir -p "$SIGNALS_DIR" "$SERVER_SIGNALS_DIR" "$CLUSTER_SIGNALS_DIR" 2>/dev/null || true

    if [[ "${CLUSTER_MASTER,,}" != "true" ]]; then
        CLUSTER_PORTS=("$SERVER_PORT")
        CLUSTER_PORTS_INITIALIZED=true
        return 0
    fi

    if [[ ! "$CLUSTER_NODES" =~ ^[0-9]+$ ]] || (( 10#$CLUSTER_NODES < 1 )); then
        LogError "CLUSTER_NODES must be a positive integer. Current value: ${CLUSTER_NODES:-<empty>}"
        return 1
    fi

    local expected_nodes
    expected_nodes=$((10#$CLUSTER_NODES))
    local timeout_sec=10
    local waited=0
    local -a discovered_ports=()

    while (( waited <= timeout_sec )); do
        mapfile -t discovered_ports < <(
            find "$SIGNALS_DIR" -mindepth 1 -maxdepth 1 -type d -name 'server_*' -printf '%f\n' 2>/dev/null \
                | sed -n 's/^server_//p' \
                | awk '/^[0-9]+$/ && $1 >= 1 && $1 <= 65535' \
                | sort -n -u
        )

        if (( ${#discovered_ports[@]} >= expected_nodes )); then
            if (( ${#discovered_ports[@]} > expected_nodes )); then
                LogWarn "Detected ${#discovered_ports[@]} server directories. Using lowest ${expected_nodes} ports."
            fi
            CLUSTER_PORTS=("${discovered_ports[@]:0:expected_nodes}")
            CLUSTER_PORTS_INITIALIZED=true
            LogInfo "Cluster ports detected: ${CLUSTER_PORTS[*]}"
            return 0
        fi

        sleep 1
        waited=$((waited + 1))
    done

    LogError "Timed out after ${timeout_sec}s waiting for cluster nodes. Expected=${expected_nodes}, detected=${#discovered_ports[@]} (${discovered_ports[*]:-none})"
    return 1
}

# JSON request helpers
# Write JSON atomically into destination (validates JSON with jq)
json_atomic_write() {
    local dest="$1"
    local src="$2"
    local dest_dir
    dest_dir=$(dirname "$dest")
    mkdir -p "$dest_dir" 2>/dev/null || true
    local tmp
    tmp=$(mktemp "${dest_dir}/.tmp.XXXXXX") || return 1
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
    # Per-server request file: ${REQUEST_JSON}
    local _name="$1" jsonfile="$2"
    mkdir -p "$(dirname "${REQUEST_JSON}")" 2>/dev/null || true
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
    local reqdir
    reqdir=$(dirname "$reqpath")
    local base
    base=$(basename "$reqpath")
    local stem
    stem="${base%.json}"
    local dest
    if [[ "$status" == "done" ]]; then
        dest="${reqdir}/${stem}.done.json"
    else
        dest="${reqdir}/${stem}.failed.json"
    fi
    mv -f "$reqpath" "$dest" 2>/dev/null || return 1

    # Delete files older than 7 days with .done or .failed extensions
    find "${reqdir}" -maxdepth 1 -type f \( -name "request-*.done.json" -o -name "request-*.failed.json" \) -mtime +7 -delete 2>/dev/null || true

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
    status_file=$(find "${SERVER_SIGNALS_DIR}" -maxdepth 1 -type f -name "request-${req_id}.*.json" 2>/dev/null | head -n 1)
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
    local req_id="$1"
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

create_request_json_for_port() {
    local port="$1"
    local jsonfile="$2"
    local request_json_for_port
    request_json_for_port="$(server_signals_dir_for_port "$port")/request.json"

    mkdir -p "$(dirname "$request_json_for_port")" 2>/dev/null || true
    if [[ -e "$request_json_for_port" ]]; then
        LogError "A request already exists: ${request_json_for_port}"
        return 1
    fi
    json_atomic_write "$request_json_for_port" "$jsonfile" || return 1
    return 0
}

create_cluster_request_json() {
    local jsonfile="$1"
    mkdir -p "${CLUSTER_SIGNALS_DIR}" 2>/dev/null || true
    if [[ -e "${CLUSTER_REQUEST_JSON}" ]]; then
        LogError "A cluster request already exists: ${CLUSTER_REQUEST_JSON}"
        return 1
    fi
    json_atomic_write "${CLUSTER_REQUEST_JSON}" "$jsonfile" || return 1
    return 0
}

check_request_status_for_port() {
    local req_id="$1"
    local port="$2"
    local server_dir
    server_dir="$(server_signals_dir_for_port "$port")"

    local status_file
    status_file=$(find "$server_dir" -maxdepth 1 -type f -name "request-${req_id}.*.json" 2>/dev/null | head -n 1)
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

check_cluster_request_status() {
    local req_id="$1"
    local status_file
    status_file=$(find "${CLUSTER_SIGNALS_DIR}" -maxdepth 1 -type f -name "request-${req_id}.*.json" 2>/dev/null | head -n 1)
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

wait_for_cluster_response() {
    local req_id="$1"
    LogInfo "Waiting for cluster request to be processed..."
    local wait_interval=5 status
    while true; do
        sleep "$wait_interval"
        status=$(check_cluster_request_status "$req_id")
        case "$status" in
            done)
                echo "" 1>&2
                LogSuccess "Cluster request completed successfully!"
                return 0
                ;;
            failed)
                echo "" 1>&2
                LogError "Cluster request failed."
                return 1
                ;;
            pending)
                echo -n "." 1>&2
                ;;
            *)
                echo "" 1>&2
                LogInfo "Cluster request status: $status."
                return 2
                ;;
        esac
    done
    return 0
}

wait_for_cluster_request_acks() {
    local req_id="$1"
    local action="$2"
    local start_epoch="$3"
    local strict="$4"
    shift 4
    local -a targets=("$@")

    if [[ ${#targets[@]} -eq 0 ]]; then
        LogError "No cluster targets to wait for."
        return 1
    fi

    local timeout_sec=120
    local -a pending=()
    local -a failed=()
    local -a unknown=()
    local port status now_epoch

    while true; do
        now_epoch=$(date +%s)
        if (( now_epoch - start_epoch >= timeout_sec )); then
            break
        fi

        pending=()
        failed=()
        unknown=()

        for port in "${targets[@]}"; do
            status=$(check_request_status_for_port "$req_id" "$port")
            case "$status" in
                done)
                    ;;
                pending)
                    pending+=("$port")
                    ;;
                failed)
                    failed+=("$port")
                    ;;
                *)
                    unknown+=("$port")
                    ;;
            esac
        done

        if [[ ${#pending[@]} -eq 0 && ${#unknown[@]} -eq 0 ]]; then
            if [[ ${#failed[@]} -eq 0 ]]; then
                LogSuccess "All cluster nodes ACKed ${action}."
                return 0
            fi

            if [[ "$strict" == "true" ]]; then
                LogError "Cluster ${action} failed on: ${failed[*]}"
                return 1
            fi

            LogWarn "Cluster ${action} partially failed: ${failed[*]}. Proceeding."
            return 0
        fi

        sleep 2
    done

    if [[ "$strict" == "true" ]]; then
        LogError "Timed out waiting for cluster ${action} ACKs. Pending: ${pending[*]:-none} Unknown: ${unknown[*]:-none} Failed: ${failed[*]:-none}"
        return 1
    fi

    LogWarn "Timed out waiting for cluster ${action} ACKs. Pending: ${pending[*]:-none} Unknown: ${unknown[*]:-none} Failed: ${failed[*]:-none}. Proceeding."
    return 0
}

dispatch_cluster_action_to_nodes() {
    local action="$1"
    local option="$2"
    local start_epoch="${3:-$(date +%s)}"
    local req_id="${4:-$(date +%s)-$$-$RANDOM}"

    if ! initialize_cluster_ports; then
        return 1
    fi

    local ts
    ts=$(date -Is 2>/dev/null || date +%s)

    local port payload
    for port in "${CLUSTER_PORTS[@]}"; do
        payload=$(mktemp)
        jq -n \
            --arg action "$action" \
            --arg option "$option" \
            --arg request_id "$req_id" \
            --arg target_port "$port" \
            --arg requested_by "${USER:-$(whoami 2>/dev/null || echo unknown)}" \
            --arg timestamp "$ts" \
            '{action:$action,option:$option,request_id:$request_id,target_port:$target_port,requested_by:$requested_by,timestamp:$timestamp}' > "$payload"

        if ! create_request_json_for_port "$port" "$payload"; then
            rm -f "$payload"
            LogError "Failed to create ${action} request for port ${port}."
            return 1
        fi
        rm -f "$payload"
    done

    local strict=false
    if [[ "$action" == "stop" || "$action" == "save" ]]; then
        strict=true
    fi
    wait_for_cluster_request_acks "$req_id" "$action" "$start_epoch" "$strict" "${CLUSTER_PORTS[@]}"
}

request_cluster_action() {
    local action="$1"
    local option="$2"
    local start_epoch="${3:-$(date +%s)}"

    if [[ "${CLUSTER_MASTER,,}" != "true" ]]; then
        LogError "Cluster request can only be initiated on the cluster master node."
        return 1
    fi

    if [[ "${CLUSTER_WORKER_CONTEXT:-false}" == "true" ]]; then
        dispatch_cluster_action_to_nodes "$action" "$option" "$start_epoch" "${CLUSTER_WORKER_REQUEST_ID:-}"
        return $?
    fi

    local req_id
    req_id="$(date +%s)-$$-$RANDOM"
    local ts
    ts=$(date -Is 2>/dev/null || date +%s)

    local payload
    payload=$(mktemp)
    jq -n \
        --arg action "$action" \
        --arg option "$option" \
        --arg request_id "$req_id" \
        --arg start_epoch "$start_epoch" \
        --arg requested_by "${USER:-$(whoami 2>/dev/null || echo unknown)}" \
        --arg timestamp "$ts" \
        '{action:$action,option:$option,request_id:$request_id,start_epoch:($start_epoch|tonumber),requested_by:$requested_by,timestamp:$timestamp}' > "$payload"

    if ! create_cluster_request_json "$payload"; then
        rm -f "$payload"
        LogError "Failed to create cluster request action=${action}."
        return 1
    fi
    rm -f "$payload"

    wait_for_cluster_response "$req_id"
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

get_server_status() {
    if [[ -f "$STATUS_FILE" ]]; then
        cat "$STATUS_FILE"
    else
        echo "UNKNOWN"
    fi
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

# Enter maintenance mode: request cluster maintenance and wait for all cluster nodes to ACK
# Usage: enter_maintenance <stop|save> [<start_epoch>]
# shellcheck disable=SC2120
enter_maintenance() {
    local action="stop"
    local start_epoch=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            stop|save)
                action="$1"
                ;;
            *)
                start_epoch="$1"
                ;;
        esac
        shift
    done

    mkdir -p "${SIGNALS_DIR}" "${CLUSTER_SIGNALS_DIR}" 2>/dev/null || true
    LogInfo "Requesting Cluster Maintenance (${action})..."
    # Remove any previous MASTER_READY_FILE to avoid immediate resume from stale state
    rm -f "$MASTER_READY_FILE" 2>/dev/null || true
    touch "$LOCK_FILE" 2>/dev/null || true
    
    # content: action (atomic write)
    local tmp_req
    tmp_req=$(mktemp "${CLUSTER_SIGNALS_DIR}/maintenance.request.XXXXXX") && echo "$action" > "$tmp_req" && mv -f "$tmp_req" "$MAINTENANCE_REQUEST_FILE"

    LogInfo "Initiating Cluster Maintenance request..."
    if [[ -z "$start_epoch" ]]; then
        start_epoch=$(date +%s)
    fi
    local option=""
    if [[ "$action" == "stop" ]]; then
        option="--saveworld"
    fi
    request_cluster_action "$action" "$option" "$start_epoch"
}


# Exit maintenance mode: remove maintenance locks and flags
# Does NOT create MASTER_READY_FILE; that file is created by the master when RCON is ready
exit_maintenance() {
    LogInfo "Releasing cluster maintenance locks..."
    rm -f "$UPDATING_FLAG" 2>/dev/null || true
    rm -f "$LOCK_FILE" 2>/dev/null || true
    rm -f "$MAINTENANCE_REQUEST_FILE" 2>/dev/null || true
    rm -f "$WAITING_FILE" 2>/dev/null || true
}


# Master release helper: start master, wait for RCON readiness (MASTER_READY_FILE), then exit maintenance
# Usage: master_release_after_start [wait_timeout_seconds]
master_release_after_start() {
    local wait_timeout=${1:-900}

    LogInfo "Master releasing: starting server and waiting for cluster readiness (timeout ${wait_timeout}s)"
    manager start

    if ! initialize_cluster_ports; then
        LogWarn "Could not initialize cluster ports. Proceeding with maintenance release."
        exit_maintenance
        return 0
    fi

    if [[ ${#CLUSTER_PORTS[@]} -gt 1 ]]; then
        local waited=0
        local wait_interval=5
        LogInfo "Waiting for cluster allowed signal (MASTER_READY_FILE)..."
        while [ "$waited" -lt "$wait_timeout" ]; do
            if [[ -f "$MASTER_READY_FILE" ]]; then
                LogSuccess "MASTER_READY_FILE detected. Proceeding to release maintenance locks."
                break
            fi
            sleep $wait_interval
            waited=$((waited + wait_interval))
        done
        if [[ ! -f "$MASTER_READY_FILE" ]]; then
            LogWarn "Timeout waiting for MASTER_READY_FILE (${wait_timeout}s). Proceeding to release locks to avoid prolonged downtime."
        fi

        # Once master is ready, trigger start on all nodes through the existing request path.
        # start is idempotent, so master receiving its own start request is safe.
        LogInfo "Dispatching cluster start requests after master readiness."
        if dispatch_cluster_action_to_nodes "start" "" "$(date +%s)"; then
            LogSuccess "Cluster start requests dispatched."
        else
            LogWarn "Failed to dispatch cluster start requests. Nodes may require manual start."
        fi
    else
        LogInfo "Single-node cluster; skipping MASTER_READY_FILE wait."
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
        # Check if process is stopped (SIGSTOP)
        local state
        state=$(ps -o state= -p "$server_pid" 2>/dev/null | xargs)
        if [[ "$state" == "T" ]]; then
            echo "PAUSED"
            return 0
        fi
        echo "UP"
        return 0
    else
        echo "DOWN"
        return 1
    fi
}

custom_rcon() {
    if [[ "$(get_health)" != "UP" ]]; then
        return 1
    fi
    "${RCON_CMDLINE[@]}" "${@}" 2>/dev/null
}

saveworld() {
    local health
    health=$(get_health)
    if [[ "$health" != "UP" ]]; then
        if [[ "$health" == "PAUSED" ]]; then
            LogInfo "Server is paused. Treating maintenance save as already completed."
            return 0
        fi
        LogWarn "Unable to save... Server not up (health: $health)."
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

wait_server_stopped() {
    local timeout_sec="${1:-120}"
    local waited=0
    while get_pid >/dev/null && (( waited < timeout_sec )); do
        sleep 1
        waited=$((waited + 1))
    done

    if get_pid >/dev/null; then
        return 1
    fi
    return 0
}


acquire_session_name_lock() {
    LogInfo "Acquiring session name lock..."
    # Wait indefinitely for others to finish. 
    # Stale locks should be cleaned up at cluster master start.
    while ! mkdir "${SESSION_NAME_LOCK}" 2>/dev/null; do
        sleep 2
    done
    LogInfo "Session name lock acquired."
}

release_session_name_lock() {
    if [ -d "${SESSION_NAME_LOCK}" ]; then
        LogInfo "Releasing session name lock..."
        rmdir "${SESSION_NAME_LOCK}" 2>/dev/null
        LogInfo "Session name lock released."
    fi
}

wait_rcon_ready_and_release_lock() {
    LogInfo "Waiting for server to be ready for RCON to release session name lock..."
    # Wait for RCON to respond, which means it definitely finished reading GameUserSettings.ini
    local count=0
    while ! "${RCON_CMDLINE[@]}" "ListPlayers" > /dev/null 2>&1; do
        sleep 10
        count=$((count + 1))
        # if rcon doesn't respond after 15 mins, something is wrong, but we still need to release eventually
        if [ $count -gt 90 ]; then
            LogWarn "RCON not ready after 15m. Releasing lock anyway to not block other servers."
            break
        fi
    done
    LogSuccess "Server is ready (or timeout). Releasing session name lock."
    release_session_name_lock
}

escape_sed_replacement() {
    printf '%s' "$1" | sed 's/[\\/&]/\\\\&/g'
}

normalize_file_to_crlf() {
    local target_file="$1"

    if [[ ! -f "$target_file" ]]; then
        return 1
    fi

    local tmp_file
    tmp_file=$(mktemp) || return 1

    awk '{ sub(/\r$/, ""); printf "%s\r\n", $0 }' "$target_file" > "$tmp_file"
    mv -f "$tmp_file" "$target_file"
    return 0
}

create_gameusersettings_minimal_template() {
    local target_file="$1"

    mkdir -p "$(dirname "$target_file")" 2>/dev/null || true
    cat > "$target_file" <<EOF
;METADATA=(Diff=true, UseCommands=true)
[ServerSettings]
EOF
    normalize_file_to_crlf "$target_file"
}

ini_get_key_value() {
    local target_file="$1"
    local key="$2"

    if [[ ! -f "$target_file" ]]; then
        return 1
    fi

    grep -m 1 "^${key}=" "$target_file" | cut -d'=' -f2- | tr -d '\r'
}

ini_server_setting_needs_update() {
    local target_file="$1"
    local key="$2"
    local desired_value="$3"

    if [[ ! -f "$target_file" ]]; then
        return 0
    fi

    if ! grep -q "^${key}=" "$target_file"; then
        return 0
    fi

    local current_value
    current_value=$(ini_get_key_value "$target_file" "$key")
    if [[ "$current_value" != "$desired_value" ]]; then
        return 0
    fi

    return 1
}

ini_upsert_server_setting() {
    local target_file="$1"
    local key="$2"
    local desired_value="$3"
    local section_name="ServerSettings"

    if [[ ! -f "$target_file" ]]; then
        return 1
    fi

    if grep -q "^${key}=" "$target_file"; then
        local current_value
        current_value=$(ini_get_key_value "$target_file" "$key")
        if [[ "$current_value" == "$desired_value" ]]; then
            return 1
        fi

        local escaped_value
        escaped_value=$(escape_sed_replacement "$desired_value")
        sed -i "s/^${key}=.*/${key}=${escaped_value}/" "$target_file"
        normalize_file_to_crlf "$target_file"
        return 0
    fi

    local escaped_value
    escaped_value=$(escape_sed_replacement "$desired_value")
    if grep -q "^\[${section_name}\]" "$target_file"; then
        sed -i "/^\[${section_name}\]/a ${key}=${escaped_value}" "$target_file"
    else
        printf '\n[%s]\n%s=%s\n' "$section_name" "$key" "$desired_value" >> "$target_file"
    fi

    normalize_file_to_crlf "$target_file"
    return 0
}

needs_sync_gameusersettings_ignored_params() {
    local target_file="$1"

    if [[ ! -f "$target_file" ]]; then
        return 0
    fi

    if [[ -n "${ARK_ADMIN_PASSWORD}" ]] && ini_server_setting_needs_update "$target_file" "ServerAdminPassword" "${ARK_ADMIN_PASSWORD}"; then
        return 0
    fi

    if ini_server_setting_needs_update "$target_file" "RCONEnabled" "True"; then
        return 0
    fi

    if [[ -n "${RCON_PORT}" ]] && ini_server_setting_needs_update "$target_file" "RCONPort" "${RCON_PORT}"; then
        return 0
    fi

    return 1
}

sync_gameusersettings_ignored_params() {
    local target_file="$1"
    local changed=1

    if [[ ! -f "$target_file" ]]; then
        create_gameusersettings_minimal_template "$target_file"
        changed=0
    fi

    if [[ -n "${ARK_ADMIN_PASSWORD}" ]] && ini_upsert_server_setting "$target_file" "ServerAdminPassword" "${ARK_ADMIN_PASSWORD}"; then
        changed=0
    fi

    if ini_upsert_server_setting "$target_file" "RCONEnabled" "True"; then
        changed=0
    fi

    if [[ -n "${RCON_PORT}" ]] && ini_upsert_server_setting "$target_file" "RCONPort" "${RCON_PORT}"; then
        changed=0
    fi

    return "$changed"
}
