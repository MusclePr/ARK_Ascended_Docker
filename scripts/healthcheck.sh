#!/bin/bash
# shellcheck source=./scripts/manager/helper.sh
source "/opt/manager/helper.sh"

if ! /usr/local/bin/manager health >/dev/null; then
    # Only RUNNING is considered strictly unhealthy when manager health fails.
    # Transitional or intentionally stopped states are treated as healthy.
    if [[ ! -f "${STATUS_FILE}" ]]; then
        LogWarn "Server unhealthy (status file not found)"
        exit 1
    fi

    status=$(cat "${STATUS_FILE}" 2>/dev/null || true)
    if [[ -z "${status}" || "${status}" == "UNKNOWN" ]]; then
        LogWarn "Server unhealthy (status unknown)"
        exit 1
    fi

    if [[ "${status}" != "RUNNING" ]]; then
        exit 0
    fi

    LogWarn "Server unhealthy"
    if [ "${HEALTHCHECK_SELFHEALING_ENABLED,,}" = true ]; then
        LogInfo "Starting Server"
        /usr/local/bin/manager start &
    fi
    exit 1
fi
exit 0
