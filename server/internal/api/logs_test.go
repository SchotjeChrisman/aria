package api

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"aria/internal/config"
	"aria/internal/db"
	"aria/internal/repo"
)

func logsDeps(t *testing.T) *Deps {
	t.Helper()
	d, err := db.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { d.Close() })
	return NewDeps(d, config.Config{}, "test")
}

// Uploaded entries round-trip through GET with level/device filters.
func TestLogsRoundTrip(t *testing.T) {
	deps := logsDeps(t)
	h := New(deps)

	body := `{"device":"linux-a1b2c3","entries":[
		{"ts":"2026-07-08T10:00:00.000Z","level":"info","tag":"app","msg":"start","extra":{"platform":"linux"}},
		{"ts":"2026-07-08T10:00:01.000Z","level":"error","tag":"playback","msg":"boom"}]}`
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("POST", "/api/logs", strings.NewReader(body)))
	if rec.Code != 200 {
		t.Fatalf("POST /api/logs = %d: %s", rec.Code, rec.Body.String())
	}
	var stored struct {
		Stored int `json:"stored"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &stored); err != nil {
		t.Fatal(err)
	}
	if stored.Stored != 2 {
		t.Fatalf("stored = %d, want 2", stored.Stored)
	}

	get := func(q string) []repo.ClientLog {
		t.Helper()
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest("GET", "/api/logs"+q, nil))
		if rec.Code != 200 {
			t.Fatalf("GET /api/logs%s = %d: %s", q, rec.Code, rec.Body.String())
		}
		var out []repo.ClientLog
		if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
			t.Fatal(err)
		}
		return out
	}

	all := get("")
	if len(all) != 2 {
		t.Fatalf("got %d rows, want 2", len(all))
	}
	// Newest first.
	if all[0].Msg != "boom" || all[1].Msg != "start" {
		t.Fatalf("order = %q, %q", all[0].Msg, all[1].Msg)
	}
	if all[1].Extra == nil || *all[1].Extra != `{"platform":"linux"}` {
		t.Fatalf("extra = %v", all[1].Extra)
	}
	if all[0].Device != "linux-a1b2c3" || all[0].ReceivedAt == "" {
		t.Fatalf("row = %+v", all[0])
	}

	if got := get("?level=error"); len(got) != 1 || got[0].Level != "error" {
		t.Fatalf("level filter = %+v", got)
	}
	if got := get("?device=other"); len(got) != 0 {
		t.Fatalf("device filter = %+v", got)
	}
	if got := get("?limit=1"); len(got) != 1 {
		t.Fatalf("limit = %+v", got)
	}
}

func TestLogsValidation(t *testing.T) {
	h := New(logsDeps(t))
	post := func(body string) int {
		t.Helper()
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest("POST", "/api/logs", strings.NewReader(body)))
		return rec.Code
	}

	if c := post(`{"entries":[{"ts":"t","level":"info","tag":"a","msg":"m"}]}`); c != 400 {
		t.Fatalf("missing device = %d, want 400", c)
	}
	if c := post(`{"device":"d","entries":[]}`); c != 400 {
		t.Fatalf("empty entries = %d, want 400", c)
	}
	if c := post(`not json`); c != 400 {
		t.Fatalf("bad json = %d, want 400", c)
	}

	var sb strings.Builder
	sb.WriteString(`{"device":"d","entries":[`)
	for i := 0; i < 1001; i++ {
		if i > 0 {
			sb.WriteString(",")
		}
		fmt.Fprintf(&sb, `{"ts":"t","level":"info","tag":"a","msg":"m%d"}`, i)
	}
	sb.WriteString(`]}`)
	if c := post(sb.String()); c != 400 {
		t.Fatalf("1001 entries = %d, want 400", c)
	}

	// Over the 1MiB body cap: MaxBytesReader kills the decode.
	huge := `{"device":"d","entries":[{"ts":"t","level":"info","tag":"a","msg":"` +
		strings.Repeat("x", maxLogsBody) + `"}]}`
	if c := post(huge); c != 400 {
		t.Fatalf("oversized body = %d, want 400", c)
	}
}

// Prune drops >30-day-old rows and caps the row count.
func TestLogsPrune(t *testing.T) {
	deps := logsDeps(t)
	ctx := context.Background()

	old := time.Now().UTC().AddDate(0, 0, -31).Format("2006-01-02T15:04:05.000Z")
	entries := []repo.ClientLog{
		{Ts: old, Level: "info", Tag: "a", Msg: "ancient"},
		{Ts: isoNow(), Level: "info", Tag: "a", Msg: "fresh"},
	}
	if err := deps.Logs.InsertBatch(ctx, "dev", isoNow(), entries); err != nil {
		t.Fatal(err)
	}
	if err := deps.Logs.Prune(ctx); err != nil {
		t.Fatal(err)
	}
	got, err := deps.Logs.List(ctx, 10, "", "")
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || got[0].Msg != "fresh" {
		t.Fatalf("after prune = %+v", got)
	}
}
