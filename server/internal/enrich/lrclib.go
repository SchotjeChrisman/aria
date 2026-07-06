package enrich

import (
	"context"
	"math"
	"net/url"
)

// LRCLib: synced + plain lyrics, on demand per track. Free, no key.
type LRCLib struct {
	c    *politeClient
	base string
}

func NewLRCLib() *LRCLib {
	return &LRCLib{c: newPoliteClient(), base: "https://lrclib.net"}
}

// Lyrics matches the cached lyricsV2 shape: {synced|null, plain|null}. A nil
// *Lyrics means "no lyrics found" and is cached too (negative cache).
type Lyrics struct {
	Synced *string `json:"synced"`
	Plain  *string `json:"plain"`
}

type lrcResult struct {
	Duration     float64 `json:"duration"`
	SyncedLyrics string  `json:"syncedLyrics"`
	PlainLyrics  string  `json:"plainLyrics"`
}

// Lyrics searches and matches by duration ourselves: LRCLIB's /get happily
// returns timings from a different master (v1 bug: 2.7s drift). Take the
// closest-duration synced entry, refuse synced timings more than 5s off —
// plain lyrics beat a highlight that lies.
func (l *LRCLib) Lyrics(ctx context.Context, title, artist string, duration float64) (*Lyrics, error) {
	q := url.Values{"track_name": {title}, "artist_name": {artist}}
	var results []lrcResult
	if err := l.c.getJSON(ctx, l.base+"/api/search?"+q.Encode(), &results); err != nil {
		return nil, err
	}
	dist := func(r *lrcResult) float64 { return math.Abs(r.Duration - duration) }
	var synced, plain *lrcResult
	for i := range results {
		r := &results[i]
		if r.SyncedLyrics != "" && (synced == nil || dist(r) < dist(synced)) {
			synced = r
		}
		if r.PlainLyrics != "" && (plain == nil || dist(r) < dist(plain)) {
			plain = r
		}
	}
	switch {
	case synced != nil && dist(synced) <= 5:
		return &Lyrics{Synced: &synced.SyncedLyrics, Plain: nullable(synced.PlainLyrics)}, nil
	case plain != nil:
		return &Lyrics{Plain: &plain.PlainLyrics}, nil
	}
	return nil, nil
}
