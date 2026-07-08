-- Client (app) log ingestion: devices batch-upload their NDJSON log lines
-- via POST /api/logs for debugging. Pruned to 30 days / 200k rows.
CREATE TABLE client_logs (
  id INTEGER PRIMARY KEY,
  device TEXT NOT NULL,
  ts TEXT NOT NULL,
  level TEXT NOT NULL,
  tag TEXT NOT NULL,
  msg TEXT NOT NULL,
  extra TEXT,
  receivedAt TEXT NOT NULL
);
CREATE INDEX idx_client_logs_ts ON client_logs(ts);
