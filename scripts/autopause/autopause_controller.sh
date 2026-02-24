#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=./scripts/manager/helper.sh
source "/opt/manager/helper.sh"

AUTO_PAUSE_POLL_SEC="${AUTO_PAUSE_POLL_SEC:-2}"
AUTO_PAUSE_IDLE_MINUTES="${AUTO_PAUSE_IDLE_MINUTES:-3}"
AUTO_PAUSE_IDLE_SEC=$((AUTO_PAUSE_IDLE_MINUTES * 60))
EOS_HEARTBEAT_SCRIPT="${EOS_HEARTBEAT_SCRIPT:-/opt/autopause/eos_heartbeat.py}"

mkdir -p "$AUTO_PAUSE_WORK_DIR" 2>/dev/null || true

echo "$$" > "$AUTO_PAUSE_PID_FILE"

log_line() {
    local line
    line="$(date -Is) $*"
    if [[ -n "$AUTO_PAUSE_LOG_PATH" ]]; then
        printf '%s\n' "$line" >> "$AUTO_PAUSE_LOG_PATH"
    else
        printf '%s\n' "$line"
    fi
}

cleanup() {
    log_line "autopause: controller shutting down, cleaning up flags..."
    heartbeat_stop_if_running || true
    rm -f "$AUTO_PAUSE_PID_FILE" "$AUTO_PAUSE_SLEEP_FLAG" "$AUTO_PAUSE_WAKE_FLAG" 2>/dev/null || true
}
trap cleanup EXIT

heartbeat_pids() {
    pgrep -f "$EOS_HEARTBEAT_SCRIPT" 2>/dev/null || true
}

heartbeat_is_running() {
    [[ -n "$(heartbeat_pids)" ]]
}

heartbeat_start_if_needed() {
    if heartbeat_is_running; then
        return 0
    fi

    if [[ ! -f "$EOS_HEARTBEAT_SCRIPT" ]]; then
        log_line "autopause: ERROR: heartbeat script not found: $EOS_HEARTBEAT_SCRIPT"
        return 1
    fi

    env AUTO_PAUSE_SLEEP_FLAG="$AUTO_PAUSE_SLEEP_FLAG" \
        EOS_SESSION_TEMPLATE="$EOS_SESSION_TEMPLATE" \
        EOS_HB_AGENT_LOG_PATH="${EOS_HB_AGENT_LOG_PATH:-}" \
        /bin/bash -c "exec /usr/bin/python3 \"\$0\" >> \"\$1\" 2>&1" \
        "$EOS_HEARTBEAT_SCRIPT" "$AUTO_PAUSE_EOS_HB_AGENT_STDOUT" &

    sleep 1
    if ! heartbeat_is_running; then
        log_line "autopause: ERROR: failed to start heartbeat process"
        return 1
    fi

    log_line "autopause: heartbeat started"
    return 0
}

heartbeat_stop_if_running() {
    local -a pids=()
    mapfile -t pids < <(heartbeat_pids)
    if (( ${#pids[@]} == 0 )); then
        return 0
    fi

    kill "${pids[@]}" 2>/dev/null || true

    local waited=0
    while (( waited < 5 )); do
        if ! heartbeat_is_running; then
            log_line "autopause: heartbeat stopped"
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done

    mapfile -t pids < <(heartbeat_pids)
    if (( ${#pids[@]} > 0 )); then
        kill -9 "${pids[@]}" 2>/dev/null || true
    fi

    if heartbeat_is_running; then
        log_line "autopause: WARNING: failed to stop heartbeat process"
        return 1
    fi

    log_line "autopause: heartbeat stopped (forced)"
    return 0
}

touch_last_active() {
    local reason="${1:-理由未指定}"
    date +%s > "$AUTO_PAUSE_LAST_ACTIVE_FILE"
    log_line "touch_last_active: ${reason}"
}

last_active_age() {
    if [[ -f "$AUTO_PAUSE_LAST_ACTIVE_FILE" ]]; then
        local last
        last=$(cat "$AUTO_PAUSE_LAST_ACTIVE_FILE" 2>/dev/null || echo 0)
        echo $(( $(date +%s) - last ))
        return 0
    fi
    echo "$AUTO_PAUSE_IDLE_SEC"
}

player_count() {
    local out
    if ! out=$(custom_rcon ListPlayers 2>/dev/null); then
        echo -1
        return 0
    fi
    if [[ -z "$out" || "$out" == "No Players"* ]]; then
        echo 0
        return 0
    fi
    echo "$out" | grep -c '[^[:space:]]'
}

is_proxy_ready() {
    local reasons=()

    # 代理応答に必要な情報の存在を確認 (テンプレートファイルが正常にキャプチャされているか)
    if [[ ! -f "$EOS_SESSION_TEMPLATE" || ! -s "$EOS_SESSION_TEMPLATE" ]]; then
        reasons+=("テンプレート未準備")
    fi

    # 外部からの視認性を確認 (EOS API経由でサーバーが検索可能か)
    # タイムアウトを追加して、EOS APIの応答が遅い場合にコントローラーがハングするのを防ぐ
    if ! timeout 10s manager check-eos >/dev/null 2>&1; then
        reasons+=("検索不可")
    fi

    if [[ ${#reasons[@]} -eq 0 ]]; then
        return 0
    fi

    # 理由をグローバル変数（またはファイル）に残して、呼び出し側でログに出せるようにする
    IS_PROXY_READY_FAILURE_REASON="${reasons[*]}"
    return 1
}

enter_sleep() {
    if [[ -f "$AUTO_PAUSE_SLEEP_FLAG" ]]; then
        return 0
    fi

    log_line "autopause: entering sleep"
    manager pause --apply || { log_line "autopause: ERROR: manager pause failed"; return 1; }

    touch "$AUTO_PAUSE_SLEEP_FLAG"

    if ! heartbeat_start_if_needed; then
        rm -f "$AUTO_PAUSE_SLEEP_FLAG" 2>/dev/null || true
        manager unpause --apply || true
        log_line "autopause: ERROR: heartbeat start failed, reverted to awake"
        return 1
    fi

    log_line "autopause: sleep flag created."
}

exit_sleep() {
    if [[ ! -f "$AUTO_PAUSE_SLEEP_FLAG" ]]; then
        # すでに起床済み
        heartbeat_stop_if_running || true
        rm -f "$AUTO_PAUSE_WAKE_FLAG" 2>/dev/null || true
        return 0
    fi
    log_line "autopause: exiting sleep"

    heartbeat_stop_if_running || log_line "autopause: WARNING: heartbeat stop failed during wake"

    # 先にスリープフラグを消して、重畳実行されないようにする
    rm -f "$AUTO_PAUSE_SLEEP_FLAG" 2>/dev/null || true
    rm -f "$AUTO_PAUSE_WAKE_FLAG" 2>/dev/null || true

    # ネットワークリダイレクトの解除は廃止

    log_line "autopause: executing local manager unpause..."
    manager unpause --apply || { log_line "autopause: ERROR: manager unpause failed"; }

    log_line "autopause: sleep flag removed."
    
    # 起床直後にすぐ再ポーズされないよう、猶予期間(180秒)を設ける
    local grace_time=$(( $(date +%s) + 180 ))
    echo "$grace_time" > "$AUTO_PAUSE_LAST_ACTIVE_FILE"
    log_line "touch_last_active: exit_sleep後の起床処理 (3分間の猶予を設定)"
}

log_line "autopause: controller started (port=${SERVER_PORT})"
touch_last_active "コントローラ起動初期化"

trap 'exit_sleep' SIGUSR1
# SIGHUP を無視して、親プロセスが死んでも生き残るようにする
trap '' SIGHUP

loop_count=0
while true; do
    loop_count=$((loop_count + 1))
    if [[ $((loop_count % 120)) -eq 0 ]]; then
        # 10分おきに生存ログを出す (5sec * 120)
        log_line "autopause: controller heartbeat (port=${SERVER_PORT})"
    fi

    if [[ -f "$AUTO_PAUSE_WAKE_FLAG" ]]; then
        if [[ -f "$AUTO_PAUSE_SLEEP_FLAG" ]]; then
            exit_sleep
            sleep "$AUTO_PAUSE_POLL_SEC"
            continue
        fi
        # Already awake, just clear the flag
        rm -f "$AUTO_PAUSE_WAKE_FLAG" 2>/dev/null || true
    fi

    if [[ -f "$AUTO_PAUSE_SLEEP_FLAG" ]]; then
        # Already sleeping, wait for wake flag
        sleep "$AUTO_PAUSE_POLL_SEC"
        continue
    fi

    if [[ -f "$LOCK_FILE" || -f "$MAINTENANCE_REQUEST_FILE" || -f "$UPDATING_FLAG" ]]; then
        touch_last_active "メンテナンス/ロック/アップデートフラグ検知"
        sleep "$AUTO_PAUSE_POLL_SEC"
        continue
    fi

    if ! get_health >/dev/null; then
        touch_last_active "get_health失敗"
        sleep "$AUTO_PAUSE_POLL_SEC"
        continue
    fi

    count=$(player_count)
    if [[ "$count" -gt 0 || "$count" -eq -1 ]]; then
        # RCON失敗時(-1)も起動中とみなして猶予を与える
        touch_last_active "プレイヤー接続検知またはサーバー起動中"
    elif [[ "$count" -eq 0 ]]; then
        if [[ $(last_active_age) -ge "$AUTO_PAUSE_IDLE_SEC" ]]; then
            IS_PROXY_READY_FAILURE_REASON=""
            if is_proxy_ready; then
                enter_sleep || touch_last_active "enter_sleep失敗"
            else
                touch_last_active "代理応答情報の収集中 (${IS_PROXY_READY_FAILURE_REASON:-理由不明} のため待機)"
            fi
        fi
    fi

    sleep "$AUTO_PAUSE_POLL_SEC"
done
