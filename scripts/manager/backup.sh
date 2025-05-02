#!/bin/bash
set -e
source "/opt/manager/helper.sh"

sanitize() {
CLEAN=${1//_/}
CLEAN=${CLEAN// /_}
CLEAN=${CLEAN//[^a-zA-Z0-9_]/}
CLEAN=$(echo -n "$CLEAN" | tr '[:upper:]' '[:lower:]')
echo "$CLEAN"
return 0
}
# create backup folder if it not already exists
path="/var/backups"
tmp_path="/opt/arkserver/tmp/backup"

mkdir -p $path
mkdir -p $tmp_path

archive_name="$(sanitize "$SESSION_NAME")_$(date +"%Y-%m-%d_%H-%M")"

# copy live path to another folder so tar doesnt get any write on read fails
LogInfo "copying save folder"
cp -r /opt/arkserver/ShooterGame/Saved "$tmp_path"
if ! [ -d "$tmp_path" ]; then
    LogError "Unable to copy save files"
    exit 1
fi

# tar.gz from the copy path
LogInfo "creating archive"
tar -czf "$path/${archive_name}.tar.gz" -C "$tmp_path" Saved

rm -R "$tmp_path"

if [[ "${OLD_BACKUP_DAYS}" =~ ^[0-9]+$ ]]; then
    LogAction "Removing old Backups"
    LogInfo "Deleting Backups older than ${OLD_BACKUP_DAYS} days!"
    find "$path" -mindepth 1 -maxdepth 1 -mtime "+${OLD_BACKUP_DAYS}" -type f -name '*.tar.gz' -print -delete
    exit 0
fi
