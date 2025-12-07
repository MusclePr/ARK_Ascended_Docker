#!/bin/bash

#exit on error
set -e

source "/opt/manager/helper.sh"

# Create steam directory and set environment variables
mkdir -p "${STEAM_COMPAT_DATA_PATH}"

update_needed=false
if [ ! -f "/opt/arkserver/ShooterGame/Binaries/Win64/ArkAscendedServer.exe" ]; then
    LogInfo "Server not found, marking update as needed"
    update_needed=true
fi

while [ -f /opt/arkserver/.updating ]; do
    update_needed=false
    LogInfo "Wait update in progress..."
    sleep 5
done

# Install or update ASA server + verify installation
if [ "${UPDATE_ON_START,,}" != "false" ]; then
    touch /opt/arkserver/.updating
    update_needed=true
fi

if [ "$update_needed" = true ]; then
    LogInfo "Updating server..."
    trap 'rm -f /opt/arkserver/.updating' EXIT
    
    for i in {1..3}; do
        LogInfo "Update attempt $i..."
        /opt/steamcmd/steamcmd.sh +login anonymous +quit
        if /opt/steamcmd/steamcmd.sh +force_install_dir /opt/arkserver +login anonymous +app_update ${ASA_APPID} validate +quit; then
            LogInfo "Update successful!"
            break
        fi
        LogWarn "Update failed!"
        
        # Clean up potential lock/corruption files before retry
        LogInfo "Cleaning up steamcmd temporary files and manifest..."
        rm -f "/opt/arkserver/steamapps/appmanifest_${ASA_APPID}.acf"
        rm -rf "/opt/arkserver/steamapps/downloading"
        rm -rf "/opt/arkserver/steamapps/temp"
        
        LogWarn "Retrying in 10 seconds..."
        sleep 10
        if [ $i -eq 3 ]; then
            LogError "Update failed after 3 attempts!"
            exit 1
        fi
    done

    trap - EXIT
    rm -f /opt/arkserver/.updating
fi

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
    LogInfo "Cronjobs started"
else
    LogInfo "No Cronjobs found"
fi

# helper links
LogAction "GENERATING HELPER LINKS"
ln -svf ./ShooterGame/Binaries/Win64/PlayersExclusiveJoinList.txt ./whitelist.txt
ln -svf ./ShooterGame/Binaries/Win64/PlayersJoinNoCheckList.txt ./bypasslist.txt
ln -svf ./ShooterGame/Saved/AllowedCheaterAccountIDs.txt ./adminlist.txt
ln -svf ./ShooterGame/Saved/Config/WindowsServer/GameUserSettings.ini ./GameUserSettings.ini
ln -svf ./ShooterGame/Saved/Config/WindowsServer/Game.ini ./Game.ini

#Create file for showing server logs
mkdir -p "${LOG_PATH%/*}" && echo "" > "${LOG_PATH}"

# Start server through manager
manager start &

# Register SIGTERM handler to stop server gracefully
trap "manager stop --saveworld" SIGTERM

# Start tail process in the background, then wait for tail to finish.
# This is just a hack to catch SIGTERM signals, tail does not forward
# the signals.
tail -F "${LOG_PATH}" &
wait $!
