#!/bin/bash

#-------------------------------
# launch proxy
#-------------------------------
if [ "${AUTO_PAUSE_ENABLED,,}" == "true" ]; then
    LogAction "AUTO PAUSE Proxy"

    LogInfo "Launch proxy."
    CAPTURE_BASE_DIR="${AUTO_PAUSE_WORK_DIR}"
    mkdir -p "$CAPTURE_BASE_DIR" 2>/dev/null || true
    chown arkuser:arkuser "$CAPTURE_BASE_DIR" 2>/dev/null || true
    CAPTURE_DIR="${CAPTURE_BASE_DIR}/$(sanitize "$SESSION_NAME")"
    mkdir -p "$CAPTURE_DIR" 2>/dev/null || true
    chown arkuser:arkuser "$CAPTURE_DIR" 2>/dev/null || true
    MITMPROXY_ADDONS_DIR="/opt/autopause/mitmproxy/addons"
    IGNORE_HOSTS="api.steamcmd.net,.steamstatic.com,.steampowered.com,.steamserver.net,.steamcontent.com,.curseforge.com,discord.com"
    # mitmproxy 用パターン生成
    IGNORE_HOSTS_PATTERN="$(
        echo "$IGNORE_HOSTS" | tr ',' '\n' | while read -r host; do
            clean="${host#.}"              # 先頭のドットを除去
            escaped="${clean//./\\.}"

            if [[ "$host" == .* ]]; then
                # サブドメインも含めたい
                echo "(.*\\.)?$escaped"
            else
                # 完全一致のみ
                echo "$escaped"
            fi
        done | paste -sd '|' -
    )"

    MITMPROXY_OPTIONS=(
        "--set" "block_global=false"
        "--ssl-insecure"
        "--ignore-hosts" "${IGNORE_HOSTS_PATTERN}"
        "-s" "${MITMPROXY_ADDONS_DIR}/capture.py"
    )
    PROXY_LISTEN_HOST="localhost"
    PROXY_LISTEN_PORT="8080"
    PROXY_WAIT_TIMEOUT="${AUTO_PAUSE_PROXY_WAIT_TIMEOUT:-60}"

    proxy_port_ready() {
        nc -z -w 1 "${PROXY_LISTEN_HOST}" "${PROXY_LISTEN_PORT}" >/dev/null 2>&1
    }

    if [ "${AUTO_PAUSE_DEBUG,,}" == "true" ]; then
        sudo -E -u arkuser -- mitmweb --web-host 0.0.0.0 "${MITMPROXY_OPTIONS[@]}" &
        proxy_pid=$!
        LogInfo "Web Interface URL: http://localhost:8081/"
    else
        sudo -E -u arkuser -- mitmdump "${MITMPROXY_OPTIONS[@]}" > /dev/null 2>&1 &
        proxy_pid=$!
    fi

    LogInfo "Wait until proxy is initialized (${PROXY_LISTEN_HOST}:${PROXY_LISTEN_PORT})..."
    wait_started_at=$(date +%s)
    while true; do
        if ! kill -0 "$proxy_pid" 2>/dev/null; then
            LogError "Proxy process exited before initialization completed."
            exit 1
        fi

        if proxy_port_ready; then
            break
        fi

        now=$(date +%s)
        if (( now - wait_started_at >= PROXY_WAIT_TIMEOUT )); then
            LogError "Timed out waiting for proxy initialization (${PROXY_WAIT_TIMEOUT}s)."
            exit 1
        fi

        sleep 0.2
    done

    LogInfo "Proxy initialized."
    if [ "$(id -u)" -eq 0 ]; then
        if [ -d "${HOME}/.mitmproxy" ]; then
            chown -R "${PUID}:${PGID}" "${HOME}/.mitmproxy"
        fi
    fi

    LogInfo "Using proxy now."
    export http_proxy="localhost:8080"
    export https_proxy="localhost:8080"
    export no_proxy="localhost,127.0.0.1,::1,192.168.0.0/16,172.16.0.0/12,10.0.0.0/8,.local,${IGNORE_HOSTS}"
fi
