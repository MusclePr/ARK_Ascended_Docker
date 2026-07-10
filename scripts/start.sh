#!/bin/bash

# shellcheck source=./scripts/manager/helper.sh
source "/opt/manager/helper.sh"

stop_if_foreign_compose_is_active() {
    local lock_owner_project=""

    if [[ ! -d "$MASTER_LOCK_DIR" ]]; then
        return 0
    fi

    if [[ -z "${COMPOSE_PROJECT_NAME:-}" ]]; then
        return 0
    fi

    if [[ -f "$MASTER_LOCK_OWNER_FILE" ]]; then
        lock_owner_project=$(sed -n 's/.*owner_id=\([^ ]*\).*/\1/p' "$MASTER_LOCK_OWNER_FILE" 2>/dev/null | head -n 1)
    fi

    if [[ -z "$lock_owner_project" ]]; then
        return 0
    fi

    if [[ "$lock_owner_project" != "$COMPOSE_PROJECT_NAME" ]]; then
        LogError "Detected active master lock from another compose project (${lock_owner_project}). This compose (${COMPOSE_PROJECT_NAME}) will stop safely."
        set_server_status "STOPPED"
        exit 0
    fi
}

mkdir -p "$SIGNALS_DIR" "$SERVER_SIGNALS_DIR" "$CLUSTER_SIGNALS_DIR"

# If another compose project already owns the shared cluster lock, stop this instance immediately.
stop_if_foreign_compose_is_active

# Clean up old status file for this server on startup
rm -f "${SERVER_SIGNALS_DIR}/status" 2>/dev/null || true

# Clean up old unused request files for this server only
rm -rf "${SERVER_SIGNALS_DIR}/request.lock" 2>/dev/null || true
find "${SERVER_SIGNALS_DIR}" -maxdepth 1 -type f -name "request*.json" -delete 2>/dev/null || true

# Start request worker early so maintenance requests can be ACKed even during startup/update phase.
if [[ -x "/opt/manager/request_worker.sh" ]]; then
    /opt/manager/request_worker.sh &
    REQUEST_WORKER_PID=$!
    LogInfo "Started request_worker early (pid=${REQUEST_WORKER_PID})"
fi

# Start cluster request worker early on master node.
if [[ "${CLUSTER_MASTER,,}" == "true" ]] && [[ -x "/opt/manager/cluster_request_worker.sh" ]]; then
    /opt/manager/cluster_request_worker.sh &
    CLUSTER_REQUEST_WORKER_PID=$!
    LogInfo "Started cluster_request_worker early (pid=${CLUSTER_REQUEST_WORKER_PID})"
fi

master_lock_acquired=false
shutdown_status_finalized=false

finalize_shutdown_status() {
    if [[ "$shutdown_status_finalized" == true ]]; then
        return 0
    fi
    set_server_status "STOPPED"
    shutdown_status_finalized=true
}

on_shutdown_signal() {
    LogWarn "Received shutdown signal. Exiting..."
    set_server_status "STOPPING"
    
    # If server is paused (SIGSTOP'd), it won't receive SIGTERM.
    # We must SIGCONT it first to let it process the shutdown command.
    if [[ -f "${STATUS_FILE}" ]]; then
        local current_status
        current_status=$(cat "${STATUS_FILE}" 2>/dev/null || true)
        if [[ "${current_status}" == "PAUSED" ]]; then
            LogInfo "Server is paused. Resuming to allow graceful shutdown..."
            manager unpause --apply "graceful shutdown preparation" || true
        fi
    fi

    # Kill background workers and cron if they are running
    if [[ -n "${REQUEST_WORKER_PID:-}" ]]; then
        kill "$REQUEST_WORKER_PID" 2>/dev/null || true
    fi
    if [[ -n "${CLUSTER_REQUEST_WORKER_PID:-}" ]]; then
        kill "$CLUSTER_REQUEST_WORKER_PID" 2>/dev/null || true
    fi
    if [[ -n "${CRON_PID:-}" ]]; then
        kill "$CRON_PID" 2>/dev/null || true
    fi
    local stop_rc=0
    if [[ -f "${START_LOCK_FILE}" ]]; then
        LogInfo "Server was not started due to start lock. Finalizing shutdown immediately."
    else
        manager stop --saveworld || stop_rc=$?
    fi
    if [[ "$stop_rc" -eq 0 ]] || ! get_pid >/dev/null 2>&1; then
        finalize_shutdown_status
    fi
    exit 0
}

cleanup_master_lock() {
    local cleanup_ok=true
    if [[ "$master_lock_acquired" == true ]]; then
        if ! rm -rf "$MASTER_LOCK_DIR" 2>/dev/null; then
            cleanup_ok=false
        fi
        if [[ -d "$MASTER_LOCK_DIR" ]]; then
            cleanup_ok=false
        fi
    fi

    if [[ "$cleanup_ok" == true ]]; then
        finalize_shutdown_status
    fi
}

trap on_shutdown_signal INT TERM
trap cleanup_master_lock EXIT

wait_for_master_allowed() {
    LogInfo "Waiting for cluster master to finish update-check..."
    set_server_status "WAIT_MASTER"
    while [[ ! -d "$MASTER_LOCK_DIR" || ! -f "$MASTER_READY_FILE" ]]; do
        if ( [[ -f "$MAINTENANCE_REQUEST_FILE" ]] && grep -q "stop" "$MAINTENANCE_REQUEST_FILE" 2>/dev/null ) || [[ -f "$LOCK_FILE" ]]; then
            touch "$WAITING_FILE"
        else
            rm -f "$WAITING_FILE" 2>/dev/null || true
        fi
        sleep 2
    done
    rm -f "$WAITING_FILE" 2>/dev/null || true
    LogInfo "Cluster master signaled ready."
}

acquire_master_lock_or_exit() {
    if ! mkdir "$MASTER_LOCK_DIR" 2>/dev/null; then
        local owner="unknown"
        if [[ -f "$MASTER_LOCK_OWNER_FILE" ]]; then
            owner=$(cat "$MASTER_LOCK_OWNER_FILE" 2>/dev/null || echo "unknown")
        fi
        LogError "AUTO_UPDATE_ENABLED=true master already exists (lock: $MASTER_LOCK_DIR). Owner: ${owner}. Exiting."
        exit 1
    fi
    master_lock_acquired=true
    echo "owner_id=${COMPOSE_PROJECT_NAME:-$HOSTNAME} pid=$$ started_at=$(date -Is 2>/dev/null || date)" > "$MASTER_LOCK_OWNER_FILE" 2>/dev/null || true
}

wait_for_valid_installation() {
    LogInfo "Waiting for valid server installation..."
    set_server_status "WAIT_INSTALL"
    while [[ ! -f "/opt/arkserver/ShooterGame/Binaries/Win64/ArkAscendedServer.exe" ]] || \
          [[ -f "$UPDATING_FLAG" ]] || \
          ( [[ -f "$MAINTENANCE_REQUEST_FILE" ]] && grep -q "stop" "$MAINTENANCE_REQUEST_FILE" 2>/dev/null ) || \
          [[ -f "$LOCK_FILE" ]]; do
        if ( [[ -f "$MAINTENANCE_REQUEST_FILE" ]] && grep -q "stop" "$MAINTENANCE_REQUEST_FILE" 2>/dev/null ) || [[ -f "$LOCK_FILE" ]]; then
            touch "$WAITING_FILE"
        else
            rm -f "$WAITING_FILE" 2>/dev/null || true
        fi
        sleep 10
    done
    rm -f "$WAITING_FILE" 2>/dev/null || true
    LogInfo "Server installation found."
}

# Create steam directory and set environment variables
mkdir -p "${STEAM_COMPAT_DATA_PATH}"

if [[ "${CLUSTER_MASTER,,}" == "true" ]]; then
    # Reset session name lock in case of previous crash
    rmdir "${SESSION_NAME_LOCK}" 2>/dev/null || true

    # At this point, stop_if_foreign_compose_is_active has already exited if the lock
    # belongs to another compose project. Any remaining lock is stale from a previous
    # crash of this same compose project.
    if [[ -d "$MASTER_LOCK_DIR" ]]; then
        LogWarn "Detected stale master lock. Removing: $MASTER_LOCK_DIR"
        rm -rf "$MASTER_LOCK_DIR" 2>/dev/null || true
    fi
    
    acquire_master_lock_or_exit
    initialize_cluster_ports
    LogInfo "Running update check (and update if needed) as cluster master..."
    manager update --no-start
else
    LogInfo "Acting as cluster node (non-master)"
    wait_for_master_allowed
fi

wait_for_valid_installation

# Remove unnecessary files (saves 6.4GB.., that will be re-downloaded next update)
if [[ -n "${REDUCE_IMAGE_SIZE}" ]]; then 
    rm -rf /opt/arkserver/ShooterGame/Binaries/Win64/ArkAscendedServer.pdb
    rm -rf /opt/arkserver/ShooterGame/Content/Movies/
fi

LogAction "GENERATING CRONTAB"
CRONTAB_FILE="/home/arkuser/crontab"
truncate -s 0 $CRONTAB_FILE

if [ "${HEALTHCHECK_SELFHEALING_ENABLED,,}" = true ]; then
    LogInfo "Create Health Check Job"
    echo "$HEALTHCHECK_CRON_EXPRESSION bash /opt/healthcheck.sh" >> "$CRONTAB_FILE"
    supercronic -quiet -test -no-reap "$CRONTAB_FILE" || exit
fi

if [ "${AUTO_BACKUP_ENABLED,,}" = true ]; then
    LogInfo "AUTO_BACKUP_ENABLED=${AUTO_BACKUP_ENABLED,,}"
    LogInfo "Adding cronjob for auto backups: $AUTO_BACKUP_CRON_EXPRESSION"
    echo "$AUTO_BACKUP_CRON_EXPRESSION bash /usr/local/bin/manager backup" >> "$CRONTAB_FILE"
    supercronic -quiet -test -no-reap "$CRONTAB_FILE" || exit
fi

if [ "${AUTO_UPDATE_ENABLED,,}" = true ]; then
    LogInfo "AUTO_UPDATE_ENABLED=${AUTO_UPDATE_ENABLED,,}"
    if [[ "${CLUSTER_MASTER,,}" == "true" ]]; then
        LogInfo "Adding cronjob for auto updating: $AUTO_UPDATE_CRON_EXPRESSION"
        echo "$AUTO_UPDATE_CRON_EXPRESSION bash /usr/local/bin/manager update" >> "$CRONTAB_FILE"
        supercronic -quiet -test -no-reap "$CRONTAB_FILE" || exit
    else
        LogInfo "Skipping auto-update cron registration because this node is not the cluster master"
    fi
fi

if [ -s "$CRONTAB_FILE" ]; then
    supercronic -split-logs -no-reap "$CRONTAB_FILE" 1>/dev/null &
    CRON_PID=$!
    LogInfo "Cronjobs started"
else
    LogInfo "No Cronjobs found"
fi

# helper links
LogAction "GENERATING HELPER LINKS"
ln -svf ./ShooterGame/Binaries/Win64/PlayersExclusiveJoinList.txt ./whitelist.txt
ln -svf ./ShooterGame/Binaries/Win64/PlayersJoinNoCheckList.txt ./bypasslist.txt
#ln -svf ./ShooterGame/Saved/AllowedCheaterAccountIDs.txt ./adminlist.txt
ln -svf ./ShooterGame/Saved/Config/WindowsServer/GameUserSettings.ini ./GameUserSettings.ini
ln -svf ./ShooterGame/Saved/Config/WindowsServer/Game.ini ./Game.ini

#Create file for showing server logs
mkdir -p "${LOG_PATH%/*}" && echo "" > "${LOG_PATH}"

# .signals/server_<port>/start.lock ファイルが存在する場合、サーバーは起動せずに待機状態となります。
# これはメモリを節約するために、起動するコンテナを制限する目的で使用されます。
if [[ -f "${START_LOCK_FILE}" ]]; then
    LogWarn "Detected start lock file. Server will not start. Waiting for lock file to be removed: ${START_LOCK_FILE}"
    set_server_status "BLOCKED"
    while [[ -f "${START_LOCK_FILE}" ]]; do
        sleep 5
    done
    LogInfo "start lock file removed. Proceeding to start server."
fi

# Start server through manager
manager start &


write_last_player_map() {
    local -r eosid="$1"
    local -r server_map="$2"
    local -r player="$3"

    if [[ -z "$eosid" ]]; then
        LogWarn "Skipping last map update: EOSID is empty"
        return 0
    fi

    if [[ -z "${CLUSTER_ID:-}" ]]; then
        LogWarn "Skipping last map update for EOSID=${eosid}: CLUSTER_ID is empty"
        return 0
    fi

    local map_name="$server_map"
    if [[ "$map_name" == *":"* ]]; then
        map_name="${map_name%%:*}"
    fi

    if [[ -z "$map_name" ]]; then
        LogWarn "Skipping last map update for EOSID=${eosid}: map name is empty"
        return 0
    fi

    local login_dir="/opt/arkserver/ShooterGame/Saved/Cluster/.login/${CLUSTER_ID}"
    local target_file="${login_dir}/last_map_${eosid}.txt"
    local tmp_file="${target_file}.tmp.$$"

    if ! mkdir -p "$login_dir" 2>/dev/null; then
        LogWarn "Failed to create login directory: ${login_dir}"
        return 0
    fi

    if ! printf '%s\n%s\n' "$map_name" "$player" > "$tmp_file" 2>/dev/null; then
        rm -f "$tmp_file" 2>/dev/null || true
        LogWarn "Failed to write temp last map file for EOSID=${eosid}"
        return 0
    fi

    if ! mv -f "$tmp_file" "$target_file" 2>/dev/null; then
        rm -f "$tmp_file" 2>/dev/null || true
        LogWarn "Failed to update last map file for EOSID=${eosid}"
        return 0
    fi
}

detect_player_from_eosid() {
    local -r eosid="$1"
    local -r login_dir="/opt/arkserver/ShooterGame/Saved/Cluster/.login/${CLUSTER_ID}"
    local -r target_file="${login_dir}/last_map_${eosid}.txt"

    if [[ ! -f "$target_file" ]]; then
        echo ""
        return 1
    fi

    local player_name
    player_name=$(sed -n '2p' "$target_file" 2>/dev/null || echo "")
    echo "$player_name"
    return 0
}

# Function to process log lines for Discord notifications
process_log_line() {
    local line
    line=$(echo -n "$1" | tr -d '\r\n')
    # The log lines have a format like:
    # [2024.06.01-12.34.56:789][ 123]LogTemp: Some message
    local -r log_head_regex='^\[[0-9]{4}\.[0-9]{2}\.[0-9]{2}\-[0-9]{2}\.[0-9]{2}\.[0-9]{2}:[0-9]{3}\]\[[0-9 ]{1,8}\](.+)'
    if [[ "$line" =~ $log_head_regex ]]; then
        line="${BASH_REMATCH[1]}"
        # Regular expression to detect server startup completion log
        local -r startup_regex='Server has completed startup'
        # Regular expression to extract incoming account ID and IP
        # IP for incoming account 00023e876b964cd3b6f01a9d7040d038 - IP 58.188.97.144
        local -r incoming_regex='IP for incoming account ([a-zA-Z0-9]+) - IP ([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}).*'
        # Regular expression to extract log body including date and time
        local -r log_body_regex='^[0-9]{4}\.[0-9]{2}\.[0-9]{2}_[0-9]{2}\.[0-9]{2}\.[0-9]{2}: (.+)$'
        # Regular expression to extract ARK version: ARK Version: 123.45
        local -r ark_version_regex='^ARK Version: ([0-9\.]+)$'
        if [[ "$line" =~ $startup_regex ]]; then
            DISCORD_MSG_UP="${DISCORD_MSG_UP:-The Server is up}"
            DiscordMessage "Started $SESSION_NAME" "${DISCORD_MSG_UP}" "success"
            LogSuccess "Server is up."
        elif [[ "$line" =~ $incoming_regex ]]; then
            local -r eosid="${BASH_REMATCH[1]}"
            local -r ip="${BASH_REMATCH[2]}"
            local -r player=$(detect_player_from_eosid "$eosid" || echo "unknown")
            if [ -x "/opt/autopause/knockd_ip_filter.sh" ]; then
                /opt/autopause/knockd_ip_filter.sh white "$ip" "\"$eosid\" \"$player\" \"$(date -Is 2>/dev/null || date)\"" || true
            fi
        elif [[ "$line" =~ $ark_version_regex ]]; then
            local -r version="${BASH_REMATCH[1]}"
            mkdir -p "${SERVER_SIGNALS_DIR}" 2>/dev/null || true
            echo "${version}" > "${SERVER_SIGNALS_DIR}/version" 2>/dev/null || true
        elif [[ "$line" =~ $log_body_regex ]]; then
            line="${BASH_REMATCH[1]}"
            local -r join_regex='(.+) \[UniqueNetId:([a-zA-Z0-9]+) Platform:([a-zA-Z0-9_]+)\] joined this ARK!$'
            local -r left_regex='(.+) \[UniqueNetId:([a-zA-Z0-9]+) Platform:([a-zA-Z0-9_]+)\] left this ARK!$'
            local -r cheat_regex='AdminCmd: (.+) \(PlayerName: (.+), ARKID: ([0-9]+), SteamID: ([a-zA-Z0-9]+)\)$'
            local -r message_regex='(.+) \((.+)\): (.+)$'
            local -r server_regex='^SERVER: (.+)$'

            if [[ "$line" =~ $join_regex ]]; then
                local -r player="${BASH_REMATCH[1]}"
                local -r id="${BASH_REMATCH[2]}"
                local -r platform="${BASH_REMATCH[3]}"
                local platform_msg=""
                if [ "$platform" != "None" ]; then
                    platform_msg=" / Platform: \`${platform}\`"
                fi

                write_last_player_map "$id" "${SERVER_MAP:-}" "$player"

                local player_msg
                DISCORD_MSG_JOINED="${DISCORD_MSG_JOINED:-"%s has joined"}"
                player_msg="${DISCORD_MSG_JOINED//%s/$player}"
                DiscordMessage "${player_msg} [${SERVER_MAP}]" "EOSID: \`${id}\`${platform_msg}" "joined"
            elif [[ "$line" =~ $left_regex ]]; then
                local -r player="${BASH_REMATCH[1]}"
                local -r id="${BASH_REMATCH[2]}"
                local -r platform="${BASH_REMATCH[3]}"
                local platform_msg=""
                if [ "$platform" != "None" ]; then
                    platform_msg=" / Platform: \`${platform}\`"
                fi
                local player_msg
                DISCORD_MSG_LEFT="${DISCORD_MSG_LEFT:-"%s has left"}"
                player_msg="${DISCORD_MSG_LEFT//%s/$player}"
                DiscordMessage "${player_msg} [${SERVER_MAP}]" "EOSID: \`${id}\`${platform_msg}" "left"
            elif [[ "$line" =~ $cheat_regex ]]; then
                local -r command="${BASH_REMATCH[1]}"
                local -r player="${BASH_REMATCH[2]}"
                local -r arkid="${BASH_REMATCH[3]}"
                local -r steamid="${BASH_REMATCH[4]}"
                if [ "${DISCORD_NOTIFY_CHEAT,,}" = "true" ]; then
                    DiscordMessage "${player} [${SERVER_MAP}]" "ARKID: \`${arkid}\` / SteamID: \`${steamid}\` / Command: \`${command:0:4}...\`" "warn"
                fi
            elif [[ "$line" =~ $message_regex ]]; then
                local -r player="${BASH_REMATCH[1]}"
                local -r id="${BASH_REMATCH[2]}"
                local -r message="${BASH_REMATCH[3]}"
                DiscordMessage "${player} (${id})" "${message}"
            elif [[ "$line" =~ $server_regex ]]; then
                local -r message="${BASH_REMATCH[1]}"
                DiscordMessage "SERVER [${SERVER_MAP}]" "${message}" "in-progress"
            fi
        fi
    fi
}

export -f process_log_line
export -f DiscordMessage

# Start tail process in the background, then wait for tail to finish.
# This is just a hack to catch SIGTERM signals, tail does not forward
# the signals.
tail -F "${LOG_PATH}" | while read -r line; do
    echo "$line"
    process_log_line "$line"
done &
wait $!
