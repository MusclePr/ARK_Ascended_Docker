#!/bin/bash
source "/opt/manager/helper.sh"

if ! /usr/local/bin/manager health >/dev/null; then
    LogWarn "Server unhealthy"
    if [ "${HEALTHCHECK_SELFHEALING_ENABLED,,}" = true ]; then
        LogInfo "Starting Server"
        /usr/local/bin/manager start &
    fi
    exit 1
fi
exit 0
