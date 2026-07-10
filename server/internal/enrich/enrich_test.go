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
