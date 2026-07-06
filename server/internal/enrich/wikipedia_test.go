package enrich

import (
	"context"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"
)

func testWikipedia(t *testing.T, h http.HandlerFunc) *Wikipedia {
	t.Helper()
	srv := httptest.NewServer(h)
	t.Cleanup(srv.Close)
	return &Wikipedia{c: newPoliteClient(), restBase: srv.URL, wdBase: srv.URL + "/w/api.php"}
}

func TestSummary(t *testing.T) {
	tests := []struct {
		name, title, wantPath, body string
		status                      int
		want                        *Summary
	}{
		{
			name: "full", title: "Miles Davis", wantPath: "/page/summary/Miles Davis", status: 200,
			body: `{"type":"standard","extract":"Trumpeter.","description":"American jazz musician",
				"thumbnail":{"source":"https://i/thumb.jpg"},"originalimage":{"source":"https://i/full.jpg"},
				"content_urls":{"desktop":{"page":"https://en.wikipedia.org/wiki/Miles_Davis"}}}`,
			want: &Summary{Type: "standard", Extract: "Trumpeter.", Description: "American jazz musician",
				PageURL: "https://en.wikipedia.org/wiki/Miles_Davis", Original: "https://i/full.jpg", Thumbnail: "https://i/thumb.jpg"},
		},
		{
			// titles from MB url-rels arrive percent-encoded; decode-then-encode
			name: "encoded title", title: "Caf%C3%A9_Tacvba", wantPath: "/page/summary/Café_Tacvba", status: 200,
			body: `{"type":"standard","extract":"Band."}`,
			want: &Summary{Type: "standard", Extract: "Band."},
		},
		{name: "missing page", title: "Nobody", wantPath: "/page/summary/Nobody", status: 404, body: `{}`, want: nil},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var gotPath string
			w := testWikipedia(t, func(rw http.ResponseWriter, r *http.Request) {
				gotPath = r.URL.Path
				rw.WriteHeader(tt.status)
				rw.Write([]byte(tt.body))
			})
			got, err := w.Summary(context.Background(), tt.title)
			if err != nil {
				t.Fatal(err)
			}
			if gotPath != tt.wantPath {
				t.Errorf("path = %q, want %q", gotPath, tt.wantPath)
			}
			if tt.want == nil {
				if got != nil {
					t.Fatalf("want nil, got %+v", got)
				}
				return
			}
			if *got != *tt.want {
				t.Errorf("got %+v, want %+v", *got, *tt.want)
			}
		})
	}
}

func TestSummaryImage(t *testing.T) {
	if (&Summary{Original: "o", Thumbnail: "t"}).Image() != "o" {
		t.Error("original should win")
	}
	if (&Summary{Thumbnail: "t"}).Image() != "t" {
		t.Error("thumbnail fallback")
	}
}

func TestSitelinkTitle(t *testing.T) {
	w := testWikipedia(t, func(rw http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("ids") != "Q93341" {
			t.Errorf("ids = %q", r.URL.Query().Get("ids"))
		}
		rw.Write([]byte(`{"entities":{"Q93341":{"sitelinks":{"enwiki":{"title":"Miles Davis"},"dewiki":{"title":"x"}}}}}`))
	})
	got, err := w.SitelinkTitle(context.Background(), "Q93341")
	if err != nil || got != "Miles Davis" {
		t.Fatalf("got %q, %v", got, err)
	}
}

func TestPoliteClientRetry(t *testing.T) {
	var n atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, r *http.Request) {
		if n.Add(1) < 3 {
			rw.WriteHeader(429)
			return
		}
		rw.Write([]byte(`{"ok":true}`))
	}))
	defer srv.Close()
	c := newPoliteClient()
	c.retryWait = time.Millisecond
	var out struct{ OK bool }
	if err := c.getJSON(context.Background(), srv.URL, &out); err != nil || !out.OK {
		t.Fatalf("after retries: %v, %+v", err, out)
	}
	if n.Load() != 3 {
		t.Errorf("attempts = %d, want 3", n.Load())
	}

	// exhausted retries surface a status error
	n.Store(-10)
	if err := c.getJSON(context.Background(), srv.URL, &out); err == nil {
		t.Error("want error after exhausting retries")
	}
}
