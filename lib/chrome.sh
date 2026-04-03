#!/usr/bin/env bash
# Chrome tab management via Chrome DevTools Protocol (CDP).
# Snapshots open tabs before a skill run and closes new ones afterward.

CHROME_DEBUG_PORT=9222

# Get the CDP WebSocket debugger URL base
_cdp_endpoint() {
    curl -s --max-time 2 "http://localhost:${CHROME_DEBUG_PORT}/json/list" 2>/dev/null
}

# Snapshot current tab IDs into the variable named by $1
# Usage: chrome_snapshot_tabs VARNAME
chrome_snapshot_tabs() {
    local -n _out="$1"
    _out=""

    # Check if Chrome is reachable via CDP
    local tabs
    tabs=$(_cdp_endpoint) || return 0
    if [[ -z "$tabs" ]]; then
        return 0
    fi

    # Extract tab IDs (the "id" field from the JSON list)
    _out=$(echo "$tabs" | jq -r '.[].id' 2>/dev/null | sort)
}

# Close any tabs that weren't in the pre-run snapshot.
# Usage: chrome_cleanup_tabs "$snapshot_before"
chrome_cleanup_tabs() {
    local before="$1"

    local tabs_after
    tabs_after=$(_cdp_endpoint) || return 0
    if [[ -z "$tabs_after" ]]; then
        return 0
    fi

    local ids_after
    ids_after=$(echo "$tabs_after" | jq -r '.[].id' 2>/dev/null | sort)

    # Find IDs present in after but not in before
    local new_ids
    new_ids=$(comm -23 <(echo "$ids_after") <(echo "$before"))

    if [[ -z "$new_ids" ]]; then
        return 0
    fi

    local count=0
    while IFS= read -r tab_id; do
        [[ -z "$tab_id" ]] && continue
        curl -s --max-time 2 "http://localhost:${CHROME_DEBUG_PORT}/json/close/${tab_id}" &>/dev/null || true
        count=$((count + 1))
    done <<< "$new_ids"

    echo "$count"
}
