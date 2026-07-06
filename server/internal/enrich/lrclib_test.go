package enrich

import (
	"context"
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"
)

func TestLyrics(t *testing.T) {
	tests := []struct {
		name     string
		duration float64
		body     string
		want     *Lyrics // nil = negative result
	}{
		{
			name: "synced within tolerance, closest duration wins", duration: 200,
			body: `[{"duration":210,"syncedLyrics":"far","plainLyrics":"farp"},
				{"duration":201,"syncedLyrics":"[00:01.00] hi","plainLyrics":"hi"},
				{"duration":199,"plainLyrics":"plain only"}]`,
			want: &Lyrics{Synced: ptr("[00:01.00] hi"), Plain: ptr("hi")},
		},
		{
			// synced 10s off is refused: plain lyrics beat a highlight that lies
			name: "synced drift over 5s falls back to plain", duration: 200,
			body: `[{"duration":210,"syncedLyrics":"[x] drifted","plainLyrics":"drifted"},
				{"duration":201,"plainLyrics":"the words"}]`,
			want: &Lyrics{Plain: ptr("the words")},
		},
		{
			name: "synced without plain yields null plain", duration: 100,
			body: `[{"duration":100,"syncedLyrics":"[x] s"}]`,
			want: &Lyrics{Synced: ptr("[x] s")},
		},
		{name: "no results", duration: 100, body: `[]`, want: nil},
		{
			// missing durations count as 0, matching legacy (r.duration || 0)
			name: "zero durations still match at small track duration", duration: 3,
			body: `[{"syncedLyrics":"[x] s","plainLyrics":"p"}]`,
			want: &Lyrics{Synced: ptr("[x] s"), Plain: ptr("p")},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var gotQuery url.Values
			srv := httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, r *http.Request) {
				gotQuery = r.URL.Query()
				rw.Write([]byte(tt.body))
			}))
			defer srv.Close()
			l := &LRCLib{c: newPoliteClient(), base: srv.URL}
			got, err := l.Lyrics(context.Background(), "Song", "Artist", tt.duration)
			if err != nil {
				t.Fatal(err)
			}
			if gotQuery.Get("track_name") != "Song" || gotQuery.Get("artist_name") != "Artist" {
				t.Errorf("query = %v", gotQuery)
			}
			if tt.want == nil {
				if got != nil {
					t.Fatalf("want nil, got %+v", got)
				}
				return
			}
			if got == nil {
				t.Fatal("want lyrics, got nil")
			}
			if !eqPtr(got.Synced, tt.want.Synced) || !eqPtr(got.Plain, tt.want.Plain) {
				t.Errorf("got {%v %v}, want {%v %v}", str(got.Synced), str(got.Plain), str(tt.want.Synced), str(tt.want.Plain))
			}
		})
	}
}

func str(p *string) string {
	if p == nil {
		return "<nil>"
	}
	return *p
}
