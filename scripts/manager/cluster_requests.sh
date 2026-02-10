#!/usr/bin/env bash
# Cluster request helper functions (sourced by manager scripts)

# Atomic write: write to tmp file then mv into place
atomic_write() {
    local target="$1" content_file="$2"
    local tmp
    tmp="${target}.$$.tmp"
    cp -f "$content_file" "$tmp" 2>/dev/null || cat "$content_file" > "$tmp"
    mv -f "$tmp" "$target"
}

# Create a simple request file at SIGNALS_DIR/<name>.request
# Usage: create_request <name> <payload-file>
create_request() {
    local name="$1" payload="$2"
    mkdir -p "${SIGNALS_DIR}" 2>/dev/null || true
    local rqf="${SIGNALS_DIR}/${name}.request"
    if [[ -f "$rqf" ]]; then
        return 3
    fi
    atomic_write "$rqf" "$payload"
    return 0
}

# Mark request done/failed for audit
mark_request_done() {
    local name="$1" status="$2"
    local ts
    ts=$(date -Is 2>/dev/null || date +%s)
    if [[ "$status" == "done" ]]; then
        touch "${SIGNALS_DIR}/${name}.request.done.${ts}" 2>/dev/null || true
    else
        touch "${SIGNALS_DIR}/${name}.request.failed.${ts}" 2>/dev/null || true
    fi
}
