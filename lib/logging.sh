#!/usr/bin/env bash

SKILLRUNNER_HOME="${XDG_CONFIG_HOME:-${HOME}/.config}/skillrunner"
LOG_FILE="${SKILLRUNNER_HOME}/logs/runner.log"
RUNS_LOG="${SKILLRUNNER_HOME}/logs/runs.jsonl"
MAX_LOG_SIZE=$((5 * 1024 * 1024))    # 5MB
MAX_RUNS_SIZE=$((10 * 1024 * 1024))  # 10MB

_get_file_size() {
    stat -c%s "$1" 2>/dev/null || stat -f%z "$1" 2>/dev/null || echo 0
}

_rotate_if_needed() {
    local file="$1" max_size="$2"
    if [[ -f "$file" ]] && (( $(_get_file_size "$file") > max_size )); then
        mv "$file" "${file}.1"
    fi
}

log_daemon() {
    local msg="$1"
    local timestamp
    timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[${timestamp}] ${msg}" >> "$LOG_FILE"
    _rotate_if_needed "$LOG_FILE" "$MAX_LOG_SIZE"
}

rotate_runs_log() {
    _rotate_if_needed "$RUNS_LOG" "$MAX_RUNS_SIZE"
}
