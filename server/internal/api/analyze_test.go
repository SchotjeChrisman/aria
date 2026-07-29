package api

import (
	"context"
	"encoding/json"
	"math"
	"net/http"
	"net/http/httptest"
	"testing"

	"aria/internal/config"
	"aria/internal/db"
	"aria/internal/repo"
)

// fakeAnalyzer is the two-method Analyzer surface, no ffmpeg involved.
type fakeAnalyzer struct{ runs int }

func (f *fakeAnalyzer) Run(context.Context) error { f.runs++; return nil }
func (f *fakeAnalyzer) Status() any {
	return map[string]any{"phase": "loudness", "done": 3, "total": 10, "running": true}
}

// record serves one request against h and returns the recorder.
func record(h http.Handler, r *http.Request) *httptest.ResponseRecorder {
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, r)
	return rec
}

func analyzeDeps(t *testing.T) *Deps {
	t.Helper()
	sqlDB, err := db.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { sqlDB.Close() })
	return NewDeps(sqlDB, config.Config{}, "test")
}

// No ffmpeg means the capability is absent, not that the server broke — so
// 501, matching the transcode tiers, not 500.
func TestAnalyzeRoutesWithoutFFmpeg(t *testing.T) {
	d := analyzeDeps(t)
	h := New(d)
	for _, r := range []*httptest.ResponseRecorder{
		record(h, httptest.NewRequest("GET", "/api/analyze/status", nil)),
		record(h, httptest.NewRequest("POST", "/api/analyze", nil)),
	} {
		if r.Code != 501 {
			t.Errorf("code = %d, want 501", r.Code)
		}
	}
}

func TestAnalyzeStatusAndKick(t *testing.T) {
	d := analyzeDeps(t)
	fa := &fakeAnalyzer{}
	d.Analyzer = fa
	h := New(d)

	for _, req := range []struct{ method, path string }{
		{"GET", "/api/analyze/status"}, {"POST", "/api/analyze"},
	} {
		rec := record(h, httptest.NewRequest(req.method, req.path, nil))
		if rec.Code != 200 {
			t.Fatalf("%s %s = %d", req.method, req.path, rec.Code)
		}
		var got map[string]any
		if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
			t.Fatal(err)
		}
		// Shape-identical to EnrichStatus so clients share one deserialiser.
		for _, k := range []string{"phase", "done", "total", "running"} {
			if _, ok := got[k]; !ok {
				t.Errorf("%s %s: status missing %q (%v)", req.method, req.path, k, got)
			}
		}
	}
	d.WaitBg() // POST is fire-and-forget; drain before asserting
	if fa.runs != 1 {
		t.Errorf("runs = %d, want 1", fa.runs)
	}
}

// /api/status advertises the capability: an ffmpeg-less deployment gets no
// loudness figures at all, and the flag is how a client can say so.
func TestStatusAdvertisesAnalyze(t *testing.T) {
	d := analyzeDeps(t)
	var got map[string]any
	rec := record(New(d), httptest.NewRequest("GET", "/api/status", nil))
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if got["analyze"] != false {
		t.Errorf("analyze = %v with no analyzer wired, want false", got["analyze"])
	}
	d.Analyzer = &fakeAnalyzer{}
	rec = record(New(d), httptest.NewRequest("GET", "/api/status", nil))
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if got["analyze"] != true {
		t.Errorf("analyze = %v with an analyzer wired, want true", got["analyze"])
	}
}

// The merged /api/tracks view carries the gains. Unanalysed is null — never 0,
// which a client would read as "measured, needs no adjustment" and apply DSP on
// no evidence.
func TestMergedTracksGains(t *testing.T) {
	ctx := context.Background()
	d := analyzeDeps(t)
	dur := func(v float64) *float64 { return &v }
	if err := d.Tracks.UpsertAll(ctx, []repo.Track{
		{ID: "t1", Path: "a/1.flac", AlbumID: "al", Album: "A", AddedAt: "now", Duration: dur(30)},
		{ID: "t2", Path: "a/2.flac", AlbumID: "al", Album: "A", AddedAt: "now", Duration: dur(30)},
		{ID: "t3", Path: "b/3.flac", AlbumID: "other", Album: "B", AddedAt: "now", Duration: dur(30)},
	}); err != nil {
		t.Fatal(err)
	}
	byID := func() map[string]map[string]any {
		t.Helper()
		d.InvalidateTracks()
		out, err := buildMergedTracks(ctx, d)
		if err != nil {
			t.Fatal(err)
		}
		m := map[string]map[string]any{}
		for _, e := range out {
			m[str(e["id"])] = e
		}
		return m
	}

	for id, m := range byID() {
		for _, k := range []string{"trackGainDb", "albumGainDb", "trackPeak", "albumPeak"} {
			if m[k] != nil {
				t.Errorf("%s.%s = %v before analysis, want null", id, k, m[k])
			}
		}
	}

	lufs, peak := -29.9, -6.0
	quiet := -33.9
	if err := d.Audio.Put(ctx, repo.TrackAudio{TrackID: "t1", IntegratedLUFS: &lufs, TruePeakDBFS: &peak}, 0, 0, "now"); err != nil {
		t.Fatal(err)
	}
	if err := d.Audio.Put(ctx, repo.TrackAudio{TrackID: "t2", IntegratedLUFS: &quiet}, 0, 0, "now"); err != nil {
		t.Fatal(err)
	}
	got := byID()
	if g := got["t1"]["trackGainDb"].(float64); math.Abs(g-11.9) > 0.005 {
		t.Errorf("t1 trackGainDb = %v, want 11.9 (-18 - -29.9)", g)
	}
	// album gain is shared by every track of the album, including the one that
	// contributed no peak
	a1, a2 := got["t1"]["albumGainDb"].(float64), got["t2"]["albumGainDb"].(float64)
	if a1 != a2 || math.Abs(a1-13.455) > 0.01 {
		t.Errorf("albumGainDb = %v / %v, want ~13.455 on both", a1, a2)
	}
	if p := got["t1"]["albumPeak"].(float64); math.Abs(p-0.501187) > 5e-6 {
		t.Errorf("albumPeak = %v, want 0.501187 (-6 dBFS)", p)
	}
	// an unanalysed track in an unanalysed album stays null on every key
	if got["t3"]["trackGainDb"] != nil || got["t3"]["albumGainDb"] != nil {
		t.Errorf("t3 gains = %v / %v, want null", got["t3"]["trackGainDb"], got["t3"]["albumGainDb"])
	}
	// t2 has no measured peak of its own, but the album's is still exact
	if got["t2"]["trackPeak"] != nil {
		t.Errorf("t2 trackPeak = %v, want null", got["t2"]["trackPeak"])
	}
}
