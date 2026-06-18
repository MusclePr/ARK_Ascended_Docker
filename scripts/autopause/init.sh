#!/bin/bash

# shellcheck source=./scripts/manager/helper.sh
source "${SCRIPT_DIR}/manager/helper.sh"

if [ "${AUTO_PAUSE_ENABLED,,}" == "true" ]; then
    if command -v knockd > /dev/null 2>&1 && ! knockd --version > /dev/null 2>&1; then
        LogError "AUTO_PAUSE requires NET_RAW capability. e.g) podman run --cap-add=NET_RAW ..."
        exit 1
    fi

    AUTO_PAUSE_EOS_HB_AGENT_STDOUT="${AUTO_PAUSE_EOS_HB_AGENT_STDOUT:-${AUTO_PAUSE_WORK_DIR}/eos_hb_agent_stdout.log}"
    AUTO_PAUSE_LOG_PATH="${AUTO_PAUSE_LOG_PATH:-${AUTO_PAUSE_WORK_DIR}/autopause.log}"
    AUTO_PAUSE_EOS_HB_AGENT_LOG_PATH="${AUTO_PAUSE_EOS_HB_AGENT_LOG_PATH:-${AUTO_PAUSE_WORK_DIR}/eos_hb_agent.log}"
    AUTO_PAUSE_KNOCKD_LOG_PATH="${AUTO_PAUSE_KNOCKD_LOG_PATH:-${AUTO_PAUSE_WORK_DIR}/knockd.log}"

    ensure_arkuser_file() {
        local -r file_path="$1"
        local -r mode="${2:-664}"
        local -r truncate="${3:-false}"
        local -r initial_content="${4:-}"

        mkdir -p "$(dirname "$file_path")" 2>/dev/null || true
        if [[ ! -e "$file_path" ]] || [[ "$truncate" == "true" ]]; then
            echo -n "$initial_content" > "$file_path"
        fi

        chown arkuser:arkuser "$file_path" 2>/dev/null || true
        chmod "$mode" "$file_path" 2>/dev/null || true
    }

    mkdir -p "$AUTO_PAUSE_WORK_DIR" 2>/dev/null || true
    chown -R arkuser:arkuser "$AUTO_PAUSE_WORK_DIR" 2>/dev/null || true

    # Cleanup stale runtime flags and logs on startup.
    # Keep AUTO_PAUSE_DISABLED_LOCK to preserve operator intent across restarts.
    rm -f "$AUTO_PAUSE_SLEEP_FLAG" "$AUTO_PAUSE_WAKE_FLAG" 2>/dev/null || true
    rm -f "$EOS_SESSION_TEMPLATE" "$EOS_CREDS_FILE" 2>/dev/null || true
    # Truncate logs and remove temporary captures to avoid confusion on new session
    ensure_arkuser_file "$AUTO_PAUSE_LOG_PATH" 644 true
    ensure_arkuser_file "$AUTO_PAUSE_EOS_HB_AGENT_LOG_PATH" 644 true
    ensure_arkuser_file "$AUTO_PAUSE_EOS_HB_AGENT_STDOUT" 644 true
    ensure_arkuser_file "$AUTO_PAUSE_KNOCKD_LOG_PATH" 644 true
    # Keep contents of whitelist/blacklist/greylist across restarts, but ensure they exist and have correct permissions.
    ensure_arkuser_file "$AUTO_PAUSE_KNOCKD_WHITELIST_PATH" 664 false "# knockd whitelist\n# one IPv4 per line, comments are allowed"
    ensure_arkuser_file "$AUTO_PAUSE_KNOCKD_BLACKLIST_PATH" 664 false "# knockd blacklist\n# one IPv4 per line, comments are allowed"
    ensure_arkuser_file "$AUTO_PAUSE_KNOCKD_GREYLIST_PATH" 664 false "# knockd greylist\n# format: ip|hostname|first_seen|last_seen|hit_count|last_reason"

    export EOS_SESSION_TEMPLATE="${EOS_SESSION_TEMPLATE:-${AUTO_PAUSE_WORK_DIR}/session_template.json}"
    export EOS_CREDS_FILE="${EOS_CREDS_FILE:-${AUTO_PAUSE_WORK_DIR}/eos_creds.json}"
    export EOS_HB_AGENT_LOG_PATH="${EOS_HB_AGENT_LOG_PATH:-$AUTO_PAUSE_EOS_HB_AGENT_LOG_PATH}"

    if [[ -f "${SCRIPT_DIR}/autopause/mitmproxy/init.sh" ]]; then
        # shellcheck source=scripts/autopause/mitmproxy/init.sh
        source "${SCRIPT_DIR}/autopause/mitmproxy/init.sh"
    fi

fi
