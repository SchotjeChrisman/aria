package api

import (
	"encoding/json"
	"log"
	"net/http"
	"strconv"

	"aria/internal/repo"
)

// Client log ingestion: the app buffers NDJSON log lines on the device and
// batch-uploads them here (see the Flutter log_sync provider); GET serves
// recent rows back for debugging.

const (
	// Log batches outgrow the shared 32KiB readJSON cap.
	maxLogsBody    = 1 << 20
	maxLogsEntries = 1000
	// Per-field byte caps: the row-count prune bounds rows, not bytes — without
	// these a 1MiB msg per request grows the table ~200GB before pruning bites.
	maxLogField = 256      // device, ts, level, tag
	maxLogMsg   = 8 * 1024 // msg, extra
)

// clip truncates s to max bytes (long fields are stored, not rejected — a
// truncated log line beats a lost one).
func clip(s string, max int) string {
	if len(s) > max {
		return s[:max]
	}
	return s
}

func init() { register(registerLogs) }

func registerLogs(mux *http.ServeMux, d *Deps) {
	mux.HandleFunc("POST /api/logs", func(w http.ResponseWriter, r *http.Request) {
		var b struct {
			Device  string `json:"device"`
			Entries []struct {
				Ts    string          `json:"ts"`
				Level string          `json:"level"`
				Tag   string          `json:"tag"`
				Msg   string          `json:"msg"`
				Extra json.RawMessage `json:"extra"`
			} `json:"entries"`
		}
		body := http.MaxBytesReader(w, r.Body, maxLogsBody)
		if err := json.NewDecoder(body).Decode(&b); err != nil {
			httpError(w, http.StatusBadRequest, "invalid json")
			return
		}
		if !requireFields(w, "device", b.Device) {
			return
		}
		if len(b.Entries) == 0 {
			httpError(w, http.StatusBadRequest, "entries required")
			return
		}
		if len(b.Entries) > maxLogsEntries {
			httpError(w, http.StatusBadRequest, "too many entries")
			return
		}
		entries := make([]repo.ClientLog, 0, len(b.Entries))
		for _, e := range b.Entries {
			var extra *string
			if len(e.Extra) > 0 && string(e.Extra) != "null" {
				s := clip(string(e.Extra), maxLogMsg)
				extra = &s
			}
			entries = append(entries, repo.ClientLog{
				Ts:    clip(e.Ts, maxLogField),
				Level: clip(e.Level, maxLogField),
				Tag:   clip(e.Tag, maxLogField),
				Msg:   clip(e.Msg, maxLogMsg),
				Extra: extra,
			})
		}
		if err := d.Logs.InsertBatch(r.Context(), clip(b.Device, maxLogField), isoNow(), entries); err != nil {
			fail(w, err)
			return
		}
		// Opportunistic prune on every upload — cheap with the ts index, and
		// uploads are the only thing that grows the table.
		if err := d.Logs.Prune(r.Context()); err != nil {
			log.Printf("api: %v", err)
		}
		writeJSON(w, http.StatusOK, map[string]int{"stored": len(entries)})
	})

	mux.HandleFunc("GET /api/logs", func(w http.ResponseWriter, r *http.Request) {
		limit := 200
		if s := r.URL.Query().Get("limit"); s != "" {
			if n, err := strconv.Atoi(s); err == nil && n > 0 {
				limit = min(n, 2000)
			}
		}
		out, err := d.Logs.List(r.Context(), limit, r.URL.Query().Get("level"), r.URL.Query().Get("device"))
		if err != nil {
			fail(w, err)
			return
		}
		if out == nil {
			out = []repo.ClientLog{}
		}
		writeJSON(w, http.StatusOK, out)
	})
}
