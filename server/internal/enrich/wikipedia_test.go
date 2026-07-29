package enrich

import (
	"context"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func testWikipedia(t *testing.T, h http.HandlerFunc) *Wikipedia {
	t.Helper()
	srv := httptest.NewServer(h)
	t.Cleanup(srv.Close)
	return &Wikipedia{c: newPoliteClient(), restBase: srv.URL,
		wdBase: srv.URL + "/w/api.php", sparql: srv.URL + "/sparql"}
}

// A captured WDQS response body. Bowie has both dates and eight instruments;
// the Beatles have neither a birth date nor an instrument, which is the
// binding-absent case (the key is simply missing from the row, not null).
const wdFactsBody = `{"head":{"vars":["a","birth","death","instruments"]},"results":{"bindings":[
 {"a":{"type":"uri","value":"http://www.wikidata.org/entity/Q5383"},
  "birth":{"datatype":"http://www.w3.org/2001/XMLSchema#dateTime","type":"literal","value":"1947-01-08T00:00:00Z"},
  "death":{"datatype":"http://www.w3.org/2001/XMLSchema#dateTime","type":"literal","value":"2016-01-10T00:00:00Z"},
  "instruments":{"type":"literal","value":"voice|ARP 2500|saxophone|guitar|piano"}},
 {"a":{"type":"uri","value":"http://www.wikidata.org/entity/Q1299"},
  "instruments":{"type":"literal","value":""}}]}}`

func TestFacts(t *testing.T) {
	var gotQuery string
	w := testWikipedia(t, func(rw http.ResponseWriter, r *http.Request) {
		gotQuery = r.URL.Query().Get("query")
		if f := r.URL.Query().Get("format"); f != "json" {
			t.Errorf("format = %q, want json (WDQS needs no Accept header)", f)
		}
		rw.Write([]byte(wdFactsBody))
	})
	got, err := w.Facts(context.Background(), []string{"Q5383", "Q1299"})
	if err != nil {
		t.Fatal(err)
	}
	// every requested id has to reach the VALUES clause, or the batch silently
	// drops artists that then settle with no facts
	for _, q := range []string{"wd:Q5383", "wd:Q1299"} {
		if !strings.Contains(gotQuery, q) {
			t.Errorf("query missing %s: %s", q, gotQuery)
		}
	}
	bowie := WDFacts{Born: "1947-01-08", Died: "2016-01-10",
		Instruments: []string{"voice", "ARP 2500", "saxophone", "guitar", "piano"}}
	if !reflect.DeepEqual(got["Q5383"], bowie) {
		t.Errorf("Q5383 = %+v, want %+v", got["Q5383"], bowie)
	}
	// present in the map (so the caller settles it) but carrying nothing
	if f, ok := got["Q1299"]; !ok || f.Born != "" || len(f.Instruments) != 0 {
		t.Errorf("Q1299 = %+v, ok=%v", f, ok)
	}
	if len(got) != 2 {
		t.Errorf("got %d rows, want 2", len(got))
	}
}

func TestFactsNoQids(t *testing.T) {
	// no ids must mean no request at all — an empty VALUES {} is a syntax error
	w := testWikipedia(t, func(rw http.ResponseWriter, r *http.Request) {
		t.Error("Facts(nil) made a request")
	})
	got, err := w.Facts(context.Background(), nil)
	if err != nil || len(got) != 0 {
		t.Fatalf("got %v, %v", got, err)
	}
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
