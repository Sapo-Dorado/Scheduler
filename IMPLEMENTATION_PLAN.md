# SkillRunner - Implementation Plan

## Project Overview

SkillRunner is a cross-platform, Nix-packaged daemon and Claude Code skill (`/schedule`) that automatically executes Claude Code skills **or bash commands** on a configurable schedule. It is "cron for Claude skills and scripts" — users define schedules like "run `/concert-search` every day at 9 AM" or "run `./scripts/backup.sh` every 6 hours" and SkillRunner handles invocation, logging, error handling, and lifecycle management.

**Key design principles:**
- **Nix-first:** Packaged as a Nix flake with pinned dependencies. No "hope jq is installed" — everything is in the closure.
- **Cross-platform:** Works on NixOS (systemd user service), macOS (LaunchAgent), and generic Linux (systemd user service).
- **Per-project schedules:** Each git repo can define a `.skillrunner.json` with its own schedules, registered with the global daemon. The project config is version-controlled; runtime state is not.
- **Home-Manager integration:** Ships a home-manager module that can be imported into an existing flake to install the daemon, the skill symlink, and the service — declaratively.
- **Telegram notifications:** Per-schedule notification config with two modes: `template` (instant, no extra cost) or `summary` (Claude generates a phone-friendly message from the skill output). Notifications can target different Telegram chats/groups per schedule.

---

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          SkillRunner System                             │
│                                                                         │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │  Claude Code Skills: /schedule, /schedule-setup                   │   │
│  │  /schedule: add | list | remove | logs | status | enable         │   │
│  │             disable | register | unregister | notify-setup        │   │
│  │  /schedule-setup: guided project setup wizard                    │   │
│  │  (Interactive management via Claude Code sessions)               │   │
│  └──────────────┬───────────────────────────────────────────────────┘   │
│                  │ reads/writes                                          │
│                  ▼                                                       │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │  ~/.config/skillrunner/                                          │   │
│  │  ├── config.json          (global schedule registry)             │   │
│  │  ├── state.json           (daemon state)                         │   │
│  │  ├── logs/                                                       │   │
│  │  │   ├── runs.jsonl       (structured execution log)             │   │
│  │  │   ├── runner.log       (daemon lifecycle log)                 │   │
│  │  │   └── output/          (captured stdout/stderr per run)       │   │
│  │  │       └── {run_id}.txt                                        │   │
│  │  └── locks/               (per-skill lock files via mkdir)       │   │
│  └──────────────┬───────────────────────────────────────────────────┘   │
│                  │ reads                                                 │
│                  ▼                                                       │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │  skillrunner-daemon (Bash 5.x, Nix-wrapped)                     │   │
│  │  - Managed by systemd user unit (Linux/NixOS)                   │   │
│  │    or macOS LaunchAgent                                          │   │
│  │  - Wakes every 60s, checks schedule                              │   │
│  │  - Skills: invokes claude -p "/<skill> <args>"                   │   │
│  │  - Commands: invokes bash -c "<command>"                         │   │
│  │  - Captures output, writes logs                                  │   │
│  │  - Handles timeouts, overlaps, retries                           │   │
│  │  - Sends Telegram notifications after runs                       │   │
│  └──────────────────────────────────────────────────────────────────┘   │
│                  │ invokes                                               │
│                  ▼                                                       │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │  claude -p --output-format json --permission-mode plan \         │   │
│  │    --max-budget-usd <budget> "/<skill-name> <args>"              │   │
│  │                                                                   │   │
│  │  Non-interactive execution of any Claude Code skill               │   │
│  └──────────────────────────────────────────────────────────────────┘   │
│                  │ on completion (if notification configured)            │
│                  ▼                                                       │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │  Notification Dispatch                                           │   │
│  │  - Evaluate "when" condition (always / on_failure / on_result)   │   │
│  │  - "template" mode: expand template string, curl Telegram API    │   │
│  │  - "summary" mode: second claude -p call to generate summary,    │   │
│  │    then curl Telegram API                                        │   │
│  └──────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────┘

Per-project config (version controlled):

  my-project/
  ├── .skillrunner.json     ← schedule definitions for this project
  └── .claude/skills/...    ← the skills themselves

Global config (runtime state, NOT version controlled):

  ~/.config/skillrunner/
  ├── config.json           ← merged registry of all project schedules
  └── ...
```

---

## How Claude Code Is Invoked Programmatically

### Confirmed CLI Behavior

The `claude` CLI supports non-interactive execution via the `-p` / `--print` flag.

**Recommended invocation for SkillRunner daemon:**
```bash
claude -p \
  --output-format json \
  --permission-mode plan \
  --max-budget-usd 0.50 \
  --no-session-persistence \
  "/<skill-name> <args>"
```

Flags:
- `--output-format json` — returns structured JSON with `result`, `is_error`, `duration_ms`, `total_cost_usd`, `usage`, etc.
- `--permission-mode plan` — safe default: read/search allowed, writes blocked. Other options: `acceptEdits`, `bypassPermissions`, `default`, `dontAsk`, `auto`.
- `--max-budget-usd 0.50` — hard cost cap per run (overridable per schedule).
- `--no-session-persistence` — don't save to session history.

**Working directory matters:** Claude Code skills operate relative to cwd. The daemon must `cd` to the project's working directory before invoking claude.

---

## File Layout

### Project Repository (this repo, version controlled)

```
/Users/nicholas/Documents/Tools/SkillRunner/
├── IMPLEMENTATION_PLAN.md          (this file)
├── flake.nix                       (Nix flake: package + home-manager module)
├── flake.lock
├── SKILL.md                        (Claude Code /schedule skill)
├── SETUP_SKILL.md                  (Claude Code /schedule-setup skill)
├── bin/
│   ├── skillrunner-daemon          (main daemon loop script)
│   ├── skillrunner-run             (single-run executor)
│   └── skillrunner-ctl             (CLI: register/unregister/status)
├── lib/
│   ├── schedule.sh                 (schedule parsing functions)
│   ├── logging.sh                  (log writing functions)
│   ├── cron-parse.sh               (cron expression evaluator)
│   ├── lock.sh                     (directory-based atomic locking)
│   └── notify.sh                   (Telegram notification dispatch)
├── module/
│   └── home-manager.nix            (home-manager module)
└── templates/
    ├── com.skillrunner.daemon.plist (macOS LaunchAgent template)
    └── skillrunner.service          (systemd user unit template)
```

### Runtime Data (`~/.config/skillrunner/`, NOT version controlled)

```
~/.config/skillrunner/
├── config.json              (merged registry of all schedules)
├── state.json               (daemon state: pid, last wake, version)
├── logs/
│   ├── runs.jsonl           (append-only structured run log)
│   ├── runner.log           (daemon lifecycle log)
│   └── output/
│       ├── {uuid}.stdout    (captured stdout per run)
│       └── {uuid}.stderr    (captured stderr per run)
└── locks/
    └── {schedule_id}/       (lock dirs, not files — atomic mkdir)
```

Uses `~/.config/skillrunner/` (XDG-compliant) instead of `~/.skillrunner/`.

### Per-Project Config (version controlled, lives in any git repo)

```
my-project/
└── .skillrunner.json
```

---

## Per-Project Schedule Config (`.skillrunner.json`)

This file lives in a project's git root and defines schedules for that project. It is version-controlled so anyone who clones the repo gets the same schedule definitions.

```json
{
  "version": 1,
  "schedules": [
    {
      "type": "skill",
      "skill": "concert-search",
      "args": "",
      "cron": "0 9 * * *",
      "human_schedule": "Daily at 9:00 AM",
      "permission_mode": "plan",
      "max_budget_usd": 0.50,
      "timeout_seconds": 300,
      "enabled": true,
      "retry": {
        "max_attempts": 1,
        "delay_seconds": 60
      },
      "notification": {
        "chat_id": "-100123456789",
        "when": "on_result",
        "mode": "summary",
        "summary_prompt": "Summarize what concerts were found, include dates and venues"
      }
    },
    {
      "type": "command",
      "command": "./scripts/backup.sh",
      "cron": "0 */6 * * *",
      "human_schedule": "Every 6 hours",
      "timeout_seconds": 600,
      "enabled": true,
      "retry": {
        "max_attempts": 3,
        "delay_seconds": 120
      },
      "notification": {
        "chat_id": "987654321",
        "when": "on_failure",
        "mode": "template",
        "template": "❌ Backup failed (exit ${exit_code}, attempt ${attempts}/${max_attempts})"
      }
    },
    {
      "type": "skill",
      "skill": "backup-verify",
      "args": "",
      "cron": "0 6 * * *",
      "human_schedule": "Daily at 6:00 AM",
      "permission_mode": "plan",
      "max_budget_usd": 0.25,
      "timeout_seconds": 120,
      "enabled": true,
      "retry": {
        "max_attempts": 2,
        "delay_seconds": 60
      },
      "notification": {
        "chat_id": "987654321",
        "when": "on_failure",
        "mode": "template"
      }
    }
  ]
}
```

### Schedule Types

Each schedule has a `type` field that determines how it is executed:

**`"type": "skill"`** — Invokes a Claude Code skill via `claude -p "/<skill> <args>"`.
- Requires: `skill` (name of the slash command)
- Optional: `args`, `permission_mode`, `max_budget_usd`
- Output: Claude's JSON response (parsed for cost, result, is_error)
- Use when: the task requires AI reasoning, reading/analyzing code, generating content, or interacting with tools

**`"type": "command"`** — Runs a bash command directly, no Claude involved.
- Requires: `command` (the command string to execute via `bash -c`)
- No `skill`, `args`, `permission_mode`, or `max_budget_usd` fields
- Output: raw stdout/stderr captured to log files
- Use when: the task is deterministic and doesn't need AI — running a script, checking disk space, pulling git updates, pinging a service, etc.
- The command runs from the project's working directory
- **Cost: $0** — no API calls

If `type` is omitted, it defaults to `"skill"` for backwards compatibility.

Note: **no `id`, no `working_directory`** — these are assigned at registration time. The working directory is the project root where `.skillrunner.json` lives. IDs are generated when registering.

### Notification Schema

The `notification` field is optional. If omitted, no notification is sent.

```json
"notification": {
  "chat_id": "string (required)",
  "when": "always | on_failure | on_result",
  "mode": "template | summary",
  "template": "optional custom template string (template mode only)",
  "summary_prompt": "required prompt string (summary mode only)"
}
```

**`chat_id`** — Telegram chat to send to:
- Positive number (e.g., `"987654321"`) = DM to one person
- Negative number (e.g., `"-100123456789"`) = group chat (anyone in the group sees it)
- To get a personal chat_id: message the bot, then check `https://api.telegram.org/bot<TOKEN>/getUpdates`
- To get a group chat_id: add the bot to a group, send a message, check getUpdates

**`when`** — when to send:
- `"always"` — after every run regardless of outcome
- `"on_failure"` — only when the run fails (non-zero exit, or `is_error: true` for skills)
- `"on_result"` — only when the run produces non-empty output

**`mode`** — how to generate the message:
- `"template"` — no Claude call. Expands a template string with run variables. If `template` is omitted, uses a default: `"[status_emoji] *skill* status (duration, $cost)"`
- `"summary"` — second Claude call (`--max-budget-usd 0.05`) with `summary_prompt` to generate a phone-friendly message from the full skill output

**`template`** variables (for template mode):
- `${name}` — skill name or command
- `${status}` — success / failure
- `${exit_code}` — exit code
- `${duration}` — seconds
- `${cost}` — USD amount
- `${attempts}` — attempt count
- `${max_attempts}` — max attempts configured
- `${project_path}` — working directory
- `${result_preview}` — first 500 chars of output
- `${timestamp}` — ISO timestamp

Example custom template:
```json
"template": "*${skill}* failed in ${project_path}\nExit: ${exit_code} | Attempts: ${attempts}/${max_attempts}"
```

### Telegram Bot Token

The bot token is stored globally, NOT in `.skillrunner.json` (which is version-controlled). It lives in:

```
~/.config/skillrunner/secrets.env
```

Contents:
```
SKILLRUNNER_TELEGRAM_TOKEN=123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11
```

The daemon sources this file before dispatching notifications. The home-manager module creates this file (empty) during activation if it doesn't exist.

### Global Registry (`~/.config/skillrunner/config.json`)

The daemon reads this file. It is the merged view of all registered projects:

```json
{
  "version": 1,
  "projects": [
    {
      "path": "/home/nicholas/Projects/ConcertAgent",
      "registered_at": "2026-03-29T10:00:00Z"
    }
  ],
  "schedules": [
    {
      "id": "a1b2c3d4",
      "type": "skill",
      "project_path": "/home/nicholas/Projects/ConcertAgent",
      "skill": "concert-search",
      "args": "",
      "cron": "0 9 * * *",
      "human_schedule": "Daily at 9:00 AM",
      "permission_mode": "plan",
      "max_budget_usd": 0.50,
      "timeout_seconds": 300,
      "enabled": true,
      "retry": {
        "max_attempts": 1,
        "delay_seconds": 60
      },
      "notification": {
        "chat_id": "-100123456789",
        "when": "on_result",
        "mode": "summary",
        "summary_prompt": "Summarize what concerts were found, include dates and venues"
      },
      "registered_at": "2026-03-29T10:00:00Z"
    },
    {
      "id": "b2c3d4e5",
      "type": "command",
      "project_path": "/home/nicholas/Projects/ConcertAgent",
      "command": "./scripts/backup.sh",
      "cron": "0 */6 * * *",
      "human_schedule": "Every 6 hours",
      "timeout_seconds": 600,
      "enabled": true,
      "retry": {
        "max_attempts": 3,
        "delay_seconds": 120
      },
      "notification": {
        "chat_id": "987654321",
        "when": "on_failure",
        "mode": "template"
      },
      "registered_at": "2026-03-29T10:00:00Z"
    }
  ]
}
```

### Registration Flow

1. User runs `/schedule register` in a project directory (or `skillrunner-ctl register /path/to/project`)
2. SkillRunner reads `.skillrunner.json` from that directory
3. Each schedule entry gets an `id` (8-char hex) and `project_path` assigned
4. Entries are merged into the global `config.json`
5. `/schedule unregister` removes all schedules for a project path

This means: clone a repo, run `/schedule register`, done. The schedules are defined by the project author, not typed in manually each time.

---

## Nix Flake (`flake.nix`)

```nix
{
  description = "SkillRunner — cron for Claude Code skills";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    in {

      packages = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
        in {
          default = pkgs.stdenv.mkDerivation {
            pname = "skillrunner";
            version = "0.1.0";
            src = ./.;

            nativeBuildInputs = [ pkgs.makeWrapper ];
            buildInputs = [ pkgs.bash pkgs.jq pkgs.coreutils pkgs.openssl pkgs.curl ];

            installPhase = ''
              mkdir -p $out/bin $out/lib $out/share/skillrunner

              # Install library files
              cp lib/*.sh $out/lib/

              # Install and wrap bin scripts
              for script in bin/*; do
                install -m755 "$script" "$out/bin/$(basename $script)"
                wrapProgram "$out/bin/$(basename $script)" \
                  --set SKILLRUNNER_LIB "$out/lib" \
                  --prefix PATH : "${pkgs.lib.makeBinPath [
                    pkgs.bash pkgs.jq pkgs.coreutils pkgs.openssl pkgs.curl
                  ]}"
              done

              # Install skill definitions
              cp SKILL.md $out/share/skillrunner/
              cp SETUP_SKILL.md $out/share/skillrunner/

              # Install service templates
              mkdir -p $out/share/skillrunner/templates
              cp templates/* $out/share/skillrunner/templates/
            '';
          };
        });

      # Home-Manager module for declarative installation
      homeManagerModules.default = import ./module/home-manager.nix self;
    };
}
```

### Home-Manager Module (`module/home-manager.nix`)

This is the key integration point with your existing NixOS flake. It:
- Installs the skillrunner package
- Creates the `~/.claude/skills/schedule` symlink
- Sets up the systemd user service (Linux) or LaunchAgent (macOS)
- Creates the runtime directory structure

```nix
skillrunner: { config, lib, pkgs, ... }:

let
  cfg = config.services.skillrunner;
  package = skillrunner.packages.${pkgs.system}.default;
  isLinux = pkgs.stdenv.isLinux;
  isDarwin = pkgs.stdenv.isDarwin;
in {
  options.services.skillrunner = {
    enable = lib.mkEnableOption "SkillRunner daemon for scheduled Claude Code skills";
  };

  config = lib.mkIf cfg.enable {

    home.packages = [ package ];

    # Symlink skills into Claude Code's skill directory
    home.file.".claude/skills/schedule/SKILL.md".source =
      "${package}/share/skillrunner/SKILL.md";
    home.file.".claude/skills/schedule-setup/SKILL.md".source =
      "${package}/share/skillrunner/SETUP_SKILL.md";

    # Create runtime directories via activation script
    home.activation.skillrunner-dirs = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      mkdir -p "${config.home.homeDirectory}/.config/skillrunner"/{logs/output,locks}
      if [ ! -f "${config.home.homeDirectory}/.config/skillrunner/config.json" ]; then
        echo '{"version": 1, "projects": [], "schedules": []}' > \
          "${config.home.homeDirectory}/.config/skillrunner/config.json"
      fi
      echo '{"last_wake": null, "pid": null, "version": 1}' > \
        "${config.home.homeDirectory}/.config/skillrunner/state.json"
      # Create secrets file (for Telegram token) if it doesn't exist
      if [ ! -f "${config.home.homeDirectory}/.config/skillrunner/secrets.env" ]; then
        echo '# Add your Telegram bot token here:' > \
          "${config.home.homeDirectory}/.config/skillrunner/secrets.env"
        echo '# SKILLRUNNER_TELEGRAM_TOKEN=your_bot_token_here' >> \
          "${config.home.homeDirectory}/.config/skillrunner/secrets.env"
        chmod 600 "${config.home.homeDirectory}/.config/skillrunner/secrets.env"
      fi
    '';

    # Systemd user service (NixOS / Linux)
    systemd.user.services.skillrunner = lib.mkIf isLinux {
      Unit = {
        Description = "SkillRunner — scheduled Claude Code skill executor";
      };
      Service = {
        Type = "oneshot";
        ExecStart = "${package}/bin/skillrunner-daemon";
        Nice = 10;
      };
    };

    systemd.user.timers.skillrunner = lib.mkIf isLinux {
      Unit = {
        Description = "SkillRunner wake timer";
      };
      Timer = {
        OnBootSec = "1min";
        OnUnitActiveSec = "1min";
        Persistent = true;   # catch up after sleep/reboot
      };
      Install = {
        WantedBy = [ "timers.target" ];
      };
    };

    # macOS LaunchAgent
    launchd.agents.skillrunner = lib.mkIf isDarwin {
      enable = true;
      config = {
        Label = "com.skillrunner.daemon";
        ProgramArguments = [ "${package}/bin/skillrunner-daemon" ];
        StartInterval = 60;
        RunAtLoad = true;
        StandardOutPath =
          "${config.home.homeDirectory}/.config/skillrunner/logs/launchd-stdout.log";
        StandardErrorPath =
          "${config.home.homeDirectory}/.config/skillrunner/logs/launchd-stderr.log";
        Nice = 10;
        ProcessType = "Background";
      };
    };
  };
}
```

### Integration with Your NixOS Flake

In your `nixosFlake/flake.nix`, add SkillRunner as an input and import the module:

```nix
# In flake.nix inputs:
inputs.skillrunner.url = "github:Sapo-Dorado/SkillRunner";  # or path
inputs.skillrunner.inputs.nixpkgs.follows = "nixpkgs";

# In home-manager modules or extraSpecialArgs, pass skillrunner through,
# then in a home .nix file:
{ skillrunner, ... }: {
  imports = [ skillrunner.homeManagerModules.default ];
  services.skillrunner.enable = true;
}
```

This gives you:
- `skillrunner-daemon`, `skillrunner-run`, `skillrunner-ctl` on PATH
- The `/schedule` skill available in all Claude Code sessions
- A systemd user timer on NixOS (or LaunchAgent on Mac) running automatically
- No manual install step — `nixos-rebuild switch` or `home-manager switch` does it all

---

## Daemon Design

### Overview

The daemon is a bash 5.x script that runs as a oneshot service, triggered every 60 seconds by either a systemd timer or macOS LaunchAgent `StartInterval`. It checks which schedules are due, runs them, and exits. No long-running process.

### Daemon Script (`bin/skillrunner-daemon`)

```bash
#!/usr/bin/env bash
set -euo pipefail

# SkillRunner Daemon — Wakes every 60s via systemd timer or LaunchAgent.

SKILLRUNNER_HOME="${XDG_CONFIG_HOME:-${HOME}/.config}/skillrunner"
CONFIG_FILE="${SKILLRUNNER_HOME}/config.json"
STATE_FILE="${SKILLRUNNER_HOME}/state.json"
LOCKS_DIR="${SKILLRUNNER_HOME}/locks"
OUTPUT_DIR="${SKILLRUNNER_HOME}/logs/output"

# Library path set by Nix wrapper, fallback for dev
SKILLRUNNER_LIB="${SKILLRUNNER_LIB:-$(cd "$(dirname "$0")/../lib" && pwd)}"

source "${SKILLRUNNER_LIB}/schedule.sh"
source "${SKILLRUNNER_LIB}/logging.sh"
source "${SKILLRUNNER_LIB}/cron-parse.sh"
source "${SKILLRUNNER_LIB}/lock.sh"

# Disk space check (100MB minimum)
available_kb=$(df -k "$SKILLRUNNER_HOME" | awk 'NR==2 {print $4}')
if (( available_kb < 102400 )); then
    log_daemon "WARNING: Low disk space (${available_kb}KB), skipping runs"
    exit 0
fi

# Verify claude is available
if ! command -v claude &>/dev/null; then
    log_daemon "ERROR: claude CLI not found on PATH"
    exit 1
fi

# Update state
update_state() {
    local now_iso
    now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local tmp
    tmp=$(mktemp)
    jq --arg ts "$now_iso" '.last_wake = $ts | .pid = '$$'' \
        "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

log_daemon "Daemon woke up (pid $$)"
update_state

# Bail if config doesn't exist
if [[ ! -f "$CONFIG_FILE" ]]; then
    log_daemon "No config file found, exiting"
    exit 0
fi

# Sync registered projects: re-read each project's .skillrunner.json
# to pick up changes made via git pull, etc.
sync_projects

# Check each schedule
schedule_count=$(jq '.schedules | length' "$CONFIG_FILE")

for ((i = 0; i < schedule_count; i++)); do
    schedule_json=$(jq -c ".schedules[$i]" "$CONFIG_FILE")

    enabled=$(echo "$schedule_json" | jq -r '.enabled')
    [[ "$enabled" != "true" ]] && continue

    cron_expr=$(echo "$schedule_json" | jq -r '.cron')
    schedule_id=$(echo "$schedule_json" | jq -r '.id')
    skill=$(echo "$schedule_json" | jq -r '.skill')

    if cron_matches_now "$cron_expr"; then
        log_daemon "Schedule ${schedule_id} (${skill}) is due, dispatching"

        if is_locked "$schedule_id"; then
            log_daemon "Schedule ${schedule_id} is already running, skipping"
            continue
        fi

        # Run in background so we can process other schedules concurrently
        "$(dirname "$0")/skillrunner-run" "$schedule_id" &
    fi
done

# Periodic cleanup: remove output files older than 30 days (check once per hour at minute 0)
if [[ "$(date +%-M)" == "0" ]]; then
    find "${OUTPUT_DIR}" -name "*.stdout" -mtime +30 -delete 2>/dev/null || true
    find "${OUTPUT_DIR}" -name "*.stderr" -mtime +30 -delete 2>/dev/null || true
fi

log_daemon "Daemon check complete"
```

### Single-Run Executor (`bin/skillrunner-run`)

```bash
#!/usr/bin/env bash
set -euo pipefail

# Executes a single scheduled skill run.
# Usage: skillrunner-run <schedule_id>

SKILLRUNNER_HOME="${XDG_CONFIG_HOME:-${HOME}/.config}/skillrunner"
CONFIG_FILE="${SKILLRUNNER_HOME}/config.json"
RUNS_LOG="${SKILLRUNNER_HOME}/logs/runs.jsonl"
OUTPUT_DIR="${SKILLRUNNER_HOME}/logs/output"

SKILLRUNNER_LIB="${SKILLRUNNER_LIB:-$(cd "$(dirname "$0")/../lib" && pwd)}"
source "${SKILLRUNNER_LIB}/logging.sh"
source "${SKILLRUNNER_LIB}/lock.sh"
source "${SKILLRUNNER_LIB}/notify.sh"

SCHEDULE_ID="$1"
RUN_ID=$(openssl rand -hex 8)

# Read schedule config
schedule_json=$(jq -c ".schedules[] | select(.id == \"${SCHEDULE_ID}\")" "$CONFIG_FILE")
if [[ -z "$schedule_json" ]]; then
    log_daemon "ERROR: Schedule ${SCHEDULE_ID} not found in config"
    exit 1
fi

run_type=$(echo "$schedule_json" | jq -r '.type // "skill"')
workdir=$(echo "$schedule_json" | jq -r '.project_path // env.HOME')
timeout_secs=$(echo "$schedule_json" | jq -r '.timeout_seconds // 300')
max_attempts=$(echo "$schedule_json" | jq -r '.retry.max_attempts // 1')
retry_delay=$(echo "$schedule_json" | jq -r '.retry.delay_seconds // 60')

# Type-specific fields
skill=""
args=""
command=""
permission_mode="plan"
max_budget="0.50"

if [[ "$run_type" == "skill" ]]; then
    skill=$(echo "$schedule_json" | jq -r '.skill')
    args=$(echo "$schedule_json" | jq -r '.args // ""')
    permission_mode=$(echo "$schedule_json" | jq -r '.permission_mode // "plan"')
    max_budget=$(echo "$schedule_json" | jq -r '.max_budget_usd // 0.50')
elif [[ "$run_type" == "command" ]]; then
    command=$(echo "$schedule_json" | jq -r '.command')
fi

# Display name for logging
run_name="${skill:-${command}}"

# Acquire lock (atomic mkdir)
acquire_lock "$SCHEDULE_ID" || {
    log_daemon "Failed to acquire lock for ${SCHEDULE_ID}"
    exit 1
}
trap 'release_lock "$SCHEDULE_ID"' EXIT

start_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
start_epoch=$(date +%s)

log_daemon "RUN ${RUN_ID}: Starting ${run_type} '${run_name}' in ${workdir}"

attempt=0
exit_code=1
stdout_file="${OUTPUT_DIR}/${RUN_ID}.stdout"
stderr_file="${OUTPUT_DIR}/${RUN_ID}.stderr"

while (( attempt < max_attempts )); do
    attempt=$((attempt + 1))
    log_daemon "RUN ${RUN_ID}: Attempt ${attempt}/${max_attempts}"

    set +e
    if [[ "$run_type" == "skill" ]]; then
        # Build skill prompt
        local prompt="/${skill}"
        [[ -n "$args" ]] && prompt="/${skill} ${args}"

        # Invoke Claude Code from the project directory
        (
            cd "$workdir" 2>/dev/null || cd "$HOME"
            timeout "${timeout_secs}" \
                claude -p \
                    --output-format json \
                    --permission-mode "$permission_mode" \
                    --max-budget-usd "$max_budget" \
                    --no-session-persistence \
                    "$prompt"
        ) > "$stdout_file" 2> "$stderr_file" < /dev/null
        exit_code=$?
    elif [[ "$run_type" == "command" ]]; then
        # Run bash command directly
        (
            cd "$workdir" 2>/dev/null || cd "$HOME"
            timeout "${timeout_secs}" \
                bash -c "$command"
        ) > "$stdout_file" 2> "$stderr_file" < /dev/null
        exit_code=$?
    fi
    set -e

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

# Parse output based on type
cost="null"
result_text=""
status="success"

if [[ -f "$stdout_file" ]]; then
    if [[ "$run_type" == "skill" ]]; then
        # Skill output is JSON from Claude
        if jq -e '.total_cost_usd' "$stdout_file" > /dev/null 2>&1; then
            cost=$(jq '.total_cost_usd' "$stdout_file")
            result_text=$(jq -r '.result // ""' "$stdout_file" | head -c 2000)
        fi
        if jq -e '.is_error == true' "$stdout_file" > /dev/null 2>&1; then
            status="failure"
        fi
    elif [[ "$run_type" == "command" ]]; then
        # Command output is raw text
        result_text=$(head -c 2000 "$stdout_file")
    fi
fi

[[ $exit_code -ne 0 ]] && status="failure"

# Truncate large output files (> 100KB)
for f in "$stdout_file" "$stderr_file"; do
    if [[ -f "$f" ]]; then
        local_size=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null || echo 0)
        if (( local_size > 102400 )); then
            truncate -s 102400 "$f"
            echo -e "\n\n[TRUNCATED - output exceeded 100KB]" >> "$f"
        fi
    fi
done

# Write structured log entry (atomic via temp file + append)
log_entry=$(jq -n \
    --arg run_id "$RUN_ID" \
    --arg schedule_id "$SCHEDULE_ID" \
    --arg type "$run_type" \
    --arg name "$run_name" \
    --arg skill "$skill" \
    --arg command "$command" \
    --arg args "$args" \
    --arg project_path "$workdir" \
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
        type: $type,
        name: $name,
        skill: $skill,
        command: $command,
        args: $args,
        project_path: $project_path,
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

log_daemon "RUN ${RUN_ID}: ${run_type} '${run_name}' completed (${status}, ${duration}s, exit ${exit_code}, cost \$${cost})"

# --- Notification dispatch ---
# Set notify_* variables for template expansion and dispatch
notify_skill="$run_name"
notify_status="$status"
notify_exit_code="$exit_code"
notify_duration="$duration"
notify_cost="$cost"
notify_attempts="$attempt"
notify_max_attempts="$max_attempts"
notify_project_path="$workdir"
notify_result_preview="${result_text:0:500}"
notify_timestamp="$end_time"

dispatch_notification "$schedule_json"
```

### Control Script (`bin/skillrunner-ctl`)

```bash
#!/usr/bin/env bash
set -euo pipefail

SKILLRUNNER_HOME="${XDG_CONFIG_HOME:-${HOME}/.config}/skillrunner"
CONFIG_FILE="${SKILLRUNNER_HOME}/config.json"

SKILLRUNNER_LIB="${SKILLRUNNER_LIB:-$(cd "$(dirname "$0")/../lib" && pwd)}"
source "${SKILLRUNNER_LIB}/logging.sh"

ensure_config() {
    mkdir -p "${SKILLRUNNER_HOME}"/{logs/output,locks}
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo '{"version": 1, "projects": [], "schedules": []}' | jq . > "$CONFIG_FILE"
    fi
    if [[ ! -f "${SKILLRUNNER_HOME}/state.json" ]]; then
        echo '{"last_wake": null, "pid": null, "version": 1}' | jq . > "${SKILLRUNNER_HOME}/state.json"
    fi
}

cmd_register() {
    local project_path="${1:-.}"
    project_path="$(cd "$project_path" && pwd)"

    local project_config="${project_path}/.skillrunner.json"
    if [[ ! -f "$project_config" ]]; then
        echo "ERROR: No .skillrunner.json found in ${project_path}"
        exit 1
    fi

    ensure_config

    # Remove existing schedules for this project
    local tmp
    tmp=$(mktemp)
    jq --arg pp "$project_path" '
        .schedules = [.schedules[] | select(.project_path != $pp)] |
        .projects = [.projects[] | select(.path != $pp)]
    ' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"

    # Read project config and merge schedules
    local now_iso
    now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Add project entry
    tmp=$(mktemp)
    jq --arg pp "$project_path" --arg ts "$now_iso" '
        .projects += [{"path": $pp, "registered_at": $ts}]
    ' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"

    # Add each schedule with generated ID
    local count
    count=$(jq '.schedules | length' "$project_config")

    for ((i = 0; i < count; i++)); do
        local sid
        sid=$(openssl rand -hex 4)

        tmp=$(mktemp)
        jq --arg pp "$project_path" --arg sid "$sid" --arg ts "$now_iso" \
            --argjson sched "$(jq -c ".schedules[$i]" "$project_config")" '
            .schedules += [$sched + {
                "id": $sid,
                "project_path": $pp,
                "registered_at": $ts
            }]
        ' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
    done

    echo "Registered ${count} schedule(s) from ${project_path}"
}

cmd_unregister() {
    local project_path="${1:-.}"
    project_path="$(cd "$project_path" && pwd)"

    local tmp
    tmp=$(mktemp)
    jq --arg pp "$project_path" '
        .schedules = [.schedules[] | select(.project_path != $pp)] |
        .projects = [.projects[] | select(.path != $pp)]
    ' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"

    echo "Unregistered all schedules for ${project_path}"
}

cmd_status() {
    echo "=== SkillRunner Status ==="

    # Check daemon (systemd or launchctl)
    if systemctl --user is-active skillrunner.timer &>/dev/null; then
        echo "Daemon: RUNNING (systemd timer)"
    elif launchctl list 2>/dev/null | grep -q "com.skillrunner.daemon"; then
        echo "Daemon: RUNNING (LaunchAgent)"
    else
        echo "Daemon: STOPPED"
    fi

    if [[ -f "${SKILLRUNNER_HOME}/state.json" ]]; then
        echo "Last wake: $(jq -r '.last_wake // "never"' "${SKILLRUNNER_HOME}/state.json")"
    fi

    if [[ -f "$CONFIG_FILE" ]]; then
        local sched_count proj_count
        sched_count=$(jq '.schedules | length' "$CONFIG_FILE")
        proj_count=$(jq '.projects | length' "$CONFIG_FILE")
        echo "Projects: ${proj_count}"
        echo "Schedules: ${sched_count}"
    fi

    if [[ -f "${SKILLRUNNER_HOME}/logs/runs.jsonl" ]]; then
        echo ""
        echo "Last 5 runs:"
        tail -5 "${SKILLRUNNER_HOME}/logs/runs.jsonl" | \
            jq -r '"  \(.started_at) | \(.skill) | \(.status) | \(.duration_seconds)s | $\(.cost_usd)"'
    fi
}

cmd_list() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "No schedules configured."
        exit 0
    fi
    jq -r '.schedules[] |
        "\(.id)\t\(.skill)\t\(.cron)\t\(.human_schedule // "")\t\(.enabled)\t\(.project_path)"
    ' "$CONFIG_FILE" | column -t -s $'\t' -N "ID,Skill,Cron,Schedule,Enabled,Project"
}

case "${1:-help}" in
    register)   cmd_register "${2:-}" ;;
    unregister) cmd_unregister "${2:-}" ;;
    status)     cmd_status ;;
    list)       cmd_list ;;
    *)
        echo "Usage: skillrunner-ctl {register|unregister|status|list} [path]"
        exit 1
        ;;
esac
```

---

## Library Functions

### `lib/cron-parse.sh` — Cron Expression Evaluator

```bash
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
```

### `lib/lock.sh` — Atomic Directory-Based Locking

Uses `mkdir` instead of file check-then-write, which is atomic on POSIX systems.

```bash
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
```

### `lib/logging.sh` — Log Writing with Rotation

```bash
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
```

### `lib/notify.sh` — Telegram Notification Dispatch

```bash
#!/usr/bin/env bash

SKILLRUNNER_HOME="${XDG_CONFIG_HOME:-${HOME}/.config}/skillrunner"
SECRETS_FILE="${SKILLRUNNER_HOME}/secrets.env"

# Load bot token
_load_telegram_token() {
    if [[ -f "$SECRETS_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$SECRETS_FILE"
    fi
    echo "${SKILLRUNNER_TELEGRAM_TOKEN:-}"
}

# send_telegram "chat_id" "message_text"
# Sends a Markdown-formatted message via Telegram Bot API.
send_telegram() {
    local chat_id="$1" text="$2"
    local token
    token=$(_load_telegram_token)

    if [[ -z "$token" ]]; then
        log_daemon "NOTIFY: No Telegram token configured, skipping"
        return 1
    fi

    local response http_code
    response=$(curl -s -w "\n%{http_code}" -X POST \
        "https://api.telegram.org/bot${token}/sendMessage" \
        -d chat_id="$chat_id" \
        -d parse_mode="Markdown" \
        -d text="$text" \
        -d disable_web_page_preview="true")

    http_code=$(echo "$response" | tail -1)

    if [[ "$http_code" != "200" ]]; then
        log_daemon "NOTIFY: Telegram API returned HTTP ${http_code}"
        return 1
    fi

    return 0
}

# expand_template "template_string" — replaces ${var} with values from
# the environment variables set by the caller.
expand_template() {
    local tmpl="$1"
    tmpl="${tmpl//\$\{name\}/$notify_skill}"
    tmpl="${tmpl//\$\{status\}/$notify_status}"
    tmpl="${tmpl//\$\{exit_code\}/$notify_exit_code}"
    tmpl="${tmpl//\$\{duration\}/$notify_duration}"
    tmpl="${tmpl//\$\{cost\}/$notify_cost}"
    tmpl="${tmpl//\$\{attempts\}/$notify_attempts}"
    tmpl="${tmpl//\$\{max_attempts\}/$notify_max_attempts}"
    tmpl="${tmpl//\$\{project_path\}/$notify_project_path}"
    tmpl="${tmpl//\$\{result_preview\}/$notify_result_preview}"
    tmpl="${tmpl//\$\{timestamp\}/$notify_timestamp}"
    echo "$tmpl"
}

# default_template — returns a simple status message.
default_template() {
    local emoji="✅"
    [[ "$notify_status" == "failure" ]] && emoji="❌"
    echo "${emoji} *${notify_skill}* ${notify_status} (${notify_duration}s, \$${notify_cost})"
}

# generate_summary "summary_prompt" "result_text" — calls Claude to
# produce a phone-friendly notification message.
generate_summary() {
    local summary_prompt="$1" result_text="$2"

    local summary_output
    summary_output=$(claude -p \
        --output-format json \
        --permission-mode plan \
        --max-budget-usd 0.05 \
        --no-session-persistence \
        "You are generating a Telegram notification message. ${summary_prompt}

Format the response for mobile reading using Telegram Markdown:
- Use *bold* for emphasis
- Keep it concise (under 500 characters)
- Do not include backticks or code blocks

Skill output to summarize:
${result_text}" 2>/dev/null)

    # Extract result from JSON response
    local summary
    summary=$(echo "$summary_output" | jq -r '.result // ""' 2>/dev/null)

    if [[ -z "$summary" ]]; then
        # Fallback to default template if summary generation fails
        default_template
        return
    fi

    echo "$summary"
}

# dispatch_notification — main entry point. Called by skillrunner-run
# after a skill completes. Reads the notification config from the
# schedule JSON and sends the appropriate message.
#
# Arguments: schedule_json, status, exit_code, duration, cost,
#            attempts, max_attempts, result_text, timestamp
dispatch_notification() {
    local schedule_json="$1"

    # Check if notification is configured
    local has_notification
    has_notification=$(echo "$schedule_json" | jq -e '.notification' 2>/dev/null) || return 0

    local chat_id when mode template summary_prompt
    chat_id=$(echo "$schedule_json" | jq -r '.notification.chat_id')
    when=$(echo "$schedule_json" | jq -r '.notification.when // "always"')
    mode=$(echo "$schedule_json" | jq -r '.notification.mode // "template"')
    template=$(echo "$schedule_json" | jq -r '.notification.template // ""')
    summary_prompt=$(echo "$schedule_json" | jq -r '.notification.summary_prompt // ""')

    # Evaluate "when" condition
    case "$when" in
        always) ;;
        on_failure)
            [[ "$notify_status" != "failure" ]] && return 0
            ;;
        on_result)
            [[ -z "$notify_result_preview" ]] && return 0
            ;;
        *)
            log_daemon "NOTIFY: Unknown when condition '${when}', skipping"
            return 0
            ;;
    esac

    # Generate message based on mode
    local message
    case "$mode" in
        template)
            if [[ -n "$template" ]]; then
                message=$(expand_template "$template")
            else
                message=$(default_template)
            fi
            ;;
        summary)
            if [[ -z "$summary_prompt" ]]; then
                log_daemon "NOTIFY: summary mode requires summary_prompt, falling back to template"
                message=$(default_template)
            else
                log_daemon "NOTIFY: Generating summary via Claude"
                message=$(generate_summary "$summary_prompt" "$notify_result_preview")
            fi
            ;;
        *)
            log_daemon "NOTIFY: Unknown mode '${mode}', skipping"
            return 0
            ;;
    esac

    # Send it
    log_daemon "NOTIFY: Sending to chat ${chat_id} (mode=${mode})"
    if send_telegram "$chat_id" "$message"; then
        log_daemon "NOTIFY: Sent successfully"
    else
        log_daemon "NOTIFY: Failed to send"
    fi
}
```

### `lib/schedule.sh` — Schedule Helpers

```bash
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
```

---

## Skill Definition (`SKILL.md`)

There are two skills: `/schedule` for managing schedules, and `/schedule-setup` for
helping users set up a new project with SkillRunner.

### `SKILL.md` (the `/schedule` skill)

```markdown
---
name: schedule
description: >
  Manage scheduled automatic execution of Claude Code skills and bash commands.
  Register projects, add/remove schedules, view logs and daemon status.
user-invocable: true
argument-hint: "register|unregister|add|list|remove|logs|status|enable|disable|notify-setup"
allowed-tools: Read, Bash, Glob, Grep
---

# SkillRunner — Scheduled Skill Execution

You are managing scheduled automatic execution of Claude Code skills and bash
commands. The user wants to set up tasks to run on a recurring schedule via a
background daemon.

## Data Locations

- Global config: `~/.config/skillrunner/config.json`
- Run logs: `~/.config/skillrunner/logs/runs.jsonl`
- Daemon log: `~/.config/skillrunner/logs/runner.log`
- Daemon state: `~/.config/skillrunner/state.json`
- Per-project config: `.skillrunner.json` in project root
- Secrets: `~/.config/skillrunner/secrets.env`

## Schedule Types

Each schedule has a `type` field:
- `"skill"` — runs a Claude Code skill via `claude -p "/<skill> <args>"` (costs API credits)
- `"command"` — runs a bash command directly (free, no Claude involved)

## Commands

### /schedule register [path]
Register a project directory with SkillRunner. Reads `.skillrunner.json` from
the project root (defaults to cwd) and adds its schedules to the global config.
Run: `skillrunner-ctl register [path]`

### /schedule unregister [path]
Remove all schedules for a project. Run: `skillrunner-ctl unregister [path]`

### /schedule add
Interactively create a schedule. First ask:
1. **Type** — skill or command?

If skill:
2. **Skill name** — which slash command to run (e.g., `concert-search`)
3. **Arguments** (optional)
4. **Permission mode** (optional) — `plan` (default), `acceptEdits`, `bypassPermissions`
5. **Budget per run** (optional) — default $0.50

If command:
2. **Command** — the bash command to run (e.g., `./scripts/backup.sh`)

Then for both:
- **Schedule** — cron expression or natural language ("daily at 9am")
- **Timeout** (optional) — default 300s
- **Retry** (optional) — max attempts and delay

Then notification (optional):
- **Notify?** — whether to send Telegram notifications (default: no)
- **Chat ID** — who to notify
- **When** — always / on_failure / on_result
- **Mode** — template (free) or summary (costs ~$0.01-0.05 per notification)
- **Template** (if template mode) — custom template or use default
- **Summary prompt** (if summary mode) — what to tell Claude about summarizing

Convert natural language to cron. Write to `.skillrunner.json` in the current
project, then re-register with `skillrunner-ctl register`.

### /schedule list
Run `skillrunner-ctl list` and display all schedules.

### /schedule remove
Show the list, ask which to remove by ID or name. Remove from
`.skillrunner.json` and re-register.

### /schedule logs [--name NAME] [--last N]
Read `~/.config/skillrunner/logs/runs.jsonl` and display. Default: last 10 runs.
Show: timestamp, type, name, duration, exit code, cost, truncated output.

### /schedule status
Run `skillrunner-ctl status`.

### /schedule enable / disable
Toggle `enabled` on a schedule in `.skillrunner.json` and re-register.

### /schedule notify-setup
Guide the user through Telegram notification setup:
1. Explain how to create a bot via @BotFather on Telegram
2. Ask for the bot token
3. Write it to `~/.config/skillrunner/secrets.env`
4. Help them find their chat_id (tell them to message the bot, then
   fetch `https://api.telegram.org/bot<TOKEN>/getUpdates` via curl)
5. For group notifications: explain adding the bot to a group
6. Send a test message to verify the setup works

## Installation Check
Before any command, verify skillrunner-ctl is on PATH. If not, tell the user
to add the SkillRunner home-manager module to their nix config:
  services.skillrunner.enable = true;
```

### `SETUP_SKILL.md` (the `/schedule-setup` skill)

This is a separate skill for helping users set up a new project with SkillRunner.
It lives alongside `SKILL.md` in the skill directory.

```markdown
---
name: schedule-setup
description: >
  Set up a project to use SkillRunner. Helps decide between bash commands
  and Claude skills, creates .skillrunner.json, and registers the project.
user-invocable: true
argument-hint: ""
allowed-tools: Read, Write, Bash, Glob, Grep, Edit
---

# SkillRunner Project Setup

You are helping the user set up a new project to use SkillRunner — a daemon
that runs Claude Code skills and bash commands on a schedule.

## Your Job

Walk the user through setting up `.skillrunner.json` in their project. This
involves understanding what they want to automate and helping them decide the
best approach for each task.

## Setup Flow

### Step 1: Understand the project
- Look at the current directory to understand what kind of project this is
- Read any existing README, CLAUDE.md, or project config files
- Ask the user what tasks they want to run on a schedule

### Step 2: For each task, help decide: skill vs command

Guide the user with these criteria:

**Use a bash command (`"type": "command"`) when:**
- The task is deterministic and well-defined (run a script, pull git, ping a URL)
- No AI reasoning is needed
- There's an existing script or CLI tool that does the job
- Cost matters — commands are free, skills cost API credits
- The task is simple enough to express as a one-liner or script
- Examples: `git pull && git status`, `./scripts/deploy.sh`, `curl -s https://example.com/health`, `df -h | mail -s "Disk report" user@example.com`

**Use a Claude skill (`"type": "skill"`) when:**
- The task requires reading and understanding code or documents
- The task needs AI judgment (e.g., "are there any security issues?")
- The output needs to be summarized or interpreted
- The task involves searching, analyzing, or generating content
- The task would be hard to express as a bash script
- Examples: code review, dependency audit, content generation, log analysis, research tasks

**Hybrid approach:** Sometimes the best solution is a bash command that
gathers data (free) paired with a skill schedule that analyzes it (paid).
For example: a command that runs `npm audit --json > /tmp/audit.json` every
hour, and a daily skill that reads that file and summarizes findings.

### Step 3: For each task, gather details
- Schedule (natural language is fine, you'll convert to cron)
- For commands: help write the command or script if needed
- For skills: check if the skill exists in `~/.claude/skills/` or the
  project's `.claude/skills/`, offer to help create it if not
- Timeout and retry settings
- Notification preferences (if they've set up Telegram)

### Step 4: Create .skillrunner.json
Write the config file to the project root.

### Step 5: Register
Run `skillrunner-ctl register` to activate the schedules.

### Step 6: Verify
Run `skillrunner-ctl status` and `skillrunner-ctl list` to confirm
everything is registered correctly.

## Important Notes

- Commands run from the project root directory
- Commands run as the user's shell (bash), with the project root as cwd
- Skills run via `claude -p` in the project directory
- If the user needs a script that doesn't exist yet, help them write it
  and save it in the project (e.g., `scripts/check-health.sh`)
- Always make scripts executable (`chmod +x`)
- If the user needs a Claude skill that doesn't exist, help them create
  it in `.claude/skills/` with a proper SKILL.md
- Remind the user to commit `.skillrunner.json` and any new scripts to git
```

---

## Platform Support

| Feature | NixOS / Linux | macOS |
|---|---|---|
| Service manager | systemd user timer | LaunchAgent |
| Bash | 5.x from nixpkgs | 5.x from nixpkgs (via nix wrapper) |
| `timeout` | coreutils from nixpkgs | coreutils from nixpkgs |
| `jq` | from nixpkgs | from nixpkgs |
| `stat` file size | `stat -c%s` | `stat -f%z` (both handled) |
| `date` epoch conversion | `date -d @epoch` | `date -r epoch` (both handled) |
| Sleep/wake catch-up | systemd `Persistent=true` | LaunchAgent fires on wake |
| Install method | `services.skillrunner.enable = true` | same (home-manager) |

All platform differences are handled either by Nix (wrapping with correct tools on PATH) or by portable bash with GNU/BSD fallbacks.

---

## Logging and Rotation

| File | Max Size | Rotation |
|---|---|---|
| `runner.log` | 5 MB | Rotate to `.1`, keep 1 copy |
| `runs.jsonl` | 10 MB | Rotate to `.1`, keep 1 copy |
| `output/*.stdout` | 100 KB each | Truncated at write time |
| `output/*.stderr` | 100 KB each | Truncated at write time |
| Output files > 30 days | — | Deleted by daemon hourly cleanup |

---

## Error Handling

- **Claude not on PATH:** Daemon logs error and exits cleanly.
- **Auth failures:** Captured in stderr, surfaced via `/schedule logs`.
- **Skill not found:** Claude returns `is_error: true` in JSON, logged as failure.
- **Overlapping runs:** Atomic `mkdir`-based locks prevent concurrent execution of same schedule.
- **Timeouts:** `timeout` from coreutils, exit code 124 logged distinctly.
- **Sleep/wake:** systemd `Persistent=true` / LaunchAgent catch-up behavior.
- **Low disk space:** Daemon checks for 100MB minimum before running.
- **Stale locks:** PID checked with `kill -0`, cleaned up automatically.
- **Telegram failures:** If notification send fails (bad token, network error), logged but does not affect the run's success/failure status. The skill run is independent of notification delivery.
- **Summary generation failures:** If the Claude call for summary mode fails, falls back to the default template so a notification is still sent.

---

## Security

1. **Default permission mode is `plan`** (read-only). Skills can't write files or run commands unless explicitly configured per-schedule.
2. **Budget caps** via `--max-budget-usd` per run.
3. **No secrets in config.** Claude auth is handled by its own CLI.
4. **Locks prevent runaway execution.**
5. **Output truncation** prevents disk exhaustion.
6. **Secrets isolation.** Telegram bot token lives in `secrets.env` (chmod 600), not in `.skillrunner.json` which is version-controlled. The token never appears in logs or run output.

---

## Step-by-Step Implementation Guide

### Phase 1: Foundation
- Create directory structure and `flake.nix`
- Implement `lib/cron-parse.sh` with tests
- Implement `lib/lock.sh` (atomic mkdir-based)
- Implement `lib/logging.sh` with rotation for both log files
- Implement `lib/schedule.sh` with `next_run_time` and `sync_projects`

### Phase 2: Daemon Core
- Implement `bin/skillrunner-run` (single-run executor)
- Implement `bin/skillrunner-daemon` (wake-and-check)
- Test manually with a `*/1 * * * *` schedule

### Phase 3: Project Registration
- Implement `bin/skillrunner-ctl` with register/unregister/status/list
- Define `.skillrunner.json` schema
- Test register → daemon picks it up → skill runs

### Phase 4: Nix Packaging
- Complete `flake.nix` with `makeWrapper` for all dependencies
- Write `module/home-manager.nix` with systemd + launchd support
- Test on NixOS: add to flake, `home-manager switch`, verify timer runs
- Test on macOS: same flow, verify LaunchAgent

### Phase 5: Claude Code Skills
- Write `SKILL.md` for `/schedule` — management commands
- Write `SETUP_SKILL.md` for `/schedule-setup` — project setup wizard
- Test `/schedule add` with both skill and command types
- Test `/schedule-setup` end-to-end: understand project, recommend skill vs command, create `.skillrunner.json`, register
- Ensure `/schedule add` writes to `.skillrunner.json` and re-registers

### Phase 6: Telegram Notifications
- Implement `lib/notify.sh` with template expansion, summary generation, and Telegram sending
- Integrate `dispatch_notification` into `skillrunner-run`
- Add `notify-setup` command to the `/schedule` skill
- Test template mode (verify variable expansion, default template)
- Test summary mode (verify Claude call, Markdown formatting, fallback on failure)
- Test `when` conditions (always, on_failure, on_result)
- Test with personal chat_id and group chat_id
- Verify secrets.env is created with correct permissions (600)

### Phase 7: Hardening
- Disk space checks
- Auth error detection
- `runs.jsonl` rotation
- 30-day output cleanup
- Stress test: 5+ schedules at same minute

---

## Dependencies (all provided by Nix)

| Dependency | Purpose |
|---|---|
| `bash` 5.x | Script execution |
| `jq` | JSON parsing |
| `coreutils` | `timeout`, `stat`, `truncate`, `date` |
| `openssl` | Random ID generation |
| `curl` | Telegram API calls |
| `claude-code` | Skill execution (expected on user's PATH via their own nix config) |

Note: `claude-code` is NOT bundled by SkillRunner's flake — it's expected to be installed separately (as you already have in `claude.nix`). The daemon just needs `claude` to be on PATH.

---

## Future Enhancements

- **Desktop notifications:** In addition to Telegram, `notify-send` (Linux) or `osascript` (macOS) for local desktop alerts
- **Additional notification channels:** Discord webhooks, ntfy.sh, email — as alternative backends behind the same `notification` config schema
- **Conditional scheduling:** Run only if a previous skill's output matches a pattern (pipeline chaining)
- **NixOS system module:** In addition to home-manager, a NixOS system-level module for running schedules as a system service
- **`flake.nix` template:** `nix flake init -t skillrunner` to scaffold a new project with `.skillrunner.json`
- **Cost dashboard:** Aggregate notification + skill costs per schedule, per day, per month
