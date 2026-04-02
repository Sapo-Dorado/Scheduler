---
name: schedule
description: >
  Manage scheduled automatic execution of Claude Code skills and bash commands.
  Register projects, add/remove schedules, view logs and daemon status.
user-invocable: true
argument-hint: "register|unregister|add|list|remove|run|logs|status|enable|disable|notify-setup|discord-setup"
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

## Skill Dependencies

`.skillrunner.json` can declare skill dependencies via the `skills` array:
```json
{
  "skills": [
    {"name": "my-skill", "git": "https://github.com/user/skill-repo.git", "ref": "main"}
  ],
  "schedules": [...]
}
```
When registering, `skillrunner-ctl register` clones/updates each skill
into `.claude/skills/<name>/`. The skill repo must have a `SKILL.md` at its root.

## Commands

### /schedule setup
Walk the user through setting up a new project with SkillRunner. Read the
`SETUP_GUIDE.md` file in this skill's directory for the full setup flow,
including how to decide between skills vs commands, skill sources, notification
setup, and creating `.skillrunner.json`.
Run: read `SETUP_GUIDE.md` from this skill's base directory, then follow its steps.

### /schedule register [path]
Register a project directory with SkillRunner. Reads `.skillrunner.json` from
the project root (defaults to cwd), adds its schedules to the global config,
and clones/updates any skill dependencies declared in the `skills` array.
Run: `skillrunner-ctl register [path]`

### /schedule unregister [path]
Remove all schedules for a project. Run: `skillrunner-ctl unregister [path]`

### /schedule add
Interactively create a schedule. First ask:
1. **Type** — skill or command?

If skill:
2. **Skill name** — which slash command to run (e.g., `concert-search`)
3. **Arguments** (optional)
4. **Chrome** — does this skill need Chrome browser? (default: no). If yes, set `"chrome": true`.
   - **Important:** Before enabling, check for a graphical display by running:
     `[ -n "$DISPLAY" ] || [ -n "$WAYLAND_DISPLAY" ] || [ "$(uname)" = "Darwin" ] && echo "Display available" || echo "No display"`
   - If no display is available, warn the user: "Chrome skills require a graphical
     desktop session (DISPLAY or WAYLAND_DISPLAY). They will be silently skipped
     when no display is available — e.g., on a headless server or pure SSH session.
     The skill will run normally when a graphical session is active."
   - Chrome skills will automatically launch Google Chrome if it's not already
     running (requires the Claude in Chrome extension to be installed).
5. **Permission mode** (optional) — `plan` (default), `acceptEdits`, `bypassPermissions`
6. **Budget per run** (optional) — default $0.50

If command:
2. **Command** — the bash command to run (e.g., `./scripts/backup.sh`)

Then for both:
- **Schedule** — cron expression or natural language ("daily at 9am")
- **Timeout** (optional) — default 300s
- **Retry** (optional) — max attempts and delay

Then notification (optional):
- **Notify?** — whether to send notifications (default: no)
- **Destinations** — one or more notification targets. Ask how many and for each:
  - **Service** — `telegram` (default) or `discord`
  - If telegram: **Chat ID** — who to notify (requires bot token in secrets.env)
  - If discord: **Webhook URL** — Discord channel webhook URL
- **When** — always / on_failure / on_result
- **Mode** — template (free) or summary (costs ~$0.01-0.05 per notification)
- **Template** (if template mode) — custom template using variables below, or omit for default
- **Summary prompt** (if summary mode) — what to tell Claude about summarizing

#### Template Variables

When using `"mode": "template"`, the following variables are available:

| Variable | Description |
|----------|-------------|
| `${name}` | Schedule name (skill or command name) |
| `${status}` | `"success"` or `"failure"` |
| `${exit_code}` | Exit code (0 = success) |
| `${duration}` | Execution time in seconds |
| `${cost}` | USD cost of API calls (skills only; 0 for commands) |
| `${attempts}` | Current attempt number |
| `${max_attempts}` | Maximum retry attempts configured |
| `${project_path}` | Working directory of the schedule |
| `${result_preview}` | First 4096 characters of command/skill output |
| `${timestamp}` | ISO 8601 completion timestamp |

**Default template** (used when no custom template is provided):
- Success: `✅ *${name}* success (${duration}s, $${cost})`
- Failure: `❌ *${name}* failure (${duration}s, $${cost})`

**Example custom template:**
```json
"template": "🕐 ${result_preview}"
```

**Important:** Only use variables from the table above. Any other `${...}` syntax will be sent literally, not interpolated.

For a single destination, either format works:
```json
"notification": { "service": "telegram", "chat_id": "123", "when": "always" }
```
For multiple destinations, use the `destinations` array:
```json
"notification": {
    "destinations": [
        {"service": "telegram", "chat_id": "123"},
        {"service": "discord", "webhook_url": "https://discord.com/api/webhooks/..."}
    ],
    "when": "always",
    "mode": "template"
}
```

Convert natural language to cron. Write to `.skillrunner.json` in the current
project, then re-register with `skillrunner-ctl register`.

### /schedule run [name or ID]
Manually trigger a schedule immediately. Run `skillrunner-ctl list` to show
available schedules, then run `skillrunner-ctl run <ID>` with the schedule's
ID (the short hex ID from the first column). The run executes in the
background using the same configuration (notifications, retries, etc.) as a
normal scheduled execution. **Always use this instead of invoking the skill
directly** — it ensures logging, notifications, and retries all work correctly.

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

### /schedule discord-setup
Guide the user through Discord webhook notification setup:
1. Explain how to create a webhook in Discord (Server Settings > Integrations > Webhooks)
2. Ask for the webhook URL
3. The webhook URL goes directly in the schedule's `notification.webhook_url` field
   (no secrets.env entry needed — it's per-schedule)
4. Send a test message to verify: `curl -H "Content-Type: application/json" -d '{"content":"Test from SkillRunner"}' <WEBHOOK_URL>`

## Installation Check
Before any command, verify skillrunner-ctl is on PATH. If not, tell the user
to add the SkillRunner home-manager module to their nix config:
  services.skillrunner.enable = true;
