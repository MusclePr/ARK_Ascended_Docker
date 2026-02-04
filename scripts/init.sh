#!/bin/bash
set -e

# Ensure permissions
chown arkuser:arkuser /opt/arkserver 2>/dev/null || true
chown arkuser:arkuser /var/backups 2>/dev/null || true

# Switch to arkuser and run start.sh
# -E preserves environment variables
exec sudo -E -u arkuser /opt/start.sh "$@"
