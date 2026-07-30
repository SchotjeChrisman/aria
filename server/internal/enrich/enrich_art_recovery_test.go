package enrich

import (
	"net/http"
	"os"
	"path/filepath"
	"testing"

	"aria/internal/repo"
)

// The art FILE outlives the album cache entry. persist() deletes the blob on any
// decision change, and the re-match sentinel makes that happen for every unpinned
// album at once — so enrichAlbum rebuilds `a` from the zero value with Art=false
// while <id>.api.jpg is still sitting on disk. If the flag is only ever set by a
// successful fetch, the fetch is skipped (the file exists), artByAlbum loses the
// album and the cover becomes a placeholder for good: the V marker stops the
// album being revisited and the file stops the fetch re-arming.
func TestEnrichAlbumRecoversArtFlagFromDisk(t *testing.T) {
	e, ctx := newTestEnricher(t)
	// every network call fails: the point is that NOTHING is fetched
	stubMB(e, func(*http.Request) (*http.Response, error) { return resp(404, ""), nil })

	albumID := "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	artPath := filepath.Join(e.dataDir, "art", albumID+".api.jpg")
	if err := os.MkdirAll(filepath.Dir(artPath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(artPath, []byte("JPEGDATA"), 0o644); err != nil {
		t.Fatal(err)
	}

	// A matched decision with no cache entry: exactly the state persist() leaves
	// behind after the sentinel wipes the decisions and phase 0 re-decides.
	mbid := "11111111-1111-1111-1111-111111111111"
	if err := e.matches.Put(ctx, repo.Decision{AlbumID: albumID, State: "matched",
		Reason: "ok", ReleaseMbid: &mbid, DecidedAt: nowISO()}); err != nil {
		t.Fatal(err)
	}
	ts := []repo.Track{{ID: "t1", AlbumID: albumID, Album: "Alb", AlbumArtist: "Art"}}
	if err := e.enrichAlbum(ctx, albumID, ts); err != nil {
		t.Fatal(err)
	}

	var a albumCache
	if !e.cacheGet(ctx, KindAlbum, albumID, &a) {
		t.Fatal("no album cache entry written")
	}
	if !a.Art {
		t.Error("art flag not recovered from the existing .api.jpg; the cover would render as a placeholder")
	}
	if _, err := os.ReadFile(artPath); err != nil {
		t.Errorf("the existing art file must be left alone: %v", err)
	}
}
