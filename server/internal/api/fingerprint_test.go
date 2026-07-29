package api

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"testing"
)

// fakeFingerprinter is the two-method Fingerprinter surface, no fpcalc involved.
type fakeFingerprinter struct{ runs int }

func (f *fakeFingerprinter) Run(context.Context) error { f.runs++; return nil }
func (f *fakeFingerprinter) Status() any {
	return map[string]any{"phase": "fingerprint", "done": 3, "total": 10, "running": true}
}

// No working fpcalc means the capability is absent, not that the server broke.
func TestFingerprintRoutesWithoutFpcalc(t *testing.T) {
	h := New(analyzeDeps(t))
	for _, r := range []*httptest.ResponseRecorder{
		record(h, httptest.NewRequest("GET", "/api/fingerprint/status", nil)),
		record(h, httptest.NewRequest("POST", "/api/fingerprint", nil)),
	} {
		if r.Code != 501 {
			t.Errorf("code = %d, want 501", r.Code)
		}
	}
}

func TestFingerprintStatusAndKick(t *testing.T) {
	d := analyzeDeps(t)
	ff := &fakeFingerprinter{}
	d.Fingerprinter = ff
	h := New(d)

	for _, req := range []struct{ method, path string }{
		{"GET", "/api/fingerprint/status"}, {"POST", "/api/fingerprint"},
	} {
		rec := record(h, httptest.NewRequest(req.method, req.path, nil))
		if rec.Code != 200 {
			t.Fatalf("%s %s = %d", req.method, req.path, rec.Code)
		}
		var got map[string]any
		if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
			t.Fatal(err)
		}
		// Shape-identical to EnrichStatus/AnalyzeStatus: the client keys purely
		// on phase != "idle" and must need no third deserialiser.
		for _, k := range []string{"phase", "done", "total", "running"} {
			if _, ok := got[k]; !ok {
				t.Errorf("%s %s: status missing %q (%v)", req.method, req.path, k, got)
			}
		}
	}
	d.WaitBg() // POST is fire-and-forget; drain before asserting
	if ff.runs != 1 {
		t.Errorf("runs = %d, want 1", ff.runs)
	}
}

// /api/status advertises the capability separately from analyze: the two have
// different binaries behind them and a deployment can have either.
func TestStatusAdvertisesFingerprint(t *testing.T) {
	d := analyzeDeps(t)
	var got map[string]any
	rec := record(New(d), httptest.NewRequest("GET", "/api/status", nil))
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if got["fingerprint"] != false {
		t.Errorf("fingerprint = %v with none wired, want false", got["fingerprint"])
	}
	d.Fingerprinter = &fakeFingerprinter{}
	rec = record(New(d), httptest.NewRequest("GET", "/api/status", nil))
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if got["fingerprint"] != true {
		t.Errorf("fingerprint = %v with one wired, want true", got["fingerprint"])
	}
}
