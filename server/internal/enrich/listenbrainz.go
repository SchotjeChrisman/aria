package enrich

import "context"

// ListenBrainz: the read side (the token-only submit path lives in api/plays).
// Two endpoints, both keyless, on two different hosts — labs is the
// unmetered research host, the main API is rate-limited (see politeClient).
// Split base fields exist only so tests can point both at one httptest server,
// same as Deezer.base.
type ListenBrainz struct {
	c    *politeClient
	base string
	labs string
}

func NewListenBrainz() *ListenBrainz {
	return &ListenBrainz{
		c:    newPoliteClient(),
		base: "https://api.listenbrainz.org",
		labs: "https://labs.api.listenbrainz.org",
	}
}

// The similarity model to ask for. Not config: labs rejects the request with a
// 400 if it is omitted, and there is exactly one model anyone would pick.
const lbAlgorithm = "session_based_days_7500_session_300_contribution_5_threshold_10_limit_100_filter_True_skip_30"

// SimilarArtists returns up to 12 artists similar to artistMbid, score
// descending. Response is a flat top-level array; an unknown MBID is a 200
// with `[]`, so an empty non-nil slice means "asked, nothing" and is
// cacheable. Image is always nil — labs returns no artwork, and the shelf
// already renders name-only tiles for Deezer artists with no picture.
func (l *ListenBrainz) SimilarArtists(ctx context.Context, artistMbid string) ([]SimilarArtist, error) {
	var raw []struct {
		Name string `json:"name"`
	}
	u := l.labs + "/similar-artists/json?artist_mbids=" + artistMbid + "&algorithm=" + lbAlgorithm
	if err := l.c.getJSON(ctx, u, &raw); err != nil {
		return nil, err
	}
	out := []SimilarArtist{}
	for _, x := range raw {
		if len(out) == 12 { // same cap as Deezer.Similar, same shelf
			break
		}
		if x.Name != "" {
			out = append(out, SimilarArtist{Name: x.Name})
		}
	}
	return out, nil
}

// lbTopMax caps what TopRecordings keeps. The endpoint ignores ?count= (verified:
// 844 items returned either way, hundreds of KB), so the cap is applied after
// decode and only the ordered MBIDs are kept — the only consumer needs rank,
// not listen counts.
const lbTopMax = 200

// TopRecordings returns recording MBIDs for an artist, most-listened first.
// Empty non-nil slice = ListenBrainz has no listens for this artist, which is
// a fine thing to cache.
func (l *ListenBrainz) TopRecordings(ctx context.Context, artistMbid string) ([]string, error) {
	var raw []struct {
		RecordingMbid string `json:"recording_mbid"`
	}
	if err := l.c.getJSON(ctx, l.base+"/1/popularity/top-recordings-for-artist/"+artistMbid, &raw); err != nil {
		return nil, err
	}
	out := []string{}
	for _, x := range raw {
		if len(out) == lbTopMax {
			break
		}
		if x.RecordingMbid != "" {
			out = append(out, x.RecordingMbid)
		}
	}
	return out, nil
}
