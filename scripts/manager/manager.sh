#!/bin/bash
RCON_CMDLINE=( rcon -a "127.0.0.1:${RCON_PORT}" -p "${ARK_ADMIN_PASSWORD}" )
EOS_FILE=/opt/manager/.eos.config
# shellcheck source=./scripts/manager/helper.sh
source "/opt/manager/helper.sh"

MSG_MAINTENANCE_COUNTDOWN="${MSG_MAINTENANCE_COUNTDOWN:-Server will shut down for maintenance. Please log out safely. %d seconds left.}"
MSG_MAINTENANCE_COUNTDOWN_SOON="${MSG_MAINTENANCE_COUNTDOWN_SOON:-%d}"

get_pid() {
    pid=$(pgrep GameThread)
    if [[ -z $pid ]]; then
        return 1
    fi
    echo "$pid"
    return 0
}

get_health() {
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
full_status_setup() {
    # Check PDB is still available
    if [[ ! -f "/opt/arkserver/ShooterGame/Binaries/Win64/ArkAscendedServer.pdb" ]]; then 
        LogError "/opt/arkserver/ShooterGame/Binaries/Win64/ArkAscendedServer.pdb is needed to setup full status."
        return 1
    fi

    # Download pdb-sym2addr-rs and extract it to /opt/manager/pdb-sym2addr
    wget -q https://github.com/azixus/pdb-sym2addr-rs/releases/latest/download/pdb-sym2addr-x86_64-unknown-linux-musl.tar.gz -O /opt/manager/pdb-sym2addr-x86_64-unknown-linux-musl.tar.gz
    tar -xzf /opt/manager/pdb-sym2addr-x86_64-unknown-linux-musl.tar.gz -C /opt/manager
    rm /opt/manager/pdb-sym2addr-x86_64-unknown-linux-musl.tar.gz

    # Extract EOS login
    symbols=$(/opt/manager/pdb-sym2addr /opt/arkserver/ShooterGame/Binaries/Win64/ArkAscendedServer.exe /opt/arkserver/ShooterGame/Binaries/Win64/ArkAscendedServer.pdb DedicatedServerClientSecret DedicatedServerClientId DeploymentId)

    client_id=$(echo "$symbols" | grep -o 'DedicatedServerClientId.*' | cut -d, -f2)
    client_secret=$(echo "$symbols" | grep -o 'DedicatedServerClientSecret.*' | cut -d, -f2)
    deployment_id=$(echo "$symbols" | grep -o 'DeploymentId.*' | cut -d, -f2)

    # Save base64 login and deployment id to file
    creds=$(echo -n "$client_id:$client_secret" | base64 -w0)
    echo "${creds},${deployment_id}" > "$EOS_FILE"

    return 0
}

full_status_first_run() {
    read -p "To display the full status, the EOS API credentials will have to be extracted from the server binary files and pdb-sym2addr-rs (azixus/pdb-sym2addr-rs) will be downloaded. Do you want to proceed [y/n]?: " -n 1 -r
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        return 1
    fi

    full_status_setup
    return $?
}

full_status_display() {
    creds=$(cut -d, -f1 "$EOS_FILE")
    id=$(cut -d, -f2 "$EOS_FILE")

    # Recover current ip
    ip=$(curl -s https://ifconfig.me/ip)

    # Recover and extract oauth token
    oauth=$(curl -s -H 'Content-Type: application/x-www-form-urlencoded' -H 'Accept: application/json' -H "Authorization: Basic ${creds}" -X POST https://api.epicgames.dev/auth/v1/oauth/token -d "grant_type=client_credentials&deployment_id=${id}")
    token=$(echo "$oauth" | jq -r '.access_token')

    # Send query to get server(s) registered under public ip
    res=$(curl -s -X "POST" "https://api.epicgames.dev/matchmaking/v1/${id}/filter"    \
        -H "Content-Type:application/json"      \
        -H "Accept:application/json"            \
        -H "Authorization: Bearer $token"       \
        -d "{\"criteria\": [{\"key\": \"attributes.ADDRESS_s\", \"op\": \"EQUAL\", \"value\": \"${ip}\"}]}")

    # Check there was no error
    if [[ "$res" == *"errorCode"* ]]; then
        LogError "Failed to query EOS... Please run command again."
        full_status_setup
        return
    fi
    
    # Extract correct server based on server port
    serv=$(echo "$res" | jq -r ".sessions[] | select( .attributes.ADDRESSBOUND_s | contains(\":${SERVER_PORT}\"))")
    
    if [[ -z "$serv" ]]; then
        LogError "Server is down"
        return
    fi

    # Extract variables
    mapfile -t vars < <(echo "$serv" | jq -r '
            .totalPlayers,
            .settings.maxPublicPlayers,
            .attributes.CUSTOMSERVERNAME_s,
            .attributes.DAYTIME_s,
            .attributes.SERVERUSESBATTLEYE_b,
            .attributes.ADDRESS_s,
            .attributes.ADDRESSBOUND_s,
            .attributes.MAPNAME_s,
            .attributes.BUILDID_s,
            .attributes.MINORBUILDID_s,
            .attributes.SESSIONISPVE_l,
            .attributes.ENABLEDMODS_s
        ')

    curr_players=${vars[0]}
    max_players=${vars[1]}
    serv_name=${vars[2]}
    day=${vars[3]}
    #battleye=${vars[4]}
    ip=${vars[5]}
    bind=${vars[6]}
    map=${vars[7]}
    major=${vars[8]}
    minor=${vars[9]}
    #pve=${vars[10]}
    mods=${vars[11]}
    #bind_ip=${bind%:*}
    bind_port=${bind#*:}

    if [[ "${mods}" == "null" ]]; then
        mods="-"
    fi

    echo -e "Server Name:    ${serv_name}"
    echo -e "Map:            ${map}"
    echo -e "Day:            ${day}"
    echo -e "Players:        ${curr_players} / ${max_players}"
    echo -e "Mods:           ${mods}"
    echo -e "Server Version: ${major}.${minor}"
    echo -e "Server Address: ${ip}:${bind_port}"
    echo "Server is up"
}

status() {
    enable_full_status=false
    # Execute initial EOS setup, true if no error
    if [[ "$1" == "--full" ]] ; then
        # If EOS file exists, no need to run initial setup
        if [[ -f "$EOS_FILE" ]]; then
            enable_full_status=true
        else
            full_status_first_run
            res=$?
            if [[ $res -eq 0 ]]; then
                enable_full_status=true
            fi
        fi
    fi

    echo -e "Server PID:     $(get_pid)"
    ark_port=$(ss -tupln | grep "GameThread" | grep -oP '(?<=:)\d+')
    if [[ -z "$ark_port" ]]; then
        echo -e "Server Port:    Not Listening"
    else
        echo -e "Server Port:    ${ark_port}"
    fi

    if [[ -f "$STATUS_FILE" ]]; then
        echo -e "Detailed Status: $(cat "$STATUS_FILE")"
    fi

    # Check initial status with rcon command
    if health=$(get_health); then
        out=$("${RCON_CMDLINE[@]}" ListPlayers 2>/dev/null)
        res=$?
        if [[ $res == 0 ]]; then
            # Once rcon is up, query EOS if requested
            if [[ "$enable_full_status" == true ]]; then
                full_status_display
            else            
                num_players=0
                if [[ "$out" != "No Players"* ]]; then
                    num_players=$(echo "$out" | wc -l)
                fi
                echo -e "Players connected:        ${num_players} / ${MAX_PLAYERS:-?}"
                LogSuccess "Server is up"
                return 0
            fi
        else
            LogInfo "Server is starting"
            return 0
        fi
    else
        LogWarn "The Server is currently $health"
    fi
}

rcon_wait_ready() {
    LogInfo "Waiting for server to respond to RCON (ListPlayers)..."
    local timeout=900 # 15 minutes
    local elapsed=0
    local interval=10
    
    while [ $elapsed -lt $timeout ]; do
        if out=$("${RCON_CMDLINE[@]}" ListPlayers 2>/dev/null); then
            LogSuccess "Server RCON is responsive."
            set_server_status "RUNNING"
            if [[ -n "${SLAVE_PORTS}" ]]; then
                LogInfo "Signaling ready to cluster."
                touch "$ALLOWED_FILE" 2>/dev/null || true
            fi
            return 0
        fi
        sleep $interval
        elapsed=$((elapsed + interval))
        if [ $((elapsed % 60)) -eq 0 ]; then
            LogInfo "Still waiting for RCON... (${elapsed}s elapsed)"
        fi
    done
    
    LogWarn "RCON wait timed out (${timeout}s)."
    if [[ -n "${SLAVE_PORTS}" ]]; then
        LogWarn "Signaling ready anyway to prevent deadlock."
        touch "$ALLOWED_FILE" 2>/dev/null || true
    fi
    return 1
}

start() {
    if get_health >/dev/null; then
        LogInfo "Server is already running."
        if [[ -n "${SLAVE_PORTS}" ]]; then
            touch "$ALLOWED_FILE" 2>/dev/null || true
        fi
        set_server_status "RUNNING"
        return 0
    fi
    LogInfo "Starting server on port ${SERVER_PORT}"
    LogAction "STARTING SERVER" >> "$LOG_PATH"
    set_server_status "STARTING"

    # Start server in the background + nohup and save PID
    DISCORD_MSG_STARTING="${DISCORD_MSG_STARTING:-The Server is starting}"
    DiscordMessage "Start $SESSION_NAME" "$DISCORD_MSG_STARTING" "success"
    nohup /opt/manager/server_start.sh >/dev/null 2>&1 &
    sleep 3

    # Wait for RCON before signaling readiness (if master) and setting RUNNING status
    rcon_wait_ready &
}

stop() {
    if ! get_health >/dev/null ; then
        LogError "Server is not running"
        return 1
    fi

    # Countdown if players are present
    local out
    out=$("${RCON_CMDLINE[@]}" ListPlayers 2>/dev/null)
    local res=$?
    local -i num_players start_t now elapsed target_elapsed
    if [[ $res == 0 && "$out" != "No Players"* ]]; then
        num_players=$(echo "$out" | wc -l)
        if [[ $num_players -gt 0 ]]; then
            LogInfo "Players connected: ${num_players}. Starting 60s countdown."
            local intervals=(60 45 30 20 15 10 9 8 7 6 5 4 3 2 1)
            start_t=$(date +%s)
            for t in "${intervals[@]}"; do
                # Wait until target time to broadcast
                target_elapsed=$((60 - t))
                while true; do
                    now=$(date +%s)
                    elapsed=$((now - start_t))
                    if [[ $elapsed -ge $target_elapsed ]]; then
                        break
                    fi
                    sleep 1
                    # Re-check players every second
                    out=$("${RCON_CMDLINE[@]}" ListPlayers 2>/dev/null)
                    if [[ $? != 0 || "$out" == "No Players"* ]]; then
                         LogInfo "All players logged out. Proceeding to stop."
                         break 2
                    fi
                done

                # Send broadcast
                local msg
                if [[ $t -gt 10 ]]; then
                    msg="${MSG_MAINTENANCE_COUNTDOWN//%d/$t}"
                else
                    msg="${MSG_MAINTENANCE_COUNTDOWN_SOON//%d/$t}"
                fi
                custom_rcon "serverchat $msg"
            done
            # Final wait for 1 second after "1" broadcast
            sleep 1
        fi
    fi

    if [[ $1 == "--saveworld" ]]; then
        saveworld
    fi
    DISCORD_MSG_STOPPING="${DISCORD_MSG_STOPPING:-Server will gracefully shutdown}"
    DiscordMessage "Stopping $SESSION_NAME" "$DISCORD_MSG_STOPPING" "in-progress"
    LogAction "STOPPING SERVER" >> "$LOG_PATH"
    set_server_status "STOPPING"

    # Check number of players
    out=$("${RCON_CMDLINE[@]}" DoExit 2>/dev/null)
    res=$?
    force=false
    if [[ $res == 0  && "$out" == "Exiting..." ]]; then
        LogInfo "Waiting ${SERVER_SHUTDOWN_TIMEOUT}s for the server to stop"
        if ! get_pid;then
            LogError "Server already down. This should not happen!"
            exit 1
        fi
        timeout "$SERVER_SHUTDOWN_TIMEOUT" tail --pid="$(get_pid)" -f /dev/null
        res=$?

        # Timeout occurred
        if [[ "$res" == 124 ]]; then
            LogWarn "Server still running after $SERVER_SHUTDOWN_TIMEOUT seconds"
            force=true
        fi
    else
        force=true
    fi

    if [[ "$force" == true ]]; then
        DISCORD_MSG_FORCE_SHUTDOWN="${DISCORD_MSG_FORCE_SHUTDOWN:-Forcing the Server to shutdown}"
        DiscordMessage "Stopping $SESSION_NAME" "$DISCORD_MSG_FORCE_SHUTDOWN" "failure"
        LogWarn "Forcing server shutdown"
        if get_pid; then
            kill -INT "$(get_pid)"
        else
            LogError "Tried to kill server, but server is not running!"
            exit 1
        fi
        timeout "$SERVER_SHUTDOWN_TIMEOUT" tail --pid="$(get_pid)" -f /dev/null
        res=$?
        # Timeout occurred
        if [[ "$res" == 124 ]]; then
            kill -9 "$(get_pid)"
            LogWarn "TIMEOUT: Server did not stop after SIGINT, sent SIGKILL"
        fi
    fi

    DISCORD_MSG_STOPPED="${DISCORD_MSG_STOPPED:-The Server has been stopped}"
    DiscordMessage "Stopped $SESSION_NAME" "$DISCORD_MSG_STOPPED" "failure"
    LogAction "SERVER STOPPED" >> "$LOG_PATH"
    set_server_status "STOPPED"
}

restart() {
    DISCORD_MSG_RESTARTING="${DISCORD_MSG_RESTARTING:-Restarting the Server}"
    DiscordMessage "Restart $SESSION_NAME" "$DISCORD_MSG_RESTARTING" "in-progress"
    LogAction "RESTARTING SERVER" >> "$LOG_PATH"
    stop "$1"
    start
}

saveworld() {
    if ! get_health >/dev/null ; then
        LogWarn "Unable to save... Server not up"
        return 1
    fi

    LogInfo "Saving world..."
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

# Returns 0 if Update Required
# Returns 1 if Update NOT Required
# Returns 2 if Check Failed
check_maintenance() {
    local rcon_listening=false
    if ss -ltn 2>/dev/null | grep -qE "[:\[]${RCON_PORT}\b"; then
        rcon_listening=true
    fi

    if [[ -f "$LOCK_FILE" || -f "$REQUEST_FILE" ]]; then
        touch "$WAITING_FILE"
        set_server_status "MAINTENANCE"
        if get_health >/dev/null; then
            if [[ "$rcon_listening" == true ]]; then
                LogWarn "Cluster maintenance detected. Stopping server..."
                touch "$RESUME_FLAG"
                stop --saveworld
            else
                LogInfo "Cluster maintenance detected, but RCON is not listening yet. Skip stop --saveworld."
            fi
        fi
    else
        rm -f "$WAITING_FILE" 2>/dev/null || true
        if [[ -f "$RESUME_FLAG" ]]; then
            LogInfo "Maintenance finished. Resuming server..."
            rm -f "$RESUME_FLAG"
            start
        fi
    fi
}

update_required() {
  LogInfo "Checking for new Server updates"
  local CURRENT_MANIFEST LATEST_MANIFEST temp_file http_code updateAvailable
    local manifest_file
    manifest_file="/opt/arkserver/steamapps/appmanifest_${ASA_APPID}.acf"
  #check steam for latest version
  temp_file=$(mktemp)
  http_code=$(curl "https://api.steamcmd.net/v1/info/$ASA_APPID" --output "$temp_file" --silent --location --write-out "%{http_code}")
  if [ "$http_code" -ne 200 ]; then
      LogError "There was a problem reaching the Steam api. Unable to check for updates!"
      DiscordMessage "Install" "There was a problem reaching the Steam api. Unable to check for updates!" "failure"
      rm "$temp_file"
      return 2
  fi

  # Parse temp file for manifest id
  LATEST_MANIFEST=$(jq '.data."'"$ASA_APPID"'".depots."'"$((ASA_APPID + 1))"'".manifests.public.gid' <"$temp_file" | sed -r 's/.*("[0-9]+")$/\1/' | tr -d '"')
  rm "$temp_file"

  if [ -z "$LATEST_MANIFEST" ]; then
      LogError "The server response does not contain the expected BuildID. Unable to check for updates!"
      DiscordMessage "Install" "Steam servers response does not contain the expected BuildID. Unable to check for updates!" "failure"
      return 2
  fi

  # If server is not installed yet, update is required.
  if [[ ! -f "$manifest_file" ]]; then
      LogWarn "Local manifest not found (${manifest_file}). Treating update as required (fresh install)."
      return 0
  fi

  # Parse current manifest from steam files
  CURRENT_MANIFEST=$(awk '/manifest/{count++} count==2 {print $2; exit}' "$manifest_file" 2>/dev/null | tr -d '"')
  if [[ -z "$CURRENT_MANIFEST" ]]; then
      LogWarn "Unable to read current manifest from ${manifest_file}. Treating update as required."
      return 0
  fi

  # Log any updates available
  local updateAvailable=false
  if [ "$CURRENT_MANIFEST" != "$LATEST_MANIFEST" ]; then
    LogWarn "An Update Is Available: $CURRENT_MANIFEST -> $LATEST_MANIFEST."
    updateAvailable=true
  fi

  if [ -n "${TARGET_MANIFEST_ID}" ] && [ "$CURRENT_MANIFEST" != "${TARGET_MANIFEST_ID}" ]; then
    LogWarn "Game not at target version. Target Version: ${TARGET_MANIFEST_ID}"
    return 0
  fi

    if [ "$updateAvailable" == true ]; then
        return 0
    fi

    return 1
}

update() {
    local skip_warn=false
    local skip_start=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-warn)
                skip_warn=true
                ;;
            --no-restart)
                skip_start=true
                ;;
        esac
        shift
    done

    # Always revoke start permission at the beginning of an update cycle.
    # This prevents slaves from starting while we are checking/updating shared volumes.
    rm -f "$ALLOWED_FILE" 2>/dev/null || true

    local update_rc=0
    update_required
    update_rc=$?
    if [[ "$update_rc" == 1 ]]; then
        LogSuccess "The server is up to date!"
        return 0
    fi
    if [[ "$update_rc" == 2 ]]; then
        LogWarn "Unable to check for updates. Proceeding without updating."
        return 0
    fi
    if [[ "$skip_warn" == true ]]; then
        LogInfo "Skipping update warning delay (--no-warn)"
    elif [[ "${UPDATE_WARN_MINUTES}" =~ ^[0-9]+$ ]]; then
        # マスターサーバーだけに通知しても仕方なく、プレイヤーが接続している全サーバーに通知する必要があります。
        # カウントダウン通知があるので、この機能自体、削除しても良いかもしれません。
        custom_rcon "serverchat The Server will update in ${UPDATE_WARN_MINUTES} minutes"
        DiscordMessage "Update" "Server will update in ${UPDATE_WARN_MINUTES} minutes" "in-progress"
        sleep $((UPDATE_WARN_MINUTES * 60))
    fi

    UPDATE_KEEP_LOCK=false

    local request_started_epoch
    request_started_epoch=$(date +%s)
    LogInfo "Requesting Cluster Maintenance..."
    touch "$REQUEST_FILE"

    LogInfo "Initiating Cluster Maintenance..."
    touch "$LOCK_FILE"

    wait_for_slave_acks "$request_started_epoch"

    trap 'if [[ "${UPDATE_KEEP_LOCK:-}" == "true" ]]; then rm -f "$UPDATING_FLAG"; else rm -f "$UPDATING_FLAG"; rm -f "$LOCK_FILE"; rm -f "$REQUEST_FILE"; fi' EXIT

    DiscordMessage "Update" "Updating Server now" "warn"
    LogAction "UPDATING SERVER"
    set_server_status "UPDATING"
    stop --saveworld

    touch "$UPDATING_FLAG"
    rm "/opt/arkserver/steamapps/appmanifest_${ASA_APPID}.acf"
    local steamcmd_rc=0
    local steamcmd_log
    steamcmd_log=$(mktemp)
    local warmup_log
    warmup_log=$(mktemp)
    local max_retries
    max_retries=${STEAMCMD_RETRIES:-3}
    local attempt=1

    LogInfo "Warming up SteamCMD session (login + quit)"
    /opt/steamcmd/steamcmd.sh +login anonymous +quit 2>&1 | tee "$warmup_log" || LogWarn "SteamCMD warm-up failed; proceeding with update attempts."
    rm -f "$warmup_log" 2>/dev/null || true

    while (( attempt <= max_retries )); do
        LogInfo "Running SteamCMD update (attempt ${attempt}/${max_retries})"

        set -o pipefail
        /opt/steamcmd/steamcmd.sh +force_install_dir /opt/arkserver +login anonymous +app_update "${ASA_APPID}" validate +quit 2>&1 | tee "$steamcmd_log"
        steamcmd_rc=${PIPESTATUS[0]}
        set +o pipefail

        # SteamCMD sometimes prints errors even if exit code is ambiguous; treat these as failures.
        if [[ $steamcmd_rc -eq 0 ]] && ! grep -qE '^(ERROR!|Failed to install app)' "$steamcmd_log"; then
            break
        fi

        LogWarn "SteamCMD update failed (exit code: ${steamcmd_rc})."

        if (( attempt < max_retries )); then
            local sleep_seconds
            case "$attempt" in
                1) sleep_seconds=10 ;;
                2) sleep_seconds=30 ;;
                *) sleep_seconds=60 ;;
            esac
            LogInfo "Retrying in ${sleep_seconds}s..."
            sleep "$sleep_seconds"
        fi

        attempt=$((attempt + 1))
    done

    rm -f "$steamcmd_log" 2>/dev/null || true

    if [[ $steamcmd_rc -ne 0 ]]; then
        UPDATE_KEEP_LOCK=true
        rm -f "$UPDATING_FLAG" 2>/dev/null || true
        LogError "Update failed after ${max_retries} attempts (last steamcmd exit code: ${steamcmd_rc}). Keeping cluster maintenance lock; server will remain stopped."
        DiscordMessage "Update" "Update failed after ${max_retries} attempts (steamcmd exit code: ${steamcmd_rc}). Server will remain stopped." "failure"
        return "$steamcmd_rc"
    fi

    # Remove unnecessary files (saves 6.4GB.., that will be re-downloaded next update)
    if [[ -n "${REDUCE_IMAGE_SIZE}" ]]; then 
        rm -rf /opt/arkserver/ShooterGame/Binaries/Win64/ArkAscendedServer.pdb
        rm -rf /opt/arkserver/ShooterGame/Content/Movies/
    fi
    # If we are skipping start (or dry-run), do not attempt to start/wait for RCON here.
    if [[ "$skip_start" != true ]]; then
        LogInfo "Starting server after update"
        start

        # If this is a clustered setup, wait for the master to signal readiness
        # by creating the ALLOWED_FILE. rcon_wait_ready creates that file when RCON
        # responds. We poll with a timeout to avoid deadlocks.
        if [[ -n "${SLAVE_PORTS}" ]]; then
            local wait_timeout=900 # 15 minutes
            local waited=0
            local wait_interval=5
            LogInfo "Waiting for cluster allowed signal (ALLOWED_FILE)..."
            while [ $waited -lt $wait_timeout ]; do
                if [[ -f "$ALLOWED_FILE" ]]; then
                    LogSuccess "ALLOWED_FILE detected. Releasing cluster locks."
                    break
                fi
                sleep $wait_interval
                waited=$((waited + wait_interval))
            done
            if [[ ! -f "$ALLOWED_FILE" ]]; then
                LogWarn "Timeout waiting for ALLOWED_FILE (${wait_timeout}s). Releasing locks anyway to avoid prolonged downtime."
            fi
        fi
    else
        LogInfo "Skipping automatic start/wait (skip_start=${skip_start})"
    fi

    # Final cleanup: remove updating flag and release cluster maintenance locks
    rm -f "$UPDATING_FLAG"
    rm -f "$LOCK_FILE"
    rm -f "$REQUEST_FILE"

    trap - EXIT

    LogSuccess "Update completed"
}

backup(){
    local path="/var/backups"
    local tmp_path="/opt/arkserver/tmp/backup"

    LogInfo "Creating backup. Backups are saved in your backup volume."
    set_server_status "BACKUP_SAVE"

    saveworld

    mkdir -p "$path"
    mkdir -p "$tmp_path"

    local label
    label="$(sanitize "$SESSION_NAME")"
    archive_name="${label}_$(date +"%Y-%m-%d_%H-%M")"

    # copy selected subpaths into temporary dir so tar doesn't get write-on-read failures
    LogInfo "Copying selected Saved subpaths"
    saved_base="/opt/arkserver/ShooterGame/Saved"
    mkdir -p "$tmp_path"

    # 1) SavedArks/${SERVER_MAP} (exclude patterns)
    if [[ -n "${SERVER_MAP}" && -d "$saved_base/SavedArks/${SERVER_MAP}" ]]; then
        mkdir -p "$tmp_path/Saved/SavedArks"
        (cd "$saved_base/SavedArks" && tar -cf - --exclude='*.profilebak' --exclude='*.tribebak' --exclude="${SERVER_MAP}_*.ark" "${SERVER_MAP}") | tar -C "$tmp_path/Saved/SavedArks" -xf -
    fi

    # 2) SaveGames (mods)
    if [[ -d "$saved_base/SaveGames" ]]; then
        mkdir -p "$tmp_path/Saved"
        tar -C "$saved_base" -cf - "SaveGames" | tar -C "$tmp_path/Saved" -xf -
    fi

    # 3) Config/WindowsServer
    if [[ -d "$saved_base/Config/WindowsServer" ]]; then
        mkdir -p "$tmp_path/Saved/Config"
        tar -C "$saved_base/Config" -cf - "WindowsServer" | tar -C "$tmp_path/Saved/Config" -xf -
    fi

    # 4) Cluster/clusters/${CLUSTER_ID}
    if [[ -n "${CLUSTER_ID}" && -d "$saved_base/Cluster/clusters/${CLUSTER_ID}" ]]; then
        mkdir -p "$tmp_path/Saved/Cluster/clusters"
        tar -C "$saved_base/Cluster/clusters" -cf - "${CLUSTER_ID}" | tar -C "$tmp_path/Saved/Cluster/clusters" -xf -
    fi

    # If no files were copied, warn but continue (no error)
    if [[ -z "$(ls -A "$tmp_path" 2>/dev/null)" ]]; then
        LogWarn "No matching Saved subpaths found to archive; creating empty backup metadata."
    fi

    LogInfo "Creating archive"
    tar -czf "$path/${archive_name}.tar.gz" -C "$tmp_path" Saved
    if [[ $? == 1 ]]; then
        LogError "Creating backup failed" >> "$LOG_PATH"
        return 1
    fi
    LogSuccess "Backup created" >> "$LOG_PATH"

    # Clean up Files
    rm -R "$tmp_path"
    if get_health >/dev/null; then set_server_status "RUNNING"; fi

    if [[ "${OLD_BACKUP_DAYS}" =~ ^[0-9]+$ ]]; then
        LogAction "Removing old Backups"
        LogInfo "Deleting Backups older than ${OLD_BACKUP_DAYS} days!"
        find "$path" -mindepth 1 -maxdepth 1 -mtime "+${OLD_BACKUP_DAYS}" -type f -name '*.tar.gz' -print -delete
    fi
    return 0
}

restoreBackup(){
    local backup_path=/var/backups
    local archive=""
    local NO_CLUSTER=false
    local NO_MOD=false
    local NO_CONFIG=false
    local NO_START=false

    # Parse args: <archive> [--no-cluster] [--no-mod] [--no-config] [--map-only]
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-cluster)
                NO_CLUSTER=true; shift ;;
            --no-mod)
                NO_MOD=true; shift ;;
            --no-config)
                NO_CONFIG=true; shift ;;
            --map-only)
                NO_CLUSTER=true; NO_MOD=true; NO_CONFIG=true; shift ;;
            --no-start)
                NO_START=true; shift ;;
            *)
                if [[ -z "$archive" ]]; then
                    archive="$1"
                fi
                shift ;;
        esac
    done

    if [[ -n "$archive" ]]; then
        archive="${backup_path}/${archive}"
        if [[ ! -f "$archive" ]]; then
            LogError "Backup file not found: $archive"
            return 1
        fi
    else
        local -i backup_count
        # Use find to count files to handle arbitrary filenames safely (SC2012)
        backup_count=$(find "$backup_path" -mindepth 1 -maxdepth 1 -type f 2>/dev/null | wc -l)
        if [[ $backup_count -eq 0 ]]; then
            LogError "You haven't created any backups yet."
            return 1
        fi
        LogInfo "Please choose the archive to restore:"
        archive=$(SelectArchive "$backup_path")
        if [[ -z "$archive" ]]; then
            LogError "No Selection was made!"
            return 1
        fi
    fi

    # Ensure cleanup on exit (also remove tmp restore dir if present)
    local tmp_restore=""
    trap '[[ -n "${tmp_restore}" && -d "${tmp_restore}" ]] && rm -rf "${tmp_restore}" 2>/dev/null || true;' EXIT

    LogInfo "Stopping local server..."
    # Call stop in a subshell so any `exit` in stop() won't kill this script
    ( stop )
    #stop_rc=$?

    # Wait for server to actually stop (timeout 60s)
    local waited=0
    local stop_timeout=60
    while get_pid >/dev/null && [ $waited -lt $stop_timeout ]; do
        sleep 1
        waited=$((waited+1))
    done

    if get_pid >/dev/null; then
        LogError "Server did not stop after ${stop_timeout}s. Aborting restore."
        rm -f "$LOCK_FILE" "$REQUEST_FILE" 2>/dev/null || true
        trap - EXIT
        return 1
    fi

    LogInfo "Restoring backup: $archive"
    set_server_status "RESTORING"

    # Prepare saved base and track map-specific backup only (do not mv entire Saved)
    local saved_path="/opt/arkserver/ShooterGame/Saved"
    local restore_success=false
    local saved_map_old=""
    if [[ -n "${SERVER_MAP}" && -d "$saved_path/SavedArks/${SERVER_MAP}" ]]; then
        # Move only the map-specific directory to a backup location (safe mv)
        saved_map_old="${saved_path}/SavedArks/${SERVER_MAP}.old_$(date +%s)"
        mkdir -p "$(dirname "$saved_map_old")" 2>/dev/null || true
        mv "$saved_path/SavedArks/${SERVER_MAP}" "$saved_map_old" 2>/dev/null || true
        LogInfo "Existing map data moved to ${saved_map_old}"
    fi

    # Prepare temporary extraction directory
    tmp_restore="/opt/arkserver/tmp/restore_$(date +%s)"
    mkdir -p "$tmp_restore"

    # Basic free-space check (archive size + 10MB margin)
    if command -v df >/dev/null 2>&1 && command -v du >/dev/null 2>&1; then
        available_kb=$(df -Pk /opt/arkserver | awk 'NR==2 {print $4}')
        archive_kb=$(du -k "$archive" 2>/dev/null | cut -f1 || echo 0)
        required_kb=$((archive_kb + 10240))
        if [[ -n "$available_kb" && -n "$archive_kb" && $available_kb -lt $required_kb ]]; then
            LogError "Not enough disk space to extract archive. Required ~${required_kb}KB, available ${available_kb}KB"
            # Rollback map-specific backup if present
            if [[ -n "$saved_map_old" && ! -d "$saved_path/SavedArks/${SERVER_MAP}" ]]; then
                mv "$saved_map_old" "$saved_path/SavedArks/${SERVER_MAP}" 2>/dev/null || true
            fi
            rm -rf "$tmp_restore" 2>/dev/null || true
            trap - EXIT
            return 1
        fi
    fi

    # Extract to temporary dir, then move into place
    if ! tar -xzf "$archive" -C "$tmp_restore"; then
        LogError "Tar extraction failed"
        # Rollback map-specific backup if present
        if [[ -n "$saved_map_old" ]]; then
            mv "$saved_map_old" "$saved_path/SavedArks/${SERVER_MAP}" 2>/dev/null || true
        fi
        rm -rf "$tmp_restore" 2>/dev/null || true
        trap - EXIT
        return 1
    fi

    # Expect archive contains a top-level 'Saved' directory
    if [[ ! -d "$tmp_restore/Saved" ]]; then
        LogError "Archive does not contain Saved directory at top-level"
        if [[ -n "$saved_map_old" ]]; then
            mv "$saved_map_old" "$saved_path/SavedArks/${SERVER_MAP}" 2>/dev/null || true
        fi
        rm -rf "$tmp_restore" 2>/dev/null || true
        trap - EXIT
        return 1
    fi
    # Move selected subpaths into place
    # Detect if other servers are running (via status files). If so,
    # do NOT restore mods/config/cluster and log a warning.
    other_running=false
    if [[ -n "${SLAVE_PORTS:-}" ]]; then
        IFS=',' read -r -a _ports <<< "${SLAVE_PORTS}" || true
        for _p in "${_ports[@]}"; do
            _p="${_p//[[:space:]]/}"
            [[ -z "$_p" ]] && continue
            [[ "$_p" == "${SERVER_PORT}" ]] && continue
            if [[ -f "${SIGNALS_DIR}/status_${_p}" ]]; then
                st=$(cat "${SIGNALS_DIR}/status_${_p}" 2>/dev/null || true)
                if [[ "$st" == "RUNNING" || "$st" == "UP" || "$st" == "STARTING" ]]; then
                    other_running=true
                    break
                fi
            fi
        done
    fi

    # Always restore map data (SavedArks/${SERVER_MAP}) if present - allowed to mv
    if [[ -n "${SERVER_MAP}" && -d "$tmp_restore/Saved/SavedArks/${SERVER_MAP}" ]]; then
        mkdir -p "$saved_path/SavedArks"
        mv "$tmp_restore/Saved/SavedArks/${SERVER_MAP}" "$saved_path/SavedArks/"
    fi

    # Restore SaveGames (mods) if present and allowed; do not rm -rf entire dirs
    if [[ -d "$tmp_restore/Saved/SaveGames" ]]; then
        if [[ "$NO_MOD" == true || "$other_running" == true ]]; then
            LogWarn "Skipping restoration of SaveGames (mods) because --no-mod provided or other servers are running."
        else
            mkdir -p "$saved_path/SaveGames"
            tar -C "$tmp_restore/Saved" -cf - "SaveGames" | tar -C "$saved_path" -xf -
        fi
    fi

    # Restore Config/WindowsServer if present and allowed
    if [[ -d "$tmp_restore/Saved/Config/WindowsServer" ]]; then
        if [[ "$NO_CONFIG" == true || "$other_running" == true ]]; then
            LogWarn "Skipping restoration of Config/WindowsServer because --no-config provided or other servers are running."
        else
            mkdir -p "$saved_path/Config"
            tar -C "$tmp_restore/Saved/Config" -cf - "WindowsServer" | tar -C "$saved_path/Config" -xf -
        fi
    fi

    # Restore cluster data if present and allowed
    if [[ -n "${CLUSTER_ID}" && -d "$tmp_restore/Saved/Cluster/clusters/${CLUSTER_ID}" ]]; then
        if [[ "$NO_CLUSTER" == true || "$other_running" == true ]]; then
            LogWarn "Skipping restoration of Cluster data because --no-cluster provided or other servers are running."
        else
            mkdir -p "$saved_path/Cluster/clusters"
            tar -C "$tmp_restore/Saved/Cluster/clusters" -cf - "${CLUSTER_ID}" | tar -C "$saved_path/Cluster/clusters" -xf -
        fi
    fi

    rm -rf "$tmp_restore" 2>/dev/null || true
    trap - EXIT

    restore_success=true

    if [[ "$restore_success" == false ]]; then
        LogError "An error occurred. Restoring failed."
        if [[ -n "$saved_map_old" ]]; then
            LogInfo "Rolling back: Moving ${saved_map_old} back to SavedArks/${SERVER_MAP}"
            mv "$saved_map_old" "$saved_path/SavedArks/${SERVER_MAP}" 2>/dev/null || true
        fi
        return 1
    fi

    LogSuccess "Backup restored successfully!"
    if [[ -n "$saved_map_old" ]]; then
        LogInfo "Previous map data was moved to ${saved_map_old}"
    fi
    if [[ "$NO_START" == true ]]; then
        LogInfo "Skipping automatic start after restore (--no-start)"
    else
        start
    fi
}

# Main function
main() {
    action="$1"
    option="$2"

    case "$action" in
        "status")
            status "$option"
            ;;
        "start")
            start
            ;;
        "stop")
            stop "$option"
            ;;
        "restart")
            restart "$option"
            ;;
        "saveworld")
            saveworld
            ;;
        "rcon")
            custom_rcon "${@:2:99}"
            ;;
        "health")
            get_health
            ;;
        "update") 
            update "${@:2}"
            ;;
        "check_maintenance")
            check_maintenance
            ;;
        "backup")
            backup
            ;;
        "restore")
            restoreBackup "${@:2}"
            ;;
        *)
            LogError "Invalid action. Supported actions: status, start, stop, restart, saveworld, rcon, update, backup, restore, check_maintenance."
            exit 1
            ;;
    esac
}

# Check if at least one argument is provided
if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <action> [options]"
    echo "  update options: --no-warn"
    echo "  stop/restart options: --saveworld"
    echo "  restore options: --no-cluster --no-mod --no-config --map-only"
    echo "  Actions: status, start, stop, restart, saveworld, rcon, update, backup, restore, check_maintenance."
    exit 1
fi

main "$@"
