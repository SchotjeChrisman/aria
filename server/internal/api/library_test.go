package api

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"net/url"
	"reflect"
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

// putAlbumBlob replaces the album's enrichment entry — classicalDeps writes the
// pre-v5 shape, with no header list on it.
func putAlbumBlob(t *testing.T, d *Deps, doc string) {
	t.Helper()
	if err := d.EnrichCache.Put(context.Background(), "album", classicalAlbumID, json.RawMessage(doc), "now"); err != nil {
		t.Fatal(err)
	}
}

// The album-header artist line: MusicBrainz's performers latinised, then
// supplemented from Deezer — with the two failure modes that make the merge a
// display-time step rather than something the enricher could have cached.
func TestMergedAlbumArtists(t *testing.T) {
	const (
		yoo = `"displayArtist":"Esther Yoo","composers":["Barber","Bruch"]`
		rpo = "Royal Philharmonic Orchestra"
	)
	for _, tc := range []struct {
		name, blob string
		want       []string
	}{
		{
			name: "Deezer supplements what MusicBrainz left out",
			blob: `{"v":5,"done":true,` + yoo + `,"performers":["Esther Yoo","` + rpo + `"],` +
				`"dzContributors":["Esther Yoo","` + rpo + `","Vasily Petrenko"]}`,
			want: []string{"Esther Yoo", rpo, "Vasily Petrenko"},
		},
		{
			// the whole reason both sides are latinised before comparing: the
			// stored performer is Cyrillic and Deezer's is not
			name: "a name already on the list is not appended in its Latin spelling",
			blob: `{"v":5,"done":true,` + yoo + `,"performers":["Esther Yoo","` + rpo + `","Василий Петренко"],` +
				`"dzContributors":["Esther Yoo","` + rpo + `","Vasily Petrenko"]}`,
			want: []string{"Esther Yoo", rpo, "Vasily Petrenko"},
		},
		{
			name: "a composer Deezer credits is not a performer",
			blob: `{"v":5,"done":true,"displayArtist":"Janine Jansen","composers":["Antonio Vivaldi"],` +
				`"performers":["Janine Jansen"],"dzContributors":["Janine Jansen","Antonio Vivaldi"]}`,
			want: []string{"Janine Jansen"},
		},
		{
			// unresolved spelling: merging would list the same person twice, so
			// the supplement is skipped until the names phase catches up
			name: "an unresolvable performer suppresses the supplement",
			blob: `{"v":5,"done":true,` + yoo + `,"performers":["Esther Yoo","Иван Иванов"],` +
				`"dzContributors":["Esther Yoo","Ivan Ivanov","` + rpo + `"]}`,
			want: []string{"Esther Yoo", "Иван Иванов"},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			d := classicalDeps(t)
			putAlbumBlob(t, d, tc.blob)
			out, err := buildMergedTracks(context.Background(), d)
			if err != nil {
				t.Fatal(err)
			}
			got, _ := out[0]["albumArtists"].([]string)
			if !reflect.DeepEqual(got, tc.want) {
				t.Errorf("albumArtists = %v, want %v", got, tc.want)
			}
		})
	}
}

// An ordinary album has no composer split, so there is no header list to
// publish and no empty array either — the key is simply absent.
func TestOrdinaryAlbumHasNoAlbumArtists(t *testing.T) {
	d := classicalDeps(t)
	putAlbumBlob(t, d, `{"v":5,"done":true,"mbid":"rel-1","album":"A","albumArtist":"B"}`)
	out, err := buildMergedTracks(context.Background(), d)
	if err != nil {
		t.Fatal(err)
	}
	if v, ok := out[0]["albumArtists"]; ok {
		t.Errorf("albumArtists = %v, want the key to be absent", v)
	}
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

// A user's album edit pins the display artist: it is applied after the policy,
// and it takes the derived header list with it — otherwise the album page would
// keep rendering the credit the user was overriding.
func TestAlbumEditBeatsDisplayArtist(t *testing.T) {
	ctx := context.Background()
	d := classicalDeps(t)
	putAlbumBlob(t, d, `{"v":5,"done":true,"displayArtist":"Esther Yoo","composers":["Barber"],`+
		`"performers":["Esther Yoo","Royal Philharmonic Orchestra"]}`)
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
	if v, ok := out[0]["albumArtists"]; ok {
		t.Errorf("albumArtists = %v, want it gone with the edited scalar", v)
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

// ---- correction precedence --------------------------------------------------

const fixAlbumID = "cccccccccccccccccccccccccccccccccccccccc"

// precedenceDeps builds one album, one track, and whichever of the four overlay
// layers the case wants. "" means the layer is absent.
func precedenceDeps(t *testing.T, derivedTrack, derivedAlbum, albumEdit, trackEdit string) *Deps {
	t.Helper()
	ctx := context.Background()
	dir := t.TempDir()
	sqlDB, err := db.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { sqlDB.Close() })
	d := NewDeps(sqlDB, config.Config{DataDir: dir}, "test")
	no := 9
	if err := d.Tracks.UpsertAll(ctx, []repo.Track{{
		ID: "t1", AlbumID: fixAlbumID, Title: "file title", Album: "file album",
		AlbumArtist: "file artist", TrackNo: &no, AddedAt: "now",
	}}); err != nil {
		t.Fatal(err)
	}
	for _, l := range []struct{ kind, key, doc string }{
		{"track", "t1", derivedTrack}, {"album", fixAlbumID, derivedAlbum},
	} {
		if l.doc == "" {
			continue
		}
		if err := d.EnrichCache.Put(ctx, l.kind, l.key, json.RawMessage(l.doc), "now"); err != nil {
			t.Fatal(err)
		}
	}
	for _, l := range []struct{ kind, key, doc string }{
		{"track", "t1", trackEdit}, {"album", fixAlbumID, albumEdit},
	} {
		if l.doc == "" {
			continue
		}
		if err := d.Edits.Put(ctx, l.kind, l.key, json.RawMessage(l.doc)); err != nil {
			t.Fatal(err)
		}
	}
	return d
}

// The precedence contract, which is the whole of "a manual edit always beats an
// automatic correction". There is no ownership check and no provenance test in
// the merge — the guarantee IS this order, so the order is what gets pinned:
// file tags -> derived track blob -> derived album blob -> album edits -> track
// edits, later always winning.
func TestCorrectionPrecedence(t *testing.T) {
	const (
		mbTrack = `{"title":"MB Title","trackNo":3,"mbRecordingId":"rec-1"}`
		mbAlbum = `{"v":4,"done":true,"mbid":"rel-1","album":"MB Album","albumArtist":"MB Artist","year":1996}`
		aEdit   = `{"album":"My Album","albumArtist":"My Artist","year":2001}`
		tEdit   = `{"title":"My Title","trackNo":7}`
	)
	cases := []struct {
		name                             string
		dTrack, dAlbum, aEdit, tEdit     string
		wantTitle, wantAlbum, wantArtist string
		wantTrackNo, wantYear            float64
	}{
		{name: "file tags only",
			wantTitle: "file title", wantAlbum: "file album", wantArtist: "file artist", wantTrackNo: 9},
		{name: "derived track beats file tags", dTrack: mbTrack,
			wantTitle: "MB Title", wantAlbum: "file album", wantArtist: "file artist", wantTrackNo: 3},
		{name: "derived album beats file tags", dTrack: mbTrack, dAlbum: mbAlbum,
			wantTitle: "MB Title", wantAlbum: "MB Album", wantArtist: "MB Artist", wantTrackNo: 3, wantYear: 1996},
		{name: "album edit beats both derived layers", dTrack: mbTrack, dAlbum: mbAlbum, aEdit: aEdit,
			wantTitle: "MB Title", wantAlbum: "My Album", wantArtist: "My Artist", wantTrackNo: 3, wantYear: 2001},
		{name: "track edit beats everything", dTrack: mbTrack, dAlbum: mbAlbum, aEdit: aEdit, tEdit: tEdit,
			wantTitle: "My Title", wantAlbum: "My Album", wantArtist: "My Artist", wantTrackNo: 7, wantYear: 2001},
		// order-independence: the user edited BEFORE the match ever ran, and the
		// match must still not overwrite it
		{name: "edit made before the match still wins", aEdit: aEdit, tEdit: tEdit,
			wantTitle: "My Title", wantAlbum: "My Album", wantArtist: "My Artist", wantTrackNo: 7, wantYear: 2001},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			d := precedenceDeps(t, tc.dTrack, tc.dAlbum, tc.aEdit, tc.tEdit)
			out, err := buildMergedTracks(context.Background(), d)
			if err != nil {
				t.Fatal(err)
			}
			m := out[0]
			if got := str(m["title"]); got != tc.wantTitle {
				t.Errorf("title = %q, want %q", got, tc.wantTitle)
			}
			if got := str(m["album"]); got != tc.wantAlbum {
				t.Errorf("album = %q, want %q", got, tc.wantAlbum)
			}
			if got := str(m["albumArtist"]); got != tc.wantArtist {
				t.Errorf("albumArtist = %q, want %q", got, tc.wantArtist)
			}
			if got := num(m["trackNo"]); got != tc.wantTrackNo {
				t.Errorf("trackNo = %v, want %v", got, tc.wantTrackNo)
			}
			if got := num(m["year"]); got != tc.wantYear {
				t.Errorf("year = %v, want %v", got, tc.wantYear)
			}
		})
	}
}

// num coerces a merged-map number, which is an int from a struct field and a
// float64 once it has been through a JSON blob.
func num(v any) float64 {
	switch x := v.(type) {
	case float64:
		return x
	case int:
		return float64(x)
	}
	return 0
}

// The enrichment-derived genres reach the merged track's `genres` array,
// without the raw `genre` string moving — which is what keeps display, the
// edits overlay and every stored smart rule intact.
func TestMergedGenresUnionSources(t *testing.T) {
	ctx := context.Background()
	const other = "cccccccccccccccccccccccccccccccccccccccc"
	for _, tc := range []struct {
		name, tag, doc string
		want           []string
	}{
		{
			name: "file tag first, then MusicBrainz genres, then Discogs styles",
			tag:  "Rock",
			doc:  `{"v":1,"mbGenres":["alternative rock","art rock"],"dgGenres":["Electronic"],"dgStyles":["Euro-Disco"]}`,
			want: []string{"Rock", "Alternative Rock", "Electronic", "Disco"},
		},
		{
			// the case that motivated the phase: a bandcamp FLAC or classical
			// rip with no GENRE tag at all was invisible in genre browse
			name: "untagged album becomes browsable",
			tag:  "",
			doc:  `{"v":1,"mbGenres":["jazz"]}`,
			want: []string{"Jazz"},
		},
		{
			name: "already-known genre is not duplicated",
			tag:  "Rock",
			doc:  `{"v":1,"mbGenres":["rock"]}`,
			want: []string{"Rock"},
		},
		{
			name: "unmappable enrichment genres are dropped, not minted as nodes",
			tag:  "Rock",
			doc:  `{"v":1,"mbGenres":["zydeco","hauntology"]}`,
			want: []string{"Rock"},
		},
		{
			name: "no sources row leaves the old behaviour exactly",
			tag:  "Rock;Jazz",
			doc:  "",
			want: []string{"Rock", "Jazz"},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			d := classicalDeps(t)
			genre := tc.tag
			if err := d.Tracks.UpsertAll(ctx, []repo.Track{{
				ID: "t2", Path: "/music/b/a.flac", AlbumID: other, Album: "A", Artist: "B", AlbumArtist: "B",
				AddedAt: "now", Genre: &genre,
			}}); err != nil {
				t.Fatal(err)
			}
			if tc.doc != "" {
				if err := d.EnrichCache.Put(ctx, "sources", other, json.RawMessage(tc.doc), "now"); err != nil {
					t.Fatal(err)
				}
			}
			out, err := buildMergedTracks(ctx, d)
			if err != nil {
				t.Fatal(err)
			}
			for _, m := range out {
				if m["id"] != "t2" {
					// the other album has no sources row: its array must be
					// untouched by this album's, i.e. no cross-album bleed
					if g, _ := m["genres"].([]string); len(g) != 0 {
						t.Errorf("album %v gained genres %v", m["albumId"], g)
					}
					continue
				}
				got, _ := m["genres"].([]string)
				if !reflect.DeepEqual(got, tc.want) {
					t.Errorf("genres = %v, want %v", got, tc.want)
				}
				if got, _ := m["genre"].(string); got != tc.tag {
					t.Errorf("raw genre = %q, want the untouched file tag %q", got, tc.tag)
				}
			}
		})
	}
}
