package api

import (
	"bytes"
	"context"
	"encoding/json"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"aria/internal/config"
	"aria/internal/db"
	"aria/internal/repo"
)

const testAlbumID = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

// stubEnricher satisfies api.Enricher plus artPreviewer; AlbumArt returns the
// canned bytes and counts calls so tests can assert a remote fetch happened
// (or didn't).
type stubEnricher struct {
	art   []byte
	calls int
}

func (s *stubEnricher) Run(context.Context) error { return nil }
func (s *stubEnricher) Status() any               { return nil }
func (s *stubEnricher) AlbumArt(context.Context, string, string, string) []byte {
	s.calls++
	return s.art
}

// jpegBytes is a header http.DetectContentType reads as image/jpeg.
var jpegBytes = []byte{0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 'J', 'F', 'I', 'F', 0, 1}

func artDeps(t *testing.T) (*Deps, string) {
	t.Helper()
	dir := t.TempDir()
	d, err := db.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { d.Close() })
	if err := os.MkdirAll(filepath.Join(dir, "art"), 0o755); err != nil {
		t.Fatal(err)
	}
	deps := NewDeps(d, config.Config{DataDir: dir}, "test")
	if err := deps.Tracks.UpsertAll(context.Background(), []repo.Track{{
		ID: "t1", AlbumID: testAlbumID, Album: "Alb", AlbumArtist: "Art", AddedAt: "now",
	}}); err != nil {
		t.Fatal(err)
	}
	return deps, dir
}

func writeSlot(t *testing.T, dir, source string, b []byte) {
	t.Helper()
	if err := os.WriteFile(artSlotPath(dir, testAlbumID, source), b, 0o644); err != nil {
		t.Fatal(err)
	}
}

func getArt(t *testing.T, h http.Handler, query string) *httptest.ResponseRecorder {
	t.Helper()
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("GET", "/api/art/"+testAlbumID+query, nil))
	return rec
}

func TestArtSourceResolution(t *testing.T) {
	deps, dir := artDeps(t)
	h := New(deps)
	writeSlot(t, dir, "file", []byte("FILE"+string(jpegBytes)))
	writeSlot(t, dir, "api", []byte("API"+string(jpegBytes)))
	writeSlot(t, dir, "custom", []byte("CUSTOM"+string(jpegBytes)))

	cases := []struct {
		name, query string
		want        string
	}{
		{"explicit file", "?source=file", "FILE"},
		{"explicit api", "?source=api", "API"},
		{"explicit custom", "?source=custom", "CUSTOM"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			rec := getArt(t, h, c.query)
			if rec.Code != 200 || !strings.HasPrefix(rec.Body.String(), c.want) {
				t.Fatalf("%s = %d %q", c.query, rec.Code, rec.Body.String())
			}
		})
	}

	// none-set, .jpg present -> .jpg
	if rec := getArt(t, h, ""); rec.Code != 200 || !strings.HasPrefix(rec.Body.String(), "FILE") {
		t.Fatalf("none-set = %d %q", rec.Code, rec.Body.String())
	}

	// none-set, only .api.jpg -> .api.jpg
	os.Remove(artSlotPath(dir, testAlbumID, "file"))
	if rec := getArt(t, h, ""); rec.Code != 200 || !strings.HasPrefix(rec.Body.String(), "API") {
		t.Fatalf("none-set api-fallback = %d %q", rec.Code, rec.Body.String())
	}

	// explicit ?source=file missing -> 404 (no fallback)
	if rec := getArt(t, h, "?source=file"); rec.Code != 404 {
		t.Fatalf("missing file slot = %d, want 404", rec.Code)
	}

	// bad source -> 400
	if rec := getArt(t, h, "?source=bogus"); rec.Code != 400 {
		t.Fatalf("bad source = %d, want 400", rec.Code)
	}
}

func TestArtLivePreview(t *testing.T) {
	deps, dir := artDeps(t)
	stub := &stubEnricher{art: jpegBytes}
	deps.Enricher = stub
	h := New(deps)

	rec := getArt(t, h, "?source=api")
	if rec.Code != 200 {
		t.Fatalf("preview = %d", rec.Code)
	}
	if cc := rec.Header().Get("Cache-Control"); cc != "no-store" {
		t.Fatalf("preview Cache-Control = %q, want no-store", cc)
	}
	if _, err := os.Stat(artSlotPath(dir, testAlbumID, "api")); !os.IsNotExist(err) {
		t.Fatalf("preview must not persist .api.jpg")
	}

	// stub returning nil -> 404
	stub.art = nil
	if rec := getArt(t, h, "?source=api"); rec.Code != 404 {
		t.Fatalf("nil preview = %d, want 404", rec.Code)
	}
}

func TestArtUpload(t *testing.T) {
	deps, dir := artDeps(t)
	h := New(deps)

	post := func(field string, body []byte) *httptest.ResponseRecorder {
		var buf bytes.Buffer
		mw := multipart.NewWriter(&buf)
		fw, _ := mw.CreateFormFile(field, "cover.jpg")
		fw.Write(body)
		mw.Close()
		req := httptest.NewRequest("POST", "/api/art/"+testAlbumID, &buf)
		req.Header.Set("Content-Type", mw.FormDataContentType())
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		return rec
	}

	// valid jpeg
	rec := post("image", jpegBytes)
	if rec.Code != 200 {
		t.Fatalf("upload = %d: %s", rec.Code, rec.Body.String())
	}
	var out map[string]any
	json.Unmarshal(rec.Body.Bytes(), &out)
	if out["artSource"] != "custom" {
		t.Fatalf("artSource = %v", out["artSource"])
	}
	if v, _ := out["artVersion"].(float64); v != 1 {
		t.Fatalf("artVersion = %v, want 1", out["artVersion"])
	}
	if _, err := os.Stat(artSlotPath(dir, testAlbumID, "custom")); err != nil {
		t.Fatalf(".custom.jpg not written: %v", err)
	}

	// non-image -> 400, no file written
	os.Remove(artSlotPath(dir, testAlbumID, "custom"))
	if rec := post("image", []byte("this is plain text, not an image")); rec.Code != 400 {
		t.Fatalf("non-image = %d, want 400", rec.Code)
	}
	if _, err := os.Stat(artSlotPath(dir, testAlbumID, "custom")); !os.IsNotExist(err) {
		t.Fatalf("non-image must not write slot")
	}

	// oversized -> 413
	big := make([]byte, maxArtBytes+1024)
	copy(big, jpegBytes)
	if rec := post("image", big); rec.Code != 413 {
		t.Fatalf("oversized = %d, want 413", rec.Code)
	}
}

func TestArtPickSideEffects(t *testing.T) {
	patch := func(deps *Deps, body string) *httptest.ResponseRecorder {
		h := New(deps)
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest("PATCH", "/api/albums/"+testAlbumID, strings.NewReader(body)))
		return rec
	}

	// PATCH artSource=api with stub -> writes .api.jpg, artVersion bumped
	t.Run("pick api", func(t *testing.T) {
		deps, dir := artDeps(t)
		stub := &stubEnricher{art: jpegBytes}
		deps.Enricher = stub
		rec := patch(deps, `{"artSource":"api"}`)
		if rec.Code != 200 {
			t.Fatalf("pick api = %d: %s", rec.Code, rec.Body.String())
		}
		if stub.calls != 1 {
			t.Fatalf("AlbumArt calls = %d, want 1", stub.calls)
		}
		if _, err := os.Stat(artSlotPath(dir, testAlbumID, "api")); err != nil {
			t.Fatalf(".api.jpg not written: %v", err)
		}
		var out map[string]any
		json.Unmarshal(rec.Body.Bytes(), &out)
		if v, _ := out["artVersion"].(float64); v != 1 {
			t.Fatalf("artVersion = %v, want 1", out["artVersion"])
		}
	})

	// PATCH artSource=file with no local art -> 400
	t.Run("pick file no embedded", func(t *testing.T) {
		deps, _ := artDeps(t)
		if rec := patch(deps, `{"artSource":"file"}`); rec.Code != 400 {
			t.Fatalf("pick file no-art = %d, want 400", rec.Code)
		}
	})

	// PATCH artSource=custom -> no remote fetch
	t.Run("pick custom no fetch", func(t *testing.T) {
		deps, _ := artDeps(t)
		stub := &stubEnricher{art: jpegBytes}
		deps.Enricher = stub
		if rec := patch(deps, `{"artSource":"custom"}`); rec.Code != 200 {
			t.Fatalf("pick custom = %d: %s", rec.Code, rec.Body.String())
		}
		if stub.calls != 0 {
			t.Fatalf("custom pick fetched remote (calls=%d)", stub.calls)
		}
		// the files carry no art, yet the grids must show the picked cover
		view, err := mergedTracks(context.Background(), deps)
		if err != nil || len(view) != 1 || view[0]["hasArt"] != true {
			t.Fatalf("hasArt after a custom pick = %v (%v), want true", view, err)
		}
	})
}

func TestArtVersionDefault(t *testing.T) {
	deps, dir := artDeps(t)
	writeSlot(t, dir, "file", jpegBytes) // so file pick is allowed
	h := New(deps)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("PATCH", "/api/albums/"+testAlbumID, strings.NewReader(`{"artSource":"file"}`)))
	if rec.Code != 200 {
		t.Fatalf("first pick = %d: %s", rec.Code, rec.Body.String())
	}
	var out map[string]any
	json.Unmarshal(rec.Body.Bytes(), &out)
	if v, _ := out["artVersion"].(float64); v != 1 {
		t.Fatalf("first artVersion = %v, want 1", out["artVersion"])
	}
}

// The album folder's own cover leads the file slot, ahead of embedded art, and
// is enough on its own for the editor to pick "file".
func TestArtPrefersLibraryCover(t *testing.T) {
	deps, dir := artDeps(t)
	deps.Cfg.MusicDir = t.TempDir()
	h := New(deps)
	ctx := context.Background()
	writeSlot(t, dir, "file", []byte("EMBEDDED"+string(jpegBytes)))
	if err := os.MkdirAll(filepath.Join(deps.Cfg.MusicDir, "Art", "Alb"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(deps.Cfg.MusicDir, "Art", "Alb", "cover.png"), []byte("\x89PNG\r\n\x1a\nCOVER"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := deps.Albums.ReplaceLocalArt(ctx, "album", map[string]repo.LocalArt{
		testAlbumID: {Path: filepath.Join("Art", "Alb", "cover.png"), Mtime: 1},
	}); err != nil {
		t.Fatal(err)
	}
	for _, q := range []string{"", "?source=file"} {
		rec := getArt(t, h, q)
		if rec.Code != 200 || !strings.HasSuffix(rec.Body.String(), "COVER") || rec.Header().Get("Content-Type") != "image/png" {
			t.Errorf("GET art%s = %d %s %q, want the folder cover", q, rec.Code, rec.Header().Get("Content-Type"), rec.Body.String())
		}
		// a rescan or a replaced cover.jpg changes what this same URL holds
		if cc := rec.Header().Get("Cache-Control"); cc != "no-cache" {
			t.Errorf("GET art%s Cache-Control = %q, want no-cache", q, cc)
		}
	}

	// a replaced cover.jpg moves the art token the app puts on the URL
	token := func() any {
		t.Helper()
		deps.InvalidateTracks()
		view, err := mergedTracks(ctx, deps)
		if err != nil || len(view) != 1 {
			t.Fatalf("merged view = %v (%v)", view, err)
		}
		return view[0]["artVersion"]
	}
	was := token()
	if err := deps.Albums.ReplaceLocalArt(ctx, "album", map[string]repo.LocalArt{
		testAlbumID: {Path: filepath.Join("Art", "Alb", "cover.png"), Mtime: 2},
	}); err != nil {
		t.Fatal(err)
	}
	if now := token(); now == was {
		t.Errorf("artVersion stayed %v across a replaced folder cover", now)
	}
	was = token()
	later := time.Now().Add(time.Hour)
	if err := os.Chtimes(artSlotPath(dir, testAlbumID, "file"), later, later); err != nil {
		t.Fatal(err)
	}
	if now := token(); now == was {
		t.Errorf("artVersion stayed %v across re-extracted embedded art", now)
	}

	os.Remove(artSlotPath(dir, testAlbumID, "file"))
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("PATCH", "/api/albums/"+testAlbumID, strings.NewReader(`{"artSource":"file"}`)))
	if rec.Code != 200 {
		t.Fatalf("pick file with only a folder cover = %d: %s", rec.Code, rec.Body.String())
	}
}

// peopleStub is the enricher's people map: an artist entry's face for Bach.
type peopleStub struct{ stubEnricher }

func (peopleStub) People(context.Context) (map[string]string, error) {
	return map[string]string{"Bach": "https://cdn.deezer.com/bach.jpg"}, nil
}
func (peopleStub) Warm([]string) int { return 0 }

// With nothing edited and nothing in the library, the composer hero still
// shows the photo the avatars show: the artist entry's face, not the composer
// cache's own portrait.
func TestComposerPortraitFollowsAvatar(t *testing.T) {
	deps, _ := artDeps(t)
	deps.Enricher = &peopleStub{}
	ctx := context.Background()
	if err := deps.EnrichCache.Put(ctx, "composer", "Bach", json.RawMessage(`{"portrait":"https://assets.openopus.org/bach.jpg"}`), "now"); err != nil {
		t.Fatal(err)
	}
	rec := httptest.NewRecorder()
	New(deps).ServeHTTP(rec, httptest.NewRequest("GET", "/api/composer/Bach", nil))
	var c struct {
		Portrait string `json:"portrait"`
	}
	json.Unmarshal(rec.Body.Bytes(), &c)
	if rec.Code != 200 || c.Portrait != "https://cdn.deezer.com/bach.jpg" {
		t.Errorf("composer portrait = %d %q, want the avatar's face", rec.Code, c.Portrait)
	}

	// a composer nothing knew of (a cached miss, or no entry) still gets a
	// hero once the user gives them a photo, and none without one
	if err := deps.EnrichCache.Put(ctx, "composer", "Minor", json.RawMessage(`null`), "now"); err != nil {
		t.Fatal(err)
	}
	for _, n := range []string{"Minor", "Unheard"} {
		rec = httptest.NewRecorder()
		New(deps).ServeHTTP(rec, httptest.NewRequest("GET", "/api/composer/"+n, nil))
		if rec.Code != 404 {
			t.Errorf("composer %s without a photo = %d, want 404", n, rec.Code)
		}
		rec = httptest.NewRecorder()
		New(deps).ServeHTTP(rec, httptest.NewRequest("PATCH", "/api/artists/"+n, strings.NewReader(`{"image":"https://example.com/m.jpg"}`)))
		rec = httptest.NewRecorder()
		New(deps).ServeHTTP(rec, httptest.NewRequest("GET", "/api/composer/"+n, nil))
		c.Portrait = ""
		json.Unmarshal(rec.Body.Bytes(), &c)
		if rec.Code != 200 || c.Portrait != "https://example.com/m.jpg" {
			t.Errorf("composer %s with an edited photo = %d %q, want a hero with it", n, rec.Code, c.Portrait)
		}
	}
}

// latinStub knows one artist under a Cyrillic tag and its Latin display name.
type latinStub struct{ stubEnricher }

func (latinStub) LatinNames(context.Context) (map[string]string, error) {
	return map[string]string{"Арт": "Art"}, nil
}
func (latinStub) ResolveName(_ context.Context, name string) string {
	if name == "Art" {
		return "Арт"
	}
	return name
}

// An artist folder's image leads the fetched portrait everywhere the app looks
// — the people map under both spellings, the proxy, the artist doc, the
// editor's original, the composer hero — never reaches a classical lead
// performer, gives way to an edited portrait at once, and follows an album
// artist renamed in the editor.
func TestPeopleLibraryPortrait(t *testing.T) {
	deps, _ := artDeps(t)
	deps.Cfg.MusicDir = t.TempDir()
	deps.Enricher = &latinStub{}
	ctx := context.Background()
	if err := deps.Tracks.UpsertAll(ctx, []repo.Track{{
		ID: "t1", AlbumID: testAlbumID, Album: "Alb", AlbumArtist: "Арт", AddedAt: "now",
	}}); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(deps.Cfg.MusicDir, "artist.jpg"), []byte("PORTRAIT"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := deps.Albums.ReplaceLocalArt(ctx, "artist", map[string]repo.LocalArt{
		testAlbumID: {Path: "artist.jpg", Mtime: 7, Name: "Арт"},
	}); err != nil {
		t.Fatal(err)
	}
	if err := deps.EnrichCache.Put(ctx, "composer", "Арт", json.RawMessage(`{"fullName":"Арт","portrait":"https://wiki/a.jpg"}`), "now"); err != nil {
		t.Fatal(err)
	}
	// the classical display may show the album under its lead performer:
	// another person, who must not get the composer's folder portrait
	if err := deps.EnrichCache.Put(ctx, "album", testAlbumID, json.RawMessage(`{"displayArtist":"Esther Yoo"}`), "now"); err != nil {
		t.Fatal(err)
	}
	h := New(deps)
	do := func(method, path, body string) *httptest.ResponseRecorder {
		t.Helper()
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest(method, path, strings.NewReader(body)))
		return rec
	}
	people := func() map[string]string {
		t.Helper()
		var m map[string]string
		if err := json.Unmarshal(do("GET", "/api/people", "").Body.Bytes(), &m); err != nil {
			t.Fatal(err)
		}
		return m
	}

	m := people()
	local := "/api/people/img/Art?v=7"
	if m["Art"] != local || m["Арт"] != "/api/people/img/%D0%90%D1%80%D1%82?v=7" || m["Esther Yoo"] != "" {
		t.Fatalf("people = %v, want the library image under both spellings and not the performer", m)
	}
	for _, p := range []string{local, "/api/people/img/Art", "/api/people/img/%D0%90%D1%80%D1%82"} {
		if rec := do("GET", p, ""); rec.Code != 200 || rec.Body.String() != "PORTRAIT" {
			t.Errorf("GET %s = %d %q, want the library image", p, rec.Code, rec.Body.String())
		}
	}
	var doc, ed, comp struct {
		Image    string `json:"image"`
		Portrait string `json:"portrait"`
		Original struct {
			Image string `json:"image"`
		} `json:"original"`
	}
	json.Unmarshal(do("GET", "/api/artist/Art", "").Body.Bytes(), &doc)
	json.Unmarshal(do("GET", "/api/edits/artist/Art", "").Body.Bytes(), &ed)
	json.Unmarshal(do("GET", "/api/composer/Art", "").Body.Bytes(), &comp)
	if doc.Image != local || ed.Original.Image != local || comp.Portrait != local {
		t.Errorf("artist image = %q, editor original = %q, composer portrait = %q, want %q",
			doc.Image, ed.Original.Image, comp.Portrait, local)
	}

	if rec := do("PATCH", "/api/artists/Art", `{"image":"https://example.com/p.jpg"}`); rec.Code != 200 {
		t.Fatalf("edit = %d: %s", rec.Code, rec.Body.String())
	}
	if m := people(); m["Арт"] != "https://example.com/p.jpg" || m["Art"] != "https://example.com/p.jpg" {
		t.Errorf("people after edit = %v, want the edited portrait under both spellings", m)
	}
	comp.Portrait = ""
	json.Unmarshal(do("GET", "/api/composer/Art", "").Body.Bytes(), &comp)
	if comp.Portrait != "https://example.com/p.jpg" {
		t.Errorf("composer portrait after edit = %q, want the edited one", comp.Portrait)
	}

	if rec := do("PATCH", "/api/albums/"+testAlbumID, `{"albumArtist":"The Art"}`); rec.Code != 200 {
		t.Fatalf("album edit = %d: %s", rec.Code, rec.Body.String())
	}
	if got := people()["The Art"]; got != "/api/people/img/The%20Art?v=7" {
		t.Errorf("people[The Art] = %q, want the library image under the edited name", got)
	}
	if rec := do("GET", "/api/people/img/The%20Art", ""); rec.Code != 200 || rec.Body.String() != "PORTRAIT" {
		t.Errorf("GET portrait of the renamed artist = %d %q", rec.Code, rec.Body.String())
	}
}
