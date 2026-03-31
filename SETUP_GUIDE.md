# SkillRunner Project Setup Guide

Reference document for setting up a new project with SkillRunner.

## Setup Flow

### Step 1: Understand the project
- Look at the current directory to understand what kind of project this is
- Read any existing README, CLAUDE.md, or project config files
- Ask the user what tasks they want to run on a schedule

### Step 2: For each task, help decide: skill vs command

**Use a bash command (`"type": "command"`) when:**
- The task is deterministic and well-defined (run a script, pull git, ping a URL)
- No AI reasoning is needed
- There's an existing script or CLI tool that does the job
- Cost matters — commands are free, skills cost API credits
- Examples: `git pull && git status`, `./scripts/deploy.sh`, `curl -s https://example.com/health`

**Use a Claude skill (`"type": "skill"`) when:**
- The task requires reading and understanding code or documents
- The task needs AI judgment (e.g., "are there any security issues?")
- The output needs to be summarized or interpreted
- The task involves searching, analyzing, or generating content
- Examples: code review, dependency audit, content generation, log analysis

**Hybrid approach:** A bash command gathers data (free) paired with a skill
that analyzes it (paid). For example: a command runs `npm audit --json > /tmp/audit.json`
every hour, and a daily skill reads that file and summarizes findings.

### Step 3: For each task, gather details
- Schedule (natural language is fine, convert to cron)
- For commands: help write the command or script if needed
- For skills: determine where the skill comes from (see Skill Sources below)
- Timeout and retry settings
- Notification preferences

### Step 4: Create .skillrunner.json
Write the config file to the project root.

### Step 5: Register and verify
Run `skillrunner-ctl register` then `skillrunner-ctl status` and
`skillrunner-ctl list` to confirm everything is registered.

## Skill Sources

When a schedule uses `"type": "skill"`, the skill must be available in
`.claude/skills/<name>/SKILL.md` (project-local) or `~/.claude/skills/<name>/SKILL.md`
(global). Three options:

### A) Create a new skill for this project

1. Create `.claude/skills/<skill-name>/SKILL.md` with frontmatter:
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
2. Remind the user to commit the skill to git

### B) Install a skill from a GitHub repo

Add it to the `skills` array in `.skillrunner.json`:
```json
{
  "skills": [
    {
      "name": "concert-search",
      "git": "https://github.com/someone/concert-search-skill.git",
      "ref": "main"
    }
  ]
}
```

`skillrunner-ctl register` will clone/update each skill into `.claude/skills/<name>/`.
The repo must have a `SKILL.md` at its root. For private repos, use SSH URLs.

Add git-managed skill directories to `.gitignore`:
```
.claude/skills/<skill-name>/
```

### C) Use an existing global skill

If already installed in `~/.claude/skills/`, no config needed.
Check with: `ls ~/.claude/skills/`

## Notification Setup

### Telegram
1. Create a bot via @BotFather on Telegram — send `/newbot`
2. Copy the bot token (format: `123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11`)
3. Write to `~/.config/skillrunner/secrets.env`:
   ```
   SKILLRUNNER_TELEGRAM_TOKEN=<token>
   ```
4. `chmod 600 ~/.config/skillrunner/secrets.env`
5. Find chat_id: message the bot, then:
   `curl -s "https://api.telegram.org/bot<TOKEN>/getUpdates" | jq '.result[0].message.chat.id'`
6. For groups: add the bot, send a message, fetch getUpdates for the negative group chat_id
7. Send a test message to verify

### Discord
1. Server Settings > Integrations > Webhooks > New Webhook
2. Choose channel, copy webhook URL
3. URL goes directly in schedule config (no secrets.env needed)
4. Test: `curl -H "Content-Type: application/json" -d '{"content":"Test from SkillRunner"}' <WEBHOOK_URL>`

## Important Notes

- Commands run from the project root directory as the user's shell (bash)
- Skills run via `claude -p` in the project directory
- If the user needs a script, help write it and save in the project (e.g., `scripts/check-health.sh`)
- Always make scripts executable (`chmod +x`)
- Remind the user to commit `.skillrunner.json`, scripts, and locally-created skills to git
