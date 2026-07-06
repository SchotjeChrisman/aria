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
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

const userAgent = "aria/0.1 (self-hosted music server; contact: local)"

// errNotFound is a well-formed 404 ("no such page"), distinct from transport
// failure; lookups map it to a definitive miss.
var errNotFound = errors.New("not found")

// politeClient enforces the legacy per-host gaps: MusicBrainz hard-requires
// <=1 req/s (1100ms), everyone else gets 300ms. 503/429 retried after
// retryWait, 3 attempts total.
type politeClient struct {
	hc        *http.Client
	retryWait time.Duration
	mu        sync.Mutex
	nextAt    map[string]time.Time
}

func newPoliteClient() *politeClient {
	return &politeClient{
		hc:        &http.Client{Timeout: 15 * time.Second},
		retryWait: 3 * time.Second,
		nextAt:    map[string]time.Time{},
	}
}

func (c *politeClient) reserve(host string) time.Duration {
	gap := 300 * time.Millisecond
	if strings.Contains(host, "musicbrainz") {
		gap = 1100 * time.Millisecond
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	wait := time.Until(c.nextAt[host])
	if wait < 0 {
		wait = 0
	}
	c.nextAt[host] = time.Now().Add(wait + gap)
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
	u, err := url.Parse(rawURL)
	if err != nil {
		return err
	}
	for tries := 3; ; tries-- {
		if err := sleepCtx(ctx, c.reserve(u.Host)); err != nil {
			return err
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
		if err != nil {
			return err
		}
		req.Header.Set("User-Agent", userAgent)
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
			return fmt.Errorf("%s: status %d", u.Host, res.StatusCode)
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

// Wikipedia serves enwiki REST page summaries and Wikidata sitelink lookups.
type Wikipedia struct {
	c        *politeClient
	restBase string
	wdBase   string
}

func NewWikipedia() *Wikipedia {
	return &Wikipedia{
		c:        newPoliteClient(),
		restBase: "https://en.wikipedia.org/api/rest_v1",
		wdBase:   "https://www.wikidata.org/w/api.php",
	}
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
