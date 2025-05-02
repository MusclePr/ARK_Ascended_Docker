#!/bin/bash
RCON_CMDLINE=( rcon -a 127.0.0.1:${RCON_PORT} -p ${ARK_ADMIN_PASSWORD} )
EOS_FILE=/opt/manager/.eos.config
source "/opt/manager/helper.sh"

get_and_check_pid() {
    # Get PID
    ark_pid=$(cat "$PID_FILE" 2>/dev/null)
    if [[ -z "$ark_pid" ]]; then
        echo "0"
        return 1
    fi

    # Check process is still alive
    if ps -p $ark_pid > /dev/null; then
        echo "$ark_pid"
        return 0
    else
        echo "0"
        return 1
    fi
}

get_health() {
    server_pid=$(pgrep GameThread)
    steam_pid=$(pidof steamcmd)
    if [[ "${steam_pid:-0}" != 0 ]]; then
        echo "Updating"
        return 0
    fi
    if [[ "${server_pid:-0}" != 0 ]]; then
        echo "UP"
        return 0
    else
        echo "Down"
        return 1
    fi
}

custom_rcon() {
    if ! get_health >/dev/null ; then
        return 1
    fi
    echo $(${RCON_CMDLINE[@]} "${@}" 2>/dev/null)
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
    creds=$(cat "$EOS_FILE" | cut -d, -f1)
    id=$(cat "$EOS_FILE" | cut -d, -f2)

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
    battleye=${vars[4]}
    ip=${vars[5]}
    bind=${vars[6]}
    map=${vars[7]}
    major=${vars[8]}
    minor=${vars[9]}
    pve=${vars[10]}
    mods=${vars[11]}
    bind_ip=${bind%:*}
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

    # Get server PID
    ark_pid=$(get_and_check_pid)
    if [[ "$ark_pid" == 0 ]]; then
        LogError "Server PID not found (server offline?)"
        return 1
    fi    
    echo -e "Server PID:     ${ark_pid}"

    ark_port=$(ss -tupln | grep "GameThread" | grep -oP '(?<=:)\d+')
    if [[ -z "$ark_port" ]]; then
        echo -e "Server Port:    Not Listening"
        return 1
    fi

    echo -e "Server Port:    ${ark_port}"

    # Check initial status with rcon command
    out=$(${RCON_CMDLINE[@]} ListPlayers 2>/dev/null)
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
            echo -e "Players:        ${num_players} / ?"
            LogSuccess "Server is up"
            return 0
        fi
    else
        LogError "Server is down"
        return 0
    fi
}

start() {
    if get_health >/dev/null ; then
        LogInfo "Server is already running."
        return 0
    fi
    LogInfo "Starting server on port ${SERVER_PORT}"
    LogAction "STARTING SERVER" >> "$LOG_FILE"

    # Start server in the background + nohup and save PID
    DiscordMessage "Start" "The Server is starting" "success"
    nohup /opt/manager/server_start.sh >/dev/null 2>&1 &
    ark_pid=$!
    echo "$ark_pid" > "$PID_FILE"
    sleep 3
}

stop() {
    if ! get_health >/dev/null ; then
        LogError "Server is not running"
        return 1
    fi

    if [[ $1 == "--saveworld" ]]; then
        saveworld
    fi
    DiscordMessage "Stopping" "Server will gracefully shutdown" "in-progress"
    LogAction "STOPPING SERVER" >> "$LOG_FILE"

    # Check number of players
    out=$(${RCON_CMDLINE[@]} DoExit 2>/dev/null)
    res=$?
    force=false
    if [[ $res == 0  && "$out" == "Exiting..." ]]; then
        LogInfo "Waiting ${SERVER_SHUTDOWN_TIMEOUT}s for the server to stop"
        timeout $SERVER_SHUTDOWN_TIMEOUT tail --pid=$ark_pid -f /dev/null
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
        DiscordMessage "Stopping" "Forcing the Server to shutdown" "faillure"
        LogWarn "Forcing server shutdown"
        kill -INT $ark_pid

        timeout $SERVER_SHUTDOWN_TIMEOUT tail --pid=$ark_pid -f /dev/null
        res=$?
        # Timeout occurred
        if [[ "$res" == 124 ]]; then
            kill -9 $ark_pid
        fi
    fi

    echo "" > $PID_FILE
    DiscordMessage "Stopping" "Server has been stopped" "faillure"
    LogAction "SERVER STOPPED" >> "$LOG_FILE"
}

restart() {
    DiscordMessage "Restart" "Restarting the Server" "in-progress"
    LogAction "RESTARTING SERVER"
    stop "$1"
    start
}

saveworld() {
    if ! get_health >/dev/null ; then
        LogError "Unable to save... Server not up"
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
update_required() {
  LogInfo "Checking for new Server updates"
  local CURRENT_MANIFEST LATEST_MANIFEST temp_file http_code updateAvailable
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
  LATEST_MANIFEST=$(jq '.data."'"$ASA_APPID"'".depots."'"$(($ASA_APPID + 1))"'".manifests.public.gid' <"$temp_file" | sed -r 's/.*("[0-9]+")$/\1/' | tr -d '"')
  rm "$temp_file"

  if [ -z "$LATEST_MANIFEST" ]; then
      LogError "The server response does not contain the expected BuildID. Unable to check for updates!"
      DiscordMessage "Install" "Steam servers response does not contain the expected BuildID. Unable to check for updates!" "failure"
      return 2
  fi

  # Parse current manifest from steam files
  CURRENT_MANIFEST=$(awk '/manifest/{count++} count==2 {print $2; exit}' /opt/arkserver/steamapps/appmanifest_$ASA_APPID.acf | tr -d '"')

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

  if [ "$updateAvailable" == false ]; then
    return 1
  fi
}

update() {
    if ! update_required; then
        LogSuccess "The server is up to date!"
        return 0
    fi
    if [[ "${AUTO_UPDATE_WARN_MINUTES}" =~ ^[0-9]+$ ]]; then
        custom_rcon "broadcast The Server will update in ${UPDATE_WARN_MINUTES} minutes"
        DiscordMessage "Update" "Server will update in ${UPDATE_WARN_MINUTES} minutes"
        sleep $((UPDATE_WARN_MINUTES * 60))
    fi

    DiscordMessage "Update" "Updating Server now" "warn"
    LogAction "UPDATING SERVER"
    stop --saveworld
    rm "/opt/arkserver/steamapps/appmanifest_$ASA_APPID.acf"
    /opt/steamcmd/steamcmd.sh +force_install_dir /opt/arkserver +login anonymous +app_update ${ASA_APPID} +quit # Remove unnecessary files (saves 6.4GB.., that will be re-downloaded next update)
    if [[ -n "${REDUCE_IMAGE_SIZE}" ]]; then 
        rm -rf /opt/arkserver/ShooterGame/Binaries/Win64/ArkAscendedServer.pdb
        rm -rf /opt/arkserver/ShooterGame/Content/Movies/
    fi

    LogSuccess "Update completed"
    start
}

backup(){
    LogInfo "Creating backup. Backups are saved in your ./ark_backup volume."
    # saving before creating the backup
    saveworld
    # Use backup script
    /opt/manager/backup.sh

    res=$?
    if [[ $res == 0 ]]; then
        LogSuccess "Backup Created" >> $LOG_FILE
    else
        LogError "creating backup failed"
    fi
}

restoreBackup(){
    backup_count=$(ls /var/backups/asa-server/ | wc -l)
    if [[ $backup_count -gt 0 ]]; then
        sleep 3
        # restoring the backup
        /opt/manager/restore.sh
        sleep 2
        start
    else
        LogError "You haven't created any backups yet."
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
            update
            ;;
        "backup")
            backup
            ;;
        "restore")
            restoreBackup
            ;;
        *)
            LogError "Invalid action. Supported actions: status, start, stop, restart, saveworld, rcon, update, backup, restore."
            exit 1
            ;;
    esac
}

# Check if at least one argument is provided
if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <action> [--saveworld]"
    exit 1
fi

main "$@"
