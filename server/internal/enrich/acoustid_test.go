package enrich

import (
	"context"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"testing"
)

// The response bodies below are the shape acoustid-server's _handle_internal
// produces with batch=1 and meta=recordingids+releasegroupids.
func TestAcoustIDLookup(t *testing.T) {
	const twoHits = `{"status":"ok","fingerprints":[
		{"index":0,"results":[
			{"id":"9ff43b6a-4f16-427c-93c2-92307ca505e0","score":0.987,
			 "recordings":[{"id":"rec-a","releasegroups":[{"id":"rg-a"}]}]},
			{"id":"low","score":0.4,"recordings":[]}]},
		{"index":1,"results":[]}]}`

	tests := []struct {
		name    string
		queries []FPQuery
		status  int
		body    string
		wantErr bool
		// want[i] is the top match id expected for query i; "" = no match
		want []string
	}{
		{
			name:    "batch of two, second unmatched",
			queries: []FPQuery{{"AQADtE", 311}, {"AQADs7", 245}},
			body:    twoHits,
			want:    []string{"9ff43b6a-4f16-427c-93c2-92307ca505e0", ""},
		},
		{
			// LookupHandlerParams.parse drops entries it cannot parse, so the
			// array both shifts AND arrives out of order. Position must never be
			// trusted: index 2's result belongs to query 2, not to slot 0.
			name:    "results keyed by index, not position",
			queries: []FPQuery{{"a", 100}, {"b", 200}, {"c", 300}},
			body: `{"status":"ok","fingerprints":[
				{"index":2,"results":[{"id":"third","score":0.9,"recordings":[]}]},
				{"index":0,"results":[{"id":"first","score":0.8,"recordings":[]}]}]}`,
			want: []string{"first", "", "third"},
		},
		{
			name:    "index outside the batch is discarded, not stored",
			queries: []FPQuery{{"a", 100}},
			body: `{"status":"ok","fingerprints":[
				{"index":-1,"results":[{"id":"bare","score":0.9,"recordings":[]}]},
				{"index":7,"results":[{"id":"alien","score":0.9,"recordings":[]}]}]}`,
			want: []string{""},
		},
		{
			// verified live: HTTP 400 plus this envelope for a bad key
			name:    "invalid key surfaces as an error",
			queries: []FPQuery{{"a", 100}},
			status:  http.StatusBadRequest,
			body:    `{"error": {"code": 4, "message": "invalid API key"}, "status": "error"}`,
			wantErr: true,
		},
		{
			name:    "error envelope served with 200 still errors",
			queries: []FPQuery{{"a", 100}},
			body:    `{"error": {"code": 2, "message": "missing required parameter \"client\""}, "status": "error"}`,
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var gotForm url.Values
			var gotMethod, gotCT string
			srv := httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, r *http.Request) {
				r.ParseForm()
				gotForm, gotMethod, gotCT = r.PostForm, r.Method, r.Header.Get("Content-Type")
				if tt.status != 0 {
					rw.WriteHeader(tt.status)
				}
				rw.Write([]byte(tt.body))
			}))
			defer srv.Close()

			a := NewAcoustID("test-key")
			a.base = srv.URL
			got, err := a.Lookup(context.Background(), tt.queries)
			if tt.wantErr {
				if err == nil {
					t.Fatalf("want error, got %+v", got)
				}
				// the message must reach the caller, not just "status 400" —
				// track_fp.lookupError is meant to be actionable
				if !strings.Contains(err.Error(), "invalid API key") &&
					!strings.Contains(err.Error(), "missing required parameter") {
					t.Errorf("error loses the API message: %v", err)
				}
				return
			}
			if err != nil {
				t.Fatalf("lookup: %v", err)
			}

			if gotMethod != http.MethodPost {
				t.Errorf("method = %s, want POST (a 10-fingerprint batch is ~26 KB)", gotMethod)
			}
			if gotCT != "application/x-www-form-urlencoded" {
				t.Errorf("content-type = %q", gotCT)
			}
			// Without batch=1 the server silently drops every fingerprint after
			// the first. This assertion is the whole reason this test exists.
			if gotForm.Get("batch") != "1" {
				t.Errorf("batch = %q, want \"1\"", gotForm.Get("batch"))
			}
			// space-separated: a literal + would arrive as %2B and yield no metadata
			if m := gotForm.Get("meta"); m != "recordingids releasegroupids" {
				t.Errorf("meta = %q, want space-separated", m)
			}
			if gotForm.Get("client") != "test-key" {
				t.Errorf("client = %q", gotForm.Get("client"))
			}
			for i, q := range tt.queries {
				s := strconv.Itoa(i)
				if gotForm.Get("fingerprint."+s) != q.Fingerprint {
					t.Errorf("fingerprint.%s = %q, want %q", s, gotForm.Get("fingerprint."+s), q.Fingerprint)
				}
				if gotForm.Get("duration."+s) == "" {
					t.Errorf("duration.%s missing", s)
				}
			}

			if len(got) != len(tt.queries) {
				t.Fatalf("got %d results, want %d (one slot per query)", len(got), len(tt.queries))
			}
			for i, want := range tt.want {
				best := got[i].Best()
				if want == "" {
					if best != nil {
						t.Errorf("query %d: got %q, want no match", i, best.ID)
					}
					continue
				}
				if best == nil || best.ID != want {
					t.Errorf("query %d: got %+v, want id %q", i, best, want)
				}
			}
		})
	}
}

// The whole feature must be dark without a key: no request, no error, nothing
// logged. A key arriving later has to be the only change needed.
func TestAcoustIDNoKeyMakesNoRequest(t *testing.T) {
	called := false
	srv := httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, r *http.Request) {
		called = true
	}))
	defer srv.Close()

	a := NewAcoustID("")
	a.base = srv.URL
	if a.Enabled() {
		t.Error("Enabled() true with an empty key")
	}
	got, err := a.Lookup(context.Background(), []FPQuery{{"AQADtE", 300}})
	if err != nil || got != nil {
		t.Errorf("Lookup with no key = (%v, %v), want (nil, nil)", got, err)
	}
	if called {
		t.Error("hit the network with no key")
	}
}

func TestAcoustIDRecordingsJSON(t *testing.T) {
	if got := (FPResult{}).RecordingsJSON(); got != nil {
		t.Errorf("no results should store NULL, got %q", *got)
	}
	r := FPResult{Results: []FPMatch{{ID: "x", Score: 0.5}}}
	got := r.RecordingsJSON()
	if got == nil || !strings.Contains(*got, `"id":"x"`) {
		t.Errorf("RecordingsJSON = %v", got)
	}
}
