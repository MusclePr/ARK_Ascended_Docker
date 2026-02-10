#!/usr/bin/env bash
set -euo pipefail
# Worker that polls /opt/arkserver/.signals/request.json and dispatches actions

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

        pid=$$
        ts=$(date -Is 2>/dev/null || date +%s)
        procf="${SIGNALS_DIR}/request.processing.${pid}.${ts}.json"
        if ! mv -f "$SIGNAL_FILE" "$procf" 2>/dev/null; then
            LogError "Failed to move request to processing file"
            rmdir "$LOCKDIR" 2>/dev/null || true
            sleep "$POLL_INTERVAL"
            continue
        fi

        # Read action
        action=$(jq -r '.action // empty' "$procf" 2>/dev/null || true)
        request_id=$(jq -r '.request_id // empty' "$procf" 2>/dev/null || true)

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
                # If this node is a slave (no SLAVE_PORTS configured), perform save and ACK
                if [[ -z "${SLAVE_PORTS:-}" ]]; then
                    # single-node / non-cluster: perform local backup
                    if /opt/manager/backup.sh apply; then
                        mark_request_status "$procf" "done"
                    else
                        mark_request_status "$procf" "failed"
                    fi
                else
                    # Cluster: determine master vs slave by presence of MASTER_LOCK_DIR
                    if [[ -d "$MASTER_LOCK_DIR" ]]; then
                        # acting as master: wait for slaves then perform local backup
                        LogInfo "Master handling backup request: entering maintenance"
                        enter_maintenance
                        # Wait for slaves to ack
                        wait_for_slave_acks "$(date +%s)"
                        if /opt/manager/backup.sh apply; then
                            mark_request_status "$procf" "done"
                        else
                            mark_request_status "$procf" "failed"
                        fi
                        exit_maintenance
                    else
                        # slave: perform saveworld and signal
                        if bash /opt/manager/manager.sh saveworld; then
                            touch "${SIGNALS_DIR}/waiting_${SERVER_PORT}.flag" 2>/dev/null || true
                            mark_request_status "$procf" "done"
                        else
                            mark_request_status "$procf" "failed"
                        fi
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

