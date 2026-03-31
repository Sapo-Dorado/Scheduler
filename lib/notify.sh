#!/usr/bin/env bash

SKILLRUNNER_HOME="${XDG_CONFIG_HOME:-${HOME}/.config}/skillrunner"
SECRETS_FILE="${SKILLRUNNER_HOME}/secrets.env"

# Load secrets from secrets.env
_load_secrets() {
    if [[ -f "$SECRETS_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$SECRETS_FILE"
    fi
}

# send_telegram "chat_id" "message_text"
# Sends a Markdown-formatted message via Telegram Bot API.
send_telegram() {
    local chat_id="$1" text="$2"
    _load_secrets
    local token="${SKILLRUNNER_TELEGRAM_TOKEN:-}"

    if [[ -z "$token" ]]; then
        log_daemon "NOTIFY: No Telegram token configured, skipping"
        return 1
    fi

    local response http_code
    response=$(curl -s -w "\n%{http_code}" -X POST \
        "https://api.telegram.org/bot${token}/sendMessage" \
        --data-urlencode "chat_id=$chat_id" \
        --data-urlencode "parse_mode=Markdown" \
        --data-urlencode "text=$text" \
        --data-urlencode "disable_web_page_preview=true")

    http_code=$(echo "$response" | tail -1)

    if [[ "$http_code" != "200" ]]; then
        log_daemon "NOTIFY: Telegram API returned HTTP ${http_code}"
        return 1
    fi

    return 0
}

# send_discord "webhook_url" "message_text"
# Sends a message via Discord webhook.
send_discord() {
    local webhook_url="$1" text="$2"

    if [[ -z "$webhook_url" ]]; then
        log_daemon "NOTIFY: No Discord webhook URL configured, skipping"
        return 1
    fi

    # Discord webhook expects JSON with a "content" field (max 2000 chars)
    local payload
    payload=$(jq -cn --arg content "${text:0:2000}" '{content: $content}')

    local response http_code
    response=$(curl -s -w "\n%{http_code}" -X POST \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "$webhook_url")

    http_code=$(echo "$response" | tail -1)

    # Discord returns 204 on success
    if [[ "$http_code" != "204" && "$http_code" != "200" ]]; then
        log_daemon "NOTIFY: Discord webhook returned HTTP ${http_code}"
        return 1
    fi

    return 0
}

# expand_template "template_string" — replaces ${var} with values from
# the environment variables set by the caller.
expand_template() {
    local tmpl="$1"
    # Build a jq filter to safely replace all template variables.
    # jq's gsub handles special characters correctly.
    tmpl=$(printf '%s' "$tmpl" | jq -Rrs \
        --arg name "$notify_skill" \
        --arg status "$notify_status" \
        --arg exit_code "$notify_exit_code" \
        --arg duration "$notify_duration" \
        --arg cost "$notify_cost" \
        --arg attempts "$notify_attempts" \
        --arg max_attempts "$notify_max_attempts" \
        --arg project_path "$notify_project_path" \
        --arg result_preview "$notify_result_preview" \
        --arg timestamp "$notify_timestamp" \
        'gsub("\\$\\{name\\}"; $name)
         | gsub("\\$\\{status\\}"; $status)
         | gsub("\\$\\{exit_code\\}"; $exit_code)
         | gsub("\\$\\{duration\\}"; $duration)
         | gsub("\\$\\{cost\\}"; $cost)
         | gsub("\\$\\{attempts\\}"; $attempts)
         | gsub("\\$\\{max_attempts\\}"; $max_attempts)
         | gsub("\\$\\{project_path\\}"; $project_path)
         | gsub("\\$\\{result_preview\\}"; $result_preview)
         | gsub("\\$\\{timestamp\\}"; $timestamp)')
    echo "$tmpl"
}

# default_template — returns a simple status message.
default_template() {
    local emoji="✅"
    [[ "$notify_status" == "failure" ]] && emoji="❌"
    echo "${emoji} *${notify_skill}* ${notify_status} (${notify_duration}s, \$${notify_cost})"
}

# generate_summary "summary_prompt" "result_text" "service" — calls Claude to
# produce a phone-friendly notification message.
generate_summary() {
    local summary_prompt="$1" result_text="$2" service="${3:-telegram}"

    local format_instructions
    if [[ "$service" == "discord" ]]; then
        format_instructions="Format the response for mobile reading using Discord Markdown:
- Use **bold** for emphasis
- Keep it concise (under 500 characters)
- Do not include code blocks"
    else
        format_instructions="Format the response for mobile reading using Telegram Markdown:
- Use *bold* for emphasis
- Keep it concise (under 500 characters)
- Do not include backticks or code blocks"
    fi

    local summary_output
    summary_output=$(claude -p \
        --output-format json \
        --permission-mode plan \
        --max-budget-usd 0.05 \
        --no-session-persistence \
        "You are generating a notification message. ${summary_prompt}

${format_instructions}

Skill output to summarize:
${result_text}" 2>/dev/null)

    # Extract result from JSON response
    local summary
    summary=$(echo "$summary_output" | jq -r '.result // ""' 2>/dev/null)

    if [[ -z "$summary" ]]; then
        log_daemon "NOTIFY: Summary generation failed (empty result from Claude), falling back to default template"
        default_template
        return
    fi

    echo "$summary"
}

# _send_notification "service" "destination" "message"
# Routes a message to the appropriate service.
# For telegram: destination is a chat_id
# For discord: destination is a webhook_url
_send_notification() {
    local service="$1" destination="$2" message="$3"
    case "$service" in
        discord)
            send_discord "$destination" "$message"
            ;;
        *)
            send_telegram "$destination" "$message"
            ;;
    esac
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

    local service when mode template summary_prompt destination
    service=$(echo "$schedule_json" | jq -r '.notification.service // "telegram"')
    when=$(echo "$schedule_json" | jq -r '.notification.when // "always"')
    mode=$(echo "$schedule_json" | jq -r '.notification.mode // "template"')
    template=$(echo "$schedule_json" | jq -r '.notification.template // ""')
    summary_prompt=$(echo "$schedule_json" | jq -r '.notification.summary_prompt // ""')

    # Resolve destination based on service
    if [[ "$service" == "discord" ]]; then
        destination=$(echo "$schedule_json" | jq -r '.notification.webhook_url')
    else
        destination=$(echo "$schedule_json" | jq -r '.notification.chat_id')
    fi

    # Always send a simple alert on failure, regardless of "when" config
    if [[ "$notify_status" == "failure" ]]; then
        local bold_l="*" bold_r="*"
        [[ "$service" == "discord" ]] && bold_l="**" && bold_r="**"
        local fail_msg="❌ ${bold_l}${notify_skill}${bold_r} failed (exit ${notify_exit_code}, ${notify_duration}s, ${notify_attempts}/${notify_max_attempts} attempts)"
        log_daemon "NOTIFY: Sending failure alert via ${service}"
        if _send_notification "$service" "$destination" "$fail_msg"; then
            log_daemon "NOTIFY: Failure alert sent"
        else
            log_daemon "NOTIFY: Failed to send failure alert"
        fi
        return 0
    fi

    # Evaluate "when" condition (only applies to successful runs)
    case "$when" in
        always) ;;
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
                message=$(generate_summary "$summary_prompt" "$notify_result_full" "$service")
            fi
            ;;
        *)
            log_daemon "NOTIFY: Unknown mode '${mode}', skipping"
            return 0
            ;;
    esac

    # Send it
    log_daemon "NOTIFY: Sending via ${service} (mode=${mode})"
    if _send_notification "$service" "$destination" "$message"; then
        log_daemon "NOTIFY: Sent successfully"
    else
        log_daemon "NOTIFY: Failed to send"
    fi
}
