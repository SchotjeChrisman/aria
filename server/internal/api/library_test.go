package api

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	"aria/internal/config"
	"aria/internal/db"
	"aria/internal/repo"
)

// latinEnricher satisfies api.Enricher + latinNamer + nameResolver with a
// canned raw-name -> Latin-name map.
type latinEnricher struct{ names map[string]string }

func (l *latinEnricher) Run(context.Context) error { return nil }
func (l *latinEnricher) Status() any               { return nil }
func (l *latinEnricher) LatinNames(context.Context) (map[string]string, error) {
	return l.names, nil
}

// mirrors enrich.resolveName: a display name maps back to its raw key,
// anything else passes through.
func (l *latinEnricher) ResolveName(_ context.Context, name string) string {
	for raw, latin := range l.names {
		if latin == name {
			return raw
		}
	}
	return name
}

const classicalAlbumID = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

func classicalDeps(t *testing.T) *Deps {
	t.Helper()
	ctx := context.Background()
	dir := t.TempDir()
	sqlDB, err := db.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { sqlDB.Close() })
	deps := NewDeps(sqlDB, config.Config{DataDir: dir}, "test")
	if err := deps.Tracks.UpsertAll(ctx, []repo.Track{{
		ID: "t1", AlbumID: classicalAlbumID, Album: "Barber, Bruch: Violin Concertos",
		Artist: "Василий Петренко", AlbumArtist: "Barber, Bruch; Esther Yoo", AddedAt: "now",
	}}); err != nil {
		t.Fatal(err)
	}
	// release-level policy from MB, stored in the original script
	if err := deps.EnrichCache.Put(ctx, "album", classicalAlbumID, json.RawMessage(
		`{"v":3,"done":true,"mbid":"ec17a59b","displayArtist":"Esther Yoo","composers":["Barber","Bruch"]}`), "now"); err != nil {
		t.Fatal(err)
	}
	// per-track credits, also in the original script
	if err := deps.EnrichCache.Put(ctx, "track", "t1", json.RawMessage(
		`{"conductor":"Василий Петренко","performers":[{"name":"Василий Петренко","role":"conductor"},{"name":"Esther Yoo","role":"violin"}]}`), "now"); err != nil {
		t.Fatal(err)
	}
	deps.Enricher = &latinEnricher{names: map[string]string{"Василий Петренко": "Vasily Petrenko"}}
	return deps
}

// Display policy: MB's performer becomes the album artist, the composers split
// off the credit, and every credited name reads Latin — while the DB and the
// enrich cache keep the original script.
func TestBuildMergedTracksDisplay(t *testing.T) {
	ctx := context.Background()
	d := classicalDeps(t)
	out, err := buildMergedTracks(ctx, d)
	if err != nil {
		t.Fatal(err)
	}
	m := out[0]
	if got := str(m["albumArtist"]); got != "Esther Yoo" {
		t.Errorf("albumArtist = %v, want %v", got, "Esther Yoo")
	}
	if got := str(m["composer"]); got != "Barber, Bruch" {
		t.Errorf("composer = %v, want %v", got, "Barber, Bruch")
	}
	if got := str(m["artist"]); got != "Vasily Petrenko" {
		t.Errorf("artist = %v, want %v", got, "Vasily Petrenko")
	}
	if got := str(m["conductor"]); got != "Vasily Petrenko" {
		t.Errorf("conductor = %v, want %v", got, "Vasily Petrenko")
	}
	ps, _ := m["performers"].([]any)
	if len(ps) != 2 {
		t.Fatalf("performers = %v, want 2 entries", ps)
	}
	if got := str(ps[0].(map[string]any)["name"]); got != "Vasily Petrenko" {
		t.Errorf("performers[0].name = %v, want %v", got, "Vasily Petrenko")
	}
	if got := str(ps[1].(map[string]any)["name"]); got != "Esther Yoo" {
		t.Errorf("performers[1].name = %v, want %v (unmapped names are untouched)", got, "Esther Yoo")
	}

	// display only: the original script survives in the DB
	tr, err := d.Tracks.ByID(ctx, "t1")
	if err != nil || tr == nil {
		t.Fatalf("ByID = %v, %v", tr, err)
	}
	if tr.Artist != "Василий Петренко" {
		t.Errorf("stored artist = %v, want %v", tr.Artist, "Василий Петренко")
	}
}

// Artist tags have to match on both spellings. Rows written before Latinisation
// are keyed by the raw name; the client only ever sees the Latin one, so every
// tag it can create from now on is keyed by that — and would otherwise be
// accepted, echoed back, and match zero tracks forever.
func TestLatinisedArtistKeepsTags(t *testing.T) {
	for _, tc := range []struct{ name, key string }{
		{"raw key, written before latinisation", "Василий Петренко"},
		{"latin key, the only one the client can send", "Vasily Petrenko"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			ctx := context.Background()
			d := classicalDeps(t)
			if err := d.Tags.Create(ctx, repo.Tag{ID: "g1", Name: "Conductors", CreatedAt: "now"}); err != nil {
				t.Fatal(err)
			}
			if err := d.Tags.AddItem(ctx, "g1", "artist", tc.key); err != nil {
				t.Fatal(err)
			}
			out, err := buildMergedTracks(ctx, d)
			if err != nil {
				t.Fatal(err)
			}
			names, _ := out[0]["tags"].([]string)
			if len(names) != 1 || names[0] != "Conductors" {
				t.Errorf("tags = %v, want [Conductors]", names)
			}
		})
	}
}

// Everything keyed by an artist name is keyed by the original script, while the
// app can only ever ask with the Latin display name it was served.
func TestLatinNameResolvesOnReads(t *testing.T) {
	ctx := context.Background()
	d := classicalDeps(t)
	const raw, latin = "Василий Петренко", "Vasily Petrenko"
	if err := d.Edits.Put(ctx, "artist", raw, json.RawMessage(`{"bio":"the user's own bio"}`)); err != nil {
		t.Fatal(err)
	}
	if err := d.EnrichCache.Put(ctx, "artist", raw, json.RawMessage(`{"area":"Russia"}`), "now"); err != nil {
		t.Fatal(err)
	}
	if err := d.EnrichCache.Put(ctx, "composer", raw, json.RawMessage(`{"epoch":"Romantic"}`), "now"); err != nil {
		t.Fatal(err)
	}
	h := New(d)
	get := func(path string) map[string]any {
		t.Helper()
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest("GET", path, nil))
		if rec.Code != 200 {
			t.Fatalf("GET %s = %d, want 200", path, rec.Code)
		}
		var m map[string]any
		if err := json.Unmarshal(rec.Body.Bytes(), &m); err != nil {
			t.Fatal(err)
		}
		return m
	}

	if got := get("/api/artist/" + url.PathEscape(latin)); got["bio"] != "the user's own bio" || got["area"] != "Russia" {
		t.Errorf("GET /api/artist/%s = %v, want the raw-keyed edit and cache entry", latin, got)
	}
	if got := get("/api/composer/" + url.PathEscape(latin)); got["epoch"] != "Romantic" {
		t.Errorf("GET /api/composer/%s = %v, want the raw-keyed cache entry", latin, got)
	}
	ed := get("/api/edits/artist/" + url.PathEscape(latin))
	if orig, _ := ed["original"].(map[string]any); orig["area"] != "Russia" {
		t.Errorf("edits original = %v, want the enrichment values being overridden", ed["original"])
	}
	if ov, _ := ed["overrides"].(map[string]any); ov["bio"] != "the user's own bio" {
		t.Errorf("edits overrides = %v, want the stored override", ed["overrides"])
	}

	// and the write side lands on the same row, not a second divergent one
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("PATCH", "/api/artists/"+url.PathEscape(latin),
		strings.NewReader(`{"born":"1976"}`)))
	if rec.Code != 200 {
		t.Fatalf("PATCH = %d, want 200", rec.Code)
	}
	raws, err := d.Edits.Get(ctx, "artist", raw)
	if err != nil || raws == nil {
		t.Fatalf("edit row under the raw name: %v, %v", raws, err)
	}
	var m map[string]any
	json.Unmarshal(raws, &m)
	if m["born"] != "1976" || m["bio"] != "the user's own bio" {
		t.Errorf("raw-keyed edit row = %v, want both fields merged into it", m)
	}
	if extra, _ := d.Edits.Get(ctx, "artist", latin); extra != nil {
		t.Errorf("a second edit row appeared under the Latin name: %s", extra)
	}
}

// A user's album edit pins the display artist: it is applied after the policy.
func TestAlbumEditBeatsDisplayArtist(t *testing.T) {
	ctx := context.Background()
	d := classicalDeps(t)
	if err := d.Edits.Put(ctx, "album", classicalAlbumID, json.RawMessage(`{"albumArtist":"My Own Name"}`)); err != nil {
		t.Fatal(err)
	}
	out, err := buildMergedTracks(ctx, d)
	if err != nil {
		t.Fatal(err)
	}
	if got := str(out[0]["albumArtist"]); got != "My Own Name" {
		t.Errorf("albumArtist = %v, want %v", got, "My Own Name")
	}
}

// The rule is a setting, not a hardcode.
func TestClassicalDisplayArtistOff(t *testing.T) {
	ctx := context.Background()
	d := classicalDeps(t)
	if err := d.Settings.Set(ctx, "classicalDisplayArtist", "0"); err != nil {
		t.Fatal(err)
	}
	out, err := buildMergedTracks(ctx, d)
	if err != nil {
		t.Fatal(err)
	}
	if got := str(out[0]["albumArtist"]); got != "Barber, Bruch; Esther Yoo" {
		t.Errorf("albumArtist = %v, want the untouched tag value", got)
	}
	// Latinisation is independent of the classical rule
	if got := str(out[0]["conductor"]); got != "Vasily Petrenko" {
		t.Errorf("conductor = %v, want %v", got, "Vasily Petrenko")
	}
}
