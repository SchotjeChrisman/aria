package enrich

import (
	"context"
	"net/url"
	"strconv"
)

// Discogs supplies the pressing-level facts nothing else in the graph has: the
// fine `styles` taxonomy MusicBrainz does not vote on (Euro-Disco, Symphonic
// Rock), and the label + catalogue number of the physical record.
//
// Token-gated (env DISCOGS_TOKEN): NewDiscogs("") returns nil and the Discogs
// half of the sources phase never runs at all. Rejected alternative: shipping
// keyless. Discogs does answer /releases/{id} with no credentials, at a
// measured 25 req/min (x-discogs-ratelimit header) — but that budget is
// per-IP and shared with everything else on the user's network, so 2,000
// albums would spend 80 minutes of somebody else's allowance, and Discogs'
// terms want identifiable clients.
//
// The token rides as a ?token= query param rather than an `Authorization:
// Discogs token=` header (both are accepted, verified) because politeClient
// has no per-request header hook, and growing one for a client shared by seven
// other sources is a worse trade than a query param. Leakage is a non-issue:
// doJSON's error path formats the HOST — `fmt.Errorf("%s: status %d", u.Host,
// …)` — never the URL.
type Discogs struct {
	c     *politeClient
	base  string // split out so tests can point it at an httptest server
	token string
}

func NewDiscogs(token string) *Discogs {
	if token == "" {
		return nil // dark, completely: every call site checks e.dg == nil
	}
	return &Discogs{c: newPoliteClient(), base: "https://api.discogs.com", token: token}
}

// DiscogsRelease is the consumed subset of a release. Everything else the
// endpoint returns — images, master_id, identifiers (barcode, matrix runouts),
// tracklist, community stats — is deliberately dropped: Cover Art Archive
// already fills art, and barcodes belong to the matcher, not to this phase.
type DiscogsRelease struct {
	Genres []string `json:"genres"` // coarse: Electronic, Pop
	Styles []string `json:"styles"` // fine: Euro-Disco
	Labels []struct {
		Name  string `json:"name"`
		Catno string `json:"catno"`
	} `json:"labels"`
}

// Release looks one release up by its Discogs id — which arrives free from the
// MusicBrainz `discogs` url-rel, so there is no search, no fuzzy matching and
// no second identity problem to solve.
//
// Gotcha, verified: an INVALID token returns 200 here rather than 401.
// Discogs silently drops lookup endpoints to the unauthenticated tier, so a
// typo'd token never surfaces as an error — only as 25/min and the occasional
// 429 (which doJSON already retries). Deliberately no validation probe: it
// would be a request per startup that buys a README sentence.
func (d *Discogs) Release(ctx context.Context, id int64) (*DiscogsRelease, error) {
	var out DiscogsRelease
	u := d.base + "/releases/" + strconv.FormatInt(id, 10) + "?token=" + url.QueryEscape(d.token)
	if err := d.c.getJSON(ctx, u, &out); err != nil {
		return nil, err
	}
	return &out, nil
}
