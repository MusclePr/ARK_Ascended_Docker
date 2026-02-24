#!/usr/bin/env bash
set -euo pipefail
# Worker that polls cluster-level request.json and dispatches node-level actions.

# shellcheck source=./scripts/manager/helper.sh
source "/opt/manager/helper.sh"

POLL_INTERVAL=${POLL_INTERVAL:-5}
SIGNAL_FILE="${CLUSTER_REQUEST_JSON}"
LOCKDIR="${CLUSTER_SIGNALS_DIR}/request.lock"

mkdir -p "${CLUSTER_SIGNALS_DIR}" 2>/dev/null || true

if [[ "${CLUSTER_MASTER,,}" != "true" ]]; then
    LogInfo "cluster_request_worker is disabled on non-master node."
    exit 0
fi

# Cleanup stale lock on start
rmdir "$LOCKDIR" 2>/dev/null || true

while true; do
    if [[ -f "$SIGNAL_FILE" ]]; then
        if ! mkdir "$LOCKDIR" 2>/dev/null; then
            sleep "$POLL_INTERVAL"
            continue
        fi

        action=$(jq -r '.action // empty' "$SIGNAL_FILE" 2>/dev/null || true)
        request_id=$(jq -r '.request_id // empty' "$SIGNAL_FILE" 2>/dev/null || true)
        option=$(jq -r '.option // empty' "$SIGNAL_FILE" 2>/dev/null || true)
        start_epoch=$(jq -r '.start_epoch // empty' "$SIGNAL_FILE" 2>/dev/null || true)

        if [[ -z "$request_id" ]]; then
            request_id="$(date +%s)-$$-$RANDOM"
        fi

        procf="${CLUSTER_SIGNALS_DIR}/request-${request_id}.json"
        if ! mv -f "$SIGNAL_FILE" "$procf" 2>/dev/null; then
            LogError "Failed to rename cluster request processing file with request ID"
            rmdir "$LOCKDIR" 2>/dev/null || true
            sleep "$POLL_INTERVAL"
            continue
        fi

        if [[ -z "$action" ]]; then
            LogError "Cluster request missing action field"
            mark_request_status "$procf" "failed"
            rmdir "$LOCKDIR" 2>/dev/null || true
            sleep "$POLL_INTERVAL"
            continue
        fi

        if [[ -z "$start_epoch" ]] || [[ ! "$start_epoch" =~ ^[0-9]+$ ]]; then
            start_epoch=$(date +%s)
        fi

        LogInfo "Processing cluster request action=$action id=${request_id:-unknown}"

        case "$action" in
            "stop"|"save")
                if dispatch_cluster_action_to_nodes "$action" "$option" "$start_epoch" "$request_id"; then
                    mark_request_status "$procf" "done"
                else
                    mark_request_status "$procf" "failed"
                fi
                ;;
            "backup")
                if CLUSTER_WORKER_CONTEXT=true CLUSTER_WORKER_REQUEST_ID="$request_id" /opt/manager/backup.sh --apply; then
                    mark_request_status "$procf" "done"
                else
                    mark_request_status "$procf" "failed"
                fi
                ;;
            "restore")
                archive=$(jq -r '.archive // empty' "$procf" 2>/dev/null || true)
                if [[ -z "$archive" ]]; then
                    LogError "Cluster restore request missing archive"
                    mark_request_status "$procf" "failed"
                elif CLUSTER_WORKER_CONTEXT=true CLUSTER_WORKER_REQUEST_ID="$request_id" /opt/manager/restore.sh --apply "$archive"; then
                    mark_request_status "$procf" "done"
                else
                    mark_request_status "$procf" "failed"
                fi
                ;;
            *)
                LogWarn "Unknown cluster request action: $action"
                mark_request_status "$procf" "failed"
                ;;
        esac

        rmdir "$LOCKDIR" 2>/dev/null || true
    fi

    sleep "$POLL_INTERVAL"
done
