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

# Load config
REMINDERS_DATA_DIR="${REMINDERS_DATA_DIR:-$HOME/.config/claude-reminders}"
if [ -f "$REMINDERS_DATA_DIR/.env" ]; then
    source "$REMINDERS_DATA_DIR/.env"
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

# Resolve bot token from workspace
BOT_TOKEN=""
if [ -f "$WORKSPACE/.claude/channels/telegram/.env" ]; then
    BOT_TOKEN=$(grep -oP 'TELEGRAM_BOT_TOKEN="\K[^"]+' "$WORKSPACE/.claude/channels/telegram/.env" 2>/dev/null || \
                grep -oP 'TELEGRAM_BOT_TOKEN=\K.+' "$WORKSPACE/.claude/channels/telegram/.env" 2>/dev/null || true)
fi
if [ -z "$BOT_TOKEN" ] && [ -f "$HOME/.claude/channels/telegram/.env" ]; then
    BOT_TOKEN=$(grep -oP 'TELEGRAM_BOT_TOKEN="\K[^"]+' "$HOME/.claude/channels/telegram/.env" 2>/dev/null || \
                grep -oP 'TELEGRAM_BOT_TOKEN=\K.+' "$HOME/.claude/channels/telegram/.env" 2>/dev/null || true)
fi
if [ -z "$BOT_TOKEN" ]; then
    log "ERROR: no bot token found"
    python3 "$SCRIPT_DIR/db.py" log "$TASK_ID" --status error --output "Bot token not found" --duration 0
    exit 3
fi

# Run claude -p from workspace
log "EXEC: model=$MODEL workspace=$WORKSPACE"
START_MS=$(date +%s%3N)

RESULT=$(cd "$WORKSPACE" && claude -p "$PROMPT" --model "$MODEL" --dangerously-skip-permissions 2>/dev/null) || {
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
    payload=$(python3 -c "import json,sys; print(json.dumps({'chat_id': '$CHAT_ID', 'text': sys.stdin.read()}))" <<< "$text")
    curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
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
    flock "$REMINDERS_DATA_DIR/.lock" bash -c "crontab -l 2>/dev/null | grep -v '# reminder:${TASK_ID}$' | crontab -"
    python3 "$SCRIPT_DIR/db.py" complete "$TASK_ID"
fi

# Clean up old logs (keep 30 days)
find "$LOG_DIR" -name "*.log" -mtime +30 -delete 2>/dev/null || true

log "DONE (${ELAPSED}ms)"
