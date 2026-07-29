// Package enrich ports the external-API clients from legacy enrich.js:
// Wikipedia/Wikidata (bios+photos), Deezer (art, similar, discographies),
// Open Opus (composer portraits/epochs), LRCLIB (lyrics). Cached JSON shapes
// match the legacy enrich.json so migrated data stays readable.
package enrich

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"slices"
	"strings"
	"sync"
	"time"
)

const userAgent = "aria/0.1 (self-hosted music server; contact: local)"

// errNotFound is a well-formed 404 ("no such page"), distinct from transport
// failure; lookups map it to a definitive miss.
var errNotFound = errors.New("not found")

// The per-host schedule is process-global, not per-client. MusicBrainz's
// 1 req/s is a ban-triggering limit applied to the whole server, so every
// politeClient — the enricher's, each NewMB/NewDeezer, on-demand route
// handlers — has to queue against one schedule. Per-instance maps would let
// two callers hit the same host at twice the agreed rate.
var (
	hostMu     sync.Mutex
	hostNextAt = map[string]time.Time{}
)

// politeClient enforces the legacy per-host gaps: MusicBrainz hard-requires
// <=1 req/s (1100ms), everyone else gets 300ms. 503/429 retried after
// retryWait, 3 attempts total.
type politeClient struct {
	hc        *http.Client
	retryWait time.Duration
}

func newPoliteClient() *politeClient {
	return &politeClient{
		hc:        &http.Client{Timeout: 15 * time.Second},
		retryWait: 3 * time.Second,
	}
}

func (c *politeClient) reserve(host string) time.Duration {
	gap := 300 * time.Millisecond
	// api.listenbrainz.org publishes a 30-per-window budget, which 300ms
	// (3.3 req/s) sits right on; MusicBrainz bans at >1 req/s. labs.api
	// deliberately stays on the default — it is unmetered and returns no
	// x-ratelimit-* headers at all.
	if strings.Contains(host, "musicbrainz") || host == "api.listenbrainz.org" {
		gap = 1100 * time.Millisecond
	}
	// AcoustID documents "do not make more than 3 requests per second"; the
	// server's own per-IP const is 4. 400ms (2.5 req/s) sits under both. The
	// default 300ms would be 3.3 req/s — over the documented line.
	if host == "api.acoustid.org" {
		gap = 400 * time.Millisecond
	}
	// Discogs publishes 60/min for an authenticated client (documented) and
	// serves 25/min without one (measured, x-discogs-ratelimit). The sources
	// phase is token-gated, so 1100ms — under 60/min with headroom — is the
	// only case that ever runs. Deliberately no x-discogs-ratelimit-remaining
	// parsing: doJSON already retries 429 three times, so an adaptive backoff
	// would be a header nothing acts on.
	if host == "api.discogs.com" {
		gap = 1100 * time.Millisecond
	}
	hostMu.Lock()
	defer hostMu.Unlock()
	wait := time.Until(hostNextAt[host])
	if wait < 0 {
		wait = 0
	}
	hostNextAt[host] = time.Now().Add(wait + gap)
	return wait
}

func sleepCtx(ctx context.Context, d time.Duration) error {
	if d <= 0 {
		return ctx.Err()
	}
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.C:
		return nil
	}
}

func (c *politeClient) getJSON(ctx context.Context, rawURL string, dst any) error {
	return c.doJSON(ctx, http.MethodGet, rawURL, nil, dst)
}

// postForm is getJSON's POST twin, for the one caller that cannot use a query
// string: an AcoustID batch of 10 fingerprints is ~26 KB, well past the usual
// 8 KB URL cap. Same reserve/retry/User-Agent discipline — the whole point of
// putting it here rather than in a new client.
func (c *politeClient) postForm(ctx context.Context, rawURL string, form url.Values, dst any) error {
	return c.doJSON(ctx, http.MethodPost, rawURL, form, dst)
}

// doJSON is the shared retry loop. form != nil makes it a urlencoded body.
func (c *politeClient) doJSON(ctx context.Context, method, rawURL string, form url.Values, dst any) error {
	u, err := url.Parse(rawURL)
	if err != nil {
		return err
	}
	for tries := 3; ; tries-- {
		if err := sleepCtx(ctx, c.reserve(u.Host)); err != nil {
			return err
		}
		var body io.Reader
		if form != nil {
			// re-made per attempt: a retry cannot re-read a consumed Reader
			body = strings.NewReader(form.Encode())
		}
		req, err := http.NewRequestWithContext(ctx, method, rawURL, body)
		if err != nil {
			return err
		}
		req.Header.Set("User-Agent", userAgent)
		if form != nil {
			req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		}
		res, err := c.hc.Do(req)
		if err != nil {
			return err
		}
		if (res.StatusCode == http.StatusServiceUnavailable || res.StatusCode == http.StatusTooManyRequests) && tries > 1 {
			res.Body.Close()
			if err := sleepCtx(ctx, c.retryWait); err != nil {
				return err
			}
			continue
		}
		defer res.Body.Close()
		if res.StatusCode == http.StatusNotFound {
			return errNotFound
		}
		if res.StatusCode < 200 || res.StatusCode > 299 {
			// The body is included (capped) because AcoustID answers an invalid
			// key with HTTP 400 and puts the only useful part — {"error":
			// {"code":4,"message":"invalid API key"}} — in the body. A bare
			// "status 400" stored in track_fp.lookupError would be unactionable.
			b, _ := io.ReadAll(io.LimitReader(res.Body, 512))
			return fmt.Errorf("%s: status %d: %s", u.Host, res.StatusCode, strings.TrimSpace(string(b)))
		}
		return json.NewDecoder(res.Body).Decode(dst)
	}
}

// nullable maps ""/missing API strings to JSON null, like legacy `x || null`.
func nullable(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}

// Wikipedia serves enwiki REST page summaries, Wikidata sitelink lookups and
// the Wikidata Query Service. One client, not two: it already talks to
// wikidata.org, so the SPARQL endpoint is a field and a method rather than a
// second type with its own politeClient and its own User-Agent.
type Wikipedia struct {
	c        *politeClient
	restBase string
	wdBase   string
	sparql   string
}

func NewWikipedia() *Wikipedia {
	return &Wikipedia{
		c:        newPoliteClient(),
		restBase: "https://en.wikipedia.org/api/rest_v1",
		wdBase:   "https://www.wikidata.org/w/api.php",
		sparql:   "https://query.wikidata.org/sparql",
	}
}

// WDFacts is the deliberately narrow slice of Wikidata worth having.
// Instruments are the only genuinely new fact: type, area, life span and band
// membership all already arrive from MusicBrainz, and P18 (Commons image) is —
// for any artist we can reach, since the Q-id comes from the same MB url-rel
// set that yields the enwiki page — the very file the Wikipedia summary
// already gave us. Band membership WITH dates (P463+P580/P582) works, and is
// rejected because the artist page renders members as card shelves with no
// room for a year range.
type WDFacts struct {
	Born        string // YYYY-MM-DD, matching MusicBrainz life spans
	Died        string
	Instruments []string
}

// Facts resolves a batch of Wikidata Q-ids to WDFacts in ONE request.
//
// SPARQL rather than wbgetentities, measured rather than assumed:
// wbgetentities&props=claims returns 360 KB across 356 properties for one
// artist, has no property-filter parameter at all, and hands back bare Q-ids
// ("instrument": Q9798) needing a further lookup each to become "voice". This
// SELECT projects exactly the three facts with English labels — 3 KB for four
// artists, 0.30 s. `format=json` works as a query PARAMETER (verified), so
// politeClient needs no Accept-header hook.
func (w *Wikipedia) Facts(ctx context.Context, qids []string) (map[string]WDFacts, error) {
	out := map[string]WDFacts{}
	if len(qids) == 0 {
		return out, nil
	}
	var vals strings.Builder
	for _, q := range qids {
		vals.WriteString("wd:" + q + " ")
	}
	// GROUP_CONCAT + GROUP BY collapse the row-per-instrument fan-out to one
	// row per artist; without it an eight-instrument artist is eight rows.
	q := `SELECT ?a ?birth ?death (GROUP_CONCAT(DISTINCT ?instrL;separator="|") AS ?instruments) WHERE {
  VALUES ?a { ` + vals.String() + `}
  OPTIONAL { ?a wdt:P569 ?birth. }
  OPTIONAL { ?a wdt:P570 ?death. }
  OPTIONAL { ?a wdt:P1303 ?instr. ?instr rdfs:label ?instrL. FILTER(lang(?instrL)="en") }
} GROUP BY ?a ?birth ?death`
	var raw struct {
		Results struct {
			Bindings []map[string]struct {
				Value string `json:"value"`
			} `json:"bindings"`
		} `json:"results"`
	}
	if err := w.c.getJSON(ctx, w.sparql+"?format=json&query="+url.QueryEscape(q), &raw); err != nil {
		return nil, err
	}
	for _, b := range raw.Results.Bindings {
		qid := b["a"].Value // an entity URI: http://www.wikidata.org/entity/Q5383
		if i := strings.LastIndex(qid, "/"); i >= 0 {
			qid = qid[i+1:]
		}
		if qid == "" {
			continue
		}
		f := WDFacts{Born: dateOnly(b["birth"].Value), Died: dateOnly(b["death"].Value)}
		for _, s := range strings.Split(b["instruments"].Value, "|") {
			if s != "" && !slices.Contains(f.Instruments, s) {
				f.Instruments = append(f.Instruments, s)
			}
		}
		out[qid] = f
	}
	return out, nil
}

// dateOnly trims Wikidata's xsd:dateTime ("1947-01-08T00:00:00Z") to the
// YYYY-MM-DD MusicBrainz life spans already use, so the two sources fill the
// same field interchangeably and the UI needs no idea which one answered.
func dateOnly(s string) string {
	d, _, _ := strings.Cut(s, "T")
	return d
}

// Summary is the subset of the REST page summary the enricher uses.
type Summary struct {
	Type        string // "disambiguation" pages are rejected by callers
	Extract     string
	Description string
	PageURL     string // content_urls.desktop.page
	Original    string // originalimage.source
	Thumbnail   string // thumbnail.source
}

// Image is the legacy preference: full original beats thumbnail.
func (s *Summary) Image() string {
	if s.Original != "" {
		return s.Original
	}
	return s.Thumbnail
}

// Summary fetches the enwiki page summary. Titles that arrive percent-encoded
// (from MB url-rels) are decoded first, matching the legacy
// encodeURIComponent(decodeURIComponent(title)) dance. (nil, nil) = no page.
func (w *Wikipedia) Summary(ctx context.Context, title string) (*Summary, error) {
	if dec, err := url.PathUnescape(title); err == nil {
		title = dec
	}
	var raw struct {
		Type          string `json:"type"`
		Extract       string `json:"extract"`
		Description   string `json:"description"`
		Thumbnail     struct{ Source string }
		OriginalImage struct{ Source string } `json:"originalimage"`
		ContentURLs   struct {
			Desktop struct{ Page string }
		} `json:"content_urls"`
	}
	err := w.c.getJSON(ctx, w.restBase+"/page/summary/"+url.PathEscape(title), &raw)
	if errors.Is(err, errNotFound) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &Summary{
		Type:        raw.Type,
		Extract:     raw.Extract,
		Description: raw.Description,
		PageURL:     raw.ContentURLs.Desktop.Page,
		Original:    raw.OriginalImage.Source,
		Thumbnail:   raw.Thumbnail.Source,
	}, nil
}

// SitelinkTitle resolves a Wikidata Q-id to its enwiki page title ("" if
// none). Callers extract the Q-id from MB wikidata url-rels.
func (w *Wikipedia) SitelinkTitle(ctx context.Context, qid string) (string, error) {
	var raw struct {
		Entities map[string]struct {
			Sitelinks struct {
				Enwiki struct{ Title string } `json:"enwiki"`
			} `json:"sitelinks"`
		} `json:"entities"`
	}
	u := w.wdBase + "?action=wbgetentities&ids=" + url.QueryEscape(qid) + "&props=sitelinks&format=json"
	err := w.c.getJSON(ctx, u, &raw)
	if errors.Is(err, errNotFound) {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	return raw.Entities[qid].Sitelinks.Enwiki.Title, nil
}
