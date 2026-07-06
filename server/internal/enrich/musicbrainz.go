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
		Name string `json:"name"`
	} `json:"artist"`
	Work *struct {
		Relations []mbRelation `json:"relations"`
	} `json:"work"`
	URL *struct {
		Resource string `json:"resource"`
	} `json:"url"`
}

type mbArtist struct {
	ID             string `json:"id"`
	Name           string `json:"name"`
	Type           string `json:"type"`
	Disambiguation string `json:"disambiguation"`
	Score          *int   `json:"score"`
	Area           *struct {
		Name string `json:"name"`
	} `json:"area"`
	LifeSpan *struct {
		Begin string `json:"begin"`
		End   string `json:"end"`
	} `json:"life-span"`
	Relations []mbRelation `json:"relations"`
}

type mbRecording struct {
	ID        string       `json:"id"`
	Relations []mbRelation `json:"relations"`
}

type mbArtistCredit struct {
	Name       string `json:"name"`
	JoinPhrase string `json:"joinphrase"`
	Artist     struct {
		Name string `json:"name"`
	} `json:"artist"`
}

type mbRelease struct {
	ID           string           `json:"id"`
	Title        string           `json:"title"`
	Date         string           `json:"date"`
	Country      string           `json:"country"`
	TrackCount   *int             `json:"track-count"`
	Score        *int             `json:"score"`
	ArtistCredit []mbArtistCredit `json:"artist-credit"`
	Media        []struct {
		Tracks []struct {
			Recording *mbRecording `json:"recording"`
		} `json:"tracks"`
	} `json:"media"`
	LabelInfo []struct {
		Label *struct {
			Name string `json:"name"`
		} `json:"label"`
	} `json:"label-info"`
	ReleaseGroup *struct {
		PrimaryType    string   `json:"primary-type"`
		SecondaryTypes []string `json:"secondary-types"`
	} `json:"release-group"`
}

// searchReleases runs the legacy release:"album" AND artist:"artist" query.
func (m *MB) searchReleases(ctx context.Context, album, artist string, limit int) []mbRelease {
	q := url.QueryEscape(`release:"` + album + `" AND artist:"` + artist + `"`)
	var out struct {
		Releases []mbRelease `json:"releases"`
	}
	m.get(ctx, fmt.Sprintf("release/?query=%s&limit=%d", q, limit), &out)
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
				if r.Type == "conductor" && r.Artist != nil {
					out.Conductor = r.Artist.Name
				}
				if strings.Contains(r.Type, "orchestra") && r.Artist != nil {
					out.Orchestra = r.Artist.Name
				}
				if (r.Type == "instrument" || r.Type == "vocal" || r.Type == "performer") && r.Artist != nil {
					role := "performer"
					if r.Type == "vocal" {
						role = "vocals"
					}
					if len(r.Attributes) > 0 {
						role = strings.Join(r.Attributes, ", ")
					}
					out.Performers = append(out.Performers, Performer{Name: r.Artist.Name, Role: role})
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
