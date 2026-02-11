#!/usr/bin/env bash
set -euo pipefail
# Worker that polls /opt/arkserver/.signals/request.json and dispatches actions (Works on master only)

# shellcheck source=./scripts/manager/helper.sh
source "/opt/manager/helper.sh"

POLL_INTERVAL=${POLL_INTERVAL:-5}
SIGNAL_FILE="${SIGNALS_DIR}/request.json"
LOCKDIR="${SIGNALS_DIR}/request.lock"

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
        procf="${SIGNALS_DIR}/request-${request_id}.json"
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

        LogInfo "Processing request action=$action id=${request_id:-unknown}"

        case "$action" in
            "backup")
                if [ "${CLUSTER_MASTER,,}" == "true" ]; then
                    if /opt/manager/backup.sh --apply; then
                        mark_request_status "$procf" "done"
                    else
                        mark_request_status "$procf" "failed"
                    fi
                fi
                ;;
            "restore")
                # Only master should apply restore
                if [[ -n "${SLAVE_PORTS:-}" ]] && [[ ! -d "$MASTER_LOCK_DIR" ]]; then
                    LogInfo "Non-master node ignoring restore request"
                    mark_request_status "$procf" "done"
                else
                    archive=$(jq -r '.archive // empty' "$procf" 2>/dev/null || true)
                    if [[ -z "$archive" ]]; then
                        LogError "Restore request missing archive"
                        mark_request_status "$procf" "failed"
                    else
                        if /opt/manager/restore.sh --apply "$archive"; then
                            mark_request_status "$procf" "done"
                        else
                            mark_request_status "$procf" "failed"
                        fi
                    fi
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

