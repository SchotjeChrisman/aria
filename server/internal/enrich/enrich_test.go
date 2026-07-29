package enrich

import (
	"context"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"aria/internal/db"
	"aria/internal/repo"
)

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func resp(code int, body string) *http.Response {
	return &http.Response{StatusCode: code, Body: io.NopCloser(strings.NewReader(body)), Header: make(http.Header)}
}

// TestEnrichAlbumArtSlot pins the behavioral change: enrichAlbum's API art
// fallback lands in <id>.api.jpg and never touches the embedded <id>.jpg slot.
// CoverArtArchive + MusicBrainz are stubbed to fail so the Deezer cover path
// (which actually returns bytes) is exercised — all hermetic via a RoundTripper.
func TestEnrichAlbumArtSlot(t *testing.T) {
	dir := t.TempDir()
	sqldb, err := db.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { sqldb.Close() })
	ctx := context.Background()
	e := New(ctx, repo.NewTracks(sqldb), repo.NewEnrich(sqldb), dir)

	rt := roundTripFunc(func(r *http.Request) (*http.Response, error) {
		switch {
		case strings.Contains(r.URL.Host, "coverartarchive"), strings.Contains(r.URL.Host, "musicbrainz"):
			return resp(404, ""), nil
		case strings.Contains(r.URL.Path, "/search/album"):
			return resp(200, `{"data":[{"cover_xl":"https://api.deezer.com/cover.jpg"}]}`), nil
		case strings.Contains(r.URL.Path, "/cover.jpg"):
			return resp(200, "JPEGDATA"), nil
		default:
			return resp(404, ""), nil
		}
	})
	for _, pc := range []*politeClient{e.pc, e.mb.c, e.dz.c} {
		pc.hc.Transport = rt
	}

	albumID := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	mbid := "11111111-1111-1111-1111-111111111111"
	if err := e.put(ctx, KindAlbum, albumID, albumCache{Mbid: &mbid}); err != nil {
		t.Fatal(err)
	}
	ts := []repo.Track{{ID: "t1", AlbumID: albumID, Album: "Alb", AlbumArtist: "Art"}}
	if err := e.enrichAlbum(ctx, albumID, ts); err != nil {
		t.Fatal(err)
	}

	got, err := os.ReadFile(filepath.Join(dir, "art", albumID+".api.jpg"))
	if err != nil || string(got) != "JPEGDATA" {
		t.Fatalf(".api.jpg = %q, err %v", got, err)
	}
	if _, err := os.Stat(filepath.Join(dir, "art", albumID+".jpg")); !os.IsNotExist(err) {
		t.Fatalf("embedded .jpg slot must not be written (err=%v)", err)
	}
}

// stubMB points every outbound client at f (MusicBrainz, Deezer, Wikipedia and
// the binary fetcher all share the same shape of politeClient).
func stubMB(e *Enricher, f roundTripFunc) {
	for _, pc := range []*politeClient{e.pc, e.mb.c, e.dz.c, e.wiki.c, e.oo.c, e.lrc.c} {
		pc.hc.Transport = f
	}
}

func newTestEnricher(t *testing.T) (*Enricher, context.Context) {
	t.Helper()
	dir := t.TempDir()
	sqldb, err := db.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { sqldb.Close() })
	ctx := context.Background()
	return New(ctx, repo.NewTracks(sqldb), repo.NewEnrich(sqldb), dir), ctx
}

// The release-level display policy has to survive the round trip into the
// album cache — that blob is what /api/tracks reads.
func TestEnrichAlbumStoresDisplayArtist(t *testing.T) {
	e, ctx := newTestEnricher(t)
	stubMB(e, func(r *http.Request) (*http.Response, error) {
		if strings.Contains(r.URL.Host, "musicbrainz") && strings.Contains(r.URL.Path, "/release/") {
			return resp(200, `{"id":"ec17a59b","artist-credit":[
				{"name":"Barber","joinphrase":", ","artist":{"id":"mb-barber","name":"Barber"}},
				{"name":"Bruch","joinphrase":"; ","artist":{"id":"mb-bruch","name":"Bruch"}},
				{"name":"Esther Yoo","joinphrase":", ","artist":{"id":"mb-yoo","name":"Esther Yoo"}},
				{"name":"Василий Петренко","joinphrase":", ","artist":{"id":"mb-petrenko","name":"Василий Петренко"}},
				{"name":"Royal Philharmonic Orchestra","joinphrase":"","artist":{"id":"mb-rpo","name":"Royal Philharmonic Orchestra"}}],
				"relations":[
				{"type":"instrument","attributes":["violin"],"artist":{"id":"mb-yoo","name":"Esther Yoo"}},
				{"type":"conductor","artist":{"id":"mb-petrenko","name":"Василий Петренко"}},
				{"type":"orchestra","artist":{"id":"mb-rpo","name":"Royal Philharmonic Orchestra"}}]}`), nil
		}
		return resp(404, ""), nil
	})

	albumID, mbid := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "ec17a59b"
	if err := e.put(ctx, KindAlbum, albumID, albumCache{Mbid: &mbid}); err != nil {
		t.Fatal(err)
	}
	ts := []repo.Track{{ID: "t1", AlbumID: albumID, Album: "Barber, Bruch", AlbumArtist: "Barber, Bruch; Esther Yoo", HasArt: true}}
	if err := e.enrichAlbum(ctx, albumID, ts); err != nil {
		t.Fatal(err)
	}
	var a albumCache
	if !e.cacheGet(ctx, KindAlbum, albumID, &a) {
		t.Fatal("album cache entry missing")
	}
	if a.DisplayArtist != "Esther Yoo" {
		t.Errorf("displayArtist = %v, want %v", a.DisplayArtist, "Esther Yoo")
	}
	if len(a.Composers) != 2 || a.Composers[0] != "Barber" || a.Composers[1] != "Bruch" {
		t.Errorf("composers = %v, want [Barber Bruch]", a.Composers)
	}
	if a.V != albumV {
		t.Errorf("v = %d, want %d", a.V, albumV)
	}
}

// nameLatin is additive: the cache key stays the original script, and
// LatinNames is what the display layer substitutes with.
func TestEnrichArtistStoresLatinName(t *testing.T) {
	e, ctx := newTestEnricher(t)
	stubMB(e, func(r *http.Request) (*http.Response, error) {
		if !strings.Contains(r.URL.Host, "musicbrainz") {
			return resp(404, ""), nil
		}
		if r.URL.Query().Get("query") != "" { // artist search
			return resp(200, `{"artists":[{"id":"7de3202f","name":"Василий Петренко"}]}`), nil
		}
		return resp(200, `{"id":"7de3202f","name":"Василий Петренко","sort-name":"Petrenko, Vasily","type":"Person",
			"aliases":[{"name":"Vasily Petrenko","sort-name":"Petrenko, Vasily","locale":"en","type":"Artist name","primary":true}]}`), nil
	})

	const raw = "Василий Петренко"
	e.enrichArtist(ctx, raw, "")
	ent := e.artistGet(ctx, raw)
	if ent == nil {
		t.Fatal("no artist entry stored under the original name")
	}
	if ent.NameLatin != "Vasily Petrenko" || ent.NameLatinSrc != "alias-en" {
		t.Errorf("nameLatin = (%q, %q), want (%q, %q)", ent.NameLatin, ent.NameLatinSrc, "Vasily Petrenko", "alias-en")
	}
	if ent.Mbid != "7de3202f" {
		t.Errorf("mbid = %q, want %q (saves a search on every later backfill)", ent.Mbid, "7de3202f")
	}
	names, err := e.LatinNames(ctx)
	if err != nil || names[raw] != "Vasily Petrenko" {
		t.Errorf("LatinNames[%q] = %v (err %v), want %v", raw, names[raw], err, "Vasily Petrenko")
	}
	// portraits must resolve under either spelling, and the raw key must stay
	ent.Image = "http://example.invalid/p.jpg"
	e.artistPut(ctx, raw, ent)
	people, err := e.People(ctx)
	if err != nil || people[raw] == "" || people["Vasily Petrenko"] != people[raw] {
		t.Errorf("People = %v (err %v), want the portrait under both spellings", people, err)
	}
	// and a request for the Latin spelling finds the original entry
	if got := e.resolveName(ctx, "Vasily Petrenko"); got != raw {
		t.Errorf("resolveName(%q) = %q, want %q", "Vasily Petrenko", got, raw)
	}

	// re-identify arrives with the Latin display name too. Writing a second
	// entry under it would shadow this one forever, because resolveName
	// short-circuits on any name that is itself a cache key.
	if _, err := e.ReidentifyArtist(ctx, "Vasily Petrenko", "7de3202f-0e33-4485-a27c-ec1302df73aa"); err != nil {
		t.Fatal(err)
	}
	if _, found, _ := e.cache.Get(ctx, KindArtist, "Vasily Petrenko"); found {
		t.Error("reidentify minted a duplicate entry under the Latin name")
	}
	if again := e.artistGet(ctx, raw); again == nil || again.NameLatin != "Vasily Petrenko" {
		t.Errorf("original-script entry after reidentify = %v, want it re-enriched in place", again)
	}
}
