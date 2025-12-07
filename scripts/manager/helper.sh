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

export LOG_PATH="${LOG_DIR}/${LOG_FILE}"

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
export SAVE_REQUEST_FILE="${SIGNALS_DIR}/save.request"
export SAVE_ACK_FILE="${SIGNALS_DIR}/save.ack_${SERVER_PORT}"
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
        /opt/manager/discord.sh "$title" "$message" "$level" "$enabled" "$webhook_url" &
    fi
}

SelectArchive() {
    set -e
    path=$1
    select fname in $path/*; do
        echo $fname
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

wait_for_save_acks() {
    local start_epoch="$1"

    if [[ -z "${SLAVE_PORTS:-}" ]]; then
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
        return 0
    fi

    LogInfo "Waiting up to 60s for other nodes to save world: ${targets[*]}"

    local all_ack=false
    local -a missing
    while true; do
        local now_epoch
        now_epoch=$(date +%s)

        if (( now_epoch - start_epoch >= 60 )); then
            break
        fi

        all_ack=true
        missing=()

        for p in "${targets[@]}"; do
            if [[ ! -f "${SIGNALS_DIR}/save.ack_${p}" ]]; then
                all_ack=false
                missing+=("$p")
            fi
        done

        if [[ "$all_ack" == true ]]; then
            LogInfo "All nodes finished saving."
            return 0
        fi

        sleep 2
    done

    LogWarn "Timed out waiting for save ACKs. Proceeding without: ${missing[*]:-unknown}"
    return 0
}


