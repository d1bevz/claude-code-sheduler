CREATE TABLE IF NOT EXISTS tasks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    prompt TEXT NOT NULL,
    model TEXT NOT NULL DEFAULT 'haiku',
    workspace TEXT NOT NULL,
    schedule_cron TEXT NOT NULL,
    is_recurring INTEGER NOT NULL DEFAULT 0,
    timezone TEXT NOT NULL DEFAULT 'UTC',
    status TEXT NOT NULL DEFAULT 'active',
    created_at TEXT NOT NULL,
    original_message TEXT
);

CREATE TABLE IF NOT EXISTS execution_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    task_id INTEGER NOT NULL REFERENCES tasks(id),
    executed_at TEXT NOT NULL,
    status TEXT NOT NULL,
    output TEXT,
    duration_ms INTEGER
);

CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);
CREATE INDEX IF NOT EXISTS idx_execution_log_task_id ON execution_log(task_id);
