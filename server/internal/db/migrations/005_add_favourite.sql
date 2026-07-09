-- Independent per-track favourite flag. A real tracks column, but deliberately
-- kept OUT of the scanner's UpsertAll ON CONFLICT SET (like addedAt) so it
-- survives rescans: new rows default 0, existing rows keep their value.
ALTER TABLE tracks ADD COLUMN favourite INTEGER NOT NULL DEFAULT 0;
