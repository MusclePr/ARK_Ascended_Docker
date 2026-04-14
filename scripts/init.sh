#!/bin/bash
set -e

# Fail fast before any worker/process startup when cluster id is unset/default.
if [[ -z "${CLUSTER_ID:-}" || "${CLUSTER_ID}" == "GlobalUniqueClusterID" ]]; then
	echo "ERROR: CLUSTER_ID must be set to a unique value and must not be empty or GlobalUniqueClusterID." >&2
	exit 1
fi

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
