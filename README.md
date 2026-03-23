# claude-code-sheduler

Time-based reminders for Claude Code agents with Telegram delivery.

## How it works

claude-code-sheduler bridges your Claude Code agent, system cron, and Telegram to deliver time-based reminders. Here's the flow:

1. You tell your agent: "remind me tomorrow at 10 to buy milk"
2. The agent parses this request, inserts a task into SQLite, and adds a crontab entry
3. At the scheduled time, cron fires `run.sh` with the task ID
4. `run.sh` reads the task from SQLite, runs `claude -p` from your workspace (with full context: CLAUDE.md, skills, MCP tools)
5. The result is sent to you via Telegram Bot API

The agent has access to your workspace context, so reminders can be creative, use tools, check your calendar, and more.

## Installation

### Prerequisites

- Claude Code CLI (`claude`)
- Python 3.12+ with sqlite3 (built-in)
- cron (systemd-timer alternative supported with manual config)
- curl and jq
- Telegram bot token (see Configuration)

### Quick Start

```bash
git clone https://github.com/d1bevz/claude-code-sheduler.git
cd claude-code-sheduler
bash scripts/install.sh --chat-id YOUR_CHAT_ID --timezone "Your/Timezone" --model haiku
```

The installer will:
- Check dependencies
- Create data directory (default: `~/.config/claude-reminders`)
- Initialize SQLite database
- Write `.env` config file with your settings
- Display next steps

Then, in your Claude Code workspace, install the plugin:

```bash
claude plugin add ./path/to/claude-code-sheduler
```

Your agent can now manage reminders.

### Finding your Telegram chat ID

1. Create a bot via [@BotFather](https://t.me/botfather) on Telegram
2. Get your bot token (format: `123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11`)
3. Send any message to your bot, then run:
   ```bash
   curl https://api.telegram.org/bot<YOUR_BOT_TOKEN>/getUpdates | jq '.result[0].message.chat.id'
   ```
4. Use that chat ID in the installer

## Usage

All commands are given to your Claude Code agent in natural language. The agent parses, schedules, and manages reminders.

### Create a reminder

**One-off:**
```
Russian: "напомни завтра в 10 купить молоко"
English: "remind me tomorrow at 10 to buy milk"
```

**Recurring:**
```
Russian: "напоминай каждый день в 23:00 лечь спать"
English: "remind me every day at 23:00 to go to sleep"
```

The agent responds with confirmation:
```
Готово, напомню завтра в 10:00 — купить молоко
(Ready, I'll remind you tomorrow at 10:00 — buy milk)
```

### List reminders

```
Russian: "покажи мои напоминания"
English: "show my reminders"
```

Output:
```
1. [каждый день 23:00] Лечь спать (haiku, recurring)
2. [24 мар 10:00] Купить молоко (haiku, one-off)
```

### Cancel a reminder

```
Russian: "отмени напоминание про молоко"
English: "cancel the milk reminder"
```

The agent lists matches and asks for confirmation before removing.

### Advanced usage

Reminders can ask the agent to do real work. For example:

```
Russian: "напомни мне завтра в 9 проверить важные письма и кратко рассказать"
English: "remind me tomorrow at 9 to check important emails and tell me briefly"
```

For complex tasks, specify the model:

```
Russian: "напомни в пятницу в 17:00 проверить прогресс в Jira, используй sonnet"
English: "remind me Friday at 5pm to check Jira progress, use sonnet"
```

## Configuration

On install, the plugin creates `~/.config/claude-reminders/.env`:

```bash
REMINDERS_CHAT_ID="123456789"                      # Your Telegram chat ID
REMINDERS_DEFAULT_TIMEZONE="Europe/Lisbon"         # Default timezone for time parsing
REMINDERS_DEFAULT_MODEL="haiku"                    # Default model for reminder prompts
REMINDERS_DATA_DIR="$HOME/.config/claude-reminders" # Where SQLite DB and logs live
```

You can override these per-workspace by adding frontmatter to `.claude/claude-code-sheduler.local.md`:

```markdown
---
data_dir: /custom/path/to/data
default_timezone: America/New_York
default_model: sonnet
---
```

The agent reads these overrides and uses them for all operations in that workspace.

### Telegram bot token

The bot token is read from:
1. Workspace's `.claude/channels/telegram/.env`
2. Home's `~/.claude/channels/telegram/.env`
3. Falls back with an error if neither exists

Set it once and the plugin finds it automatically.

## How delivery works

When a reminder fires:

1. **Cron triggers:** System cron runs `run.sh <task_id>` at the scheduled time
2. **Context is loaded:** `run.sh` loads task details from SQLite and your Telegram config
3. **Claude runs:** From your workspace, `claude -p` executes with full context:
   - Your `CLAUDE.md` and project instructions
   - All installed skills
   - MCP tools (if configured)
4. **Result is sent:** Output is split into 4096-char chunks and sent via Telegram API
5. **Logged:** Execution time, status, and output are recorded in the SQLite database and daily logs

Reminders run in your workspace directory, so they inherit all your tools and context.

## Known limitations (v0.1)

- **DST transitions:** Recurring reminders set for a specific local time may shift by 1 hour during daylight saving time transitions if system timezone differs from user timezone. Workaround: use the same timezone for system and user settings.
- **No snooze:** Once a reminder is sent, there's no snooze feature. Cancel and recreate if needed.
- **Single-user:** The plugin stores all reminders in one SQLite DB and sends to one Telegram chat. Multi-user support is planned.
- **No task IDs in cron:** Crontab is user-level, not system-wide. Each user needs their own installation.

## Logs

Reminders log execution details to `~/.config/claude-reminders/logs/`:

- `YYYY-MM-DD.log` — Daily execution log (task ID, status, timing, errors)
- `cron.log` — Cron stdout/stderr (if configured in crontab)

Old logs (>30 days) are cleaned up automatically.

View recent executions:

```bash
tail -f ~/.config/claude-reminders/logs/$(date +%Y-%m-%d).log
```

Or ask your agent: "покажи мою историю напоминаний" ("show my reminder history").

## Troubleshooting

### Reminder didn't fire

1. Check crontab:
   ```bash
   crontab -l | grep reminder
   ```
2. Check logs:
   ```bash
   tail ~/.config/claude-reminders/logs/$(date +%Y-%m-%d).log
   ```
3. Verify bot token is set:
   ```bash
   cat ~/.claude/channels/telegram/.env | grep TELEGRAM_BOT_TOKEN
   ```

### Python SQLite error

If you see `sqlite3` module errors, ensure Python 3 has it:

```bash
python3 -c "import sqlite3; print('OK')"
```

On Debian/Ubuntu: `sudo apt-get install python3-sqlite3`

### Cron environment issues

Cron runs with a minimal environment. If `claude` command is not found, the installer adds common paths to `run.sh`:

```bash
export PATH="$HOME/.local/bin:$HOME/.npm/bin:$HOME/.cargo/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
```

If you installed Claude Code in a custom location, update `run.sh` to include that path.

### Telegram message not received

1. Verify the bot is active and has access to the chat
2. Check the Telegram chat ID is correct (must be numeric, e.g., `123456789`)
3. Look for errors in logs

## License

MIT. See LICENSE file.

## Contributing

Issues, PRs, and forks welcome. This is v0.1 — expect refinements.

---

**Questions?** Open an issue on [GitHub](https://github.com/d1bevz/claude-code-sheduler).
