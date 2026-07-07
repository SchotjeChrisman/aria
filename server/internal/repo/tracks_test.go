package repo

import (
	"context"
	"database/sql"
	"testing"

	"aria/internal/db"
)

func testDB(t *testing.T) *sql.DB {
	t.Helper()
	d, err := db.Open(t.TempDir())
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	t.Cleanup(func() { d.Close() })
	return d
}

func strp(s string) *string { return &s }
func intp(n int) *int       { return &n }

func track(id, path, title, artist, album string) Track {
	return Track{
		ID: id, Path: path, AddedAt: "2026-01-01T00:00:00Z",
		Title: title, Artist: artist, AlbumArtist: artist, Album: album,
		AlbumID: "al-" + album, Format: "FLAC", Lossless: true,
	}
}

func TestTracksUpsertPreservesAddedAt(t *testing.T) {
	d := testDB(t)
	r := NewTracks(d)
	ctx := context.Background()

	t1 := track("id1", "a/one.flac", "Moonlight Sonata", "Beethoven", "Sonatas")
	t1.Composer = strp("Ludwig van Beethoven")
	t1.Year = intp(1801)
	t2 := track("id2", "a/two.flac", "Clair de Lune", "Debussy", "Suite")
	if err := r.UpsertAll(ctx, []Track{t1, t2}); err != nil {
		t.Fatalf("upsert: %v", err)
	}

	// rescan: same id, new addedAt candidate + changed title
	t1b := t1
	t1b.AddedAt = "2026-06-01T00:00:00Z"
	t1b.Title = "Piano Sonata No. 14"
	if err := r.UpsertAll(ctx, []Track{t1b, t2}); err != nil {
		t.Fatalf("upsert 2: %v", err)
	}
	got, err := r.ByID(ctx, "id1")
	if err != nil || got == nil {
		t.Fatalf("byid: %v %v", got, err)
	}
	if got.AddedAt != "2026-01-01T00:00:00Z" {
		t.Errorf("addedAt = %q, want original preserved", got.AddedAt)
	}
	if got.Title != "Piano Sonata No. 14" {
		t.Errorf("title = %q, want updated", got.Title)
	}
	if got.Year == nil || *got.Year != 1801 {
		t.Errorf("year = %v, want 1801", got.Year)
	}
}

func TestTracksDeleteNotIn(t *testing.T) {
	d := testDB(t)
	r := NewTracks(d)
	ctx := context.Background()

	if err := r.UpsertAll(ctx, []Track{
		track("id1", "p1", "Alpha", "A", "X"),
		track("id2", "p2", "Beta", "B", "X"),
		track("id3", "p3", "Gamma", "C", "Y"),
	}); err != nil {
		t.Fatalf("upsert: %v", err)
	}
	n, err := r.DeleteNotIn(ctx, []string{"id1", "id3"})
	if err != nil || n != 1 {
		t.Fatalf("delete = %d, %v; want 1", n, err)
	}
	if got, _ := r.Count(ctx); got != 2 {
		t.Errorf("count = %d, want 2", got)
	}
	if ts, err := r.ByAlbum(ctx, "al-X"); err != nil || len(ts) != 1 || ts[0].ID != "id1" {
		t.Errorf("byAlbum = %v, %v; want [id1]", ts, err)
	}
}
