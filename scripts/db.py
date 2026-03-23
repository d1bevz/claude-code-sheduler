#!/usr/bin/env python3
"""SQLite helper for claude-code-sheduler. Called by run.sh and the skill."""

import argparse
import json
import os
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path

def get_db_path():
    data_dir = os.environ.get("REMINDERS_DATA_DIR", os.path.expanduser("~/.config/claude-reminders"))
    return os.path.join(data_dir, "reminders.db")

def get_conn():
    db_path = get_db_path()
    if not os.path.exists(db_path):
        print(f"Error: database not found at {db_path}. Run install.sh first.", file=sys.stderr)
        sys.exit(1)
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    return conn

def cmd_get(args):
    conn = get_conn()
    row = conn.execute("SELECT * FROM tasks WHERE id = ?", (args.id,)).fetchone()
    if not row:
        sys.exit(1)
    print(json.dumps(dict(row)))

def cmd_insert(args):
    conn = get_conn()
    now = datetime.now(timezone.utc).isoformat()
    cur = conn.execute(
        """INSERT INTO tasks (prompt, model, workspace, schedule_cron, is_recurring, timezone, status, created_at, original_message)
           VALUES (?, ?, ?, ?, ?, ?, 'active', ?, ?)""",
        (args.prompt, args.model, args.workspace, args.schedule, int(args.is_recurring), args.timezone, now, args.original)
    )
    conn.commit()
    print(cur.lastrowid)

def cmd_complete(args):
    conn = get_conn()
    conn.execute("UPDATE tasks SET status = 'completed' WHERE id = ?", (args.id,))
    conn.commit()

def cmd_cancel(args):
    conn = get_conn()
    conn.execute("UPDATE tasks SET status = 'cancelled' WHERE id = ?", (args.id,))
    conn.commit()

def cmd_list(args):
    conn = get_conn()
    status = args.status or "active"
    rows = conn.execute("SELECT * FROM tasks WHERE status = ?", (status,)).fetchall()
    print(json.dumps([dict(r) for r in rows]))

def cmd_log(args):
    conn = get_conn()
    now = datetime.now(timezone.utc).isoformat()
    conn.execute(
        "INSERT INTO execution_log (task_id, executed_at, status, output, duration_ms) VALUES (?, ?, ?, ?, ?)",
        (args.task_id, now, args.status, args.output, args.duration)
    )
    conn.commit()

def cmd_history(args):
    conn = get_conn()
    limit = args.limit or 10
    rows = conn.execute(
        "SELECT * FROM execution_log WHERE task_id = ? ORDER BY executed_at DESC LIMIT ?",
        (args.task_id, limit)
    ).fetchall()
    print(json.dumps([dict(r) for r in rows]))

def main():
    parser = argparse.ArgumentParser(description="Reminders DB helper")
    sub = parser.add_subparsers(dest="command", required=True)

    p_get = sub.add_parser("get")
    p_get.add_argument("id", type=int)

    p_ins = sub.add_parser("insert")
    p_ins.add_argument("--prompt", required=True)
    p_ins.add_argument("--model", default="haiku")
    p_ins.add_argument("--workspace", required=True)
    p_ins.add_argument("--schedule", required=True)
    p_ins.add_argument("--is-recurring", default="0")
    p_ins.add_argument("--timezone", default="UTC")
    p_ins.add_argument("--original", default="")

    p_comp = sub.add_parser("complete")
    p_comp.add_argument("id", type=int)

    p_cancel = sub.add_parser("cancel")
    p_cancel.add_argument("id", type=int)

    p_list = sub.add_parser("list")
    p_list.add_argument("--status", default="active")

    p_log = sub.add_parser("log")
    p_log.add_argument("task_id", type=int)
    p_log.add_argument("--status", required=True)
    p_log.add_argument("--output", default="")
    p_log.add_argument("--duration", type=int, default=0)

    p_hist = sub.add_parser("history")
    p_hist.add_argument("task_id", type=int)
    p_hist.add_argument("--limit", type=int, default=10)

    args = parser.parse_args()
    commands = {
        "get": cmd_get, "insert": cmd_insert, "complete": cmd_complete,
        "cancel": cmd_cancel, "list": cmd_list, "log": cmd_log, "history": cmd_history
    }
    commands[args.command](args)

if __name__ == "__main__":
    main()
