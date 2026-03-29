#!/usr/bin/env bash

LOCKS_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/skillrunner/locks"

acquire_lock() {
    local schedule_id="$1"
    local lock_dir="${LOCKS_DIR}/${schedule_id}"
    local pid_file="${lock_dir}/pid"

    # Try atomic mkdir
    if mkdir "$lock_dir" 2>/dev/null; then
        echo $$ > "$pid_file"
        return 0
    fi

    # Lock dir exists — check if holder is still alive
    if [[ -f "$pid_file" ]]; then
        local old_pid
        old_pid=$(cat "$pid_file")
        if kill -0 "$old_pid" 2>/dev/null; then
            return 1  # still running
        fi
    fi

    # Stale lock — reclaim
    rm -rf "$lock_dir"
    if mkdir "$lock_dir" 2>/dev/null; then
        echo $$ > "$pid_file"
        return 0
    fi

    return 1  # someone else grabbed it
}

release_lock() {
    local schedule_id="$1"
    rm -rf "${LOCKS_DIR}/${schedule_id}"
}

is_locked() {
    local schedule_id="$1"
    local lock_dir="${LOCKS_DIR}/${schedule_id}"
    local pid_file="${lock_dir}/pid"

    if [[ -d "$lock_dir" ]] && [[ -f "$pid_file" ]]; then
        local old_pid
        old_pid=$(cat "$pid_file")
        if kill -0 "$old_pid" 2>/dev/null; then
            return 0  # locked
        fi
        # Stale
        rm -rf "$lock_dir"
    fi
    return 1
}
