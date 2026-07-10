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

	// PATCH artSource=file with no embedded art -> 400
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
