package enrich

import (
	"context"
	"fmt"
	"net/url"
	"strings"
)

// MB is the MusicBrainz WS/2 client. Requests go through a politeClient,
// which enforces the hard 1 req/s MB rate limit and the aria User-Agent.
// All lookups are soft-failing (empty/nil results), like legacy mb().
type MB struct{ c *politeClient }

func NewMB() *MB { return &MB{newPoliteClient()} }

func (m *MB) get(ctx context.Context, path string, v any) bool {
	sep := "?"
	if strings.Contains(path, "?") {
		sep = "&"
	}
	return m.c.getJSON(ctx, "https://musicbrainz.org/ws/2/"+path+sep+"fmt=json", v) == nil
}

type mbRelation struct {
	Type       string   `json:"type"`
	Direction  string   `json:"direction"`
	Attributes []string `json:"attributes"`
	Artist     *struct {
		ID   string `json:"id"`
		Name string `json:"name"`
	} `json:"artist"`
	Work *struct {
		Relations []mbRelation `json:"relations"`
	} `json:"work"`
	URL *struct {
		Resource string `json:"resource"`
	} `json:"url"`
}

// mbAlias is one MB artist alias. Latin display names live here: the
// locale=en, primary, "Artist name" alias is the name MB itself considers the
// English spelling.
type mbAlias struct {
	Name     string `json:"name"`
	SortName string `json:"sort-name"`
	Locale   string `json:"locale"`
	Type     string `json:"type"`
	Primary  bool   `json:"primary"`
}

type mbArtist struct {
	ID             string    `json:"id"`
	Name           string    `json:"name"`
	SortName       string    `json:"sort-name"`
	Type           string    `json:"type"`
	Disambiguation string    `json:"disambiguation"`
	Score          *int      `json:"score"`
	Aliases        []mbAlias `json:"aliases"`
	Area           *struct {
		Name string `json:"name"`
	} `json:"area"`
	LifeSpan *struct {
		Begin string `json:"begin"`
		End   string `json:"end"`
	} `json:"life-span"`
	Relations []mbRelation `json:"relations"`
}

// mbGenre is one community-voted genre tag (inc=genres). Count is the number
// of MusicBrainz editors who voted it, and is the only thing separating an
// album's real genre from one person's opinion.
type mbGenre struct {
	Name  string `json:"name"`
	Count int    `json:"count"`
}

type mbRecording struct {
	ID        string       `json:"id"`
	Relations []mbRelation `json:"relations"`
}

type mbArtistCredit struct {
	Name       string `json:"name"`
	JoinPhrase string `json:"joinphrase"`
	Artist     struct {
		ID       string `json:"id"`
		Name     string `json:"name"`
		SortName string `json:"sort-name"`
	} `json:"artist"`
}

// mbMediumTrack is one track on a medium. Length is MILLISECONDS (verified
// against a live release: 506706 for an 8:26 movement) — the matcher's duration
// component is in ms for exactly this reason, so no unit conversion sits between
// MB's number and the penalty curve.
type mbMediumTrack struct {
	Position  int          `json:"position"`
	Number    string       `json:"number"` // may be "A1"/"1a" on vinyl; Position is the reliable one
	Title     string       `json:"title"`
	Length    *int         `json:"length"`
	Recording *mbRecording `json:"recording"`
}

type mbMedium struct {
	Position   int             `json:"position"`
	Format     string          `json:"format"`
	TrackCount int             `json:"track-count"`
	Tracks     []mbMediumTrack `json:"tracks"`
}

type mbRelease struct {
	ID             string           `json:"id"`
	Title          string           `json:"title"`
	Date           string           `json:"date"`
	Country        string           `json:"country"`
	Disambiguation string           `json:"disambiguation"`
	Barcode        string           `json:"barcode"`
	TrackCount     *int             `json:"track-count"`
	Score          *int             `json:"score"`
	ArtistCredit   []mbArtistCredit `json:"artist-credit"`
	// the release's own artist-rels (already requested, previously dropped by
	// the decoder): where the conductor/soloist/orchestra roles come from
	Relations []mbRelation `json:"relations"`
	Media     []mbMedium   `json:"media"`
	LabelInfo []struct {
		CatalogNumber string `json:"catalog-number"`
		Label         *struct {
			Name string `json:"name"`
		} `json:"label"`
	} `json:"label-info"`
	// inc=genres puts voted tags on BOTH the release and its nested release
	// group, in one response. The group's are the rich ones — one vote pool
	// across every pressing — and the release's own are usually a single tag.
	Genres       []mbGenre `json:"genres"`
	ReleaseGroup *struct {
		ID             string    `json:"id"`
		PrimaryType    string    `json:"primary-type"`
		SecondaryTypes []string  `json:"secondary-types"`
		Genres         []mbGenre `json:"genres"`
	} `json:"release-group"`
}

// searchReleases runs the legacy release:"album" AND artist:"artist" query.
// An empty artist drops that clause entirely rather than searching for
// artist:"" — the matcher's Various-Artists retry needs a title-only search,
// and `AND artist:""` matches nothing at all.
func (m *MB) searchReleases(ctx context.Context, album, artist string, limit int) []mbRelease {
	query := `release:"` + album + `"`
	if artist != "" {
		query += ` AND artist:"` + artist + `"`
	}
	var out struct {
		Releases []mbRelease `json:"releases"`
	}
	m.get(ctx, fmt.Sprintf("release/?query=%s&limit=%d", url.QueryEscape(query), limit), &out)
	return out.Releases
}

// ReleaseGroupByBarcode resolves a UPC to a MusicBrainz release-group MBID —
// the identity that survives across editions and across catalogues, since
// Deezer, Qobuz and MusicBrainz all carry the barcode. "" when MB does not
// know the barcode, which is common for the first weeks of a new release.
//
// The release search embeds release-group.id in its hits, so this is one
// request, not a search followed by a lookup.
func (m *MB) ReleaseGroupByBarcode(ctx context.Context, upc string) string {
	if upc == "" {
		return ""
	}
	var out struct {
		Releases []mbRelease `json:"releases"`
	}
	m.get(ctx, "release/?query="+url.QueryEscape("barcode:"+upc)+"&limit=5", &out)
	// One barcode can legitimately hit several releases (territory variants,
	// or MB data errors); they nearly always share a group. Highest score wins.
	best, bestScore := "", -1
	for _, r := range out.Releases {
		if r.ReleaseGroup == nil || r.ReleaseGroup.ID == "" {
			continue
		}
		s := 0
		if r.Score != nil {
			s = *r.Score
		}
		if s > bestScore {
			best, bestScore = r.ReleaseGroup.ID, s
		}
	}
	return best
}

// ReleaseGroupByName is the fallback when there is no usable barcode: the
// legacy artist+title search, narrowed by release date. year is the release
// year to prefer ("" to skip); a hit within a year of it beats a bare top hit,
// because a title search alone happily returns a tribute album.
func (m *MB) ReleaseGroupByName(ctx context.Context, artist, title, year string) string {
	best, bestScore := "", -1
	for _, r := range m.searchReleases(ctx, title, artist, 8) {
		if r.ReleaseGroup == nil || r.ReleaseGroup.ID == "" {
			continue
		}
		s := 0
		if r.Score != nil {
			s = *r.Score
		}
		if year != "" && len(r.Date) >= 4 && r.Date[:4] == year {
			s += 50
		}
		if s > bestScore {
			best, bestScore = r.ReleaseGroup.ID, s
		}
	}
	return best
}

// ReleasesInGroup lists the releases belonging to a release group. A library
// rip is tagged with one specific release, so membership in this set is what
// proves "this album is now owned" regardless of which edition.
//
// inc=media is what makes this one request useful to the matcher too: the
// browse endpoint returns media[].track-count and media[].format for up to 100
// releases, so a whole release group can be track-count-prefiltered before a
// single verification fetch is spent on it.
func (m *MB) ReleasesInGroup(ctx context.Context, rgid string) []mbRelease {
	if rgid == "" {
		return nil
	}
	var out struct {
		Releases []mbRelease `json:"releases"`
	}
	m.get(ctx, "release?release-group="+url.QueryEscape(rgid)+"&inc=media&limit=100", &out)
	return out.Releases
}

// release looks one release up with the given inc= set; nil on any failure.
func (m *MB) release(ctx context.Context, mbid, inc string) *mbRelease {
	var out mbRelease
	if !m.get(ctx, "release/"+mbid+"?inc="+inc, &out) {
		return nil
	}
	return &out
}

func (m *MB) searchArtists(ctx context.Context, name string, limit int) []mbArtist {
	q := url.QueryEscape(`artist:"` + name + `"`)
	var out struct {
		Artists []mbArtist `json:"artists"`
	}
	m.get(ctx, fmt.Sprintf("artist/?query=%s&limit=%d", q, limit), &out)
	return out.Artists
}

// searchArtistMBID is the common top-hit lookup; "" when MB has no match.
func (m *MB) searchArtistMBID(ctx context.Context, name string) string {
	if as := m.searchArtists(ctx, name, 1); len(as) > 0 {
		return as[0].ID
	}
	return ""
}

func (m *MB) artist(ctx context.Context, mbid, inc string) *mbArtist {
	var out mbArtist
	if !m.get(ctx, "artist/"+mbid+"?inc="+inc, &out) {
		return nil
	}
	return &out
}

// creditsByRecording extracts per-recording credit corrections from a release
// fetched with recordings+recording-level-rels+work-rels+work-level-rels+artist-rels.
// MB work titles are movement-level; the title-derived work/movement grouping
// from tags is kept, so "performance" rels only contribute the composer.
func creditsByRecording(rel *mbRelease) map[string]TrackCredits {
	byRec := map[string]TrackCredits{}
	for _, medium := range rel.Media {
		for _, tr := range medium.Tracks {
			if tr.Recording == nil {
				continue
			}
			var out TrackCredits
			for _, r := range tr.Recording.Relations {
				if r.Artist != nil {
					switch roleOf(r) {
					case "conductor":
						out.Conductor = r.Artist.Name
					case "orchestra":
						out.Orchestra = r.Artist.Name
					case "soloist", "performer":
						role := "performer"
						if r.Type == "vocal" {
							role = "vocals"
						}
						if len(r.Attributes) > 0 {
							role = strings.Join(r.Attributes, ", ")
						}
						out.Performers = append(out.Performers, Performer{Name: r.Artist.Name, Role: role})
					}
				}
				if r.Type == "performance" && r.Work != nil {
					for _, w := range r.Work.Relations {
						if w.Type == "composer" && w.Artist != nil {
							out.Composer = w.Artist.Name
							break
						}
					}
				}
			}
			if !out.empty() {
				byRec[tr.Recording.ID] = out
			}
		}
	}
	return byRec
}
