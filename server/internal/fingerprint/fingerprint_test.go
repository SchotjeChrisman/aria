package fingerprint

import (
	"context"
	"strings"
	"testing"

	"aria/internal/db"
	"aria/internal/repo"
)

// The strings below are real fpcalc 1.6.1 stdout, captured from the exact
// command Fingerprinter.one runs. Nothing here execs fpcalc: every repo fixture
// is ~2 s and Chromaprint needs roughly 3 s of audio, so the success path cannot
// be produced locally without synthesising a file with ffmpeg.
func TestParseFPCalc(t *testing.T) {
	tests := []struct {
		name    string
		stdout  string
		wantFP  string
		wantDur int
		wantErr bool
	}{
		{
			// duration is the FULL file length (300 s) even though -length 120
			// capped what was fingerprinted — which is what AcoustID matches on
			name: "real output", stdout: `{"duration": 300.00, "fingerprint": "AQADtEmUaEkSZSoA"}`,
			wantFP: "AQADtEmUaEkSZSoA", wantDur: 300,
		},
		{
			name: "fractional duration rounds to whole seconds",
			// AcoustID's duration is an int and its tolerance is 7 s
			stdout: `{"duration": 311.63, "fingerprint": "AQADs7"}`,
			wantFP: "AQADs7", wantDur: 312,
		},
		{
			name: "trailing newline", stdout: "{\"duration\": 2.00, \"fingerprint\": \"AQ\"}\n",
			wantFP: "AQ", wantDur: 2,
		},
		// Every fpcalc failure exits 2 with the reason on stderr and NOTHING on
		// stdout: "Empty fingerprint" (audio under ~3 s), "Could not open the
		// input file", "Error reading from the audio source".
		{name: "failure writes nothing to stdout", stdout: "", wantErr: true},
		{name: "stderr text is not JSON", stdout: "ERROR: Empty fingerprint", wantErr: true},
		{
			// defensive: valid JSON, no fingerprint, is still a failure
			name: "empty fingerprint field", stdout: `{"duration": 2.00, "fingerprint": ""}`,
			wantErr: true,
		},
		{name: "truncated json", stdout: `{"duration": 300.00, "fing`, wantErr: true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			fp, dur, err := parseFPCalc(tt.stdout)
			if tt.wantErr {
				if err == nil {
					t.Fatalf("want error, got %q/%d", fp, dur)
				}
				return
			}
			if err != nil {
				t.Fatalf("parseFPCalc: %v", err)
			}
			if fp != tt.wantFP || dur != tt.wantDur {
				t.Errorf("got (%q, %d), want (%q, %d)", fp, dur, tt.wantFP, tt.wantDur)
			}
		})
	}
}

func testFP(t *testing.T) (*repo.FP, *repo.Tracks) {
	t.Helper()
	d, err := db.Open(t.TempDir())
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	t.Cleanup(func() { d.Close() })
	return repo.NewFP(d), repo.NewTracks(d)
}

// With no ACOUSTID_KEY the local half still runs and the lookup half must be
// completely dark: no rows touched, no phase noise, and lookedUpAt left NULL so
// that a key added later picks the work straight up.
func TestLookupIsDarkWithoutKey(t *testing.T) {
	fp, tracks := testFP(t)
	ctx := context.Background()
	if err := tracks.UpsertAll(ctx, []repo.Track{{
		ID: "t1", Path: "a.flac", AddedAt: "2026-01-01T00:00:00Z", Title: "T",
		Artist: "A", AlbumArtist: "A", Album: "Al", AlbumID: "al", Format: "FLAC",
	}}); err != nil {
		t.Fatal(err)
	}
	if err := fp.PutFP(ctx, "t1", "AQADtE", 300, 0, 0, "2026-01-01T00:00:00Z"); err != nil {
		t.Fatal(err)
	}

	f := New("/nonexistent-fpcalc", t.TempDir(), fp, "") // no key
	f.log = func(string) {}
	if err := f.lookupAll(ctx); err != nil {
		t.Fatalf("lookupAll with no key: %v", err)
	}
	// still pending: dark is indistinguishable from not-yet-done
	pend, err := fp.ListPendingLookup(ctx, 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(pend) != 1 || pend[0].TrackID != "t1" {
		t.Errorf("pending after a dark pass = %+v, want t1 still pending", pend)
	}
	if s := f.Status().(map[string]any); s["phase"] != "idle" {
		t.Errorf("phase = %v, want idle (no key must not announce a lookup phase)", s["phase"])
	}
}

// A file fpcalc cannot fingerprint must not end the pass, and must report
// fpcalc's own stderr rather than "exit status 2".
func TestFingerprintAllSurvivesAFailingFile(t *testing.T) {
	fp, tracks := testFP(t)
	ctx := context.Background()
	if err := tracks.UpsertAll(ctx, []repo.Track{{
		ID: "t1", Path: "a.flac", AddedAt: "2026-01-01T00:00:00Z", Title: "T",
		Artist: "A", AlbumArtist: "A", Album: "Al", AlbumID: "al", Format: "FLAC",
	}}); err != nil {
		t.Fatal(err)
	}
	f := New("/nonexistent-fpcalc", t.TempDir(), fp, "")
	var logged []string
	f.log = func(m string) { logged = append(logged, m) }
	if err := f.fingerprintAll(ctx); err != nil {
		t.Fatalf("pass aborted on an unrunnable fpcalc: %v", err)
	}
	if len(logged) == 0 || !strings.Contains(strings.Join(logged, "\n"), "a.flac") {
		t.Errorf("failure not reported per file: %v", logged)
	}
	// no row written -> still pending, retried next pass
	pend, err := fp.ListPendingFP(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(pend) != 1 {
		t.Errorf("pending = %d, want the failed file still pending", len(pend))
	}
}
