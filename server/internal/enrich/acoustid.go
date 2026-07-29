package enrich

import (
	"context"
	"encoding/json"
	"fmt"
	"net/url"
	"strconv"
)

// AcoustID resolves Chromaprint fingerprints to AcoustID ids and MusicBrainz
// recording/release-group MBIDs.
//
// It lives here rather than in internal/fingerprint because politeClient is
// unexported and its per-host schedule is process-global on purpose: two
// clients with their own schedules would hit api.acoustid.org at twice the
// agreed rate. enrich is already one file per source; AcoustID is a source.
//
// No key ships with Aria and none is invented. key == "" is the whole feature
// gate: Lookup returns (nil, nil) without touching the network, so the caller
// has nothing to special-case and a key added later simply starts working.
type AcoustID struct {
	c    *politeClient
	key  string
	base string
}

func NewAcoustID(key string) *AcoustID {
	return &AcoustID{c: newPoliteClient(), key: key, base: "https://api.acoustid.org/v2/lookup"}
}

// Enabled reports whether a key was configured. It is the outer gate — the
// fingerprint job skips the whole lookup phase, and its progress frames, when
// it is false. Lookup's own empty-key short circuit is the inner one, so a
// caller that forgets this check still cannot send a keyless request.
func (a *AcoustID) Enabled() bool { return a.key != "" }

// FPQuery is one fingerprint to look up. Duration is the FULL track length in
// seconds — AcoustID matches it against the indexed recording with
// maxdurationdiff (7 s by default), so the 120 s fingerprint window is
// irrelevant here.
type FPQuery struct {
	Fingerprint string
	Duration    int
}

// FPResult is one query's answer, in the same order as the queries passed in.
// Results is nil for a fingerprint AcoustID knows nothing about — a real,
// storable answer, not an error.
type FPResult struct {
	Results []FPMatch
}

// FPMatch mirrors AcoustID's results[] with meta=recordingids+releasegroupids:
// with the *ids* metas (rather than `recordings`/`releasegroups`) each nested
// object carries nothing but an id, which is all Phase 4 needs.
type FPMatch struct {
	ID         string  `json:"id"`    // the AcoustID UUID
	Score      float64 `json:"score"` // 0..1
	Recordings []struct {
		ID            string `json:"id"` // MusicBrainz recording MBID
		ReleaseGroups []struct {
			ID string `json:"id"` // MusicBrainz release-group MBID
		} `json:"releasegroups"`
	} `json:"recordings"`
}

// Lookup resolves up to a batch of fingerprints in one POST.
//
// Three things here are load-bearing and each fails SILENTLY if got wrong:
//
//  1. batch=1 is always sent, even for a single fingerprint. acoustid-server
//     does `fingerprints = params.fingerprints if params.batch else
//     params.fingerprints[:1]` — without it every fingerprint after the first
//     is dropped with no error and nine tracks simply look unmatched.
//  2. meta is SPACE-separated (`self.meta = self.meta.split()`). The familiar
//     `meta=recordingids+releasegroupids` only works in a URL because + decodes
//     to a space; url.Values would percent-encode a literal + to %2B, yielding
//     one unrecognised token and results with no metadata at all.
//  3. Results are keyed off the response's `index`, never off position.
//     LookupHandlerParams.parse drops an entry it cannot parse, which shifts
//     every later result onto the wrong track.
//
// POST, not GET: a real fingerprint is ~2.6 KB, so ten of them is a ~26 KB
// query string — past the usual 8 KB URL cap. werkzeug's req.values covers form
// bodies, so the server takes it either way.
func (a *AcoustID) Lookup(ctx context.Context, qs []FPQuery) ([]FPResult, error) {
	if a.key == "" || len(qs) == 0 {
		return nil, nil
	}
	form := url.Values{
		"client": {a.key},
		"format": {"json"},
		"batch":  {"1"},
		"meta":   {"recordingids releasegroupids"}, // SPACE — see (2) above
	}
	for i, q := range qs {
		s := strconv.Itoa(i)
		form.Set("fingerprint."+s, q.Fingerprint)
		form.Set("duration."+s, strconv.Itoa(q.Duration))
	}

	var raw struct {
		Status string `json:"status"`
		Error  struct {
			Code    int    `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
		Fingerprints []struct {
			Index   int       `json:"index"`
			Results []FPMatch `json:"results"`
		} `json:"fingerprints"`
	}
	if err := a.c.postForm(ctx, a.base, form, &raw); err != nil {
		return nil, err
	}
	// The documented failures (code 2 missing parameter, code 4 invalid key)
	// arrive as HTTP 400 and are already an error from postForm, which includes
	// the body. This catches the same envelope served with a 2xx.
	if raw.Status == "error" {
		return nil, fmt.Errorf("acoustid: %s (code %d)", raw.Error.Message, raw.Error.Code)
	}
	out := make([]FPResult, len(qs))
	for _, f := range raw.Fingerprints {
		// A bare unsuffixed `fingerprint` maps to index -1, and a garbled entry
		// is omitted entirely — either way an index outside the batch is not
		// ours to store.
		if f.Index < 0 || f.Index >= len(qs) {
			continue
		}
		out[f.Index] = FPResult{Results: f.Results}
	}
	return out, nil
}

// RecordingsJSON is the results array as stored in track_fp.recordings, or nil
// when there was no match. Marshalled here so the storage shape stays whatever
// AcoustID returned rather than a lossy re-encoding invented by the caller.
func (r FPResult) RecordingsJSON() *string {
	if len(r.Results) == 0 {
		return nil
	}
	b, err := json.Marshal(r.Results)
	if err != nil {
		return nil
	}
	s := string(b)
	return &s
}

// Best is the top-scoring match (AcoustID returns results ordered, but ordering
// is not documented as a guarantee, and max over <=10 items is free).
func (r FPResult) Best() *FPMatch {
	var best *FPMatch
	for i := range r.Results {
		if best == nil || r.Results[i].Score > best.Score {
			best = &r.Results[i]
		}
	}
	return best
}
