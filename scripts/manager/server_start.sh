#!/bin/bash
# This file is called by manager.sh to start a new instance of ASA
source "/opt/manager/helper.sh"

# Server main options
cmd="${SERVER_MAP}?listen?SessionName=\"${SESSION_NAME}\"?Port=${SERVER_PORT}"
if [ -n "${MAX_PLAYERS}" ]; then
    cmd="${cmd}?MaxPlayers=${MAX_PLAYERS}"
fi

cmd="${cmd}?ServerPassword=${SERVER_PASSWORD}"

if [ -n "${ARK_ADMIN_PASSWORD}" ]; then
    cmd="${cmd}?ServerAdminPassword=\"${ARK_ADMIN_PASSWORD}\""
fi

if [ -n "${RCON_PORT}" ]; then
    cmd="${cmd}?RCONEnabled=True?RCONPort=${RCON_PORT}"
fi

if [ -n "${MULTIHOME}" ]; then
    cmd="${cmd}?MultiHome=${MULTIHOME}"
fi

if [ -n "${DYNAMIC_CONFIG_URL}" ]; then
    cmd="${cmd}?CustomDynamicConfigUrl=\"${DYNAMIC_CONFIG_URL}\""
    ark_flags="${ark_flags} -UseDynamicConfig"
fi

cmd="${cmd}${ARK_EXTRA_OPTS}"

# Server dash options
# Install mods
if [ -n "$MODS" ]; then
    ark_flags="${ark_flags} -mods=${MODS}"
fi

if [ -n "$LOG_FILE" ]; then
    ark_flags="${ark_flags} -log=$(basename "$LOG_FILE")"
else
    ark_flags="${ark_flags} -log"
fi

if [ -n "${DISABLE_BATTLEYE}" ]; then 
    ark_flags="${ark_flags} -NoBattlEye"
else 
    ark_flags="${ark_flags} -BattlEye"
fi

if [ -n "${MAX_PLAYERS}" ]; then 
    ark_flags="${ark_flags} -WinLiveMaxPlayers=${MAX_PLAYERS}"
fi

if [ -n "${SERVER_IP}" ]; then
    ark_flags="${ark_flags} -ServerIP=${SERVER_IP}"
fi

if [ -n "${QUERY_PORT}" ]; then
    ark_flags="${ark_flags} -QueryPort=${QUERY_PORT}"
fi

if [ -n "${CLUSTER_ID}" ]; then
    CLUSTER_DIR="${CLUSTER_DIR:-/opt/arkserver/ShooterGame/Saved/Cluster}"
    mkdir -p "${CLUSTER_DIR}"
    ark_flags="${ark_flags} -clusterID=${CLUSTER_ID} -ClusterDirOverride=\"${CLUSTER_DIR}\" -NoTransferFromFiltering"
fi

if [ "${SERVERGAMELOG,,}" = "true" ]; then
    ark_flags="${ark_flags} -servergamelog"
fi

ark_flags="${ark_flags} ${ARK_EXTRA_DASH_OPTS}"

#fix for docker compose exec / docker exec parsing inconsistencies
STEAM_COMPAT_DATA_PATH=$(eval echo "$STEAM_COMPAT_DATA_PATH")

#starting server and outputting log file
proton run /opt/arkserver/ShooterGame/Binaries/Win64/ArkAscendedServer.exe ${cmd} ${ark_flags} >> "${LOG_PATH}" 2>&1

set_server_status "STOPPED"
