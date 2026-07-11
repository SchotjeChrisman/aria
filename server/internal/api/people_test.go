package api

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
)

// peopleEnricher satisfies api.Enricher + warmEnricher with a canned portrait
// map. Run/Status are no-ops; Warm is unused by the proxy path.
type peopleEnricher struct{ portraits map[string]string }

func (p *peopleEnricher) Run(context.Context) error                         { return nil }
func (p *peopleEnricher) Status() any                                       { return nil }
func (p *peopleEnricher) People(context.Context) (map[string]string, error) { return p.portraits, nil }
func (p *peopleEnricher) Warm([]string) int                                 { return 0 }

func getImg(h http.Handler, name string) *httptest.ResponseRecorder {
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("GET", "/api/people/img/"+name, nil))
	return rec
}

func TestPeopleImgProxy(t *testing.T) {
	// stand-in external CDN, counting hits so we can prove the second request
	// is served from disk without re-fetching.
	var hits int
	cdn := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits++
		if r.URL.Path == "/notimage" {
			w.Write([]byte("<html>error page, 200 but not an image</html>"))
			return
		}
		w.Write(jpegBytes)
	}))
	defer cdn.Close()

	deps, _ := artDeps(t)
	deps.Enricher = &peopleEnricher{portraits: map[string]string{
		"Miles":   cdn.URL + "/miles.jpg",
		"BadFace": cdn.URL + "/notimage",
	}}
	h := New(deps)

	// cold fetch -> caches + serves the jpeg
	if rec := getImg(h, "Miles"); rec.Code != 200 || rec.Body.String() != string(jpegBytes) {
		t.Fatalf("cold Miles = %d %q", rec.Code, rec.Body.String())
	}
	if hits != 1 {
		t.Fatalf("cold fetch hits = %d, want 1", hits)
	}

	// warm hit -> served from disk, no second upstream request
	if rec := getImg(h, "Miles"); rec.Code != 200 || rec.Body.String() != string(jpegBytes) {
		t.Fatalf("warm Miles = %d %q", rec.Code, rec.Body.String())
	}
	if hits != 1 {
		t.Fatalf("warm fetch hits = %d, want still 1 (disk cache)", hits)
	}

	// unknown name -> 404
	if rec := getImg(h, "Nobody"); rec.Code != 404 {
		t.Fatalf("unknown = %d, want 404", rec.Code)
	}

	// upstream 200 but not an image -> 404, nothing cached
	if rec := getImg(h, "BadFace"); rec.Code != 404 {
		t.Fatalf("non-image = %d, want 404", rec.Code)
	}
	if rec := getImg(h, "BadFace"); rec.Code == 200 {
		t.Fatalf("non-image must not be cached and served")
	}
}
