package api

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"testing"

	"aria/internal/repo"
)

func ptr[T any](v T) *T { return &v }

// healthDeps builds a small but deliberately messy library: one clean album,
// one album with no art and no MBID holding a transcode and a clipper, and one
// track nothing has decoded.
func healthDeps(t *testing.T) *Deps {
	t.Helper()
	d := analyzeDeps(t)
	ctx := context.Background()
	if err := d.Tracks.UpsertAll(ctx, []repo.Track{
		{ID: "t1", Path: "a/1.flac", AddedAt: "now", Title: "One", Artist: "A",
			Album: "Clean", AlbumArtist: "A", AlbumID: "al1", Format: "flac",
			Lossless: true, HasArt: true, MBAlbumID: ptr("mb-1")},
		{ID: "t2", Path: "b/1.flac", AddedAt: "now", Title: "Two", Artist: "B",
			Album: "Messy", AlbumArtist: "B", AlbumID: "al2", Format: "flac", Lossless: true},
		{ID: "t3", Path: "b/2.flac", AddedAt: "now", Title: "Three", Artist: "B",
			Album: "Messy", AlbumArtist: "B", AlbumID: "al2", Format: "flac", Lossless: true},
		{ID: "t4", Path: "b/3.flac", AddedAt: "now", Title: "Four", Artist: "B",
			Album: "Messy", AlbumArtist: "B", AlbumID: "al2", Format: "flac", Lossless: true},
	}); err != nil {
		t.Fatal(err)
	}
	put := func(a repo.TrackAudio) {
		t.Helper()
		if err := d.Audio.Put(ctx, a, 1, 1, "now"); err != nil {
			t.Fatal(err)
		}
	}
	put(repo.TrackAudio{TrackID: "t1", IntegratedLUFS: ptr(-14.0), TruePeakDBFS: ptr(-1.5),
		Codec: "flac", Lossless: true, AudioMD5: "aaa"})
	// claims FLAC, decodes as AAC
	put(repo.TrackAudio{TrackID: "t2", IntegratedLUFS: ptr(-8.0), TruePeakDBFS: ptr(1.2),
		Codec: "aac", Lossless: false, Suspect: true, AudioMD5: "bbb"})
	// same decoded audio as t2 — an exact duplicate under a different name
	put(repo.TrackAudio{TrackID: "t3", IntegratedLUFS: ptr(-8.0), TruePeakDBFS: ptr(-2.0),
		Codec: "flac", Lossless: true, AudioMD5: "bbb"})
	// t4 deliberately has no track_audio row at all
	return d
}

func getJSON(t *testing.T, d *Deps, path string, into any) {
	t.Helper()
	rec := record(New(d), httptest.NewRequest("GET", path, nil))
	if rec.Code != 200 {
		t.Fatalf("%s = %d, want 200", path, rec.Code)
	}
	if err := json.Unmarshal(rec.Body.Bytes(), into); err != nil {
		t.Fatal(err)
	}
}

func TestLibraryHealth(t *testing.T) {
	d := healthDeps(t)
	ctx := context.Background()
	// an album the matcher could not settle, and one it settled by a hair
	if err := d.Matches.Put(ctx, repo.Decision{AlbumID: "al2", State: "review",
		Reason: "indistinguishable-siblings", Attempts: 1, DecidedAt: "now"}); err != nil {
		t.Fatal(err)
	}
	if err := d.Matches.Put(ctx, repo.Decision{AlbumID: "al1", State: "matched", Reason: "ok",
		ReleaseMbid: ptr("mb-1"), Distance: ptr(0.05), Separation: ptr(0.3),
		Attempts: 1, DecidedAt: "now"}); err != nil {
		t.Fatal(err)
	}

	var got struct {
		Counts map[string]int `json:"counts"`
		Issues []struct {
			Kind  string `json:"kind"`
			Count int    `json:"count"`
			Items []struct {
				AlbumID, TrackID, Title, Detail string
			} `json:"items"`
		} `json:"issues"`
	}
	getJSON(t, d, "/api/library/health", &got)

	if got.Counts["tracks"] != 4 || got.Counts["albums"] != 2 || got.Counts["analysed"] != 3 {
		t.Errorf("counts = %v", got.Counts)
	}
	by := map[string]int{}
	items := map[string][]string{}
	for _, is := range got.Issues {
		by[is.Kind] = is.Count
		for _, it := range is.Items {
			id := it.TrackID
			if id == "" {
				id = it.AlbumID
			}
			items[is.Kind] = append(items[is.Kind], id)
		}
	}
	for kind, want := range map[string]int{
		"unmatched": 1, "lowSeparation": 1, "missingArt": 1, "missingMbid": 1,
		"suspect": 1, "clipping": 1, "unanalysed": 1,
	} {
		if by[kind] != want {
			t.Errorf("%s count = %d, want %d (items %v)", kind, by[kind], want, items[kind])
		}
	}
	// and each one names the right thing, not just the right number
	for kind, want := range map[string]string{
		"unmatched": "al2", "lowSeparation": "al1", "missingArt": "al2",
		"missingMbid": "al2", "suspect": "t2", "clipping": "t2", "unanalysed": "t4",
	} {
		if len(items[kind]) != 1 || items[kind][0] != want {
			t.Errorf("%s = %v, want [%s]", kind, items[kind], want)
		}
	}
}

// A separation comfortably clear of the veto is not a health problem. Without
// the band this section would list every matched album in the library.
func TestLibraryHealthIgnoresConfidentMatches(t *testing.T) {
	d := healthDeps(t)
	if err := d.Matches.Put(context.Background(), repo.Decision{AlbumID: "al1",
		State: "matched", Reason: "ok", Distance: ptr(0.01), Separation: ptr(0.9),
		Attempts: 1, DecidedAt: "now"}); err != nil {
		t.Fatal(err)
	}
	var got struct {
		Issues []struct {
			Kind  string `json:"kind"`
			Count int    `json:"count"`
		} `json:"issues"`
	}
	getJSON(t, d, "/api/library/health", &got)
	for _, is := range got.Issues {
		if is.Kind == "lowSeparation" && is.Count != 0 {
			t.Errorf("lowSeparation = %d, want 0", is.Count)
		}
	}
}

func TestDuplicates(t *testing.T) {
	d := healthDeps(t)
	ctx := context.Background()
	// t2 and t3 share a decoded MD5; AcoustID additionally ties t4 to them,
	// which is the near-duplicate case MD5 cannot see (a re-encode).
	for _, id := range []string{"t2", "t3", "t4"} {
		if err := d.FP.PutFP(ctx, id, "AQAB", 200, 1, 1, "now"); err != nil {
			t.Fatal(err)
		}
		if err := d.FP.PutLookup(ctx, id, ptr("ac-1"), ptr(0.99), ptr(`[]`), "now"); err != nil {
			t.Fatal(err)
		}
	}
	var got []struct {
		Key    string `json:"key"`
		Exact  bool   `json:"exact"`
		Tracks []struct {
			ID     string `json:"id"`
			Format string `json:"format"`
		} `json:"tracks"`
	}
	getJSON(t, d, "/api/library/duplicates", &got)
	if len(got) != 2 {
		t.Fatalf("groups = %d, want 2 (one exact, one near): %+v", len(got), got)
	}
	if !got[0].Exact || len(got[0].Tracks) != 2 ||
		got[0].Tracks[0].ID != "t2" || got[0].Tracks[1].ID != "t3" {
		t.Errorf("exact group = %+v, want t2+t3", got[0])
	}
	if got[1].Exact || len(got[1].Tracks) != 3 {
		t.Errorf("near group = %+v, want three tracks", got[1])
	}
}

// The near-duplicate list must not simply repeat the exact one: byte-identical
// files share an AcoustID too, so an unsuppressed acoustId group would show
// every exact duplicate twice.
func TestDuplicatesSuppressesRepeatOfExactGroup(t *testing.T) {
	d := healthDeps(t)
	ctx := context.Background()
	for _, id := range []string{"t2", "t3"} { // exactly the MD5 group, no more
		if err := d.FP.PutFP(ctx, id, "AQAB", 200, 1, 1, "now"); err != nil {
			t.Fatal(err)
		}
		if err := d.FP.PutLookup(ctx, id, ptr("ac-1"), ptr(0.99), ptr(`[]`), "now"); err != nil {
			t.Fatal(err)
		}
	}
	var got []dupeView
	getJSON(t, d, "/api/library/duplicates", &got)
	if len(got) != 1 || !got[0].Exact {
		t.Errorf("groups = %+v, want the exact group only", got)
	}
}

// No fingerprints and no analysis is the state of a fresh deployment, and of
// any deployment without ffmpeg or ACOUSTID_KEY. Both routes must answer with
// empty structures rather than 500.
func TestHealthAndDuplicatesOnBareLibrary(t *testing.T) {
	d := analyzeDeps(t)
	if err := d.Tracks.UpsertAll(context.Background(), []repo.Track{
		{ID: "t1", Path: "a/1.flac", AddedAt: "now", Album: "A", AlbumID: "al1"},
	}); err != nil {
		t.Fatal(err)
	}
	var dupes []dupeView
	getJSON(t, d, "/api/library/duplicates", &dupes)
	if len(dupes) != 0 {
		t.Errorf("duplicates = %+v, want none", dupes)
	}
	var health map[string]any
	getJSON(t, d, "/api/library/health", &health)
	if health["counts"] == nil || health["issues"] == nil {
		t.Errorf("health = %v", health)
	}
}
