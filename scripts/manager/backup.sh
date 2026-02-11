#!/usr/bin/env bash
# Master-side backup request helper
# Usage: backup.sh --request|--apply

set -euo pipefail

# shellcheck source=./scripts/manager/helper.sh
source "/opt/manager/helper.sh"

Backup_request() {
    mkdir -p "${SIGNALS_DIR}" 2>/dev/null || true
    if [[ -f "$REQUEST_JSON" ]]; then
        LogError "A request already exists: $REQUEST_JSON. Please wait for it to be processed or remove it manually."
        return 3
    fi

    # Build JSON payload and write atomically
    local ts req_id payload
    ts=$(date -Is 2>/dev/null || date +%s)
    req_id="$(date +%s)-$$-$RANDOM"
    payload=$(mktemp)
    jq -n --arg action "backup" --arg request_id "$req_id" --arg requested_by "${USER:-$(whoami 2>/dev/null || echo unknown)}" --arg timestamp "$ts" '{action:$action,request_id:$request_id,requested_by:$requested_by,timestamp:$timestamp}' > "$payload"
    if ! create_request_json "backup" "$payload"; then
        LogError "Failed to create backup request (busy)."
        rm -f "$payload"
        return 4
    fi
    rm -f "$payload"
    LogSuccess "Backup request created: $REQUEST_JSON"
    wait_for_response "$req_id"
    return $?
}

# Create backup immediately (called by worker/monitor)
Backup_create() {
    local path="/var/backups"
    local tmp_path="/opt/arkserver/tmp/backup_$$"

    LogInfo "Creating backup. Backups are saved in your backup volume."
    set_server_status "BACKUP_SAVE"

    saveworld

    # Wait for save files to stabilize (check size constancy)
    LogInfo "Waiting for save file stability..."
    local _chk_basedir="/opt/arkserver/ShooterGame/Saved"
    local _s_prev=""
    local _s_curr=""
    local _s_retries=24 # Max 2 mins
    for ((i=0; i<_s_retries; i++)); do
        sync
        sleep 5
        # Calculate sum of sizes of all .ark files
        _s_curr=$(find "$_chk_basedir/SavedArks" -name "*.ark" -type f -exec stat -c%s {} + 2>/dev/null | awk '{s+=$1} END {print s}')
        _s_curr=${_s_curr:-0}
        
        if [[ "$_s_prev" == "$_s_curr" && "$_s_curr" != "0" ]]; then
            LogSuccess "Save files are stable (Size: $_s_curr bytes)."
            break
        fi
        
        if [[ $i -eq $((_s_retries - 1)) ]]; then
             LogWarn "Timed out waiting for save file stability. Proceeding immediately."
        elif [[ "$_s_prev" != "" ]]; then
             LogInfo "Waiting for disk write... (Size changing: $_s_prev -> $_s_curr)"
        fi
        _s_prev="$_s_curr"
    done

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
                (cd "$saved_base/SavedArks" && (tar -cf - --exclude='*.profilebak' --exclude='*.tribebak' --exclude="${__m}_*.ark" "${__m}" || [[ $? -eq 1 ]])) | tar -C "$tmp_path/Saved/SavedArks" -xf -
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
        (tar -C "$saved_base" -cf - "SaveGames" || [[ $? -eq 1 ]]) | tar -C "$tmp_path/Saved" -xf -
    fi

    if [[ -d "$saved_base/Config/WindowsServer" ]]; then
        mkdir -p "$tmp_path/Saved/Config"
        (tar -C "$saved_base/Config" -cf - "WindowsServer" || [[ $? -eq 1 ]]) | tar -C "$tmp_path/Saved/Config" -xf -
    fi

    if [[ -n "${CLUSTER_ID}" && -d "$saved_base/Cluster/clusters/${CLUSTER_ID}" ]]; then
        mkdir -p "$tmp_path/Saved/Cluster/clusters"
        (tar -C "$saved_base/Cluster/clusters" -cf - "${CLUSTER_ID}" || [[ $? -eq 1 ]]) | tar -C "$tmp_path/Saved/Cluster/clusters" -xf -
    fi

    if [[ -z "$(ls -A "$tmp_path" 2>/dev/null)" ]]; then
        LogWarn "No matching Saved subpaths found to archive; creating empty backup metadata."
    fi

    LogInfo "Creating archive"
    tar -czf "$path/${archive_name}.tar.gz" -C "$tmp_path" Saved || [[ $? -eq 1 ]]
    if [[ $? -gt 1 ]]; then
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

# Apply backup immediately (called by worker/monitor)
Backup_apply() {
    # Enter cluster maintenance save mode (requests cluster-wide save)
    LogInfo "Backup request started. Initiating cluster maintenance and waiting for slaves."
    local request_started_epoch
    request_started_epoch=$(date +%s)
    enter_maintenance save "$request_started_epoch"

    LogInfo "Performing create backup now..."
    if ! Backup_create; then
        rc=$?
        LogError "Backup failed with code $rc"
        return $rc
    fi

    LogSuccess "Cluster backup completed on master. Releasing maintenance locks."
    exit_maintenance
    return 0
}

Backup_main() {
    if [ "${CLUSTER_MASTER,,}" != "true" ]; then
        LogError "Backup can only be initiated on the cluster master node."
        return 1
    fi

    if [[ $# -gt 0 ]]; then
        case "$1" in
            --apply)
                Backup_apply
                return $?
                ;;
            --request)
                Backup_request
                return $?
                ;;
        esac
    fi

    LogError "Usage: backup.sh [--request | --apply]"
    return 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    # Called directly: forward CLI to restore function
    Backup_main "$@"
    exit $?
fi
