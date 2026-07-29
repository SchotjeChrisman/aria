package enrich

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"aria/internal/repo"
)

// lbServer fakes both ListenBrainz hosts on one mux; labs and base point at it
// so a test can exercise either endpoint.
func lbServer(t *testing.T, similar, top string) *ListenBrainz {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc("/similar-artists/json", func(rw http.ResponseWriter, r *http.Request) {
		// labs 400s when either param is missing — a client that drops
		// `algorithm` gets a pydantic error, not results.
		if r.URL.Query().Get("artist_mbids") == "" || r.URL.Query().Get("algorithm") == "" {
			http.Error(rw, `{"detail":"field required"}`, http.StatusBadRequest)
			return
		}
		rw.Write([]byte(similar))
	})
	mux.HandleFunc("/1/popularity/top-recordings-for-artist/", func(rw http.ResponseWriter, r *http.Request) {
		rw.Write([]byte(top))
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return &ListenBrainz{c: newPoliteClient(), base: srv.URL, labs: srv.URL}
}

const lbMbid = "5b11f4ce-a62d-471e-81fc-a69a8278c7da"

func TestSimilarArtists(t *testing.T) {
	// 13 results -> capped at 12, flat top-level array, no images anywhere
	body := "["
	for i := 0; i < 13; i++ {
		if i > 0 {
			body += ","
		}
		body += fmt.Sprintf(`{"artist_mbid":"m%d","name":"a%d","score":%d,"gender":null}`, i, i, 100-i)
	}
	body += "]"

	l := lbServer(t, body, "")
	got, err := l.SimilarArtists(context.Background(), lbMbid)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 12 {
		t.Fatalf("len = %d, want 12", len(got))
	}
	if got[0].Name != "a0" {
		t.Errorf("got[0] = %+v, want name a0 in server (score) order", got[0])
	}
	if got[0].Image != nil {
		t.Errorf("labs returns no artwork; image must stay nil, got %q", *got[0].Image)
	}
}

func TestSimilarArtistsUnknownMbid(t *testing.T) {
	// an MBID LB has never seen is a 200 with `[]` — a clean negative the
	// caller may cache, not an error.
	l := lbServer(t, `[]`, "")
	got, err := l.SimilarArtists(context.Background(), lbMbid)
	if err != nil || got == nil || len(got) != 0 {
		t.Errorf("got %#v, %v; want empty non-nil slice, no error", got, err)
	}
}

func TestSimilarArtistsBadRequest(t *testing.T) {
	l := lbServer(t, `[]`, "")
	l.c.retryWait = 0
	if _, err := l.SimilarArtists(context.Background(), ""); err == nil {
		t.Error("missing artist_mbids must surface as an error, not empty results")
	}
}

func TestTopRecordings(t *testing.T) {
	// the endpoint ignores ?count=, so the cap has to be ours: 250 in, 200 out
	var b strings.Builder
	b.WriteString("[")
	for i := 0; i < 250; i++ {
		if i > 0 {
			b.WriteString(",")
		}
		fmt.Fprintf(&b, `{"recording_mbid":"r%d","recording_name":"n%d","total_listen_count":%d,"tags":[{"tag":"rock","count":3}]}`, i, i, 1000-i)
	}
	b.WriteString("]")

	l := lbServer(t, "", b.String())
	got, err := l.TopRecordings(context.Background(), lbMbid)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != lbTopMax {
		t.Fatalf("len = %d, want %d", len(got), lbTopMax)
	}
	if got[0] != "r0" || got[199] != "r199" {
		t.Errorf("server order not preserved: got[0]=%q got[199]=%q", got[0], got[199])
	}

	l = lbServer(t, "", `[]`)
	if got, err = l.TopRecordings(context.Background(), lbMbid); err != nil || got == nil || len(got) != 0 {
		t.Errorf("no listens: got %#v, %v; want empty non-nil slice", got, err)
	}
}

// The point of the whole integration: when Deezer's editorial graph is empty,
// the ListenBrainz names still land in the cached ArtistEntry.Similar the
// artist shelf reads. Deezer winning means LB is never called.
func TestSimilarOrEmptyFallsBackToListenBrainz(t *testing.T) {
	tests := []struct {
		name     string
		deezer   string // /artist/27/related body
		mbid     string
		wantName string
	}{
		{"deezer empty, mbid known -> listenbrainz", `{"data":[]}`, lbMbid, "Nirvana"},
		{"deezer empty, no mbid -> stays empty", `{"data":[]}`, "", ""},
		{"deezer answered -> listenbrainz not consulted", `{"data":[{"id":9,"name":"Soundgarden"}]}`, lbMbid, "Soundgarden"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e, ctx := newTestEnricher(t)
			stubMB(e, func(r *http.Request) (*http.Response, error) {
				switch {
				case strings.Contains(r.URL.Path, "/search/artist"):
					return resp(200, `{"data":[{"id":27,"name":"Mudhoney"}]}`), nil
				case strings.Contains(r.URL.Path, "/related"):
					return resp(200, tt.deezer), nil
				case strings.Contains(r.URL.Path, "/similar-artists/json"):
					return resp(200, `[{"artist_mbid":"x","name":"Nirvana","score":11684}]`), nil
				}
				return resp(404, ""), nil
			})

			got := e.similarOrEmpty(ctx, "Mudhoney", tt.mbid)
			if tt.wantName == "" {
				if len(got) != 0 {
					t.Fatalf("got %+v, want empty", got)
				}
				return
			}
			if len(got) != 1 || got[0].Name != tt.wantName {
				t.Fatalf("got %+v, want one entry named %q", got, tt.wantName)
			}
		})
	}
}

// The popularity phase writes exactly what api/mixes reads: one doc per artist
// MBID holding only ordered recording MBIDs. Driven through the real Run so
// the collection + gating logic is what is under test, not a re-statement of it.
func TestRunPopularityPhase(t *testing.T) {
	e, ctx := newTestEnricher(t)
	var hits int
	stubMB(e, func(r *http.Request) (*http.Response, error) {
		if strings.Contains(r.URL.Path, "/1/popularity/top-recordings-for-artist/") {
			hits++
			if !strings.HasSuffix(r.URL.Path, lbMbid) {
				t.Errorf("keyed by %q, want the artist mbid", r.URL.Path)
			}
			return resp(200, `[{"recording_mbid":"r1","total_listen_count":9},{"recording_mbid":"r2","total_listen_count":4}]`), nil
		}
		return resp(404, ""), nil
	})
	if err := e.tracks.UpsertAll(ctx, []repo.Track{
		{ID: "t1", Path: "t1", AlbumID: "al1", Album: "Superfuzz", AlbumArtist: "Mudhoney"},
		{ID: "t2", Path: "t2", AlbumID: "al2", Album: "Nowhere", AlbumArtist: "No Mbid Here"},
	}); err != nil {
		t.Fatal(err)
	}
	// pre-cached so the artists phase skips them: this phase must be reachable
	// on nothing but an already-known MBID (zero MusicBrainz requests).
	for name, mbid := range map[string]string{"Mudhoney": lbMbid, "No Mbid Here": ""} {
		if err := e.put(ctx, KindArtist, name, ArtistEntry{Mbid: mbid, Similar: &[]SimilarArtist{}}); err != nil {
			t.Fatal(err)
		}
	}

	if err := e.Run(ctx); err != nil {
		t.Fatal(err)
	}
	var pc popularCache
	if !e.cacheGet(ctx, KindPopular, lbMbid, &pc) {
		t.Fatal("no popular doc cached under the artist mbid")
	}
	if pc.V != 1 || len(pc.Top) != 2 || pc.Top[0] != "r1" {
		t.Errorf("popular doc = %+v, want {1 [r1 r2]}", pc)
	}
	if hits != 1 {
		t.Errorf("%d fetches, want 1 (the artist with no mbid must not be looked up)", hits)
	}
	// a fresh doc must not be re-fetched on the next pass
	if err := e.Run(ctx); err != nil {
		t.Fatal(err)
	}
	if hits != 1 {
		t.Errorf("second pass re-fetched (hits=%d): the 30-day TTL is not gating", hits)
	}
}
