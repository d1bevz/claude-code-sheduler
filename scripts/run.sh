#!/bin/bash
# run.sh — Cron-triggered reminder executor
# Usage: run.sh <task_id>
# Called by cron for each reminder. Reads task from SQLite, runs claude -p, sends to Telegram.

set -euo pipefail

# Ensure PATH includes common install locations (cron has minimal PATH)
export PATH="$HOME/.local/bin:$HOME/.npm/bin:$HOME/.cargo/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

TASK_ID="${1:?Usage: run.sh <task_id>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"

# Load config (safe parsing, no source)
REMINDERS_DATA_DIR="${REMINDERS_DATA_DIR:-$HOME/.config/claude-reminders}"
if [ -f "$REMINDERS_DATA_DIR/.env" ]; then
    while IFS='=' read -r key value; do
        key=$(echo "$key" | tr -d '[:space:]')
        value=$(echo "$value" | sed 's/^["'\''"]//;s/["'\''"]$//' | tr -d '[:space:]')
        case "$key" in
            REMINDERS_CHAT_ID|REMINDERS_*) export "$key=$value" ;;
        esac
    done < <(grep -E '^[A-Z_]+=.+' "$REMINDERS_DATA_DIR/.env")
fi

CHAT_ID="${REMINDERS_CHAT_ID:?REMINDERS_CHAT_ID not set}"
LOG_DIR="$REMINDERS_DATA_DIR/logs"
mkdir -p "$LOG_DIR"

log() { echo "[$(date -Iseconds)] [task:$TASK_ID] $1" >> "$LOG_DIR/$(date +%Y-%m-%d).log"; }

log "START"

# Read task from DB
TASK_JSON=$(python3 "$SCRIPT_DIR/db.py" get "$TASK_ID" 2>/dev/null) || {
    log "ERROR: task $TASK_ID not found in DB"
    exit 1
}

STATUS=$(echo "$TASK_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['status'])")
if [ "$STATUS" != "active" ]; then
    log "SKIP: status=$STATUS"
    exit 0
fi

PROMPT=$(echo "$TASK_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['prompt'])")
MODEL=$(echo "$TASK_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['model'])")
WORKSPACE=$(echo "$TASK_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['workspace'])")
IS_RECURRING=$(echo "$TASK_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['is_recurring'])")

# Validate workspace path
WORKSPACE=$(realpath -e "$WORKSPACE" 2>/dev/null) || {
    log "ERROR: workspace path does not exist: $WORKSPACE"
    exit 1
}
if [[ "$WORKSPACE" != "$HOME"* ]]; then
    log "ERROR: workspace outside home directory: $WORKSPACE"
    exit 1
fi

# Resolve bot token from workspace (stored in file, read on demand to avoid process list exposure)
BOT_TOKEN_FILE=""
for candidate in "$WORKSPACE/.claude/channels/telegram/.env" "$HOME/.claude/channels/telegram/.env"; do
    if [ -f "$candidate" ] && grep -qP 'TELEGRAM_BOT_TOKEN=' "$candidate" 2>/dev/null; then
        BOT_TOKEN_FILE="$candidate"
        break
    fi
done
if [ -z "$BOT_TOKEN_FILE" ]; then
    log "ERROR: no bot token found"
    python3 "$SCRIPT_DIR/db.py" log "$TASK_ID" --status error --output "Bot token not found" --duration 0
    exit 3
fi

read_bot_token() {
    grep -oP 'TELEGRAM_BOT_TOKEN="\K[^"]+' "$BOT_TOKEN_FILE" 2>/dev/null || \
    grep -oP 'TELEGRAM_BOT_TOKEN=\K.+' "$BOT_TOKEN_FILE" 2>/dev/null
}

# Run claude -p from workspace
log "EXEC: model=$MODEL workspace=$WORKSPACE"
START_MS=$(date +%s%3N)

RESULT=$(cd "$WORKSPACE" && claude -p "$PROMPT" --model "$MODEL" --dangerously-skip-permissions --setting-sources "" 2>/dev/null) || {
    ELAPSED=$(( $(date +%s%3N) - START_MS ))
    log "ERROR: claude -p failed (exit $?)"
    python3 "$SCRIPT_DIR/db.py" log "$TASK_ID" --status error --output "claude -p failed" --duration "$ELAPSED"
    exit 2
}

ELAPSED=$(( $(date +%s%3N) - START_MS ))

# Save original result before splitting (split loop consumes RESULT)
FULL_RESULT="$RESULT"

# Send to Telegram via JSON body (handles special chars safely)
send_message() {
    local text="$1"
    local payload
    payload=$(python3 -c "
import json, sys, os
print(json.dumps({'chat_id': os.environ['REMINDERS_CHAT_ID'], 'text': sys.stdin.read()}))
" <<< "$text")
    local token
    token=$(read_bot_token)
    curl -s -X POST "https://api.telegram.org/bot${token}/sendMessage" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null
}

MSG_LEN=${#RESULT}
if [ "$MSG_LEN" -le 4096 ]; then
    RESPONSE=$(send_message "$RESULT")
else
    # Split into chunks
    while [ -n "$RESULT" ]; do
        CHUNK="${RESULT:0:4096}"
        RESULT="${RESULT:4096}"
        RESPONSE=$(send_message "$CHUNK")
    done
fi

# Check last response
if echo "$RESPONSE" | python3 -c "import sys,json; sys.exit(0 if json.load(sys.stdin).get('ok') else 1)" 2>/dev/null; then
    log "SENT: ${MSG_LEN} chars in ${ELAPSED}ms"
    python3 "$SCRIPT_DIR/db.py" log "$TASK_ID" --status success --output "$FULL_RESULT" --duration "$ELAPSED"
else
    log "ERROR: Telegram send failed: $RESPONSE"
    python3 "$SCRIPT_DIR/db.py" log "$TASK_ID" --status error --output "Telegram failed: $RESPONSE" --duration "$ELAPSED"
    exit 3
fi

# One-off cleanup
if [ "$IS_RECURRING" = "0" ]; then
    log "ONE-OFF: removing from crontab and marking completed"
    flock "$REMINDERS_DATA_DIR/.lock" bash -c "crontab -l 2>/dev/null | grep -vF '# reminder:$1' | crontab -" -- "$TASK_ID"
    python3 "$SCRIPT_DIR/db.py" complete "$TASK_ID"
fi

# Clean up old logs (keep 30 days)
find "$LOG_DIR" -name "*.log" -mtime +30 -delete 2>/dev/null || true

log "DONE (${ELAPSED}ms)"
