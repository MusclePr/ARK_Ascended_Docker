#!/bin/bash

export AUTO_PAUSE_WORK_DIR="${AUTO_PAUSE_WORK_DIR:-${SERVER_SIGNALS_DIR}/autopause}"
export AUTO_PAUSE_SLEEP_FLAG="${AUTO_PAUSE_SLEEP_FLAG:-${AUTO_PAUSE_WORK_DIR}/sleep.flag}"
export AUTO_PAUSE_WAKE_FLAG="${AUTO_PAUSE_WAKE_FLAG:-${AUTO_PAUSE_WORK_DIR}/wake.flag}"
export AUTO_PAUSE_PID_FILE="${AUTO_PAUSE_PID_FILE:-${AUTO_PAUSE_WORK_DIR}/controller.pid}"
export AUTO_PAUSE_LAST_ACTIVE_FILE="${AUTO_PAUSE_LAST_ACTIVE_FILE:-${AUTO_PAUSE_WORK_DIR}/last_active.ts}"
export AUTO_PAUSE_LOG_PATH="${AUTO_PAUSE_LOG_PATH:-${AUTO_PAUSE_WORK_DIR}/autopause.log}"
export AUTO_PAUSE_EOS_HB_AGENT_STDOUT="${AUTO_PAUSE_EOS_HB_AGENT_STDOUT:-${AUTO_PAUSE_WORK_DIR}/eos_hb_agent_stdout.log}"
export AUTO_PAUSE_EOS_HB_AGENT_LOG_PATH="${AUTO_PAUSE_EOS_HB_AGENT_LOG_PATH:-${AUTO_PAUSE_WORK_DIR}/eos_hb_agent.log}"
export AUTO_PAUSE_KNOCKD_CONF="${AUTO_PAUSE_KNOCKD_CONF:-${AUTO_PAUSE_WORK_DIR}/knockd.conf}"
export AUTO_PAUSE_KNOCKD_PID_FILE="${AUTO_PAUSE_KNOCKD_PID_FILE:-${AUTO_PAUSE_WORK_DIR}/knockd.pid}"
export AUTO_PAUSE_KNOCKD_LOG_PATH="${AUTO_PAUSE_KNOCKD_LOG_PATH:-${AUTO_PAUSE_WORK_DIR}/knockd.log}"
export EOS_SESSION_TEMPLATE="${EOS_SESSION_TEMPLATE:-${AUTO_PAUSE_WORK_DIR}/session_template.json}"
export EOS_CREDS_FILE="${EOS_CREDS_FILE:-${AUTO_PAUSE_WORK_DIR}/eos_creds.json}"

# This file is sourced from manager/helper.sh and can rely on Log* and get_health.

autopause_manage_controller() {
	local action="${1:-start}"

	if [[ "${AUTO_PAUSE_ENABLED,,}" != "true" ]]; then
		return 0
	fi

	if [[ ! -x "/opt/autopause/autopause_controller.sh" ]]; then
		return 0
	fi

	mkdir -p "$AUTO_PAUSE_WORK_DIR" 2>/dev/null || true

	local controller_pid=""
	local controller_running=false
	if [[ -f "$AUTO_PAUSE_PID_FILE" ]]; then
		controller_pid=$(cat "$AUTO_PAUSE_PID_FILE" 2>/dev/null || true)
		if [[ -n "$controller_pid" ]] && kill -0 "$controller_pid" 2>/dev/null && ps -p "$controller_pid" -o args= 2>/dev/null | grep -q "autopause_controller.sh"; then
			controller_running=true
		else
			rm -f "$AUTO_PAUSE_PID_FILE" 2>/dev/null || true
		fi
	fi

	case "$action" in
		start)
			if [[ "$controller_running" == true ]]; then
				return 0
			fi

			env AUTO_PAUSE_WORK_DIR="$AUTO_PAUSE_WORK_DIR" \
				AUTO_PAUSE_SLEEP_FLAG="$AUTO_PAUSE_SLEEP_FLAG" \
				AUTO_PAUSE_WAKE_FLAG="$AUTO_PAUSE_WAKE_FLAG" \
				AUTO_PAUSE_PID_FILE="$AUTO_PAUSE_PID_FILE" \
				AUTO_PAUSE_LAST_ACTIVE_FILE="$AUTO_PAUSE_LAST_ACTIVE_FILE" \
				AUTO_PAUSE_LOG_PATH="$AUTO_PAUSE_LOG_PATH" \
				AUTO_PAUSE_EOS_HB_AGENT_STDOUT="$AUTO_PAUSE_EOS_HB_AGENT_STDOUT" \
				EOS_HB_AGENT_LOG_PATH="$AUTO_PAUSE_EOS_HB_AGENT_LOG_PATH" \
				EOS_SESSION_TEMPLATE="$EOS_SESSION_TEMPLATE" \
				EOS_CREDS_FILE="$EOS_CREDS_FILE" \
				/opt/autopause/autopause_controller.sh &

			LogInfo "Started autopause_controller (pid=$!)"
			;;
		stop)
			if [[ "$controller_running" == true ]]; then
				kill "$controller_pid" 2>/dev/null || true
			fi
			rm -f "$AUTO_PAUSE_PID_FILE" 2>/dev/null || true
			;;
		*)
			LogWarn "Unknown autopause controller action: $action"
			return 1
			;;
	esac

	return 0
}

autopause_manage_knockd() {
	local action="$1"

	if [[ "${AUTO_PAUSE_ENABLED,,}" != "true" ]]; then
		return 0
	fi

	if [[ ! -x "/opt/autopause/autopause_knockd.sh" ]]; then
		return 0
	fi

	/opt/autopause/autopause_knockd.sh "$action" || {
		LogWarn "Failed to ${action} knockd for autopause"
		return 1
	}
	return 0
}

autopause_mark_awake() {
	local auto_pause_wake_grace_sec="${AUTO_PAUSE_WAKE_GRACE_SEC:-300}"

	mkdir -p "$AUTO_PAUSE_WORK_DIR" 2>/dev/null || true
	rm -f "$AUTO_PAUSE_SLEEP_FLAG" "$AUTO_PAUSE_WAKE_FLAG" 2>/dev/null || true

	local grace_time
	grace_time=$(( $(date +%s) + auto_pause_wake_grace_sec ))
	echo "$grace_time" > "$AUTO_PAUSE_LAST_ACTIVE_FILE"
}

ensure_server_awake_for_operation() {
	local reason="${1:-operation}"
	local -i auto_pause_wake_timeout_sec=${AUTO_PAUSE_WAKE_TIMEOUT_SEC:-120}

	if [[ -f "$AUTO_PAUSE_SLEEP_FLAG" ]]; then
		LogInfo "Server is sleeping. Requesting wake-up before ${reason}."
		mkdir -p "$AUTO_PAUSE_WORK_DIR" 2>/dev/null || true
		touch "$AUTO_PAUSE_WAKE_FLAG"

		local -i waited=0
		local -i interval=2
		while [[ -f "$AUTO_PAUSE_SLEEP_FLAG" ]] && (( waited < auto_pause_wake_timeout_sec )); do
			sleep "$interval"
			waited=$((waited + interval))
		done

		if [[ -f "$AUTO_PAUSE_SLEEP_FLAG" ]]; then
			LogError "Wake-up timed out after ${auto_pause_wake_timeout_sec}s."
			return 1
		fi

		LogInfo "Wake-up signal completed for ${reason}."
	fi

	if [[ "$(get_health 2>/dev/null || true)" == "PAUSED" ]]; then
		LogInfo "Server is paused. Unpausing before ${reason}."
		if ! /opt/manager/manager.sh unpause --apply; then
			LogError "Failed to unpause server for ${reason}."
			return 1
		fi
	fi

	return 0
}

