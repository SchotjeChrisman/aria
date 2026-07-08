package api

import (
	"context"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"aria/internal/config"
	"aria/internal/db"
	"aria/internal/repo"
)

func TestBooklet(t *testing.T) {
	d, err := db.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()

	music := t.TempDir()
	albumDir := filepath.Join(music, "Artist", "Album")
	if err := os.MkdirAll(albumDir, 0o755); err != nil {
		t.Fatal(err)
	}
	// scan.pdf is larger, but the "booklet" name must win
	if err := os.WriteFile(filepath.Join(albumDir, "scan.pdf"), []byte("%PDF big scan file"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(albumDir, "Booklet.PDF"), []byte("%PDF booklet"), 0o644); err != nil {
		t.Fatal(err)
	}

	// multi-disc box set: booklet at the album root, tracks in CD1/CD2
	boxDir := filepath.Join(music, "Artist", "Box")
	for _, sub := range []string{"CD1", "CD2"} {
		if err := os.MkdirAll(filepath.Join(boxDir, sub), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(boxDir, "booklet.pdf"), []byte("%PDF box booklet"), 0o644); err != nil {
		t.Fatal(err)
	}
	// a PDF at the music root must never be attributed to any album
	if err := os.WriteFile(filepath.Join(music, "random.pdf"), []byte("%PDF unrelated"), 0o644); err != nil {
		t.Fatal(err)
	}

	deps := NewDeps(d, config.Config{MusicDir: music}, "test")
	withPdf := strings.Repeat("a", 40)
	without := strings.Repeat("b", 40)
	multiDisc := strings.Repeat("c", 40)
	rootAlbum := strings.Repeat("d", 40)
	if err := deps.Tracks.UpsertAll(context.Background(), []repo.Track{
		{ID: "t1", Path: "Artist/Album/01.flac", Title: "One", AlbumID: withPdf,
			AddedAt: "2026-01-01T00:00:00.000Z", Format: "FLAC"},
		{ID: "t2", Path: "Artist/Other/01.flac", Title: "Two", AlbumID: without,
			AddedAt: "2026-01-01T00:00:00.000Z", Format: "FLAC"},
		{ID: "t3", Path: "Artist/Box/CD1/01.flac", Title: "Three", AlbumID: multiDisc,
			AddedAt: "2026-01-01T00:00:00.000Z", Format: "FLAC"},
		{ID: "t4", Path: "Artist/Box/CD2/01.flac", Title: "Four", AlbumID: multiDisc,
			AddedAt: "2026-01-01T00:00:00.000Z", Format: "FLAC"},
		{ID: "t5", Path: "loose.flac", Title: "Five", AlbumID: rootAlbum,
			AddedAt: "2026-01-01T00:00:00.000Z", Format: "FLAC"},
	}); err != nil {
		t.Fatal(err)
	}

	get := func(id string) *httptest.ResponseRecorder {
		rec := httptest.NewRecorder()
		New(deps).ServeHTTP(rec, httptest.NewRequest("GET", "/api/albums/"+id+"/booklet", nil))
		return rec
	}

	rec := get(withPdf)
	if rec.Code != 200 || rec.Body.String() != "%PDF booklet" {
		t.Errorf("booklet = %d %q, want 200 %%PDF booklet", rec.Code, rec.Body.String())
	}
	if ct := rec.Header().Get("Content-Type"); ct != "application/pdf" {
		t.Errorf("Content-Type = %q, want application/pdf", ct)
	}
	if rec.Header().Get("Content-Encoding") != "" {
		t.Errorf("booklet must bypass gzip, got encoding %q", rec.Header().Get("Content-Encoding"))
	}
	if rec := get(without); rec.Code != 404 {
		t.Errorf("no-pdf album = %d, want 404", rec.Code)
	}
	if rec := get(multiDisc); rec.Code != 200 || rec.Body.String() != "%PDF box booklet" {
		t.Errorf("multi-disc booklet = %d %q, want 200 %%PDF box booklet", rec.Code, rec.Body.String())
	}
	if rec := get(rootAlbum); rec.Code != 404 {
		t.Errorf("root-level album = %d, want 404 (root PDFs unattributable)", rec.Code)
	}
	if rec := get("not-a-sha1"); rec.Code != 404 {
		t.Errorf("bad id = %d, want 404", rec.Code)
	}
}
