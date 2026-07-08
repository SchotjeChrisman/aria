package repo

import (
	"context"
	"database/sql"
	"time"
)

// ClientLog is one uploaded app-log line (client_logs table).
type ClientLog struct {
	ID         int64   `json:"id"`
	Device     string  `json:"device"`
	Ts         string  `json:"ts"`
	Level      string  `json:"level"`
	Tag        string  `json:"tag"`
	Msg        string  `json:"msg"`
	Extra      *string `json:"extra,omitempty"`
	ReceivedAt string  `json:"receivedAt"`
}

type Logs struct{ db *sql.DB }

func NewLogs(db *sql.DB) *Logs { return &Logs{db} }

// InsertBatch stores one device's entries, all stamped with receivedAt.
func (r *Logs) InsertBatch(ctx context.Context, device, receivedAt string, entries []ClientLog) error {
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	stmt, err := tx.PrepareContext(ctx,
		`INSERT INTO client_logs (device, ts, level, tag, msg, extra, receivedAt) VALUES (?,?,?,?,?,?,?)`)
	if err != nil {
		return err
	}
	defer stmt.Close()
	for _, e := range entries {
		if _, err := stmt.ExecContext(ctx, device, e.Ts, e.Level, e.Tag, e.Msg, e.Extra, receivedAt); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// List returns the newest entries first; empty level/device means no filter.
func (r *Logs) List(ctx context.Context, limit int, level, device string) ([]ClientLog, error) {
	rows, err := r.db.QueryContext(ctx,
		`SELECT id, device, ts, level, tag, msg, extra, receivedAt FROM client_logs
		 WHERE (?1 = '' OR level = ?1) AND (?2 = '' OR device = ?2)
		 ORDER BY id DESC LIMIT ?3`, level, device, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []ClientLog
	for rows.Next() {
		var l ClientLog
		if err := rows.Scan(&l.ID, &l.Device, &l.Ts, &l.Level, &l.Tag, &l.Msg, &l.Extra, &l.ReceivedAt); err != nil {
			return nil, err
		}
		out = append(out, l)
	}
	return out, rows.Err()
}

// Prune drops entries older than 30 days, then caps the table at 200k rows
// (newest kept). Cheap: ts is indexed and ids are monotonic.
func (r *Logs) Prune(ctx context.Context) error {
	cutoff := time.Now().UTC().AddDate(0, 0, -30).Format("2006-01-02T15:04:05.000Z")
	if _, err := r.db.ExecContext(ctx, `DELETE FROM client_logs WHERE ts < ?`, cutoff); err != nil {
		return err
	}
	_, err := r.db.ExecContext(ctx,
		`DELETE FROM client_logs WHERE id NOT IN (SELECT id FROM client_logs ORDER BY id DESC LIMIT 200000)`)
	return err
}
