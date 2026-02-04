#!/bin/bash

source "/opt/manager/helper.sh"

mkdir -p "$SIGNALS_DIR"

# Clean up old status files for this port on startup
rm -f "${SIGNALS_DIR}/status_${SERVER_PORT}" 2>/dev/null || true

is_master=false
master_lock_acquired=false

if [[ -n "${SLAVE_PORTS}" ]]; then
    is_master=true
fi

on_shutdown_signal() {
    LogWarn "Received shutdown signal. Exiting..."
    # Kill background monitor and cron if they are running
    [[ -n "$MONITOR_PID" ]] && kill "$MONITOR_PID" 2>/dev/null || true
    [[ -n "$CRON_PID" ]] && kill "$CRON_PID" 2>/dev/null || true
    manager stop --saveworld || true
    exit 0
}

cleanup_master_lock() {
    if [[ "$master_lock_acquired" == true ]]; then
        rm -rf "$MASTER_LOCK_DIR" 2>/dev/null || true
    fi
}

trap on_shutdown_signal INT TERM
trap cleanup_master_lock EXIT

wait_for_master_allowed() {
    LogInfo "Waiting for update master to finish update-check..."
    set_server_status "WAIT_MASTER"
    while [[ ! -d "$MASTER_LOCK_DIR" || ! -f "$ALLOWED_FILE" ]]; do
        if [[ -f "$REQUEST_FILE" || -f "$LOCK_FILE" ]]; then
            touch "$WAITING_FILE"
        else
            rm -f "$WAITING_FILE" 2>/dev/null || true
        fi
        sleep 2
    done
    rm -f "$WAITING_FILE" 2>/dev/null || true
    LogInfo "Update master signaled ready."
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
    echo "service=${HOSTNAME} pid=$$ started_at=$(date -Is 2>/dev/null || date)" > "$MASTER_LOCK_OWNER_FILE" 2>/dev/null || true
}

wait_for_valid_installation() {
    LogInfo "Waiting for valid server installation..."
    set_server_status "WAIT_INSTALL"
    while [[ ! -f "/opt/arkserver/ShooterGame/Binaries/Win64/ArkAscendedServer.exe" ]] || \
          [[ -f "$UPDATING_FLAG" ]] || \
          [[ -f "$REQUEST_FILE" ]] || \
          [[ -f "$LOCK_FILE" ]]; do
        if [[ -f "$REQUEST_FILE" || -f "$LOCK_FILE" ]]; then
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

if [[ "$is_master" == true ]]; then
    # Revoke permission early so slaves never start using a stale flag from a previous run.
    rm -f "$ALLOWED_FILE" 2>/dev/null || true
    acquire_master_lock_or_exit
    LogInfo "SLAVE_PORTS detected, acting as update master"
    LogInfo "Running update check (and update if needed) via manager"
    manager update --no-warn
else
    LogInfo "No SLAVE_PORTS, acting as update slave"
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

LogInfo "Create Health Check Job"
echo "$HEALTHCHECK_CRON_EXPRESSION bash /opt/healthcheck.sh" >> "$CRONTAB_FILE"
supercronic -quiet -test -no-reap "$CRONTAB_FILE" || exit

if [ "${BACKUP_ENABLED,,}" = true ]; then
    LogInfo "BACKUP_ENABLED=${BACKUP_ENABLED,,}"
    LogInfo "Adding cronjob for auto backups"
    echo "$BACKUP_CRON_EXPRESSION bash /usr/local/bin/manager backup" >> "$CRONTAB_FILE"
    supercronic -quiet -test -no-reap "$CRONTAB_FILE" || exit
fi

if [ "${AUTO_UPDATE_ENABLED,,}" = true ]; then
    LogInfo "AUTO_UPDATE_ENABLED=${AUTO_UPDATE_ENABLED,,}"
    LogInfo "Adding cronjob for auto updating"
    echo "$AUTO_UPDATE_CRON_EXPRESSION bash /usr/local/bin/manager update" >> "$CRONTAB_FILE"
    supercronic -quiet -test -no-reap "$CRONTAB_FILE" || exit
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

# Start server through manager
manager start &

# Background loop for high-frequency signal monitoring (Maintenance, Save requests, etc.)
(
    LogInfo "Starting background signal monitor loop (5s interval)"
    while true; do
        if [[ "${AUTO_UPDATE_ENABLED,,}" != "true" ]]; then
            manager check_maintenance || true
        fi
        manager check_signals || true
        sleep 5
    done
) &
MONITOR_PID=$!

# Function to process log lines for Discord notifications
process_log_line() {
    local line
    line=$(echo -n "$1" | tr -d '\r\n')
    local -r log_head_regex='^\[[0-9]{4}\.[0-9]{2}\.[0-9]{2}\-[0-9]{2}\.[0-9]{2}\.[0-9]{2}:[0-9]{3}\]\[[0-9 ]{3}\](.+)'
    if [[ "$line" =~ $log_head_regex ]]; then
        line="${BASH_REMATCH[1]}"
        local -r log_body_regex='^[0-9]{4}\.[0-9]{2}\.[0-9]{2}_[0-9]{2}\.[0-9]{2}\.[0-9]{2}: (.+)$'
        if [[ "$line" =~ $log_body_regex ]]; then
            line="${BASH_REMATCH[1]}"
            local -r join_regex='(.+) \[UniqueNetId:([a-zA-Z0-9]+) Platform:([a-zA-Z0-9_]+)\] joined this ARK!$'
            local -r left_regex='(.+) \[UniqueNetId:([a-zA-Z0-9]+) Platform:([a-zA-Z0-9_]+)\] left this ARK!$'
            local -r cheat_regex='AdminCmd: (.+) \(PlayerName: (.+), ARKID: ([0-9]+), SteamID: ([a-zA-Z0-9]+)\)$'
            local -r message_regex='(.+) \((.+)\): (.+)$'
            local -r server_regex='^SERVER: (.+)$'

            if [[ "$line" =~ $join_regex ]]; then
                local player="${BASH_REMATCH[1]}"
                local id="${BASH_REMATCH[2]}"
                local platform="${BASH_REMATCH[3]}"
                local platform_msg=""
                if [ "$platform" != "None" ]; then
                    platform_msg=" / Platform: \`${platform}\`"
                fi
                local player_msg
                DISCORD_MSG_JOINED="${DISCORD_MSG_JOINED:-"%s joined"}"
                player_msg=$(printf "$DISCORD_MSG_JOINED" "$player")
                DiscordMessage "${player_msg}" "EOSID: \`${id}\`${platform_msg}" "joined"
            elif [[ "$line" =~ $left_regex ]]; then
                local player="${BASH_REMATCH[1]}"
                local id="${BASH_REMATCH[2]}"
                local platform="${BASH_REMATCH[3]}"
                local platform_msg=""
                if [ "$platform" != "None" ]; then
                    platform_msg=" / Platform: \`${platform}\`"
                fi
                local player_msg
                DISCORD_MSG_LEFT="${DISCORD_MSG_LEFT:-"%s left"}"
                player_msg=$(printf "$DISCORD_MSG_LEFT" "$player")
                DiscordMessage "${player_msg}" "EOSID: \`${id}\`${platform_msg}" "left"
            elif [[ "$line" =~ $cheat_regex ]]; then
                local command="${BASH_REMATCH[1]}"
                local player="${BASH_REMATCH[2]}"
                local arkid="${BASH_REMATCH[3]}"
                local steamid="${BASH_REMATCH[4]}"
                if [ "${DISCORD_NOTIFY_CHEAT,,}" = "true" ]; then
                    DiscordMessage "${player}" "ARKID: \`${arkid}\` / SteamID: \`${steamid}\` / Command: \`${command:0:4}...\`" "warn"
                fi
            elif [[ "$line" =~ $message_regex ]]; then
                local player="${BASH_REMATCH[1]}"
                local id="${BASH_REMATCH[2]}"
                local message="${BASH_REMATCH[3]}"
                DiscordMessage "${player} (${id})" "${message}"
            elif [[ "$line" =~ $server_regex ]]; then
                local message="${BASH_REMATCH[1]}"
                DiscordMessage "SERVER" "${message}" "in-progress"
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
