# SkillRunner - Implementation Plan

## Project Overview

SkillRunner is a Claude Code skill (`/schedule`) and companion daemon that automatically executes Claude Code skills on a configurable schedule. It is "cron for Claude skills" -- users define schedules like "run `/concert-search` every day at 9 AM" and SkillRunner handles invocation, logging, error handling, and lifecycle management via a macOS LaunchAgent.

---

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          SkillRunner System                             │
│                                                                         │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │  Claude Code Skill: /schedule                                    │   │
│  │  add | list | remove | logs | status | enable | disable          │   │
│  │  (Interactive management via Claude Code sessions)               │   │
│  └──────────────┬───────────────────────────────────────────────────┘   │
│                  │ reads/writes                                          │
│                  ▼                                                       │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │  ~/.skillrunner/                                                  │   │
│  │  ├── config.json          (schedule definitions)                  │   │
│  │  ├── state.json           (daemon state, lock info)               │   │
│  │  ├── logs/                                                        │   │
│  │  │   ├── runs.jsonl       (structured execution log)              │   │
│  │  │   ├── runner.log       (human-readable daemon log)             │   │
│  │  │   └── output/          (captured stdout/stderr per run)        │   │
│  │  │       └── {run_id}.txt                                         │   │
│  │  └── locks/               (per-skill lock files)                  │   │
│  └──────────────┬───────────────────────────────────────────────────┘   │
│                  │ reads                                                 │
│                  ▼                                                       │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │  skillrunner-daemon (Bash script)                                │   │
│  │  - Managed by macOS LaunchAgent                                  │   │
│  │  - Wakes every 60s, checks schedule                              │   │
│  │  - Invokes: claude -p --print "/<skill> <args>"                  │   │
│  │  - Captures output, writes logs                                  │   │
│  │  - Handles timeouts, overlaps, retries                           │   │
│  └──────────────────────────────────────────────────────────────────┘   │
│                  │ invokes                                               │
│                  ▼                                                       │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │  claude -p --output-format json --permission-mode plan \         │   │
│  │    --max-budget-usd <budget> "/<skill-name> <args>"              │   │
│  │                                                                   │   │
│  │  Non-interactive execution of any Claude Code skill               │   │
│  └──────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## How Claude Code Is Invoked Programmatically

### Confirmed CLI Behavior (v2.1.76)

The `claude` CLI at `/Users/nicholas/.nix-profile/bin/claude` supports non-interactive execution via the `-p` / `--print` flag. Key findings from testing:

**Basic non-interactive invocation:**
```bash
claude -p "your prompt here"
```
This sends the prompt, prints the response to stdout, and exits. No interactive session is created.

**JSON output mode (essential for structured log capture):**
```bash
claude -p --output-format json "your prompt here"
```
Returns a JSON object with fields:
- `result` -- the text response
- `is_error` -- boolean
- `duration_ms` -- wall clock time
- `duration_api_ms` -- API time
- `total_cost_usd` -- cost of the run
- `stop_reason` -- why it stopped
- `session_id` -- UUID of the session
- `usage` -- token breakdown
- `permission_denials` -- array of denied tool uses

**Running a skill (slash command):**
```bash
claude -p "/<skill-name> <arguments>"
```
When Claude receives a prompt starting with `/`, it loads the matching skill from `~/.claude/skills/` (or project `.claude/skills/`). The skill's SKILL.md frontmatter controls which tools are available.

**Permission handling for unattended execution:**
```bash
claude -p --permission-mode plan "/<skill-name>"
```
The `plan` mode allows Claude to read and search but blocks writes/edits, making it safe for autonomous runs. For skills that need to write files:
```bash
claude -p --dangerously-skip-permissions "/<skill-name>"
```
This bypasses all permission checks. Only use this in controlled environments.

A safer middle ground:
```bash
claude -p --permission-mode acceptEdits "/<skill-name>"
```
Auto-accepts file edits but still prompts for bash commands (which won't work in `-p` mode, so those would be denied).

**Recommended invocation for SkillRunner daemon:**
```bash
claude -p \
  --output-format json \
  --permission-mode plan \
  --max-budget-usd 0.50 \
  --no-session-persistence \
  "/<skill-name> <args>"
```

Flags explained:
- `--output-format json` -- structured output for log parsing
- `--permission-mode plan` -- safe default (overridable per schedule)
- `--max-budget-usd 0.50` -- cost cap per run (overridable per schedule)
- `--no-session-persistence` -- don't pollute the user's session history with daemon runs

**Working directory matters:** Claude Code skills that use tools (Bash, Read, etc.) operate relative to the cwd. The daemon must `cd` to the correct directory before invoking claude, or use `--add-dir`.

---

## File Layout

```
/Users/nicholas/Documents/Tools/SkillRunner/
├── IMPLEMENTATION_PLAN.md          (this file)
├── SKILL.md                        (Claude Code skill definition)
├── bin/
│   ├── skillrunner-daemon          (main daemon loop script)
│   ├── skillrunner-run             (single-run executor)
│   └── skillrunner-ctl             (CLI for install/uninstall/status)
├── lib/
│   ├── schedule.sh                 (schedule parsing functions)
│   ├── logging.sh                  (log writing functions)
│   ├── cron-parse.sh               (cron expression evaluator)
│   └── lock.sh                     (file-based locking)
├── templates/
│   └── com.skillrunner.daemon.plist (LaunchAgent template)
└── install.sh                      (one-shot installer)
```

**Runtime data directory:** `~/.skillrunner/`

```
~/.skillrunner/
├── config.json              (all schedule definitions)
├── state.json               (daemon state: pid, last wake, version)
├── logs/
│   ├── runs.jsonl           (append-only structured run log)
│   ├── runner.log           (daemon lifecycle log)
│   └── output/
│       ├── {uuid}.stdout    (captured stdout per run)
│       └── {uuid}.stderr    (captured stderr per run)
└── locks/
    └── {schedule_id}.lock   (prevents overlapping runs)
```

**Skill symlink:** After installation, a symlink is created:
```
~/.claude/skills/schedule -> /Users/nicholas/Documents/Tools/SkillRunner
```
This makes `/schedule` available in all Claude Code sessions.

---

## Skill Definition (`SKILL.md`)

```markdown
---
name: schedule
description: >
  Manage scheduled automatic execution of Claude Code skills.
  Add, remove, list, and monitor skill schedules that run via
  a background daemon. View execution logs and daemon status.
user-invocable: true
argument-hint: "add|list|remove|logs|status|enable|disable"
allowed-tools: Read, Bash, Glob, Grep
---

# SkillRunner — Scheduled Skill Execution

You are managing scheduled automatic execution of Claude Code skills. The user
wants to set up skills to run on a recurring schedule (like cron) via a
background daemon.

## Data Locations

- Schedule config: `~/.skillrunner/config.json`
- Run logs: `~/.skillrunner/logs/runs.jsonl`
- Daemon log: `~/.skillrunner/logs/runner.log`
- Daemon state: `~/.skillrunner/state.json`
- LaunchAgent: `~/Library/LaunchAgents/com.skillrunner.daemon.plist`

## Commands

### /schedule add
Prompt the user for:
1. **Skill name** — which slash command to run (e.g., `concert-search`)
2. **Schedule** — cron expression or natural language ("daily at 9am", "every 6 hours", "weekdays at 8:30am")
3. **Arguments** (optional) — arguments to pass to the skill
4. **Working directory** (optional) — directory to run in (defaults to $HOME)
5. **Permission mode** (optional) — `plan` (default, read-only), `acceptEdits`, or `dangerouslySkipPermissions`
6. **Budget per run** (optional) — max USD per execution (default: $0.50)
7. **Timeout** (optional) — max seconds per execution (default: 300)
8. **Enabled** (optional) — whether to enable immediately (default: true)

Convert natural language schedules to cron expressions. Write the entry to
`~/.skillrunner/config.json`. Verify the skill exists in `~/.claude/skills/`.

### /schedule list
Read `~/.skillrunner/config.json` and display all schedules in a table:
| ID | Skill | Schedule (cron) | Human Schedule | Next Run | Enabled | Last Result |
Compute "Next Run" from the cron expression and current time. Pull "Last Result"
from `~/.skillrunner/logs/runs.jsonl`.

### /schedule remove
Show the list, ask the user which to remove (by ID or skill name). Remove from
config.json.

### /schedule logs [--skill NAME] [--status success|failure] [--last N]
Read `~/.skillrunner/logs/runs.jsonl` and filter/display. Default: show last 10
runs. For each run show: timestamp, skill, duration, exit code, cost, truncated
output (first 5 lines).

### /schedule status
Show:
- Daemon running? (check LaunchAgent status via `launchctl list | grep skillrunner`)
- Last daemon wake time (from state.json)
- Number of scheduled skills (from config.json)
- Next upcoming run across all schedules
- Recent errors (last 3 failures from runs.jsonl)

### /schedule enable / /schedule disable
Toggle the `enabled` field on a specific schedule entry.

## Installation Check
Before any command, verify the daemon is installed:
1. Check if `~/Library/LaunchAgents/com.skillrunner.daemon.plist` exists
2. Check if `~/.skillrunner/` directory exists
3. If not installed, offer to run the installer:
   `bash /Users/nicholas/Documents/Tools/SkillRunner/install.sh`
```

---

## Schedule Configuration Format (`config.json`)

```json
{
  "version": 1,
  "schedules": [
    {
      "id": "a1b2c3d4",
      "skill": "concert-search",
      "args": "",
      "cron": "0 9 * * *",
      "human_schedule": "Daily at 9:00 AM",
      "working_directory": "/Users/nicholas/Documents/Tools/ConcertAgent",
      "permission_mode": "plan",
      "max_budget_usd": 0.50,
      "timeout_seconds": 300,
      "enabled": true,
      "retry": {
        "max_attempts": 1,
        "delay_seconds": 60
      },
      "created_at": "2026-03-29T10:00:00Z",
      "updated_at": "2026-03-29T10:00:00Z"
    },
    {
      "id": "e5f6g7h8",
      "skill": "nix-flakes",
      "args": "check for outdated flake inputs",
      "cron": "0 8 * * 1",
      "human_schedule": "Every Monday at 8:00 AM",
      "working_directory": "/Users/nicholas/Projects/my-app",
      "permission_mode": "plan",
      "max_budget_usd": 0.25,
      "timeout_seconds": 120,
      "enabled": true,
      "retry": {
        "max_attempts": 2,
        "delay_seconds": 120
      },
      "created_at": "2026-03-29T10:30:00Z",
      "updated_at": "2026-03-29T10:30:00Z"
    }
  ]
}
```

**ID generation:** 8-character hex from `openssl rand -hex 4`.

**Cron expression format:** Standard 5-field cron: `minute hour day_of_month month day_of_week`. No seconds field.

**Natural language to cron mapping (handled by the skill via Claude):**
| Natural Language | Cron |
|---|---|
| daily at 9am | `0 9 * * *` |
| every 6 hours | `0 */6 * * *` |
| weekdays at 8:30am | `30 8 * * 1-5` |
| every monday at noon | `0 12 * * 1` |
| every 30 minutes | `*/30 * * * *` |
| first of every month at 6am | `0 6 1 * *` |

---

## Daemon Design

### Overview

The daemon is a bash script that runs as a macOS LaunchAgent. It is designed as a "wake and check" loop: launchd wakes it every 60 seconds, it checks which schedules are due, runs them, and exits. This is simpler and more reliable than a long-running process.

### LaunchAgent plist (`com.skillrunner.daemon.plist`)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.skillrunner.daemon</string>

    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>/Users/nicholas/Documents/Tools/SkillRunner/bin/skillrunner-daemon</string>
    </array>

    <key>StartInterval</key>
    <integer>60</integer>

    <key>RunAtLoad</key>
    <true/>

    <key>StandardOutPath</key>
    <string>/Users/nicholas/.skillrunner/logs/launchd-stdout.log</string>

    <key>StandardErrorPath</key>
    <string>/Users/nicholas/.skillrunner/logs/launchd-stderr.log</string>

    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/Users/nicholas/.nix-profile/bin:/usr/local/bin:/usr/bin:/bin</string>
        <key>HOME</key>
        <string>/Users/nicholas</string>
    </dict>

    <key>Nice</key>
    <integer>10</integer>

    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
```

**Key design choices:**
- `StartInterval` of 60 seconds: the daemon wakes once per minute, matching cron's minimum granularity. This is lightweight -- the script checks timestamps and exits immediately if nothing is due.
- `RunAtLoad: true`: starts on login.
- `Nice: 10`: lower priority so it doesn't compete with interactive work.
- `ProcessType: Background`: tells macOS this is a background task, eligible for power nap.
- PATH includes nix-profile so `claude` is found.

### Daemon Script (`bin/skillrunner-daemon`)

```bash
#!/usr/bin/env bash
set -euo pipefail

# SkillRunner Daemon - Wakes every 60s via LaunchAgent, runs due schedules.

SKILLRUNNER_HOME="${HOME}/.skillrunner"
CONFIG_FILE="${SKILLRUNNER_HOME}/config.json"
STATE_FILE="${SKILLRUNNER_HOME}/state.json"
LOG_FILE="${SKILLRUNNER_HOME}/logs/runner.log"
RUNS_LOG="${SKILLRUNNER_HOME}/logs/runs.jsonl"
LOCKS_DIR="${SKILLRUNNER_HOME}/locks"
OUTPUT_DIR="${SKILLRUNNER_HOME}/logs/output"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Source library functions
source "${SCRIPT_DIR}/../lib/schedule.sh"
source "${SCRIPT_DIR}/../lib/logging.sh"
source "${SCRIPT_DIR}/../lib/cron-parse.sh"
source "${SCRIPT_DIR}/../lib/lock.sh"

# Update state file with current wake time
update_state() {
    local now_iso
    now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    # Use a temp file for atomic write
    local tmp
    tmp=$(mktemp)
    jq --arg ts "$now_iso" '.last_wake = $ts | .pid = '$$'' \
        "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

# Check if a schedule is due at the current minute
is_due() {
    local cron_expr="$1"
    cron_matches_now "$cron_expr"
}

# Main
log_daemon "Daemon woke up (pid $$)"
update_state

# Bail if config doesn't exist
if [[ ! -f "$CONFIG_FILE" ]]; then
    log_daemon "No config file found at ${CONFIG_FILE}, exiting"
    exit 0
fi

# Read schedules and check each one
schedule_count=$(jq '.schedules | length' "$CONFIG_FILE")

for ((i = 0; i < schedule_count; i++)); do
    schedule_json=$(jq -c ".schedules[$i]" "$CONFIG_FILE")

    enabled=$(echo "$schedule_json" | jq -r '.enabled')
    [[ "$enabled" != "true" ]] && continue

    cron_expr=$(echo "$schedule_json" | jq -r '.cron')
    schedule_id=$(echo "$schedule_json" | jq -r '.id')
    skill=$(echo "$schedule_json" | jq -r '.skill')

    if is_due "$cron_expr"; then
        log_daemon "Schedule ${schedule_id} (${skill}) is due, dispatching"

        # Check for overlap lock
        if is_locked "$schedule_id"; then
            log_daemon "Schedule ${schedule_id} is already running, skipping"
            continue
        fi

        # Run in background so we can process other schedules
        "${SCRIPT_DIR}/skillrunner-run" "$schedule_id" &
    fi
done

log_daemon "Daemon check complete"
```

### Single-Run Executor (`bin/skillrunner-run`)

```bash
#!/usr/bin/env bash
set -euo pipefail

# Executes a single scheduled skill run.
# Usage: skillrunner-run <schedule_id>

SKILLRUNNER_HOME="${HOME}/.skillrunner"
CONFIG_FILE="${SKILLRUNNER_HOME}/config.json"
RUNS_LOG="${SKILLRUNNER_HOME}/logs/runs.jsonl"
LOCKS_DIR="${SKILLRUNNER_HOME}/locks"
OUTPUT_DIR="${SKILLRUNNER_HOME}/logs/output"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "${SCRIPT_DIR}/../lib/logging.sh"
source "${SCRIPT_DIR}/../lib/lock.sh"

SCHEDULE_ID="$1"
RUN_ID=$(openssl rand -hex 8)

# Read schedule config
schedule_json=$(jq -c ".schedules[] | select(.id == \"${SCHEDULE_ID}\")" "$CONFIG_FILE")
if [[ -z "$schedule_json" ]]; then
    log_daemon "ERROR: Schedule ${SCHEDULE_ID} not found in config"
    exit 1
fi

skill=$(echo "$schedule_json" | jq -r '.skill')
args=$(echo "$schedule_json" | jq -r '.args // ""')
workdir=$(echo "$schedule_json" | jq -r '.working_directory // env.HOME')
permission_mode=$(echo "$schedule_json" | jq -r '.permission_mode // "plan"')
max_budget=$(echo "$schedule_json" | jq -r '.max_budget_usd // 0.50')
timeout_secs=$(echo "$schedule_json" | jq -r '.timeout_seconds // 300')
max_attempts=$(echo "$schedule_json" | jq -r '.retry.max_attempts // 1')
retry_delay=$(echo "$schedule_json" | jq -r '.retry.delay_seconds // 60')

# Acquire lock
acquire_lock "$SCHEDULE_ID" $$ || {
    log_daemon "Failed to acquire lock for ${SCHEDULE_ID}"
    exit 1
}
trap 'release_lock "$SCHEDULE_ID"' EXIT

prompt="/${skill}"
[[ -n "$args" ]] && prompt="/${skill} ${args}"

start_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
start_epoch=$(date +%s)

log_daemon "RUN ${RUN_ID}: Starting skill '${skill}' in ${workdir}"

attempt=0
exit_code=1
stdout_file="${OUTPUT_DIR}/${RUN_ID}.stdout"
stderr_file="${OUTPUT_DIR}/${RUN_ID}.stderr"

while (( attempt < max_attempts )); do
    attempt=$((attempt + 1))
    log_daemon "RUN ${RUN_ID}: Attempt ${attempt}/${max_attempts}"

    # Invoke Claude Code
    set +e
    timeout "${timeout_secs}" \
        /Users/nicholas/.nix-profile/bin/claude -p \
            --output-format json \
            --permission-mode "$permission_mode" \
            --max-budget-usd "$max_budget" \
            --no-session-persistence \
            "$prompt" \
        > "$stdout_file" 2> "$stderr_file" < /dev/null
    exit_code=$?
    set -e

    # Exit code 124 means timeout killed it
    if [[ $exit_code -eq 124 ]]; then
        log_daemon "RUN ${RUN_ID}: Timed out after ${timeout_secs}s"
    fi

    if [[ $exit_code -eq 0 ]]; then
        break
    fi

    if (( attempt < max_attempts )); then
        log_daemon "RUN ${RUN_ID}: Failed (exit ${exit_code}), retrying in ${retry_delay}s"
        sleep "$retry_delay"
    fi
done

end_epoch=$(date +%s)
duration=$((end_epoch - start_epoch))
end_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Parse cost from JSON output if available
cost="null"
result_text=""
if [[ -f "$stdout_file" ]] && jq -e '.total_cost_usd' "$stdout_file" > /dev/null 2>&1; then
    cost=$(jq '.total_cost_usd' "$stdout_file")
    result_text=$(jq -r '.result // ""' "$stdout_file" | head -c 2000)
fi

# Determine status
status="success"
[[ $exit_code -ne 0 ]] && status="failure"

# Truncate output files if huge (> 100KB)
for f in "$stdout_file" "$stderr_file"; do
    if [[ -f "$f" ]] && (( $(stat -f%z "$f" 2>/dev/null || echo 0) > 102400 )); then
        truncate -s 102400 "$f"
        echo -e "\n\n[TRUNCATED - output exceeded 100KB]" >> "$f"
    fi
done

# Write structured log entry
log_entry=$(jq -n \
    --arg run_id "$RUN_ID" \
    --arg schedule_id "$SCHEDULE_ID" \
    --arg skill "$skill" \
    --arg args "$args" \
    --arg start "$start_time" \
    --arg end "$end_time" \
    --argjson duration "$duration" \
    --argjson exit_code "$exit_code" \
    --arg status "$status" \
    --argjson cost "$cost" \
    --argjson attempts "$attempt" \
    --arg result_preview "$result_text" \
    --arg stdout_file "$stdout_file" \
    --arg stderr_file "$stderr_file" \
    '{
        run_id: $run_id,
        schedule_id: $schedule_id,
        skill: $skill,
        args: $args,
        started_at: $start,
        ended_at: $end,
        duration_seconds: $duration,
        exit_code: $exit_code,
        status: $status,
        cost_usd: $cost,
        attempts: $attempts,
        result_preview: $result_preview,
        stdout_file: $stdout_file,
        stderr_file: $stderr_file
    }'
)

echo "$log_entry" >> "$RUNS_LOG"

log_daemon "RUN ${RUN_ID}: Completed (${status}, ${duration}s, exit ${exit_code}, cost \$${cost})"
```

### Control Script (`bin/skillrunner-ctl`)

```bash
#!/usr/bin/env bash
set -euo pipefail

# SkillRunner control script: install, uninstall, start, stop, status

PLIST_NAME="com.skillrunner.daemon"
PLIST_SRC="$(cd "$(dirname "$0")/../templates" && pwd)/${PLIST_NAME}.plist"
PLIST_DST="${HOME}/Library/LaunchAgents/${PLIST_NAME}.plist"
SKILLRUNNER_HOME="${HOME}/.skillrunner"

case "${1:-help}" in
    install)
        echo "Installing SkillRunner..."

        # Create directory structure
        mkdir -p "${SKILLRUNNER_HOME}"/{logs/output,locks}

        # Initialize config if not present
        if [[ ! -f "${SKILLRUNNER_HOME}/config.json" ]]; then
            echo '{"version": 1, "schedules": []}' | jq . > "${SKILLRUNNER_HOME}/config.json"
        fi

        # Initialize state
        echo '{"last_wake": null, "pid": null, "version": 1}' | jq . > "${SKILLRUNNER_HOME}/state.json"

        # Generate plist with correct paths
        sed "s|__USER_HOME__|${HOME}|g; s|__SKILLRUNNER_DIR__|$(cd "$(dirname "$0")/.." && pwd)|g; s|__NIX_BIN__|$(dirname "$(which claude)")|g" \
            "$PLIST_SRC" > "$PLIST_DST"

        # Install skill symlink
        mkdir -p "${HOME}/.claude/skills"
        SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
        ln -sfn "$SKILL_DIR" "${HOME}/.claude/skills/schedule"

        # Load the LaunchAgent
        launchctl load "$PLIST_DST" 2>/dev/null || true

        echo "SkillRunner installed successfully."
        echo "  Config: ${SKILLRUNNER_HOME}/config.json"
        echo "  Logs:   ${SKILLRUNNER_HOME}/logs/"
        echo "  Skill:  /schedule is now available in Claude Code"
        ;;

    uninstall)
        echo "Uninstalling SkillRunner..."
        launchctl unload "$PLIST_DST" 2>/dev/null || true
        rm -f "$PLIST_DST"
        rm -f "${HOME}/.claude/skills/schedule"
        echo "LaunchAgent removed. Data preserved at ${SKILLRUNNER_HOME}/"
        echo "To fully remove: rm -rf ${SKILLRUNNER_HOME}"
        ;;

    start)
        launchctl load "$PLIST_DST"
        echo "SkillRunner daemon started."
        ;;

    stop)
        launchctl unload "$PLIST_DST"
        echo "SkillRunner daemon stopped."
        ;;

    status)
        echo "=== SkillRunner Status ==="
        if launchctl list | grep -q "$PLIST_NAME"; then
            echo "Daemon: RUNNING"
        else
            echo "Daemon: STOPPED"
        fi

        if [[ -f "${SKILLRUNNER_HOME}/state.json" ]]; then
            echo "Last wake: $(jq -r '.last_wake // "never"' "${SKILLRUNNER_HOME}/state.json")"
        fi

        if [[ -f "${SKILLRUNNER_HOME}/config.json" ]]; then
            local count
            count=$(jq '.schedules | length' "${SKILLRUNNER_HOME}/config.json")
            echo "Schedules: ${count}"
        fi

        if [[ -f "${SKILLRUNNER_HOME}/logs/runs.jsonl" ]]; then
            echo ""
            echo "Last 5 runs:"
            tail -5 "${SKILLRUNNER_HOME}/logs/runs.jsonl" | \
                jq -r '"  \(.started_at) | \(.skill) | \(.status) | \(.duration_seconds)s | $\(.cost_usd)"'
        fi
        ;;

    *)
        echo "Usage: skillrunner-ctl {install|uninstall|start|stop|status}"
        exit 1
        ;;
esac
```

---

## Library Functions

### `lib/cron-parse.sh` — Cron Expression Evaluator

This is the most complex library component. It evaluates whether a 5-field cron expression matches the current minute.

```bash
#!/usr/bin/env bash

# cron_matches_now "minute hour dom month dow"
# Returns 0 (true) if the cron expression matches the current minute.
# Returns 1 (false) otherwise.

cron_matches_now() {
    local cron_expr="$1"

    local cron_min cron_hour cron_dom cron_mon cron_dow
    read -r cron_min cron_hour cron_dom cron_mon cron_dow <<< "$cron_expr"

    local now_min now_hour now_dom now_mon now_dow
    now_min=$(date +%-M)     # minute 0-59 (no leading zero)
    now_hour=$(date +%-H)    # hour 0-23
    now_dom=$(date +%-d)     # day of month 1-31
    now_mon=$(date +%-m)     # month 1-12
    now_dow=$(date +%u)      # day of week 1=Mon..7=Sun
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

    # Wildcard
    [[ "$expr" == "*" ]] && return 0

    # Step on wildcard: */N
    if [[ "$expr" =~ ^\*/([0-9]+)$ ]]; then
        local step="${BASH_REMATCH[1]}"
        (( val % step == 0 )) && return 0
        return 1
    fi

    # Comma-separated list (may contain ranges)
    IFS=',' read -ra parts <<< "$expr"
    for part in "${parts[@]}"; do
        # Range with step: N-M/S
        if [[ "$part" =~ ^([0-9]+)-([0-9]+)/([0-9]+)$ ]]; then
            local start="${BASH_REMATCH[1]}" end="${BASH_REMATCH[2]}" step="${BASH_REMATCH[3]}"
            if (( val >= start && val <= end && (val - start) % step == 0 )); then
                return 0
            fi
        # Range: N-M
        elif [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            local start="${BASH_REMATCH[1]}" end="${BASH_REMATCH[2]}"
            if (( val >= start && val <= end )); then
                return 0
            fi
        # Exact value
        elif [[ "$part" =~ ^[0-9]+$ ]]; then
            (( val == part )) && return 0
        fi
    done

    return 1
}
```

### `lib/lock.sh` — File-Based Locking

```bash
#!/usr/bin/env bash

LOCKS_DIR="${HOME}/.skillrunner/locks"

acquire_lock() {
    local schedule_id="$1" pid="$2"
    local lock_file="${LOCKS_DIR}/${schedule_id}.lock"

    # Check for stale lock
    if [[ -f "$lock_file" ]]; then
        local old_pid
        old_pid=$(cat "$lock_file")
        if kill -0 "$old_pid" 2>/dev/null; then
            return 1  # Process still running
        fi
        # Stale lock, remove it
        rm -f "$lock_file"
    fi

    echo "$pid" > "$lock_file"
    return 0
}

release_lock() {
    local schedule_id="$1"
    rm -f "${LOCKS_DIR}/${schedule_id}.lock"
}

is_locked() {
    local schedule_id="$1"
    local lock_file="${LOCKS_DIR}/${schedule_id}.lock"

    if [[ -f "$lock_file" ]]; then
        local old_pid
        old_pid=$(cat "$lock_file")
        if kill -0 "$old_pid" 2>/dev/null; then
            return 0  # locked
        fi
        # Stale, clean up
        rm -f "$lock_file"
    fi
    return 1  # not locked
}
```

### `lib/logging.sh` — Log Writing

```bash
#!/usr/bin/env bash

LOG_FILE="${HOME}/.skillrunner/logs/runner.log"
MAX_LOG_SIZE=$((5 * 1024 * 1024))  # 5MB

log_daemon() {
    local msg="$1"
    local timestamp
    timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[${timestamp}] ${msg}" >> "$LOG_FILE"

    # Rotate if too large
    if [[ -f "$LOG_FILE" ]] && (( $(stat -f%z "$LOG_FILE" 2>/dev/null || echo 0) > MAX_LOG_SIZE )); then
        mv "$LOG_FILE" "${LOG_FILE}.1"
        # Keep only one rotated file
        rm -f "${LOG_FILE}.2"
    fi
}
```

### `lib/schedule.sh` — Schedule Helpers

```bash
#!/usr/bin/env bash

# next_run_time "cron_expr"
# Computes the next matching time for a cron expression.
# Returns ISO 8601 timestamp.
# (Brute-force: check each minute for the next 48 hours)
next_run_time() {
    local cron_expr="$1"
    local check_epoch
    check_epoch=$(date +%s)

    # Round up to next minute boundary
    check_epoch=$(( (check_epoch / 60 + 1) * 60 ))

    local max_checks=$((48 * 60))  # 48 hours

    for ((i = 0; i < max_checks; i++)); do
        local check_date
        check_date=$(date -r "$check_epoch" +"%Y-%m-%dT%H:%M:00Z" 2>/dev/null || \
                     date -d "@$check_epoch" +"%Y-%m-%dT%H:%M:00Z" 2>/dev/null)

        # Temporarily override date for cron check
        local min hour dom mon dow
        min=$(date -r "$check_epoch" +%-M 2>/dev/null || date -d "@$check_epoch" +%-M)
        hour=$(date -r "$check_epoch" +%-H 2>/dev/null || date -d "@$check_epoch" +%-H)
        dom=$(date -r "$check_epoch" +%-d 2>/dev/null || date -d "@$check_epoch" +%-d)
        mon=$(date -r "$check_epoch" +%-m 2>/dev/null || date -d "@$check_epoch" +%-m)
        dow=$(date -r "$check_epoch" +%u 2>/dev/null || date -d "@$check_epoch" +%u)
        [[ "$dow" -eq 7 ]] && dow=0

        local cron_min cron_hour cron_dom cron_mon cron_dow
        read -r cron_min cron_hour cron_dom cron_mon cron_dow <<< "$cron_expr"

        if field_matches "$cron_min" "$min" 0 59 && \
           field_matches "$cron_hour" "$hour" 0 23 && \
           field_matches "$cron_dom" "$dom" 1 31 && \
           field_matches "$cron_mon" "$mon" 1 12 && \
           field_matches "$cron_dow" "$dow" 0 6; then
            echo "$check_date"
            return 0
        fi

        check_epoch=$((check_epoch + 60))
    done

    echo "unknown"
    return 1
}
```

---

## Logging System Design

### Structured Run Log (`runs.jsonl`)

One JSON object per line, appended after each run completes:

```json
{
  "run_id": "a1b2c3d4e5f6g7h8",
  "schedule_id": "a1b2c3d4",
  "skill": "concert-search",
  "args": "",
  "started_at": "2026-03-29T09:00:00Z",
  "ended_at": "2026-03-29T09:02:15Z",
  "duration_seconds": 135,
  "exit_code": 0,
  "status": "success",
  "cost_usd": 0.23,
  "attempts": 1,
  "result_preview": "Found 3 new concerts matching your preferences...",
  "stdout_file": "/Users/nicholas/.skillrunner/logs/output/a1b2c3d4e5f6g7h8.stdout",
  "stderr_file": "/Users/nicholas/.skillrunner/logs/output/a1b2c3d4e5f6g7h8.stderr"
}
```

### Log Rotation Strategy

| File | Max Size | Rotation |
|---|---|---|
| `runner.log` | 5 MB | Rotate to `runner.log.1`, keep 1 old copy |
| `runs.jsonl` | 10 MB | Rotate to `runs.jsonl.1`, keep 1 old copy |
| `output/*.stdout` | 100 KB each | Truncated at write time |
| `output/*.stderr` | 100 KB each | Truncated at write time |
| `launchd-stdout.log` | 1 MB | Managed by launchd restart |

A weekly cleanup job (also run by the daemon) removes output files older than 30 days:

```bash
find "${OUTPUT_DIR}" -name "*.stdout" -mtime +30 -delete
find "${OUTPUT_DIR}" -name "*.stderr" -mtime +30 -delete
```

---

## Error Handling and Edge Cases

### Authentication Failures

When Claude is not authenticated, `claude -p` exits with a non-zero code and stderr contains auth-related messages. The daemon captures this in the run log. The `/schedule status` command surfaces recent failures prominently.

Detection (in `skillrunner-run`):
```bash
if grep -qi "auth\|login\|token\|expired\|unauthorized" "$stderr_file" 2>/dev/null; then
    log_daemon "RUN ${RUN_ID}: Authentication error detected"
    # Write a marker so /schedule status can highlight this
fi
```

### Skill Not Found

If the user schedules a skill that doesn't exist (or is later removed), Claude will respond with an error message in its output but may still exit 0. The daemon checks the JSON response for `is_error: true`:

```bash
if jq -e '.is_error == true' "$stdout_file" > /dev/null 2>&1; then
    status="failure"
fi
```

### Overlapping Runs

The file-based lock system (one lock file per schedule ID containing the PID) prevents the same schedule from running concurrently. Stale locks are detected by checking if the PID is still alive (`kill -0`).

### Timeout Handling

The `timeout` command (from coreutils) wraps the `claude` invocation. Exit code 124 indicates the process was killed due to timeout. This is logged distinctly from other failures.

### System Sleep/Wake

LaunchAgent with `StartInterval` handles sleep correctly on macOS: if the machine is asleep when a run is due, the LaunchAgent fires immediately on wake. Multiple missed intervals do NOT queue up -- only one invocation occurs after wake.

### Disk Space

Before each run, the daemon checks available disk space:
```bash
available_kb=$(df -k "$SKILLRUNNER_HOME" | awk 'NR==2 {print $4}')
if (( available_kb < 102400 )); then  # 100MB minimum
    log_daemon "WARNING: Low disk space (${available_kb}KB), skipping runs"
    exit 0
fi
```

### Claude CLI Not Found

The daemon uses an absolute path (`/Users/nicholas/.nix-profile/bin/claude`) but also validates at startup:
```bash
if ! command -v claude &>/dev/null && [[ ! -x "/Users/nicholas/.nix-profile/bin/claude" ]]; then
    log_daemon "ERROR: claude CLI not found"
    exit 1
fi
```

### Cost Tracking

Each run's cost is extracted from Claude's JSON output (`total_cost_usd`). The `/schedule logs` command can aggregate costs by skill or time period. The `--max-budget-usd` flag provides a hard cap per invocation.

---

## Installation Script (`install.sh`)

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILLRUNNER_HOME="${HOME}/.skillrunner"
PLIST_NAME="com.skillrunner.daemon"
PLIST_DST="${HOME}/Library/LaunchAgents/${PLIST_NAME}.plist"

echo "=== SkillRunner Installer ==="
echo ""

# 1. Check prerequisites
echo "Checking prerequisites..."

CLAUDE_BIN=$(which claude 2>/dev/null || echo "")
if [[ -z "$CLAUDE_BIN" ]]; then
    echo "ERROR: claude CLI not found in PATH"
    exit 1
fi
echo "  claude CLI: ${CLAUDE_BIN}"

if ! command -v jq &>/dev/null; then
    echo "ERROR: jq is required but not installed"
    echo "  Install with: brew install jq (or nix-env -iA nixpkgs.jq)"
    exit 1
fi
echo "  jq: $(which jq)"

# 2. Create directory structure
echo ""
echo "Creating ~/.skillrunner/ ..."
mkdir -p "${SKILLRUNNER_HOME}"/{logs/output,locks}

if [[ ! -f "${SKILLRUNNER_HOME}/config.json" ]]; then
    echo '{"version": 1, "schedules": []}' | jq . > "${SKILLRUNNER_HOME}/config.json"
fi

echo '{"last_wake": null, "pid": null, "version": 1}' | jq . > "${SKILLRUNNER_HOME}/state.json"

# 3. Make scripts executable
echo "Setting permissions..."
chmod +x "${SCRIPT_DIR}"/bin/*

# 4. Generate and install LaunchAgent plist
echo "Installing LaunchAgent..."
CLAUDE_DIR=$(dirname "$CLAUDE_BIN")

cat > "$PLIST_DST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_NAME}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${SCRIPT_DIR}/bin/skillrunner-daemon</string>
    </array>
    <key>StartInterval</key>
    <integer>60</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${SKILLRUNNER_HOME}/logs/launchd-stdout.log</string>
    <key>StandardErrorPath</key>
    <string>${SKILLRUNNER_HOME}/logs/launchd-stderr.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>${CLAUDE_DIR}:/usr/local/bin:/usr/bin:/bin</string>
        <key>HOME</key>
        <string>${HOME}</string>
    </dict>
    <key>Nice</key>
    <integer>10</integer>
    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
PLIST

# 5. Install skill symlink
echo "Installing Claude Code skill symlink..."
mkdir -p "${HOME}/.claude/skills"
ln -sfn "$SCRIPT_DIR" "${HOME}/.claude/skills/schedule"

# 6. Load LaunchAgent
echo "Loading LaunchAgent..."
launchctl unload "$PLIST_DST" 2>/dev/null || true
launchctl load "$PLIST_DST"

echo ""
echo "=== Installation Complete ==="
echo ""
echo "  Data directory:  ${SKILLRUNNER_HOME}/"
echo "  LaunchAgent:     ${PLIST_DST}"
echo "  Skill command:   /schedule (available in Claude Code)"
echo ""
echo "  Next steps:"
echo "    1. Open Claude Code"
echo "    2. Type: /schedule add"
echo "    3. Follow the prompts to schedule your first skill"
echo ""
echo "  Management:"
echo "    ${SCRIPT_DIR}/bin/skillrunner-ctl status"
echo "    ${SCRIPT_DIR}/bin/skillrunner-ctl stop"
echo "    ${SCRIPT_DIR}/bin/skillrunner-ctl start"
```

---

## Step-by-Step Implementation Guide

### Phase 1: Foundation (Day 1)

**Goal:** Directory structure, library functions, config format.

1. Create the project directory structure:
   ```
   mkdir -p /Users/nicholas/Documents/Tools/SkillRunner/{bin,lib,templates}
   ```

2. Implement `lib/cron-parse.sh` with the `field_matches` and `cron_matches_now` functions. Write tests:
   ```bash
   # Test script: test-cron.sh
   source lib/cron-parse.sh
   # Override date for testing, or test field_matches directly
   assert field_matches "*/5" "0" 0 59   # true
   assert field_matches "*/5" "3" 0 59   # false
   assert field_matches "1-5" "3" 1 31   # true
   assert field_matches "1,15" "15" 1 31 # true
   ```

3. Implement `lib/lock.sh` with `acquire_lock`, `release_lock`, `is_locked`.

4. Implement `lib/logging.sh` with `log_daemon` and rotation logic.

5. Implement `lib/schedule.sh` with `next_run_time`.

6. Write a minimal `config.json` schema and validate with jq.

### Phase 2: Daemon Core (Day 2)

**Goal:** Working daemon that can detect due schedules and invoke claude.

1. Write `bin/skillrunner-run` -- the single-run executor. Test manually:
   ```bash
   # Create a test schedule in config.json, then:
   ./bin/skillrunner-run "test-id"
   ```

2. Write `bin/skillrunner-daemon` -- the wake-and-check loop. Test by running directly:
   ```bash
   # Set a schedule for "every minute" and run:
   bash ./bin/skillrunner-daemon
   ```

3. Verify JSON output parsing -- ensure cost, duration, result_preview are correctly extracted from Claude's `--output-format json` response.

4. Test timeout handling with a deliberately slow skill.

### Phase 3: LaunchAgent Integration (Day 3)

**Goal:** Daemon runs automatically via macOS LaunchAgent.

1. Write the plist template in `templates/`.

2. Write `install.sh` with prerequisite checks.

3. Write `bin/skillrunner-ctl` for install/uninstall/start/stop/status.

4. Test the full lifecycle:
   ```bash
   ./install.sh
   skillrunner-ctl status
   # Add a test schedule (every minute)
   # Wait 2 minutes, check logs
   skillrunner-ctl stop
   ```

5. Test sleep/wake behavior by putting the machine to sleep and verifying runs resume.

### Phase 4: Claude Code Skill (Day 4)

**Goal:** The `/schedule` skill works interactively in Claude Code.

1. Write `SKILL.md` with the frontmatter and all command documentation.

2. Test each subcommand in Claude Code:
   - `/schedule status` -- should show daemon state
   - `/schedule add` -- should prompt for details and write config
   - `/schedule list` -- should display all schedules with next run times
   - `/schedule logs` -- should show recent run history
   - `/schedule remove` -- should remove a schedule

3. Ensure the skill handles the "not installed" case gracefully by offering to run the installer.

### Phase 5: Polish and Hardening (Day 5)

**Goal:** Production-ready reliability.

1. Add disk space check before runs.

2. Add authentication error detection and surfacing.

3. Add log rotation for `runs.jsonl` (not just `runner.log`).

4. Add the 30-day output file cleanup routine.

5. Add a `--dry-run` flag to `skillrunner-daemon` for testing without actually invoking Claude.

6. Stress test: schedule 5+ skills at the same minute, verify no race conditions.

7. Add cost aggregation to `/schedule logs` (total cost per skill, per day, etc.).

8. Document the project with a top-level README covering installation, usage, and troubleshooting.

---

## Dependencies

| Dependency | Purpose | Availability |
|---|---|---|
| `bash` 4+ | Script execution | macOS ships bash 3.2; use `/bin/bash` or nix bash |
| `jq` | JSON parsing | `brew install jq` or via nix |
| `claude` CLI | Skill execution | Already installed at `/Users/nicholas/.nix-profile/bin/claude` |
| `timeout` (coreutils) | Kill long-running processes | `brew install coreutils` provides `gtimeout`; or use nix |
| `openssl` | Random ID generation | Ships with macOS |
| `launchctl` | LaunchAgent management | Ships with macOS |

**Important bash version note:** macOS ships bash 3.2 which lacks some features (associative arrays, `readarray`). The scripts above are written to be bash 3.2 compatible. If nix provides a newer bash, update the plist `ProgramArguments` to use it.

**Important coreutils note:** macOS `timeout` may not exist. The scripts should detect this and fall back:
```bash
TIMEOUT_CMD="timeout"
if ! command -v timeout &>/dev/null; then
    if command -v gtimeout &>/dev/null; then
        TIMEOUT_CMD="gtimeout"
    else
        # Fallback: no timeout enforcement
        TIMEOUT_CMD=""
    fi
fi
```

---

## Security Considerations

1. **Permission modes:** Default to `plan` (read-only) for scheduled runs. This prevents autonomous skills from modifying files or running arbitrary commands without explicit opt-in per schedule.

2. **Budget caps:** Every schedule has a `max_budget_usd` field. Combined with Claude's `--max-budget-usd` flag, this provides a hard cost ceiling per run.

3. **No secrets in config:** The `config.json` file contains no API keys or credentials. Claude's own authentication is handled by its CLI (OAuth tokens stored in `~/.claude/`).

4. **Lock files prevent abuse:** A compromised or buggy skill cannot spawn infinite parallel runs.

5. **Output truncation:** Large outputs are truncated to 100KB to prevent disk exhaustion.

---

## Future Enhancements

- **Notification system:** Send macOS notifications (`osascript -e 'display notification'`) on failure or interesting results.
- **Web dashboard:** A simple local web UI to view schedules and logs.
- **Conditional scheduling:** Run a skill only if a previous skill's output matches a pattern (pipeline chaining).
- **Remote monitoring:** Optional webhook to post run results to Slack/Discord.
- **Multi-machine sync:** Store config in iCloud or git for syncing across machines.
