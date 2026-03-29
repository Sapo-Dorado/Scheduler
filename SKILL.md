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
