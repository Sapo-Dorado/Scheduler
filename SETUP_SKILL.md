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
- For skills: determine where the skill comes from (see Skill Management below)
- Timeout and retry settings
- Notification preferences (see Notification Setup below)

### Skill Management

When a schedule uses `"type": "skill"`, the skill must be available in
`.claude/skills/<name>/SKILL.md` (project-local) or `~/.claude/skills/<name>/SKILL.md`
(global). There are three ways to set up a skill:

#### A) Create a new skill for this project

If the user needs a custom skill that doesn't exist yet:

1. Create the directory: `.claude/skills/<skill-name>/`
2. Write a `SKILL.md` with proper frontmatter:
   ```markdown
   ---
   name: <skill-name>
   description: >
     What this skill does, in one or two sentences.
   user-invocable: true
   argument-hint: "<expected arguments>"
   allowed-tools: Read, Bash, Glob, Grep
   ---

   # Skill Title

   Instructions for Claude on how to execute this skill...
   ```
3. Remind the user to commit `.claude/skills/<skill-name>/SKILL.md` to git

#### B) Install a skill from a GitHub repo

If the skill is published in a git repository, add it to the `skills`
array in `.skillrunner.json`:

```json
{
  "version": 1,
  "skills": [
    {
      "name": "concert-search",
      "git": "https://github.com/someone/concert-search-skill.git",
      "ref": "main"
    }
  ],
  "schedules": [...]
}
```

When the user runs `skillrunner-ctl register`, it will automatically
clone or update each skill dependency into `.claude/skills/<name>/`.

- `name` — the skill name (becomes the directory name and slash command)
- `git` — the git clone URL (HTTPS or SSH)
- `ref` — branch, tag, or commit hash (default: `main`)

The cloned repo must have a `SKILL.md` at its root.

Ask the user if the skill repo is public or if they need SSH access.
For private repos, SSH URLs (e.g. `git@github.com:org/skill.git`) work
if the user has SSH keys configured.

**Important:** Add `.claude/skills/` entries installed via git to
`.gitignore` so cloned skill repos aren't committed into the project:
```
# Git-managed skills (installed by skillrunner)
.claude/skills/<skill-name>/
```

#### C) Use an existing global skill

If the skill is already installed globally in `~/.claude/skills/`, no
config is needed — Claude will find it automatically when the daemon
runs from the project directory.

Help the user check: `ls ~/.claude/skills/` to see what's available.

### Notification Setup

Ask the user if they want notifications for their schedules. If yes, help
them set up one or both services:

#### Telegram
1. Create a bot via @BotFather on Telegram — send `/newbot` and follow prompts
2. Copy the bot token (format: `123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11`)
3. Write it to `~/.config/skillrunner/secrets.env`:
   ```
   SKILLRUNNER_TELEGRAM_TOKEN=<token>
   ```
4. Ensure the file is private: `chmod 600 ~/.config/skillrunner/secrets.env`
5. Find the chat_id: have the user message the bot, then fetch:
   `curl -s "https://api.telegram.org/bot<TOKEN>/getUpdates" | jq '.result[0].message.chat.id'`
6. For group notifications: add the bot to the group, send a message in the
   group, then fetch getUpdates to find the negative group chat_id
7. Send a test message to verify

#### Discord
1. In Discord: Server Settings > Integrations > Webhooks > New Webhook
2. Choose the channel, copy the webhook URL
3. The URL goes directly in the schedule config (no secrets.env needed)
4. Test with: `curl -H "Content-Type: application/json" -d '{"content":"Test from SkillRunner"}' <WEBHOOK_URL>`

#### Multiple destinations
Schedules can notify multiple places at once using the `destinations` array:
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

For a single destination, the flat format also works:
```json
"notification": { "service": "telegram", "chat_id": "123", "when": "always" }
```

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
  it in `.claude/skills/<name>/SKILL.md` with proper frontmatter
- For skills from GitHub repos, add them to the `skills` array in
  `.skillrunner.json` — they'll be cloned on `skillrunner-ctl register`
- Add git-managed skill directories to `.gitignore`
- Remind the user to commit `.skillrunner.json`, any new scripts, and
  any locally-created skills to git
