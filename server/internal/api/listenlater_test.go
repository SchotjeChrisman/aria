package api

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"aria/internal/config"
	"aria/internal/db"
	"aria/internal/repo"
)

// llDeps seeds a profile and a fresh extAlbum cache entry, so POST
// /api/listenlater resolves entirely from cache and the test never touches
// Deezer or MusicBrainz.
func llDeps(t *testing.T, artist, title string, doc string) *Deps {
	t.Helper()
	d, err := db.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { d.Close() })
	deps := NewDeps(d, config.Config{}, "test")
	ctx := context.Background()
	if err := repo.NewProfiles(d).Create(ctx, repo.Profile{ID: "p1", Name: "L", Color: "#000000", CreatedAt: "t"}); err != nil {
		t.Fatal(err)
	}
	at := time.Now().UTC().Format("2006-01-02T15:04:05.000Z")
	if err := deps.EnrichCache.Put(ctx, "extAlbum", extKey(artist, title), json.RawMessage(doc), at); err != nil {
		t.Fatal(err)
	}
	return deps
}

func addTrack(t *testing.T, deps *Deps, id, albumArtist, album, mbAlbumID string) {
	t.Helper()
	_, err := deps.DB.Exec(
		`INSERT INTO tracks (id, path, addedAt, title, artist, albumArtist, album, albumId, mbAlbumId)
		 VALUES (?,?,?,?,?,?,?,?,?)`,
		id, "/m/"+id+".flac", "t", "Track", albumArtist, albumArtist, album, "alb-"+id, mbAlbumID)
	if err != nil {
		t.Fatal(err)
	}
}

// An album saved while unowned disappears from the list once a rip tagged with
// any release in its release group lands in the library — and the row is
// deleted, not merely hidden.
func TestListenLaterDropsOnAcquireByReleaseGroup(t *testing.T) {
	const doc = `{"id":"rg:aa997ea0-2936-40bd-884d-3af8a0e064dc",
		"rgMbid":"aa997ea0-2936-40bd-884d-3af8a0e064dc","upc":"886443927087","deezerId":6575789,
		"artist":"Daft Punk","title":"Random Access Memories","cover":"https://cdn/x.jpg",
		"date":"2013-05-17","type":"album","tracks":[],
		"releases":["5000a285-b67e-4cfc-b54b-2b98f1810d2e","36e2aede-346d-4931-8565-78d810d167c7"]}`
	deps := llDeps(t, "Daft Punk", "Random Access Memories", doc)
	h := New(deps)

	get := func() []repo.ListenLater {
		t.Helper()
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest("GET", "/api/listenlater?profileId=p1", nil))
		if rec.Code != 200 {
			t.Fatalf("GET = %d: %s", rec.Code, rec.Body.String())
		}
		var out []repo.ListenLater
		if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
			t.Fatal(err)
		}
		return out
	}

	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("POST", "/api/listenlater",
		strings.NewReader(`{"profileId":"p1","artist":"Daft Punk","title":"Random Access Memories"}`)))
	if rec.Code != 200 {
		t.Fatalf("POST = %d: %s", rec.Code, rec.Body.String())
	}
	var saved repo.ListenLater
	if err := json.Unmarshal(rec.Body.Bytes(), &saved); err != nil {
		t.Fatal(err)
	}
	if saved.ID != "rg:aa997ea0-2936-40bd-884d-3af8a0e064dc" {
		t.Fatalf("id = %q, want the release-group key", saved.ID)
	}
	if saved.UPC == nil || *saved.UPC != "886443927087" {
		t.Fatalf("upc not carried across: %+v", saved.UPC)
	}

	if got := get(); len(got) != 1 {
		t.Fatalf("before acquiring: %d entries, want 1", len(got))
	}

	// A different edition of the same record — the 2013 XW release, not the one
	// the entry was created from. Release-group identity must still match.
	addTrack(t, deps, "t1", "Daft Punk", "Random Access Memories (Bonus Edition)",
		"36e2aede-346d-4931-8565-78d810d167c7")

	if got := get(); len(got) != 0 {
		t.Fatalf("after acquiring: %d entries, want 0", len(got))
	}
	// Filtered *and* deleted: a second read must not resurrect it.
	rows, err := deps.ListenLater.List(context.Background(), "p1")
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 0 {
		t.Fatalf("row survived the drop-off: %+v", rows)
	}
}

// Rips with no MusicBrainz tag are common, so artist + normalized title has to
// clear the entry too. normTitle ignores edition suffixes, so a "(Deluxe
// Edition)" rip counts as owning the album.
func TestListenLaterDropsOnAcquireByTitleFallback(t *testing.T) {
	const doc = `{"id":"dz:650278821","deezerId":650278821,"artist":"Coldplay","title":"Moon Music",
		"cover":null,"date":"2024-10-04","type":"album","tracks":[]}`
	deps := llDeps(t, "Coldplay", "Moon Music", doc)
	h := New(deps)

	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("POST", "/api/listenlater",
		strings.NewReader(`{"profileId":"p1","artist":"Coldplay","title":"Moon Music"}`)))
	if rec.Code != 200 {
		t.Fatalf("POST = %d: %s", rec.Code, rec.Body.String())
	}
	var saved repo.ListenLater
	json.Unmarshal(rec.Body.Bytes(), &saved)
	if saved.ID != "dz:650278821" {
		t.Fatalf("id = %q, want the Deezer fallback key", saved.ID)
	}

	// No mbAlbumId at all, and a different-looking title.
	addTrack(t, deps, "t1", "Coldplay", "Moon Music (Deluxe Edition)", "")

	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("GET", "/api/listenlater?profileId=p1", nil))
	var out []repo.ListenLater
	json.Unmarshal(rec.Body.Bytes(), &out)
	if len(out) != 0 {
		t.Fatalf("untagged rip did not clear the entry: %+v", out)
	}
}

// Saving the same album twice is a no-op, not a duplicate or an error — the
// menu item is easy to hit twice.
func TestListenLaterAddIsIdempotent(t *testing.T) {
	const doc = `{"id":"dz:1","deezerId":1,"artist":"A","title":"B","cover":null,"date":"2024-01-01","type":"album","tracks":[]}`
	deps := llDeps(t, "A", "B", doc)
	h := New(deps)

	for range 2 {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest("POST", "/api/listenlater",
			strings.NewReader(`{"profileId":"p1","artist":"A","title":"B"}`)))
		if rec.Code != 200 {
			t.Fatalf("POST = %d: %s", rec.Code, rec.Body.String())
		}
	}
	rows, err := deps.ListenLater.List(context.Background(), "p1")
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 1 {
		t.Fatalf("%d rows after a double add, want 1", len(rows))
	}

	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("DELETE", "/api/listenlater/dz:1?profileId=p1", nil))
	if rec.Code != 200 {
		t.Fatalf("DELETE = %d: %s", rec.Code, rec.Body.String())
	}
	rows, _ = deps.ListenLater.List(context.Background(), "p1")
	if len(rows) != 0 {
		t.Fatalf("%d rows after delete, want 0", len(rows))
	}
}

// normTitle keeps only [a-z0-9], so "÷" and "=" both normalize to "". Two
// albums with unusable keys must not be treated as the same record — this rule
// DELETES rows, so a false match is unrecoverable data loss.
func TestListenLaterEmptyTitleKeyNeverMatches(t *testing.T) {
	const doc = `{"id":"dz:99","deezerId":99,"artist":"Ed Sheeran","title":"=",
		"cover":null,"date":"2021-10-29","type":"album","tracks":[]}`
	deps := llDeps(t, "Ed Sheeran", "=", doc)
	h := New(deps)

	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("POST", "/api/listenlater",
		strings.NewReader(`{"profileId":"p1","artist":"Ed Sheeran","title":"="}`)))
	if rec.Code != 200 {
		t.Fatalf("POST = %d: %s", rec.Code, rec.Body.String())
	}
	var saved repo.ListenLater
	json.Unmarshal(rec.Body.Bytes(), &saved)
	if saved.TitleKey != "" {
		t.Fatalf("titleKey = %q, expected the normalization to empty this test relies on", saved.TitleKey)
	}

	// A *different* album by the same artist, whose title also normalizes away.
	addTrack(t, deps, "t1", "Ed Sheeran", "÷", "")

	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("GET", "/api/listenlater?profileId=p1", nil))
	var out []repo.ListenLater
	json.Unmarshal(rec.Body.Bytes(), &out)
	if len(out) != 1 {
		t.Fatalf("unrelated album cleared the entry: %d left, want 1", len(out))
	}
	rows, _ := deps.ListenLater.List(context.Background(), "p1")
	if len(rows) != 1 {
		t.Fatalf("row was deleted: %d left, want 1", len(rows))
	}
}

// An entry saved before MusicBrainz knew the record is keyed "dz:<id>"; once
// the cache refreshes it resolves to "rg:<mbid>". Saving again must re-key the
// existing row, not leave the album listed twice under two ids.
func TestListenLaterIdUpgradeReplacesRow(t *testing.T) {
	const before = `{"id":"dz:650278821","deezerId":650278821,"artist":"Coldplay","title":"Moon Music",
		"cover":null,"date":"2024-10-04","type":"album","tracks":[]}`
	deps := llDeps(t, "Coldplay", "Moon Music", before)
	h := New(deps)
	ctx := context.Background()

	post := func() {
		t.Helper()
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest("POST", "/api/listenlater",
			strings.NewReader(`{"profileId":"p1","artist":"Coldplay","title":"Moon Music"}`)))
		if rec.Code != 200 {
			t.Fatalf("POST = %d: %s", rec.Code, rec.Body.String())
		}
	}
	post()

	// MusicBrainz has now ingested it; the 30-day refresh rewrites the cache.
	const after = `{"id":"rg:3988c875-b35f-4c3e-b143-ccb484d45347",
		"rgMbid":"3988c875-b35f-4c3e-b143-ccb484d45347","deezerId":650278821,
		"artist":"Coldplay","title":"Moon Music","cover":null,"date":"2024-10-04",
		"type":"album","tracks":[],"releases":["aaaaaaaa-0000-0000-0000-000000000000"]}`
	at := time.Now().UTC().Format("2006-01-02T15:04:05.000Z")
	if err := deps.EnrichCache.Put(ctx, "extAlbum", extKey("Coldplay", "Moon Music"),
		json.RawMessage(after), at); err != nil {
		t.Fatal(err)
	}
	post()

	rows, err := deps.ListenLater.List(ctx, "p1")
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 1 {
		t.Fatalf("%d rows after the identity upgrade, want 1: %+v", len(rows), rows)
	}
	if rows[0].ID != "rg:3988c875-b35f-4c3e-b143-ccb484d45347" {
		t.Fatalf("row kept the stale id %q", rows[0].ID)
	}
	// The upgraded row must carry the release set, or the accurate drop-off
	// rule can never fire for it.
	if len(rows[0].Releases) == 0 {
		t.Fatal("upgraded row has no releases")
	}
}

// profileId is a foreign key. A request without one must be rejected up front,
// not after spending the upstream lookup only to fail the insert.
func TestListenLaterRejectsUnknownProfile(t *testing.T) {
	const doc = `{"id":"dz:1","deezerId":1,"artist":"A","title":"B","cover":null,"date":"2024-01-01","type":"album","tracks":[]}`
	deps := llDeps(t, "A", "B", doc)
	h := New(deps)

	for _, body := range []string{
		`{"artist":"A","title":"B"}`,
		`{"profileId":"nope","artist":"A","title":"B"}`,
	} {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest("POST", "/api/listenlater", strings.NewReader(body)))
		if rec.Code != 400 {
			t.Fatalf("POST %s = %d, want 400: %s", body, rec.Code, rec.Body.String())
		}
	}
}

// The library's spelling of an artist wins over the upstream one, because the
// ownership fallback compares against the library's own albumArtist tag.
func TestListenLaterKeepsCallerArtistSpelling(t *testing.T) {
	const doc = `{"id":"dz:2","deezerId":2,"artist":"Beyoncé","title":"Lemonade",
		"cover":null,"date":"2016-04-23","type":"album","tracks":[]}`
	deps := llDeps(t, "Beyonce", "Lemonade", doc)
	h := New(deps)

	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("POST", "/api/listenlater",
		strings.NewReader(`{"profileId":"p1","artist":"Beyonce","title":"Lemonade"}`)))
	if rec.Code != 200 {
		t.Fatalf("POST = %d: %s", rec.Code, rec.Body.String())
	}
	var saved repo.ListenLater
	json.Unmarshal(rec.Body.Bytes(), &saved)
	if saved.Artist != "Beyonce" {
		t.Fatalf("artist = %q, want the library spelling", saved.Artist)
	}

	// Untagged rip under the library's spelling must still clear the entry.
	addTrack(t, deps, "t1", "Beyonce", "Lemonade", "")
	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("GET", "/api/listenlater?profileId=p1", nil))
	var out []repo.ListenLater
	json.Unmarshal(rec.Body.Bytes(), &out)
	if len(out) != 0 {
		t.Fatalf("entry survived acquisition: %+v", out)
	}
}

// The cover proxy takes a URL, so it must refuse anything that is not a known
// cover CDN — otherwise it fetches arbitrary addresses the server can reach.
func TestExtAlbumImgHostAllowlist(t *testing.T) {
	allowed := []string{
		"https://cdn-images.dzcdn.net/images/cover/x/1000x1000.jpg",
		"https://coverartarchive.org/release/abc/front-500",
	}
	refused := []string{
		"http://cdn-images.dzcdn.net/x.jpg",          // not https
		"https://169.254.169.254/latest/meta-data/",  // link-local metadata
		"https://evil.example.com/x.jpg",             // unknown host
		"https://cdn-images.dzcdn.net.evil.com/x",    // suffix spoofing
		"https://localhost/x.jpg",
		"",
	}
	for _, u := range allowed {
		if !allowedCoverHost(u) {
			t.Errorf("allowedCoverHost(%q) = false, want true", u)
		}
	}
	for _, u := range refused {
		if allowedCoverHost(u) {
			t.Errorf("allowedCoverHost(%q) = true, want false", u)
		}
	}
}

// Entries belong to a profile: one listener's saved albums stay out of
// another's list, and deleting a profile takes its entries with it.
func TestListenLaterIsProfileScoped(t *testing.T) {
	const doc = `{"id":"dz:1","deezerId":1,"artist":"A","title":"B","cover":null,"date":"2024-01-01","type":"album","tracks":[]}`
	deps := llDeps(t, "A", "B", doc)
	ctx := context.Background()
	if err := repo.NewProfiles(deps.DB).Create(ctx, repo.Profile{ID: "p2", Name: "M", Color: "#111111", CreatedAt: "t"}); err != nil {
		t.Fatal(err)
	}
	h := New(deps)

	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("POST", "/api/listenlater",
		strings.NewReader(`{"profileId":"p1","artist":"A","title":"B"}`)))
	if rec.Code != 200 {
		t.Fatalf("POST = %d: %s", rec.Code, rec.Body.String())
	}

	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("GET", "/api/listenlater?profileId=p2", nil))
	var out []repo.ListenLater
	json.Unmarshal(rec.Body.Bytes(), &out)
	if len(out) != 0 {
		t.Fatalf("p2 sees p1's entries: %+v", out)
	}

	if err := repo.NewProfiles(deps.DB).Delete(ctx, "p1"); err != nil {
		t.Fatal(err)
	}
	rows, err := deps.ListenLater.List(ctx, "p1")
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 0 {
		t.Fatalf("entries survived profile deletion: %+v", rows)
	}
}
