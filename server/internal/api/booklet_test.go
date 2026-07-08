package api

import (
	"context"
	"net/http/httptest"
	"net/url"
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
	// scan.pdf is larger, but the "booklet" name must sort first
	if err := os.WriteFile(filepath.Join(albumDir, "scan.pdf"), []byte("%PDF big scan file"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(albumDir, "Booklet.PDF"), []byte("%PDF booklet"), 0o644); err != nil {
		t.Fatal(err)
	}

	// multi-disc box set: booklet at the album root, tracks in CD1/CD2, plus
	// a same-named PDF in both disc dirs (de-dupe must keep the larger one)
	boxDir := filepath.Join(music, "Artist", "Box")
	for _, sub := range []string{"CD1", "CD2"} {
		if err := os.MkdirAll(filepath.Join(boxDir, sub), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(boxDir, "booklet.pdf"), []byte("%PDF box booklet"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(boxDir, "CD1", "notes.pdf"), []byte("%PDF cd1 notes"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(boxDir, "CD2", "notes.pdf"), []byte("%PDF cd2 notes, longer"), 0o644); err != nil {
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

	list := func(id string) *httptest.ResponseRecorder {
		rec := httptest.NewRecorder()
		New(deps).ServeHTTP(rec, httptest.NewRequest("GET", "/api/albums/"+id+"/booklets", nil))
		return rec
	}
	// name is inserted raw so traversal cases can pre-encode their own
	get := func(id, name string) *httptest.ResponseRecorder {
		rec := httptest.NewRecorder()
		New(deps).ServeHTTP(rec, httptest.NewRequest("GET", "/api/albums/"+id+"/booklet/"+name, nil))
		return rec
	}

	// list: booklet-named first, then size desc; JSON body from writeJSON
	if rec := list(withPdf); rec.Code != 200 ||
		strings.TrimSpace(rec.Body.String()) != `{"booklets":["Booklet.PDF","scan.pdf"]}` {
		t.Errorf("list = %d %q, want Booklet.PDF then scan.pdf", rec.Code, rec.Body.String())
	}
	if rec := list(multiDisc); rec.Code != 200 ||
		strings.TrimSpace(rec.Body.String()) != `{"booklets":["booklet.pdf","notes.pdf"]}` {
		t.Errorf("multi-disc list = %d %q, want de-duped booklet.pdf + notes.pdf", rec.Code, rec.Body.String())
	}
	// no PDFs / only-unattributable-root PDFs: 200 with an empty list
	for _, id := range []string{without, rootAlbum} {
		if rec := list(id); rec.Code != 200 ||
			strings.TrimSpace(rec.Body.String()) != `{"booklets":[]}` {
			t.Errorf("list(%s) = %d %q, want 200 []", id[:1], rec.Code, rec.Body.String())
		}
	}
	if rec := list("not-a-sha1"); rec.Code != 404 {
		t.Errorf("list bad id = %d, want 404", rec.Code)
	}

	rec := get(withPdf, url.PathEscape("Booklet.PDF"))
	if rec.Code != 200 || rec.Body.String() != "%PDF booklet" {
		t.Errorf("booklet = %d %q, want 200 %%PDF booklet", rec.Code, rec.Body.String())
	}
	if ct := rec.Header().Get("Content-Type"); ct != "application/pdf" {
		t.Errorf("Content-Type = %q, want application/pdf", ct)
	}
	if rec.Header().Get("Content-Encoding") != "" {
		t.Errorf("booklet must bypass gzip, got encoding %q", rec.Header().Get("Content-Encoding"))
	}
	if rec := get(withPdf, "scan.pdf"); rec.Code != 200 || rec.Body.String() != "%PDF big scan file" {
		t.Errorf("scan.pdf = %d %q, want 200 the scan", rec.Code, rec.Body.String())
	}
	// multi-disc: booklet at box root; duplicate basename serves the winner (larger CD2)
	if rec := get(multiDisc, "booklet.pdf"); rec.Code != 200 || rec.Body.String() != "%PDF box booklet" {
		t.Errorf("multi-disc booklet = %d %q, want 200 %%PDF box booklet", rec.Code, rec.Body.String())
	}
	if rec := get(multiDisc, "notes.pdf"); rec.Code != 200 || rec.Body.String() != "%PDF cd2 notes, longer" {
		t.Errorf("deduped notes.pdf = %d %q, want the larger CD2 copy", rec.Code, rec.Body.String())
	}
	// unknown and traversal names never match a candidate
	if rec := get(withPdf, "nope.pdf"); rec.Code != 404 {
		t.Errorf("unknown name = %d, want 404", rec.Code)
	}
	if rec := get(withPdf, "..%2F..%2Frandom.pdf"); rec.Code != 404 {
		t.Errorf("traversal name = %d, want 404", rec.Code)
	}
	if rec := get(rootAlbum, "random.pdf"); rec.Code != 404 {
		t.Errorf("root-level album = %d, want 404 (root PDFs unattributable)", rec.Code)
	}
	if rec := get("not-a-sha1", "booklet.pdf"); rec.Code != 404 {
		t.Errorf("bad id = %d, want 404", rec.Code)
	}
}
