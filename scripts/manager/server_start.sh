#!/bin/bash
# This file is called by manager.sh to start a new instance of ASA
# shellcheck source=./scripts/manager/helper.sh
source "/opt/manager/helper.sh"

# Server main options
# shellcheck disable=SC2153
cmd="${SERVER_MAP}?SessionName=\"${SESSION_NAME}\"?ServerPassword=${SERVER_PASSWORD}"

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
fi

cmd="${cmd}${ARK_EXTRA_OPTS}"

# Server dash options

ark_flags=()

# Install mods
if [ -n "$MODS" ]; then
    ark_flags+=("-mods=${MODS}")
fi

if [ -n "$LOG_FILE" ]; then
    ark_flags+=("-log=$(basename "$LOG_FILE")")
else
    ark_flags+=("-log")
fi

if [ -n "${DISABLE_BATTLEYE}" ]; then
    ark_flags+=("-NoBattlEye")
else
    ark_flags+=("-BattlEye")
fi

if [ -n "${MAX_PLAYERS}" ]; then
    ark_flags+=("-WinLiveMaxPlayers=${MAX_PLAYERS}")
fi

if [ -n "${SERVER_IP}" ]; then
    ark_flags+=("-ServerIP=${SERVER_IP}")
fi

if [ -n "${SERVER_PORT}" ]; then
    ark_flags+=("-Port=${SERVER_PORT}")
fi

if [ -n "${QUERY_PORT}" ]; then
    ark_flags+=("-QueryPort=${QUERY_PORT}")
fi

if [ -n "${CLUSTER_ID}" ]; then
    CLUSTER_DIR="${CLUSTER_DIR:-/opt/arkserver/ShooterGame/Saved/Cluster}"
    mkdir -p "${CLUSTER_DIR}"
    ark_flags+=("-clusterID=${CLUSTER_ID}" "-ClusterDirOverride=${CLUSTER_DIR}" "-NoTransferFromFiltering")
fi

if [ "${SERVERGAMELOG,,}" = "true" ]; then
    ark_flags+=("-servergamelog")
fi

# Dynamic config flag
if [ -n "${DYNAMIC_CONFIG_URL}" ]; then
    ark_flags+=("-UseDynamicConfig")
fi

# Append any extra dash-style opts by splitting on whitespace
if [ -n "${ARK_EXTRA_DASH_OPTS}" ]; then
    # read into array respecting shell word splitting
    read -r -a _ark_extra <<< "${ARK_EXTRA_DASH_OPTS}"
    ark_flags+=("${_ark_extra[@]}")
fi

#fix for docker compose exec / docker exec parsing inconsistencies
STEAM_COMPAT_DATA_PATH=$(eval echo "$STEAM_COMPAT_DATA_PATH")

# Logic to update SessionName in GameUserSettings.ini
GUS_FILE="/opt/arkserver/ShooterGame/Saved/Config/WindowsServer/GameUserSettings.ini"
if [ -f "${GUS_FILE}" ] && [ -n "${SESSION_NAME}" ]; then
    # tr -d '\r' to handle Windows-style line endings
    CURRENT_SESSION_NAME=$(grep "^SessionName=" "${GUS_FILE}" | cut -d'=' -f2- | tr -d '\r')
    if [ "${CURRENT_SESSION_NAME}" != "${SESSION_NAME}" ]; then
        LogInfo "SessionName change detected in ${GUS_FILE}: '${CURRENT_SESSION_NAME}' -> '${SESSION_NAME}'"
        acquire_session_name_lock
        sed -i "s/^SessionName=.*/SessionName=${SESSION_NAME}/" "${GUS_FILE}"
        # Wait for RCON in background to release lock once server is fully up
        wait_rcon_ready_and_release_lock &
    fi
fi

#starting server and outputting log file
proton run /opt/arkserver/ShooterGame/Binaries/Win64/ArkAscendedServer.exe "${cmd}" "${ark_flags[@]}" >> "${LOG_PATH}" 2>&1

set_server_status "STOPPED"
