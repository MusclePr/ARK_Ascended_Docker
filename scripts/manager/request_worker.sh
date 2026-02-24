#!/usr/bin/env bash
set -euo pipefail
# Worker that polls per-server request.json and dispatches actions

# shellcheck source=./scripts/manager/helper.sh
source "/opt/manager/helper.sh"

POLL_INTERVAL=${POLL_INTERVAL:-5}
SIGNAL_FILE="${SERVER_SIGNALS_DIR}/request.json"
LOCKDIR="${SERVER_SIGNALS_DIR}/request.lock"

mkdir -p "${SERVER_SIGNALS_DIR}" 2>/dev/null || true

can_handle_request() {
    local action="$1"
    local target_port="$2"

    if [[ -n "$target_port" && "$target_port" != "$SERVER_PORT" ]]; then
        return 1
    fi

    return 0
}

# Cleanup stale lock on start
rmdir "$LOCKDIR" 2>/dev/null || true

while true; do

    if [[ -f "$SIGNAL_FILE" ]]; then
        # try to acquire lock
        if ! mkdir "$LOCKDIR" 2>/dev/null; then
            # another worker is handling it
            sleep "$POLL_INTERVAL"
            continue
        fi

        # Read action
        action=$(jq -r '.action // empty' "$SIGNAL_FILE" 2>/dev/null || true)
        request_id=$(jq -r '.request_id // empty' "$SIGNAL_FILE" 2>/dev/null || true)
        target_port=$(jq -r '.target_port // empty' "$SIGNAL_FILE" 2>/dev/null || true)

        if ! can_handle_request "$action" "$target_port"; then
            rmdir "$LOCKDIR" 2>/dev/null || true
            sleep "$POLL_INTERVAL"
            continue
        fi

        procf="${SERVER_SIGNALS_DIR}/request-${request_id}.json"
        if ! mv -f "$SIGNAL_FILE" "$procf" 2>/dev/null; then
            LogError "Failed to rename processing file with request ID"
            rmdir "$LOCKDIR" 2>/dev/null || true
            sleep "$POLL_INTERVAL"
            continue
        fi

        if [[ -z "$action" ]]; then
            LogError "Request missing action field"
            mark_request_status "$procf" "failed"
            rmdir "$LOCKDIR" 2>/dev/null || true
            sleep "$POLL_INTERVAL"
            continue
        fi

        LogInfo "Processing request action=$action id=${request_id:-unknown} target_port=${target_port:-none}"

        case "$action" in
            "pause")
                if /opt/manager/manager.sh pause --apply; then
                    mark_request_status "$procf" "done"
                else
                    mark_request_status "$procf" "failed"
                fi
                ;;
            "unpause")
                if /opt/manager/manager.sh unpause --apply; then
                    mark_request_status "$procf" "done"
                else
                    mark_request_status "$procf" "failed"
                fi
                ;;
            "stop")
                opt=$(jq -r '.option // empty' "$procf" 2>/dev/null || true)
                if /opt/manager/manager.sh stop "$opt"; then
                    mark_request_status "$procf" "done"
                else
                    mark_request_status "$procf" "failed"
                fi
                ;;
            "save")
                health=$(get_health 2>/dev/null || true)
                if [[ "$health" == "DOWN" ]]; then
                    LogInfo "Server already down. Treating save request as acknowledged."
                    mark_request_status "$procf" "done"
                else
                    save_wait_timeout_sec=${SAVE_REQUEST_STARTUP_TIMEOUT_SEC:-180}
                    save_wait_interval_sec=${SAVE_REQUEST_STARTUP_INTERVAL_SEC:-5}
                    save_waited=0

                    if [[ "$health" == "PAUSED" ]]; then
                        LogInfo "Server is paused. Treating save request as acknowledged."
                        mark_request_status "$procf" "done"
                    else
                        if ! "${RCON_CMDLINE[@]}" ListPlayers >/dev/null 2>&1; then
                            LogInfo "Save request received while server is not RCON-ready (health=${health:-UNKNOWN}). Waiting up to ${save_wait_timeout_sec}s for RCON readiness."
                            while (( save_waited < save_wait_timeout_sec )); do
                                if "${RCON_CMDLINE[@]}" ListPlayers >/dev/null 2>&1; then
                                    break
                                fi
                                sleep "$save_wait_interval_sec"
                                save_waited=$((save_waited + save_wait_interval_sec))
                            done
                        fi

                        if ! "${RCON_CMDLINE[@]}" ListPlayers >/dev/null 2>&1; then
                            LogError "Save request failed: RCON is not ready after ${save_wait_timeout_sec}s (health=${health:-UNKNOWN})."
                            mark_request_status "$procf" "failed"
                        elif saveworld; then
                            mark_request_status "$procf" "done"
                        else
                            mark_request_status "$procf" "failed"
                        fi
                    fi
                fi
                ;;
            "start")
                if [[ "${CLUSTER_MASTER,,}" != "true" ]] && { [[ ! -f "$MASTER_READY_FILE" ]] || [[ -f "$LOCK_FILE" ]]; }; then
                    LogInfo "Deferring start request id=${request_id:-unknown}: master not ready or maintenance lock is active."
                    if [[ ! -f "$SIGNAL_FILE" ]] && mv -f "$procf" "$SIGNAL_FILE" 2>/dev/null; then
                        :
                    else
                        LogWarn "Failed to defer start request safely. Marking request as failed."
                        mark_request_status "$procf" "failed"
                    fi
                elif /opt/manager/manager.sh start; then
                    mark_request_status "$procf" "done"
                else
                    mark_request_status "$procf" "failed"
                fi
                ;;
            *)
                LogWarn "Unknown request action: $action"
                mark_request_status "$procf" "failed"
                ;;
        esac

        # release lock
        rmdir "$LOCKDIR" 2>/dev/null || true
    fi
    sleep "$POLL_INTERVAL"
done

