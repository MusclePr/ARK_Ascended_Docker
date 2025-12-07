#!/bin/bash
set -e

# Ensure permissions
mkdir -p /opt/arkserver/.signals
chown -R arkuser:arkuser /opt/arkserver
chown -R arkuser:arkuser /var/backups 2>/dev/null || true

#export HOME=/home/arkuser

# Switch to arkuser and run start.sh
# -E preserves environment variables
exec sudo -E -u arkuser /opt/start.sh "$@"
