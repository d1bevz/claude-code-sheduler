---
name: reminders
description: "Use when the user wants to create, list, cancel, or manage reminders and scheduled notifications. Trigger on: напомни, напоминание, поставь напоминание, покажи напоминания, удали напоминание, отмени напоминание, remind, reminder, set reminder, show reminders, cancel reminder, delete reminder, напоминай, каждый день, recurring, расписание напоминаний."
---

# Reminders

Manage time-based reminders that are delivered via Telegram by running `claude -p` at the scheduled time.

## Setup

- **DB helper:** `${CLAUDE_PLUGIN_ROOT}/scripts/db.py`
- **Runner:** `${CLAUDE_PLUGIN_ROOT}/scripts/run.sh`
- **Data dir:** `~/.config/claude-reminders`
- **Config file:** `~/.config/claude-reminders/config.md` (YAML frontmatter with `default_timezone` and `default_model` fields). If missing, use defaults.
- **Default timezone:** Read from config file field `default_timezone`, or default to `UTC`
- **Default model:** Read from config file field `default_model`, or default to `haiku`

## Create Reminder

When the user says something like "напомни", "remind me", "напоминай каждый день":

### Step 1: Parse the request

Extract from the user's message:
- **What:** The reminder content (what to remind about)
- **When:** Date/time or recurrence pattern
- **Recurring:** Is this one-off or recurring?

**If time is NOT specified, you MUST ask: "Когда напомнить?"** Do not guess or default.

### Step 2: Convert time to cron expression

Use your reasoning to convert natural language to a 5-field cron expression (minute hour day month weekday). The cron runs in **system timezone** (check with `date +%Z`).

**Timezone conversion:** If user timezone (from config) differs from system timezone, you MUST convert:
1. Run `date +%Z` to get system timezone
2. Run `TZ="<user_timezone>" date +%z` and `date +%z` to get UTC offsets for both
3. Calculate the difference and adjust the cron hour accordingly
4. Example: User wants 10:00 in Europe/Lisbon (UTC+1), system is UTC → cron hour = 9

**If system timezone = user timezone** (most common), no conversion needed.

**Ambiguous time resolution:**
- "в 1 ночи" / "at 1am" when current time is after midnight → means tonight (same calendar date, already past → use NEXT occurrence)
- "в 1 ночи" when current time is before midnight (e.g. 23:00) → means in ~2 hours (next calendar date at 01:00)
- **Rule: always pick the NEXT future occurrence of the requested time.** Never schedule in the past.
- When in doubt, confirm with user: "Имеешь в виду через ~2 часа, в 1:00 ночи?"

Common conversions:
| User says | Cron expression | Notes |
|-----------|----------------|-------|
| "завтра в 10:00" | `0 10 24 3 *` | One-off: specific date fields |
| "через час" | `35 22 23 3 *` | One-off: calculate from now |
| "каждый день в 23:00" | `0 23 * * *` | Recurring |
| "каждый понедельник в 9:00" | `0 9 * * 1` | Recurring (1=Monday) |
| "каждый будний день в 8:30" | `30 8 * * 1-5` | Recurring |
| "1 числа каждого месяца в 10:00" | `0 10 1 * *` | Recurring |

For one-off reminders, use specific day/month. For recurring, use wildcards.

**DST warning:** Cron uses fixed times. Recurring reminders may shift by 1 hour during DST transitions (spring/fall). If this happens, recreate the reminder with the corrected time.

### Step 3: Compose the prompt

The prompt is what `claude -p` will receive when the reminder fires. It should be a clear instruction:

- Simple reminder: `"Напомни пользователю: {what}. Будь кратким, 1-2 предложения."`
- Creative reminder: `"Придумай короткое креативное напоминание о том, что нужно {what}. Можешь шутить. 1-2 предложения."`
- Task with tools: `"Проверь {what} и сообщи результат кратко."` (use sonnet/opus for these)

### Step 4: Choose model

- **haiku** (default): Simple text reminders, creative messages
- **sonnet**: Tasks requiring tool use (calendar, email, web), structured analysis
- **opus**: Complex multi-step tasks, deep research

If the user explicitly asks for a specific model, use it. Otherwise, choose based on task complexity.

### Step 5: Insert into database

```bash
export REMINDERS_DATA_DIR="<data_dir from config>"
TASK_ID=$(python3 ${CLAUDE_PLUGIN_ROOT}/scripts/db.py insert \
  --prompt "<composed prompt>" \
  --model <model> \
  --workspace "$(pwd)" \
  --schedule "<cron expression>" \
  --is-recurring <0 or 1> \
  --timezone "<user timezone from config>" \
  --original "<user's original message>")
```

### Step 6: Add crontab entry

```bash
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
DATA_DIR="$HOME/.config/claude-reminders"
(flock -w 5 200 && {
    (crontab -l 2>/dev/null; echo "<cron_expression> REMINDERS_DATA_DIR=\"$DATA_DIR\" \"$PLUGIN_ROOT/scripts/run.sh\" \"$TASK_ID\" >> \"$DATA_DIR/logs/cron.log\" 2>&1 # reminder:$TASK_ID") | crontab -
}) 200>"$DATA_DIR/.lock"
```

Note: `REMINDERS_DATA_DIR` is set inline in the crontab entry so run.sh finds the config in cron's minimal environment.

### Step 7: Confirm to user

Format: "Готово, напомню [when in human-readable form] — [what]"

Examples:
- "Готово, напомню завтра в 10:00 — купить молоко"
- "Готово, буду напоминать каждый день в 23:00 — лечь спать"

## List Reminders

When the user says "покажи напоминания", "мои напоминания", "show reminders", "list reminders":

```bash
export REMINDERS_DATA_DIR="<data_dir>"
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/db.py list --status active
```

Format the JSON output as a readable list:
```
1. [каждый день 23:00] Лечь спать (haiku, recurring)
2. [24 мар 10:00] Купить молоко (haiku, one-off)
```

Show schedule in user's timezone, not UTC.

## Cancel Reminder

When the user says "отмени напоминание", "удали напоминание", "cancel reminder":

1. If user specifies ID: cancel directly
2. If user describes by text: list active reminders, find best match, confirm before canceling

```bash
export REMINDERS_DATA_DIR="<data_dir>"

# Cancel in DB
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/db.py cancel <task_id>

# Remove from crontab
(flock -w 5 200 && {
    crontab -l 2>/dev/null | grep -v "# reminder:<task_id>$" | crontab -
}) 200>"$DATA_DIR/.lock"
```

Confirm: "Напоминание #<id> отменено."

## View History

When the user asks about past executions:

```bash
export REMINDERS_DATA_DIR="<data_dir>"
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/db.py history <task_id> --limit 5
```

Show: date, status (success/error), output preview.

## Important Notes

- **DST limitation (v0.1):** Cron expressions use fixed times. Recurring reminders set for a specific local time may shift by 1 hour during DST transitions if system timezone differs from user timezone. Mitigate by using the same timezone for system and user.
- **One-off cleanup:** run.sh automatically removes one-off reminders from crontab after execution. No manual cleanup needed.
- **All times in crontab use system timezone.** Convert if user timezone differs.
