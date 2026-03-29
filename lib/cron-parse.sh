#!/usr/bin/env bash

# cron_matches_now "minute hour dom month dow"
# Returns 0 (true) if the cron expression matches the current minute.
cron_matches_now() {
    local cron_expr="$1"

    local cron_min cron_hour cron_dom cron_mon cron_dow
    read -r cron_min cron_hour cron_dom cron_mon cron_dow <<< "$cron_expr"

    local now_min now_hour now_dom now_mon now_dow
    now_min=$(date +%-M)
    now_hour=$(date +%-H)
    now_dom=$(date +%-d)
    now_mon=$(date +%-m)
    now_dow=$(date +%u)
    # Convert to cron convention: 0=Sun, 1=Mon..6=Sat
    [[ "$now_dow" -eq 7 ]] && now_dow=0

    field_matches "$cron_min"  "$now_min"  0 59 && \
    field_matches "$cron_hour" "$now_hour" 0 23 && \
    field_matches "$cron_dom"  "$now_dom"  1 31 && \
    field_matches "$cron_mon"  "$now_mon"  1 12 && \
    field_matches "$cron_dow"  "$now_dow"  0 6
}

# field_matches "field_expr" "current_value" "min" "max"
# Handles: *, */N, N, N-M, N,M,O, N-M/S
field_matches() {
    local expr="$1" val="$2" min_val="$3" max_val="$4"

    [[ "$expr" == "*" ]] && return 0

    if [[ "$expr" =~ ^\*/([0-9]+)$ ]]; then
        local step="${BASH_REMATCH[1]}"
        (( val % step == 0 )) && return 0
        return 1
    fi

    IFS=',' read -ra parts <<< "$expr"
    for part in "${parts[@]}"; do
        if [[ "$part" =~ ^([0-9]+)-([0-9]+)/([0-9]+)$ ]]; then
            local start="${BASH_REMATCH[1]}" end="${BASH_REMATCH[2]}" step="${BASH_REMATCH[3]}"
            if (( val >= start && val <= end && (val - start) % step == 0 )); then
                return 0
            fi
        elif [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            local start="${BASH_REMATCH[1]}" end="${BASH_REMATCH[2]}"
            if (( val >= start && val <= end )); then
                return 0
            fi
        elif [[ "$part" =~ ^[0-9]+$ ]]; then
            (( val == part )) && return 0
        fi
    done

    return 1
}
