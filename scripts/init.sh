#!/bin/bash
set -e

# Ensure permissions
chown arkuser:arkuser /opt/arkserver 2>/dev/null || true
chown arkuser:arkuser /var/backups 2>/dev/null || true

mkdir -p "/opt/arkserver/.signals/server_${SERVER_PORT}" 2>/dev/null || true
chown -R arkuser:arkuser /opt/arkserver/.signals 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/autopause/init.sh
source "$SCRIPT_DIR/autopause/init.sh"

# Switch to arkuser and run start.sh
# -E preserves environment variables
exec sudo -E -u arkuser /opt/start.sh "$@"
