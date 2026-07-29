package api

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"

	"aria/internal/config"
	"aria/internal/db"
	"aria/internal/repo"
)

// The manual album flags are a trust boundary: an unknown state or a non-bool
// locked must reject the whole patch, exactly like every other bad field.
func TestCleanEditsAlbumFlags(t *testing.T) {
	cases := []struct {
		name, body string
		want       any // nil = the patch must be rejected
		field      string
	}{
		{name: "state local", body: `{"state":"local"}`, field: "state", want: "local"},
		{name: "state matched", body: `{"state":"matched"}`, field: "state", want: "matched"},
		// "review" became settable in Phase 4: a user can push an album the
		// matcher settled back into the review queue.
		{name: "state review", body: `{"state":"review"}`, field: "state", want: "review"},
		{name: "state unknown", body: `{"state":"pending"}`},
		{name: "state not a string", body: `{"state":1}`},
		{name: "locked true", body: `{"locked":true}`, field: "locked", want: true},
		{name: "locked false", body: `{"locked":false}`, field: "locked", want: false},
		{name: "locked not a bool", body: `{"locked":"yes"}`},
		{name: "disambiguation", body: `{"disambiguation":" 2019-05, Amsterdam "}`,
			field: "disambiguation", want: "2019-05, Amsterdam"},
		{name: "disambiguation empty", body: `{"disambiguation":"  "}`},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var body map[string]json.RawMessage
			if err := json.Unmarshal([]byte(tc.body), &body); err != nil {
				t.Fatal(err)
			}
			got := cleanEdits(body, "album")
			if tc.field == "" {
				if got != nil {
					t.Errorf("cleanEdits(%s) = %v, want nil", tc.body, got)
				}
				return
			}
			if got[tc.field] != tc.want {
				t.Errorf("cleanEdits(%s)[%s] = %v, want %v", tc.body, tc.field, got[tc.field], tc.want)
			}
		})
	}
}

// ---- provenance and the revert path -----------------------------------------

// stubUnmatcher is api.Enricher + unmatcher, recording what the PATCH asked for.
type stubUnmatcher struct {
	called bool
	local  bool
}

func (s *stubUnmatcher) Run(context.Context) error { return nil }
func (s *stubUnmatcher) Status() any               { return nil }
func (s *stubUnmatcher) SetLocal(_ context.Context, _ string, _ []repo.Track, local bool) error {
	s.called, s.local = true, local
	return nil
}

const editsAlbumID = "dddddddddddddddddddddddddddddddddddddddd"

func editsDeps(t *testing.T) (*Deps, *stubUnmatcher) {
	t.Helper()
	ctx := context.Background()
	dir := t.TempDir()
	sqlDB, err := db.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { sqlDB.Close() })
	d := NewDeps(sqlDB, config.Config{DataDir: dir}, "test")
	if err := d.Tracks.UpsertAll(ctx, []repo.Track{{
		ID: "t1", AlbumID: editsAlbumID, Title: "file title", Album: "file album",
		AlbumArtist: "file artist", AddedAt: "now",
	}}); err != nil {
		t.Fatal(err)
	}
	s := &stubUnmatcher{}
	d.Enricher = s
	return d, s
}

// matched wires the two rows a confirmed match leaves behind: the decision and
// the derived album blob that carries the same release MBID.
func matched(t *testing.T, d *Deps) {
	t.Helper()
	ctx := context.Background()
	mbid := "ec17a59b-6ca3-4817-9ca9-67b137550819"
	dist, sep := 0.04, 0.31
	if err := d.Matches.Put(ctx, repo.Decision{
		AlbumID: editsAlbumID, State: "matched", Reason: "ok", ReleaseMbid: &mbid,
		Distance: &dist, Separation: &sep, DecidedAt: "2026-07-29T10:12:03.000Z",
		Candidates: json.RawMessage(`[{"mbid":"` + mbid + `","title":"Barber, Bruch: Violin Concertos"}]`),
	}); err != nil {
		t.Fatal(err)
	}
	if err := d.EnrichCache.Put(ctx, "album", editsAlbumID, json.RawMessage(
		`{"v":4,"done":true,"mbid":"`+mbid+`","album":"MB Album"}`), "now"); err != nil {
		t.Fatal(err)
	}
}

// `source` is the provenance requirement: one object per entity, present only
// while the derived layer is actually being applied.
func TestEditsSource(t *testing.T) {
	cases := []struct {
		name  string
		setup func(*testing.T, *Deps)
		want  bool
		path  string
	}{
		{name: "album, never matched", path: "/api/edits/album/" + editsAlbumID},
		{name: "album, matched", setup: matched, want: true, path: "/api/edits/album/" + editsAlbumID},
		{name: "track inherits its album's source", setup: matched, want: true, path: "/api/edits/track/t1"},
		// the derived layer is gone but the decision row survives: no source,
		// because nothing derived is on screen to attribute
		{name: "matched then unmatched", want: false, path: "/api/edits/album/" + editsAlbumID,
			setup: func(t *testing.T, d *Deps) {
				matched(t, d)
				if err := d.EnrichCache.Put(context.Background(), "album", editsAlbumID,
					json.RawMessage(`{"v":4,"done":true}`), "now"); err != nil {
					t.Fatal(err)
				}
			}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			d, _ := editsDeps(t)
			if tc.setup != nil {
				tc.setup(t, d)
			}
			rec := httptest.NewRecorder()
			New(d).ServeHTTP(rec, httptest.NewRequest("GET", tc.path, nil))
			if rec.Code != 200 {
				t.Fatalf("GET %s = %d, want 200", tc.path, rec.Code)
			}
			var body map[string]any
			if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
				t.Fatal(err)
			}
			src, _ := body["source"].(map[string]any)
			if (src != nil) != tc.want {
				t.Fatalf("source = %v, want present=%v", body["source"], tc.want)
			}
			if !tc.want {
				return
			}
			if src["releaseTitle"] != "Barber, Bruch: Violin Concertos" || src["kind"] != "musicbrainz" {
				t.Errorf("source = %v, want the matched release named", src)
			}
			// derived values are `original`, never `overrides`: that is what
			// makes the editor's reset button revert to the correction
			orig, _ := body["original"].(map[string]any)
			if orig["album"] != "MB Album" {
				t.Errorf("original.album = %v, want the derived value", orig["album"])
			}
			if ov, _ := body["overrides"].(map[string]any); len(ov) != 0 {
				t.Errorf("overrides = %v, want empty — nothing was typed by hand", ov)
			}
		})
	}
}

// The revert path: a state PATCH drops the derived layer immediately, and
// clearing it re-arms re-derivation. The API's job is only to route the verdict;
// what SetLocal deletes is pinned in the enrich package.
func TestAlbumStatePatchReverts(t *testing.T) {
	cases := []struct {
		name, body        string
		wantCall, wantLoc bool
	}{
		{name: "local drops the derived layer", body: `{"state":"local"}`, wantCall: true, wantLoc: true},
		{name: "clearing re-arms re-derivation", body: `{"state":null}`, wantCall: true},
		{name: "back to matched re-arms too", body: `{"state":"matched"}`, wantCall: true},
		{name: "an unrelated field touches nothing", body: `{"genre":"Classical"}`},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			d, s := editsDeps(t)
			rec := httptest.NewRecorder()
			New(d).ServeHTTP(rec, httptest.NewRequest("PATCH", "/api/albums/"+editsAlbumID,
				strings.NewReader(tc.body)))
			if rec.Code != 200 {
				t.Fatalf("PATCH = %d (%s), want 200", rec.Code, rec.Body)
			}
			if s.called != tc.wantCall || s.local != tc.wantLoc {
				t.Errorf("SetLocal called=%v local=%v, want called=%v local=%v",
					s.called, s.local, tc.wantCall, tc.wantLoc)
			}
		})
	}
}
