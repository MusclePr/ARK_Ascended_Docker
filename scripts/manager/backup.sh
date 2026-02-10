#!/usr/bin/env bash
# Master-side backup request helper
# Usage: backup.sh request

set -euo pipefail

# shellcheck source=./scripts/manager/helper.sh
source "/opt/manager/helper.sh"

mode="request"
if [[ $# -gt 0 ]]; then
    mode="$1"
fi

# backup implementation migrated from manager.sh
backup() {
    local path="/var/backups"
    local tmp_path="/opt/arkserver/tmp/backup"

    LogInfo "Creating backup. Backups are saved in your backup volume."
    set_server_status "BACKUP_SAVE"

    saveworld

    mkdir -p "$path"
    mkdir -p "$tmp_path"

    local label
    label="$(sanitize "$SESSION_NAME")"
    archive_name="${label}_$(date +"%Y-%m-%d_%H-%M")"

    # copy selected subpaths into temporary dir so tar doesn't get write-on-read failures
    LogInfo "Copying selected Saved subpaths"
    saved_base="/opt/arkserver/ShooterGame/Saved"
    mkdir -p "$tmp_path"

    if [[ -d "$saved_base/SavedArks" ]]; then
        found_any=false
        for __entry in "$saved_base/SavedArks"/*; do
            if [[ ! -e "${__entry}" ]]; then
                continue
            fi
            __m=$(basename "${__entry}")
            [[ -z "${__m}" ]] && continue
            if [[ -d "${__entry}" ]]; then
                found_any=true
                mkdir -p "$tmp_path/Saved/SavedArks"
                (cd "$saved_base/SavedArks" && tar -cf - --exclude='*.profilebak' --exclude='*.tribebak' --exclude="${__m}_*.ark" "${__m}") | tar -C "$tmp_path/Saved/SavedArks" -xf -
            fi
        done
        if [[ "$found_any" != true ]]; then
            LogWarn "No SavedArks/* subpaths found to archive; skipping SavedArks."
        fi
    else
        LogWarn "$saved_base/SavedArks not found; skipping SavedArks backups."
    fi

    if [[ -d "$saved_base/SaveGames" ]]; then
        mkdir -p "$tmp_path/Saved"
        tar -C "$saved_base" -cf - "SaveGames" | tar -C "$tmp_path/Saved" -xf -
    fi

    if [[ -d "$saved_base/Config/WindowsServer" ]]; then
        mkdir -p "$tmp_path/Saved/Config"
        tar -C "$saved_base/Config" -cf - "WindowsServer" | tar -C "$tmp_path/Saved/Config" -xf -
    fi

    if [[ -n "${CLUSTER_ID}" && -d "$saved_base/Cluster/clusters/${CLUSTER_ID}" ]]; then
        mkdir -p "$tmp_path/Saved/Cluster/clusters"
        tar -C "$saved_base/Cluster/clusters" -cf - "${CLUSTER_ID}" | tar -C "$tmp_path/Saved/Cluster/clusters" -xf -
    fi

    if [[ -z "$(ls -A "$tmp_path" 2>/dev/null)" ]]; then
        LogWarn "No matching Saved subpaths found to archive; creating empty backup metadata."
    fi

    LogInfo "Creating archive"
    tar -czf "$path/${archive_name}.tar.gz" -C "$tmp_path" Saved
    if [[ $? == 1 ]]; then
        LogError "Creating backup failed" >> "$LOG_PATH"
        return 1
    fi
    LogSuccess "Backup created" >> "$LOG_PATH"

    rm -R "$tmp_path"
    if get_health >/dev/null; then set_server_status "RUNNING"; fi

    if [[ "${OLD_BACKUP_DAYS}" =~ ^[0-9]+$ ]]; then
        LogAction "Removing old Backups"
        LogInfo "Deleting Backups older than ${OLD_BACKUP_DAYS} days!"
        find "$path" -mindepth 1 -maxdepth 1 -mtime "+${OLD_BACKUP_DAYS}" -type f -name '*.tar.gz' -print -delete
    fi
    return 0
}

if [[ "$mode" == "request" ]]; then
    mkdir -p "${SIGNALS_DIR}" 2>/dev/null || true

    local_ts=$(date -Is 2>/dev/null || date +%s)
    # generate a simple request id
    req_id="$(date +%s)-$$-$RANDOM"
    payload=$(mktemp)
    # Build JSON payload
    jq -n --arg action "backup" --arg request_id "$req_id" --arg requested_by "${USER:-$(whoami 2>/dev/null || echo unknown)}" --arg timestamp "$local_ts" '{action:$action,request_id:$request_id,requested_by:$requested_by,timestamp:$timestamp}' > "$payload"

    if [[ -e "${REQUEST_JSON}" ]]; then
        LogError "A request already exists (${REQUEST_JSON}). Aborting."
        rm -f "$payload"
        exit 3
    fi

    if ! create_request_json "backup" "$payload"; then
        LogError "Failed to create backup request (busy)."
        rm -f "$payload"
        exit 4
    fi

    rm -f "$payload"

    LogInfo "Backup request created. Initiating cluster maintenance and waiting for slaves."
    request_started_epoch=$(date +%s)
    enter_maintenance "$request_started_epoch"

    LogInfo "Performing master-local backup now..."
    if ! backup; then
        rc=$?
        LogError "Local backup failed with code $rc"
        # mark processing request as failed (use JSON-aware wrapper)
        mark_request_status "${REQUEST_JSON}" "failed"
        exit $rc
    fi

    # mark done
    mark_request_status "${REQUEST_JSON}" "done"
    LogSuccess "Cluster backup completed on master. Releasing maintenance locks."
    exit_maintenance
    exit 0

elif [[ "$mode" == "apply" ]]; then
    # Perform local backup without creating a new request (used by worker)
    backup
    exit $?
else
    echo "Usage: $0 request|apply"
    exit 1
fi
