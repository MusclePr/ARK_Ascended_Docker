#!/bin/bash

#exit on error
set -e

source "/opt/manager/helper.sh"

# Create steam directory and set environment variables
mkdir -p "${STEAM_COMPAT_DATA_PATH}"

# Install or update ASA server + verify installation
/opt/steamcmd/steamcmd.sh +force_install_dir /opt/arkserver +login anonymous +app_update ${ASA_APPID} +quit

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
supercronic -quiet -test "$CRONTAB_FILE" || exit

if [ "${BACKUP_ENABLED,,}" = true ]; then
    LogInfo "BACKUP_ENABLED=${BACKUP_ENABLED,,}"
    LogInfo "Adding cronjob for auto backups"
    echo "$BACKUP_CRON_EXPRESSION bash /usr/local/bin/manager backup" >> "$CRONTAB_FILE"
    supercronic -quiet -test "$CRONTAB_FILE" || exit
fi

if [ "${AUTO_UPDATE_ENABLED,,}" = true ]; then
    LogInfo "AUTO_UPDATE_ENABLED=${AUTO_UPDATE_ENABLED,,}"
    LogInfo "Adding cronjob for auto updating"
    echo "$AUTO_UPDATE_CRON_EXPRESSION bash /usr/local/bin/manager update" >> "$CRONTAB_FILE"
    supercronic -quiet -test "$CRONTAB_FILE" || exit
fi
if [ -s "$CRONTAB_FILE" ]; then
    supercronic -split-logs  "$CRONTAB_FILE" 1>/dev/null &
    LogInfo "Cronjobs started"
else
    LogInfo "No Cronjobs found"
fi

#Create file for showing server logs
mkdir -p "${LOG_FILE%/*}" && echo "" > "${LOG_FILE}"

# Start server through manager
echo "" > "${PID_FILE}"
manager start &

# Register SIGTERM handler to stop server gracefully
trap "manager stop --saveworld" SIGTERM

# Start tail process in the background, then wait for tail to finish.
# This is just a hack to catch SIGTERM signals, tail does not forward
# the signals.
tail -F "${LOG_FILE}" &
wait $!
