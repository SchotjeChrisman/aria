package enrich

import (
	"context"
	"errors"
	"regexp"
	"slices"
	"sort"
	"strconv"
)

// KindSources is the release-level source graph for one album, keyed by
// albumId like KindAlbum.
//
// Deliberately a separate kind rather than more fields on albumCache: the
// Discogs half stays dark until the user supplies a token, and folding it in
// would mean bumping albumV — re-pulling every album's heavy
// recordings+rels+works payload from MusicBrainz just to learn a genre.
const KindSources = "sources"

// sourcesV: bump to re-pull the MusicBrainz half of every album.
const sourcesV = 1

const (
	// mbGenreMinVotes drops single-vote noise: OK Computer's release group is
	// voted alternative rock 26, art rock 13, electronic 2, britpop 1 — the
	// last is one person's opinion and would widen the browse for nothing.
	// ponytail: a tuning knob, not a law. Raise it if genre browse gets noisy;
	// the fully-safe setting is to merge only when the file tag yielded
	// nothing at all (see buildMergedTracks).
	mbGenreMinVotes = 2
	mbGenreCap      = 5
)

type sourcesCache struct {
	V         int      `json:"v"`
	MBGenres  []string `json:"mbGenres,omitempty"`  // vote-count desc, count>=2, capped
	DiscogsID int64    `json:"discogsId,omitempty"` // from the MB `discogs` url-rel; 0 = MB has no link
	Genres    []string `json:"dgGenres,omitempty"`  // Discogs coarse genres
	Styles    []string `json:"dgStyles,omitempty"`  // Discogs styles — the fine taxonomy
	Label     string   `json:"label,omitempty"`
	Catno     string   `json:"catno,omitempty"`
	// DiscogsAt is stamped once the Discogs half has an ANSWER (hit or 404),
	// never on transport failure — the BioCheckedAt discipline. Empty with a
	// token present therefore means "still owed", so a token appearing months
	// later re-runs only the Discogs half and not the MusicBrainz one.
	DiscogsAt string `json:"discogsAt,omitempty"`
}

// All is every genre-ish string this album's sources produced, for
// genres.SplitAll. Order matters: MusicBrainz's voted tags are the
// best-evidenced, Discogs' coarse genres next, its styles last.
// mbGenrePick selects the genres worth keeping from a release fetched with
// inc=genres+release-groups. The release GROUP's tags are the rich ones (one
// vote pool across every pressing); the release's own are thin but free in the
// same response, so they are appended rather than ignored.
func mbGenrePick(rel *mbRelease) []string {
	out := []string{}
	if rel.ReleaseGroup != nil {
		rg := slices.Clone(rel.ReleaseGroup.Genres)
		// count desc, name asc: the tie-break is what keeps the stored list
		// stable across passes, so a re-run does not churn every album's row.
		sort.SliceStable(rg, func(i, j int) bool {
			if rg[i].Count != rg[j].Count {
				return rg[i].Count > rg[j].Count
			}
			return rg[i].Name < rg[j].Name
		})
		for _, g := range rg {
			if g.Count < mbGenreMinVotes || len(out) == mbGenreCap {
				break // sorted desc, so the first failure is the last
			}
			out = append(out, g.Name)
		}
	}
	for _, g := range rel.Genres {
		if g.Name != "" && !slices.Contains(out, g.Name) {
			out = append(out, g.Name)
		}
	}
	return out
}

// MB stores the link as a plain www.discogs.com URL; some are language-prefixed
// (/de/release/123).
var discogsRe = regexp.MustCompile(`discogs\.com/(?:[a-z]{2}/)?release/(\d+)`)

// discogsReleaseID reads the Discogs release id straight out of the
// MusicBrainz url-rels — which is why nothing here ever calls Discogs' search
// endpoint, and why the whole class of Phase 4 mismatch risk is skipped: MB
// already did the linking, by hand, per release.
//
// Several `discogs` rels on one release are pressings of the same record and
// carry identical genres/styles, so the first is as good as any.
func discogsReleaseID(rels []mbRelation) int64 {
	for _, r := range rels {
		if r.Type != "discogs" || r.URL == nil {
			continue
		}
		if m := discogsRe.FindStringSubmatch(r.URL.Resource); m != nil {
			id, _ := strconv.ParseInt(m[1], 10, 64)
			return id
		}
	}
	return 0
}

// enrichSources fills one album's source graph: one MusicBrainz request that
// yields BOTH the community genre tags and the Discogs release id, then one
// Discogs request when a token is set and MB had a link.
//
// Inherited risk: the release we ask about is whatever the matching phase
// decided, which is exactly what the matcher exists to make trustworthy. A
// mis-identified album gets its sibling's genres — acceptable, because genres
// barely differ between pressings of one record (unlike track listings), and
// this phase gets better for free every time matching does.
func (e *Enricher) enrichSources(ctx context.Context, albumID, mbid string) error {
	var s sourcesCache
	e.cacheGet(ctx, KindSources, albumID, &s)
	if s.V < sourcesV {
		rel := e.mb.release(ctx, mbid, "genres+release-groups+url-rels")
		if rel == nil {
			return nil // no marker written: a transport failure must retry next pass
		}
		s = sourcesCache{
			V:         sourcesV,
			MBGenres:  mbGenrePick(rel),
			DiscogsID: discogsReleaseID(rel.Relations),
		}
		if err := e.put(ctx, KindSources, albumID, s); err != nil {
			return err
		}
	}
	if e.dg == nil || s.DiscogsID == 0 || s.DiscogsAt != "" {
		return nil
	}
	dr, err := e.dg.Release(ctx, s.DiscogsID)
	if err != nil && !errors.Is(err, errNotFound) {
		return err // unstamped: retried next pass
	}
	if dr != nil {
		s.Genres, s.Styles = dr.Genres, dr.Styles
		if len(dr.Labels) > 0 {
			s.Label, s.Catno = dr.Labels[0].Name, dr.Labels[0].Catno
		}
	}
	s.DiscogsAt = nowISO()
	if err := e.put(ctx, KindSources, albumID, s); err != nil {
		return err
	}
	// The album page's facts line is served from the KindAlbumInfo blob, which
	// is cached forever on first view. Dropping it is what makes a catalogue
	// number that arrived AFTER someone already opened the album actually show
	// up; the next view re-derives it (one MB + one Wikipedia request, on the
	// on-demand path that was always going to run for an unvisited album).
	if s.Catno != "" || s.Label != "" {
		return e.cache.Delete(ctx, KindAlbumInfo, albumID)
	}
	return nil
}
