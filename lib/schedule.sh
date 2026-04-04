#!/usr/bin/env bash

SKILLRUNNER_HOME="${XDG_CONFIG_HOME:-${HOME}/.config}/skillrunner"
CONFIG_FILE="${SKILLRUNNER_HOME}/config.json"

# sync_projects — re-reads each registered project's .skillrunner.json
# and updates the global config with any changes (new/removed/modified schedules).
sync_projects() {
    local projects
    projects=$(jq -c '.projects[]?' "$CONFIG_FILE" 2>/dev/null) || return 0

    while IFS= read -r project; do
        local project_path
        project_path=$(echo "$project" | jq -r '.path')

        local project_config="${project_path}/.skillrunner.json"
        if [[ ! -f "$project_config" ]]; then
            log_daemon "Project config missing: ${project_config}, skipping sync"
            continue
        fi

        # Check if .skillrunner.json has been modified since last registration
        # by comparing schedule counts (lightweight check)
        local file_count global_count
        file_count=$(jq '.schedules | length' "$project_config" 2>/dev/null || echo 0)
        global_count=$(jq --arg pp "$project_path" \
            '[.schedules[] | select(.project_path == $pp)] | length' \
            "$CONFIG_FILE" 2>/dev/null || echo 0)

        if [[ "$file_count" != "$global_count" ]]; then
            log_daemon "Project ${project_path} schedule count changed, re-registering"
            # Re-register (skillrunner-ctl handles dedup)
            "$(dirname "$0")/skillrunner-ctl" register "$project_path" 2>/dev/null || true
        fi
    done <<< "$projects"
}

# schedule_is_overdue "schedule_id" "cron_expr"
# Returns 0 (true) if any cron-matching minute has elapsed since the
# schedule was last dispatched.  Always true on first run.
# Resilient to missed wakes, reboots, and timer drift.
schedule_is_overdue() {
    local schedule_id="$1"
    local cron_expr="$2"

    local state_file="${SKILLRUNNER_HOME}/state.json"
    local last_ts
    last_ts=$(jq -r --arg sid "$schedule_id" \
        '.last_dispatched[$sid] // ""' "$state_file" 2>/dev/null)

    # No record = first run, always overdue
    if [[ -z "$last_ts" || "$last_ts" == "null" ]]; then
        return 0
    fi

    # Convert last_dispatched to epoch (GNU date, then BSD fallback)
    local last_epoch
    if last_epoch=$(date -d "$last_ts" +%s 2>/dev/null); then
        :
    else
        last_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_ts" +%s 2>/dev/null) || return 0
    fi

    local now_epoch
    now_epoch=$(date +%s)

    # Start checking from the minute AFTER last_dispatched
    local check_epoch=$(( (last_epoch / 60 + 1) * 60 ))

    # Cap at current minute (inclusive)
    local end_epoch=$(( (now_epoch / 60) * 60 ))

    local cron_min cron_hour cron_dom cron_mon cron_dow
    read -r cron_min cron_hour cron_dom cron_mon cron_dow <<< "$cron_expr"

    # For large gaps, skip ahead hour-by-hour checking only the cron-matching
    # minute within each hour, rather than iterating every minute or blindly
    # returning overdue.
    local step=60
    if (( end_epoch - check_epoch > 86400 )); then
        step=3600
    fi

    while (( check_epoch <= end_epoch )); do
        local min hour dom mon dow
        if min=$(date -d "@$check_epoch" +%-M 2>/dev/null); then
            hour=$(date -d "@$check_epoch" +%-H)
            dom=$(date -d "@$check_epoch" +%-d)
            mon=$(date -d "@$check_epoch" +%-m)
            dow=$(date -d "@$check_epoch" +%u)
        else
            min=$(date -r "$check_epoch" +%-M)
            hour=$(date -r "$check_epoch" +%-H)
            dom=$(date -r "$check_epoch" +%-d)
            mon=$(date -r "$check_epoch" +%-m)
            dow=$(date -r "$check_epoch" +%u)
        fi
        [[ "$dow" -eq 7 ]] && dow=0

        if field_matches "$cron_min" "$min" 0 59 && \
           field_matches "$cron_hour" "$hour" 0 23 && \
           field_matches "$cron_dom" "$dom" 1 31 && \
           field_matches "$cron_mon" "$mon" 1 12 && \
           field_matches "$cron_dow" "$dow" 0 6; then
            return 0
        fi

        check_epoch=$((check_epoch + step))
    done

    return 1
}

# next_run_time "cron_expr"
# Computes the next matching time for a cron expression.
# Returns ISO 8601 timestamp.
# Iterates minute-by-minute for up to 62 days (covers "first of month" schedules).
next_run_time() {
    local cron_expr="$1"
    local check_epoch
    check_epoch=$(date +%s)
    check_epoch=$(( (check_epoch / 60 + 1) * 60 ))

    local max_checks=$((62 * 24 * 60))  # 62 days

    local cron_min cron_hour cron_dom cron_mon cron_dow
    read -r cron_min cron_hour cron_dom cron_mon cron_dow <<< "$cron_expr"

    for ((i = 0; i < max_checks; i++)); do
        local min hour dom mon dow

        # Use portable date: try GNU first, then BSD
        if min=$(date -d "@$check_epoch" +%-M 2>/dev/null); then
            hour=$(date -d "@$check_epoch" +%-H)
            dom=$(date -d "@$check_epoch" +%-d)
            mon=$(date -d "@$check_epoch" +%-m)
            dow=$(date -d "@$check_epoch" +%u)
        else
            min=$(date -r "$check_epoch" +%-M)
            hour=$(date -r "$check_epoch" +%-H)
            dom=$(date -r "$check_epoch" +%-d)
            mon=$(date -r "$check_epoch" +%-m)
            dow=$(date -r "$check_epoch" +%u)
        fi
        [[ "$dow" -eq 7 ]] && dow=0

        if field_matches "$cron_min" "$min" 0 59 && \
           field_matches "$cron_hour" "$hour" 0 23 && \
           field_matches "$cron_dom" "$dom" 1 31 && \
           field_matches "$cron_mon" "$mon" 1 12 && \
           field_matches "$cron_dow" "$dow" 0 6; then
            # Output in ISO format
            if date -d "@$check_epoch" +"%Y-%m-%dT%H:%M:00Z" 2>/dev/null; then
                return 0
            else
                date -r "$check_epoch" +"%Y-%m-%dT%H:%M:00Z"
                return 0
            fi
        fi

        check_epoch=$((check_epoch + 60))
    done

    echo "unknown"
    return 1
}
