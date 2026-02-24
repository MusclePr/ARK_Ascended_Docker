#!/bin/bash
# shellcheck source=./scripts/manager/helper.sh
source "/opt/manager/helper.sh"

if ! /usr/local/bin/manager health >/dev/null; then
    # If manager reports unhealthy but the server status indicates it was
    # intentionally stopped or paused, consider healthcheck successful so 
    # orchestrators don't mark the container unhealthy.
    if [[ -f "${STATUS_FILE}" ]]; then
        status=$(cat "${STATUS_FILE}" 2>/dev/null || true)
        # Treat explicit STOPPED, STOPPING, PAUSED or PAUSING as healthy (no notification)
        if [[ "${status}" == "STOPPED" || "${status}" == "STOPPING" || "${status}" == "PAUSED" || "${status}" == "PAUSING" ]]; then
            exit 0
        fi
    fi
    LogWarn "Server unhealthy"
    if [ "${HEALTHCHECK_SELFHEALING_ENABLED,,}" = true ]; then
        LogInfo "Starting Server"
        /usr/local/bin/manager start &
    fi
    exit 1
fi
exit 0
