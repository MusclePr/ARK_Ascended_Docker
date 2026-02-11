#!/usr/bin/env bash
set -euo pipefail
# Restore backup implementation moved out of manager.sh

# shellcheck source=./scripts/manager/helper.sh
source "/opt/manager/helper.sh"

backup_path="/var/backups"

Restore_request() {
    local archive="$1"
    # Resolve archive choice
    if [[ -n "$archive" ]]; then
        # Non-interactive mode
        # if user passed basename, allow both absolute and relative within backup_path
        if [[ ! "$archive" =~ ^/ ]]; then
            archive="${backup_path}/${archive}"
        fi
        if [[ ! -f "$archive" ]]; then
            LogError "Backup file not found: $archive"
            return 1
        fi
    else
        # Interactive mode
        local -i backup_count
        backup_count=$(find "$backup_path" -mindepth 1 -maxdepth 1 -type f 2>/dev/null | wc -l)
        if [[ $backup_count -eq 0 ]]; then
            LogError "You haven't created any backups yet."
            return 1
        fi
        LogInfo "Please choose the archive to restore:"
        archive=$(SelectArchive "$backup_path")
        if [[ -z "$archive" ]]; then
            LogError "No Selection was made!"
            return 1
        fi
        echo -n "Create restore request for '$archive'? [y/N]: "
        read -r ans
        if [[ ! $ans =~ ^[Yy]$ ]]; then
            LogInfo "Aborted by user. No request created."
            return 2
        fi
    fi

    mkdir -p "$SIGNALS_DIR" 2>/dev/null || true
    if [[ -f "$REQUEST_JSON" ]]; then
        LogError "A request already exists: $REQUEST_JSON. Please wait for it to be processed or remove it manually."
        return 3
    fi

    # Build JSON payload and write atomically
    local ts req_id payload
    ts=$(date -Is 2>/dev/null || date +%s)
    req_id="$(date +%s)-$$-$RANDOM"
    payload=$(mktemp)
    jq -n --arg action "restore" --arg request_id "$req_id" --arg archive "$archive" --arg requested_by "${USER:-$(whoami 2>/dev/null || echo unknown)}" --arg timestamp "$ts" '{action:$action,request_id:$request_id,archive:$archive,requested_by:$requested_by,timestamp:$timestamp}' >"$payload"
    if ! create_request_json "restore" "$payload"; then
        LogError "Failed to create restore request (busy)."
        rm -f "$payload"
        return 4
    fi
    rm -f "$payload"
    LogSuccess "Restore request created: $REQUEST_JSON"
    wait_for_response "$req_id"
    return $?
}

tmp_restore=""

Restore_apply() {
    local archive="$1"
    if [[ -z "$archive" ]]; then
        LogError "No archive specified for restore."
        return 1
    fi

    # Enter cluster maintenance mode (requests cluster-wide stop)
    local request_started_epoch
    request_started_epoch=$(date +%s)
    enter_maintenance stop "$request_started_epoch"

    LogInfo "Stopping local server for restore..."
    # Stop this node gracefully
    manager stop --saveworld

    # Wait for server to actually stop (timeout 120s = stop 60s + countdown 60s)
    local waited=0
    local stop_timeout=120
    while get_pid >/dev/null && [ $waited -lt $stop_timeout ]; do
        sleep 1
        waited=$((waited+1))
    done

    if get_pid >/dev/null; then
        LogError "Server did not stop after ${stop_timeout}s. Aborting restore."
        exit_maintenance
        trap - EXIT
        return 1
    fi

    LogInfo "Restoring backup: $archive"
    set_server_status "RESTORING"

    # Simple extraction: unpack archive directly into /opt/arkserver
    if ! tar -xzf "$archive" -C /opt/arkserver --overwrite; then
        LogError "Tar extraction failed"
        trap - EXIT
        exit_maintenance
        return 1
    fi

    LogSuccess "Backup restored successfully!"
    # Start server and release cluster maintenance locks after readiness
    master_release_after_start 900
}

Restore_main() {
    if [ "${CLUSTER_MASTER,,}" != "true" ]; then
        LogError "Restore can only be initiated on the cluster master node."
        return 1
    fi

    # Simplified cluster-wide restore using enter_maintenance stop/exit_maintenance
    # Modes:
    #   --request [<archive>]  : create a restore request (default interactive)
    #   --apply <archive>      : actually apply the restore (used by monitor/worker)
    local mode="request"
    local backup_path=/var/backups
    local archive=""

    if [[ $# -gt 0 ]]; then
        case "$1" in
            --apply)
                mode="apply"
                shift
                archive="$1"
                ;;
            --request)
                mode="request"
                shift
                archive="$1"
                ;;
            *)
                # default: treat positional as archive but still create request interactively
                archive="$1"
                mode="request"
                ;;
        esac
    fi

    if [[ "$mode" == "request" ]]; then
        Restore_request "$archive"
        return $?
    elif [[ "$mode" == "apply" ]]; then
        Restore_apply "$archive"
        return $?
    fi
    LogError "Usage: restore.sh [--request [<archive>] | --apply <archive>]"
    return 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    # Called directly: forward CLI to restore function
    Restore_main "$@"
    exit $?
fi
