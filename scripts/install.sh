#!/bin/bash
# install.sh — Setup claude-code-sheduler plugin
# Creates data directory, initializes SQLite DB, writes config.
# Usage: install.sh [--data-dir DIR] [--chat-id ID] [--timezone TZ] [--model MODEL]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"

# Parse args
DATA_DIR="$HOME/.config/claude-reminders"
CHAT_ID=""
TZ=""
MODEL=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --data-dir) DATA_DIR="$2"; shift 2 ;;
        --chat-id) CHAT_ID="$2"; shift 2 ;;
        --timezone) TZ="$2"; shift 2 ;;
        --model) MODEL="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

echo "=== claude-code-sheduler installer ==="
echo ""

# Check dependencies
MISSING=""
for cmd in python3 claude curl jq flock; do
    if ! command -v "$cmd" &>/dev/null; then
        MISSING="$MISSING $cmd"
    fi
done
if [ -n "$MISSING" ]; then
    echo "ERROR: missing dependencies:$MISSING"
    echo "Install them and re-run."
    exit 1
fi

# Verify python3 has sqlite3
python3 -c "import sqlite3" 2>/dev/null || {
    echo "ERROR: python3 sqlite3 module not available"
    exit 1
}

echo "Dependencies: OK"

# Create data directory
mkdir -p "$DATA_DIR/logs"
chmod 700 "$DATA_DIR"
echo "Data directory: $DATA_DIR"

# Apply migration
DB_PATH="$DATA_DIR/reminders.db"
if [ -f "$DB_PATH" ]; then
    echo "Database already exists at $DB_PATH — skipping migration"
else
    python3 -c "
import sqlite3
conn = sqlite3.connect('$DB_PATH')
with open('$PLUGIN_DIR/migrations/001_init.sql') as f:
    conn.executescript(f.read())
conn.close()
"
    chmod 600 "$DB_PATH"
    echo "Database created: $DB_PATH"
fi

# Write .env config (for run.sh)
if [ -f "$DATA_DIR/.env" ]; then
    echo "Config already exists at $DATA_DIR/.env — skipping"
else
    # Interactive prompts if args not provided
    if [ -z "$CHAT_ID" ]; then read -p "Telegram chat ID: " CHAT_ID; fi
    if [ -z "$TZ" ]; then read -p "Default timezone [Europe/Lisbon]: " TZ; fi
    TZ="${TZ:-Europe/Lisbon}"
    if [ -z "$MODEL" ]; then read -p "Default model [haiku]: " MODEL; fi
    MODEL="${MODEL:-haiku}"

    cat > "$DATA_DIR/.env" <<EOF
REMINDERS_CHAT_ID="$CHAT_ID"
REMINDERS_DEFAULT_TIMEZONE="$TZ"
REMINDERS_DEFAULT_MODEL="$MODEL"
REMINDERS_DATA_DIR="$DATA_DIR"
EOF
    chmod 600 "$DATA_DIR/.env"
    echo "Config written: $DATA_DIR/.env"
fi

echo ""
echo "=== Setup complete ==="
echo ""
echo "Next steps:"
echo "  1. Install the plugin in your workspace"
echo "  2. Tell your agent: 'напомни завтра в 10 купить молоко'"
echo ""
