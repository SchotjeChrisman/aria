package enrich

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"reflect"
	"slices"
	"strings"
	"testing"

	"aria/internal/db"
	"aria/internal/repo"
)

// OK Computer, trimmed to what inc=genres+release-groups+url-rels returns
// (verified live): a thin release-level vote, a rich release-group one, and
// two discogs url-rels for two pressings of the same record.
const mbSourcesRelease = `{
  "id":"1834eae1-741b-3c03-9ca5-0df3decb43ea","title":"OK Computer",
  "genres":[{"name":"rock","count":1}],
  "release-group":{"id":"rg","primary-type":"Album","genres":[
    {"name":"alternative rock","count":26},{"name":"art rock","count":13},
    {"name":"electronic","count":2},{"name":"britpop","count":1}]},
  "relations":[
    {"type":"wikidata","url":{"resource":"https://www.wikidata.org/wiki/Q1234"}},
    {"type":"discogs","url":{"resource":"https://www.discogs.com/release/1348271"}},
    {"type":"discogs","url":{"resource":"https://www.discogs.com/release/6886814"}}]}`

func TestMBGenrePick(t *testing.T) {
	tests := []struct {
		name string
		body string
		want []string
	}{
		{
			// count>=2 cuts britpop; the release's own thin tag is appended
			name: "release group votes, count cut, release tag appended",
			body: mbSourcesRelease,
			want: []string{"alternative rock", "art rock", "electronic", "rock"},
		},
		{
			name: "cap at 5",
			body: `{"release-group":{"genres":[
			  {"name":"a","count":9},{"name":"b","count":8},{"name":"c","count":7},
			  {"name":"d","count":6},{"name":"e","count":5},{"name":"f","count":4}]}}`,
			want: []string{"a", "b", "c", "d", "e"},
		},
		{
			// equal counts must order by name, or the stored row churns
			name: "tie broken by name",
			body: `{"release-group":{"genres":[{"name":"zeta","count":3},{"name":"alpha","count":3}]}}`,
			want: []string{"alpha", "zeta"},
		},
		{
			name: "release tag not duplicated",
			body: `{"genres":[{"name":"rock","count":1}],"release-group":{"genres":[{"name":"rock","count":5}]}}`,
			want: []string{"rock"},
		},
		{name: "nothing voted", body: `{"id":"x"}`, want: []string{}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var rel mbRelease
			if err := json.Unmarshal([]byte(tt.body), &rel); err != nil {
				t.Fatal(err)
			}
			if got := mbGenrePick(&rel); !reflect.DeepEqual(got, tt.want) {
				t.Errorf("got %v, want %v", got, tt.want)
			}
		})
	}
}

func TestDiscogsReleaseID(t *testing.T) {
	tests := []struct {
		name string
		rels []mbRelation
		want int64
	}{
		{"none", []mbRelation{{Type: "wikidata", URL: &struct {
			Resource string `json:"resource"`
		}{"https://www.wikidata.org/wiki/Q1"}}}, 0},
		{"first of several wins", relsOf("https://www.discogs.com/release/1348271",
			"https://www.discogs.com/release/6886814"), 1348271},
		{"language-prefixed path", relsOf("https://www.discogs.com/de/release/42"), 42},
		{"master link ignored", relsOf("https://www.discogs.com/master/96559"), 0},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := discogsReleaseID(tt.rels); got != tt.want {
				t.Errorf("got %d, want %d", got, tt.want)
			}
		})
	}
}

func relsOf(urls ...string) []mbRelation {
	var out []mbRelation
	for _, u := range urls {
		out = append(out, mbRelation{Type: "discogs", URL: &struct {
			Resource string `json:"resource"`
		}{u}})
	}
	return out
}

// srcEnricher wires an Enricher whose MusicBrainz and Discogs clients both
// point at httptest servers. discogs == "" leaves e.dg nil, i.e. no token.
func srcEnricher(t *testing.T, discogs string) *Enricher {
	t.Helper()
	dir := t.TempDir()
	sqldb, err := db.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { sqldb.Close() })
	e := New(context.Background(), repo.NewTracks(sqldb), repo.NewEnrich(sqldb),
		repo.NewMatches(sqldb), repo.NewSettings(sqldb), dir, discogs)

	mb := httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, r *http.Request) {
		if !strings.Contains(r.URL.RawQuery, "genres") {
			t.Errorf("inc= lacked genres: %s", r.URL.RawQuery)
		}
		rw.Write([]byte(mbSourcesRelease))
	}))
	t.Cleanup(mb.Close)
	// MB's base URL is a const inside MB.get, so redirect at the transport
	mbHost := strings.TrimPrefix(mb.URL, "http://")
	e.mb.c.hc.Transport = roundTripFunc(func(r *http.Request) (*http.Response, error) {
		r.URL.Scheme, r.URL.Host = "http", mbHost
		return http.DefaultTransport.RoundTrip(r)
	})
	if e.dg != nil {
		dg, _ := dgServer(t, dgRelease, 200)
		e.dg.base, e.dg.c = dg.base, dg.c
	}
	return e
}

func TestEnrichSources(t *testing.T) {
	ctx := context.Background()
	const albumID = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	const mbid = "1834eae1-741b-3c03-9ca5-0df3decb43ea"

	t.Run("no token: MusicBrainz half only, Discogs half left owed", func(t *testing.T) {
		e := srcEnricher(t, "")
		if err := e.enrichSources(ctx, albumID, mbid); err != nil {
			t.Fatal(err)
		}
		var s sourcesCache
		if !e.cacheGet(ctx, KindSources, albumID, &s) {
			t.Fatal("nothing cached")
		}
		if want := []string{"alternative rock", "art rock", "electronic", "rock"}; !reflect.DeepEqual(s.MBGenres, want) {
			t.Errorf("MBGenres = %v, want %v", s.MBGenres, want)
		}
		if s.DiscogsID != 1348271 {
			t.Errorf("DiscogsID = %d, want 1348271", s.DiscogsID)
		}
		if s.DiscogsAt != "" || s.Styles != nil {
			t.Errorf("Discogs half ran without a token: %+v", s)
		}
	})

	t.Run("token: styles, label and catalogue number", func(t *testing.T) {
		e := srcEnricher(t, "tok")
		if err := e.enrichSources(ctx, albumID, mbid); err != nil {
			t.Fatal(err)
		}
		var s sourcesCache
		e.cacheGet(ctx, KindSources, albumID, &s)
		if !reflect.DeepEqual(s.Styles, []string{"Euro-Disco"}) {
			t.Errorf("Styles = %v", s.Styles)
		}
		if s.Label != "RCA" || s.Catno != "PB 41447" {
			t.Errorf("label/catno = %q/%q", s.Label, s.Catno)
		}
		if s.DiscogsAt == "" {
			t.Error("DiscogsAt unstamped after an answer: the album would be re-fetched forever")
		}
		// the order api/library.go feeds to genres.SplitAll: MB's voted tags
		// first, then Discogs' genres, then its styles.
		want := []string{"alternative rock", "art rock", "electronic", "rock",
			"Electronic", "Pop", "Euro-Disco"}
		got := slices.Concat(s.MBGenres, s.Genres, s.Styles)
		if !reflect.DeepEqual(got, want) {
			t.Errorf("sources genres = %v, want %v", got, want)
		}
	})

	t.Run("token appears later: only the Discogs half re-runs", func(t *testing.T) {
		e := srcEnricher(t, "tok")
		// a row from a tokenless pass: MB half settled, Discogs half owed
		if err := e.put(ctx, KindSources, albumID, sourcesCache{
			V: sourcesV, MBGenres: []string{"rock"}, DiscogsID: 1348271,
		}); err != nil {
			t.Fatal(err)
		}
		mbHits := 0
		inner := e.mb.c.hc.Transport
		e.mb.c.hc.Transport = roundTripFunc(func(r *http.Request) (*http.Response, error) {
			mbHits++
			return inner.RoundTrip(r)
		})
		if err := e.enrichSources(ctx, albumID, mbid); err != nil {
			t.Fatal(err)
		}
		if mbHits != 0 {
			t.Errorf("re-fetched MusicBrainz %d times; the v marker should have skipped it", mbHits)
		}
		var s sourcesCache
		e.cacheGet(ctx, KindSources, albumID, &s)
		if !reflect.DeepEqual(s.MBGenres, []string{"rock"}) {
			t.Errorf("MBGenres clobbered: %v", s.MBGenres)
		}
		if s.Catno != "PB 41447" {
			t.Errorf("Discogs half did not run: %+v", s)
		}
	})

	t.Run("a catalogue number drops the cached album blurb so the page re-derives", func(t *testing.T) {
		e := srcEnricher(t, "tok")
		if err := e.put(ctx, KindAlbumInfo, albumID, map[string]any{"label": "old"}); err != nil {
			t.Fatal(err)
		}
		if err := e.enrichSources(ctx, albumID, mbid); err != nil {
			t.Fatal(err)
		}
		if _, ok, _ := e.cache.Get(ctx, KindAlbumInfo, albumID); ok {
			t.Error("stale albumInfo kept: the catalogue number would never surface")
		}
	})
}
