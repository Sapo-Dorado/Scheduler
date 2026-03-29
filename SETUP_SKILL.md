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
