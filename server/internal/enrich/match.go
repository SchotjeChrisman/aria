package enrich

import (
	"context"
	"encoding/json"
	"math"
	"sort"
	"strconv"
	"time"

	"aria/internal/repo"
)

// Album matching: the impure half. Candidate gathering, the verification
// fetches, and persistence. The scoring and the veto live in distance.go and
// never touch this file's I/O.
//
// This is a phase of Enricher.Run rather than its own job type for one hard
// reason: hostNextAt is a PACKAGE-LEVEL global in this package (enrich.go), and
// it is what keeps MusicBrainz to the agreed 1 req/s. A matcher in its own
// package would carry its own politeClient, would not queue against that
// schedule, and would hit MB at twice the rate — a ban, not a slowdown. Being a
// phase also buys setPhase/step SSE progress, single-flight and cancellation for
// free.

const (
	// Verification fetches per album. 12 × 1.1 s is a ~13 s worst case, which
	// is also the interactive re-match's ceiling.
	maxVerify = 12
	// Search hits considered. Raised from the enricher's 1: the Madrid cluster
	// is thirteen releases and the veto cannot fire on candidates it never saw.
	searchLimit = 15
	// A candidate whose track count is this far from the local one cannot be
	// this album. Free (search hits and inc=media browses both carry the count)
	// and it typically cuts the fetch set to 1-3.
	trackCountSlack = 2
	// A release group needs this share of the album's tracks voting for it
	// before it is worth expanding, and at most this many groups are expanded.
	fpVoteShare = 0.30
	fpMaxGroups = 2

	defaultMaxDistance   = 0.10 // the spec's "distance under roughly 0.10"
	defaultMinSeparation = 0.25 // beets' verified rec_gap_thresh

	// Retry ladder for review/local. Days, not minutes: MusicBrainz ingest
	// happens on the scale of days, so anything faster is pure request waste.
	retryBase = 24 * time.Hour
	retryMax  = 30 * 24 * time.Hour
)

// thresholds reads the two calibration knobs. They are settings rather than
// constants because the spec is explicit that both want calibrating against a
// real library before being frozen, and because the distance scale here is
// beets-shaped but not byte-identical to beets'.
func (e *Enricher) thresholds(ctx context.Context) (maxDistance, minSeparation float64) {
	return Thresholds(ctx, e.settings)
}

// Thresholds is thresholds() without an Enricher, so the library health view
// can band "the runner-up was nearly as good" against the very number this
// pass vetoed on rather than a second copy of 0.25 that silently stops
// matching when the setting is calibrated. nil settings gives the defaults.
func Thresholds(ctx context.Context, settings *repo.Settings) (maxDistance, minSeparation float64) {
	maxDistance, minSeparation = defaultMaxDistance, defaultMinSeparation
	if settings == nil {
		return
	}
	get := func(key string, def float64) float64 {
		s, err := settings.Get(ctx, key)
		if err != nil || s == "" {
			return def
		}
		v, err := strconv.ParseFloat(s, 64)
		if err != nil || v <= 0 || v > 1 {
			return def
		}
		return v
	}
	return get("matchMaxDistance", defaultMaxDistance), get("matchMinSeparation", defaultMinSeparation)
}

// runMatching is Run's first phase. Everything it decides is written before the
// next album starts and PendingAlbums is recomputed from scratch each pass, so
// the query IS the cursor: a SIGTERM mid-pass costs at most one album, and a
// settled library costs one query and an idle frame.
func (e *Enricher) runMatching(ctx context.Context) error {
	if e.matches == nil { // not wired (older callers of New); matching is simply off
		return nil
	}
	pending, err := e.matches.PendingAlbums(ctx, nowISO())
	if err != nil {
		return err
	}
	maxDistance, minSeparation := e.thresholds(ctx)
	e.setPhase("matching", len(pending))
	for _, p := range pending {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		ts, err := e.tracks.ByAlbum(ctx, p.AlbumID)
		if err == nil && len(ts) > 0 {
			if _, err := e.matchOne(ctx, p, ts, maxDistance, minSeparation); err != nil {
				e.log("match " + p.Album + ": " + err.Error())
			}
		}
		e.step()
	}
	return nil
}

// MatchAlbum re-decides one album now, synchronously, through the identical
// code path the batch pass uses — so an interactive score can never differ from
// a background one. Returns nil when the album has no tracks.
func (e *Enricher) MatchAlbum(ctx context.Context, albumID string, ts []repo.Track) (*repo.Decision, error) {
	if e.matches == nil || len(ts) == 0 {
		return nil, nil
	}
	sig, err := e.matches.TrackSig(ctx, albumID)
	if err != nil {
		return nil, err
	}
	attempts := 0
	if d, ok, err := e.matches.Get(ctx, albumID); err == nil && ok {
		attempts = d.Attempts
	}
	maxDistance, minSeparation := e.thresholds(ctx)
	p := repo.PendingAlbum{AlbumID: albumID, Album: ts[0].Album, AlbumArtist: ts[0].AlbumArtist,
		TrackSig: sig, Attempts: attempts}
	return e.matchOne(ctx, p, ts, maxDistance, minSeparation)
}

// matchOne is gather -> prefilter -> verify -> score -> decide -> persist for a
// single album. It NEVER computes or changes an albumId: albumId is the
// scanner's sha1(dir||album||artist) and is only ever used here as a lookup key.
// Re-keying an album orphans tag_items, enrich_cache, edits and the art files on
// disk (see 007_album_identity.sql), so it is out of this phase entirely.
//
// It also never opens a file. Everything on the local side comes from tracks
// rows the scanner already parsed; the only writes are SQLite rows.
func (e *Enricher) matchOne(ctx context.Context, p repo.PendingAlbum, ts []repo.Track,
	maxDistance, minSeparation float64) (*repo.Decision, error) {

	la := localAlbumOf(ts)
	cands := e.gather(ctx, p, la)
	winner, d1, separation, state, reason := decide(cands, maxDistance, minSeparation)

	d := repo.Decision{
		AlbumID: p.AlbumID, State: state, Reason: reason,
		TrackSig: p.TrackSig, Attempts: p.Attempts + 1, DecidedAt: nowISO(),
	}
	if len(cands) > 0 {
		d.Distance = &d1
		if !math.IsInf(separation, 1) {
			d.Separation = &separation
		}
		// The whole candidate set is stored, not just the winner: "thirteen
		// candidates were indistinguishable" is only sayable with the losers in
		// hand, and that sentence is the point of the review queue.
		if b, err := json.Marshal(cands); err == nil {
			d.Candidates = b
		}
	}
	if state == "matched" && winner != nil {
		d.ReleaseMbid = &winner.Mbid
		if winner.RGMbid != "" {
			d.ReleaseGroupMbid = &winner.RGMbid
		}
		d.Disambiguation = winner.Disambiguation
	} else {
		// review and machine-set `local` both come back on a backoff. This is
		// what replaces enrich.go's permanent negative cache: an album MB
		// ingests next month is eventually found, without asking every pass.
		d.RetryAfter = backoff(d.Attempts)
	}
	if err := e.persist(ctx, d); err != nil {
		return nil, err
	}
	return &d, nil
}

// persist writes the decision and, when the album's identity actually moved,
// drops its enrich_cache entry so the `albums` phase later in this same Run
// re-pulls the release. Without that, a review -> matched transition would sit
// behind the albumCache V marker until the next albumV bump.
func (e *Enricher) persist(ctx context.Context, d repo.Decision) error {
	old, had, err := e.matches.Get(ctx, d.AlbumID)
	if err != nil {
		return err
	}
	if err := e.matches.Put(ctx, d); err != nil {
		return err
	}
	if !had || old.State != d.State || strOf(old.ReleaseMbid) != strOf(d.ReleaseMbid) {
		return e.cache.Delete(ctx, KindAlbum, d.AlbumID)
	}
	return nil
}

// backoff is 24h doubling to a 30d ceiling, keyed off the attempt count.
func backoff(attempts int) string {
	d := retryBase
	for i := 1; i < attempts && d < retryMax; i++ {
		d *= 2
	}
	return time.Now().Add(min(d, retryMax)).UTC().Format(time.RFC3339)
}

// localAlbumOf projects the tracks rows onto the pure scoring model. Durations
// are seconds in the DB and milliseconds here, because that is MusicBrainz's
// unit and the conversion belongs on one side of the boundary, not in the
// penalty curve.
func localAlbumOf(ts []repo.Track) localAlbum {
	la := localAlbum{Album: ts[0].Album, AlbumArtist: ts[0].AlbumArtist}
	discs := map[int]bool{}
	for _, t := range ts {
		lt := localTrack{Title: t.Title, id: t.ID}
		if t.DiscNo != nil {
			lt.Disc = *t.DiscNo
		}
		if t.TrackNo != nil {
			lt.Num = *t.TrackNo
		}
		if t.Duration != nil {
			lt.LengthMS = int(*t.Duration * 1000)
		}
		if t.MBRecordingID != nil {
			lt.RecID = *t.MBRecordingID
		}
		if t.Year != nil && la.Year == 0 {
			la.Year = *t.Year
		}
		if t.MBAlbumID != nil && *t.MBAlbumID != "" && la.MBAlbumID == "" {
			la.MBAlbumID = *t.MBAlbumID
		}
		d := lt.Disc
		if d == 0 {
			d = 1
		}
		discs[d] = true
		la.Tracks = append(la.Tracks, lt)
	}
	la.Discs = len(discs)
	// Same order the keyed and sequential pairings both assume. ByAlbum already
	// sorts this way; re-sorting here is what makes the pure half independent of
	// the caller's query.
	sort.SliceStable(la.Tracks, func(i, j int) bool {
		a, b := la.Tracks[i], la.Tracks[j]
		da, db := max(a.Disc, 1), max(b.Disc, 1)
		if da != db {
			return da < db
		}
		na, nb := a.Num, b.Num
		if na == 0 {
			na = math.MaxInt32
		}
		if nb == 0 {
			nb = math.MaxInt32
		}
		return na < nb
	})
	return la
}

// gather assembles the candidate set, prefilters it and verifies the survivors.
//
// Barcode and catalogue number are deliberately absent as candidate sources
// even though the spec lists them: the scanner reads neither tag and repo.Track
// has no field for either, so wiring them up is a taglib read plus a tracks
// column plus a migration, for a candidate source that only helps where the
// tags are already good enough to have found the release by text.
func (e *Enricher) gather(ctx context.Context, p repo.PendingAlbum, la localAlbum) []candidate {
	seen := map[string]bool{}
	var seeds []candidate
	add := func(c candidate) {
		if c.Mbid == "" || seen[c.Mbid] {
			return
		}
		seen[c.Mbid] = true
		seeds = append(seeds, c)
	}

	// 1. MBIDs already in the file tags. A direct lookup, no search, and it is
	//    exempt from the track-count prefilter below: the user's tagger already
	//    claimed this exact release and a bonus disc must not silently drop it.
	if la.MBAlbumID != "" {
		add(candidate{Mbid: la.MBAlbumID, Source: "tag"})
	}

	// 2. AcoustID release groups, expanded with one browse each. Absent
	//    fingerprints simply yield no votes, so a deployment with no fpcalc or
	//    no ACOUSTID_KEY degrades to text search with nothing to special-case.
	for _, rgid := range topGroups(e.matches.ReleaseGroupVotes(ctx, p.AlbumID), len(la.Tracks)) {
		for _, rel := range e.mb.ReleasesInGroup(ctx, rgid) {
			c := candidateOf(rel, "acoustid")
			c.RGMbid = rgid // the browse response does not echo the group back
			add(c)
		}
	}

	// 3. Text search, last resort.
	hits := e.mb.searchReleases(ctx, p.Album, p.AlbumArtist, searchLimit)
	if len(hits) == 0 && isVarious(p.AlbumArtist) {
		hits = e.mb.searchReleases(ctx, p.Album, "", searchLimit)
	}
	for _, rel := range hits {
		add(candidateOf(rel, "search"))
	}

	// 4. Track-count prefilter, before any verification fetch is spent. Free:
	//    search hits carry track-count and inc=media browses carry it per
	//    medium. It does nothing for the tour-nights case — all thirteen shows
	//    have the same track count — which is precisely why the veto exists.
	var keep []candidate
	for _, c := range seeds {
		if c.Source != "tag" && c.Tracks > 0 && abs(c.Tracks-len(la.Tracks)) > trackCountSlack {
			continue
		}
		keep = append(keep, c)
	}

	// 5. Verify. Search RANK is never evidence — it only decides the order
	//    candidates enter the fetch cap.
	var out []candidate
	for _, c := range keep {
		if len(out) == maxVerify || ctx.Err() != nil {
			break
		}
		rel := e.mb.release(ctx, c.Mbid, "recordings+labels+release-groups")
		if rel == nil {
			continue
		}
		full := candidateOf(*rel, c.Source)
		if full.RGMbid == "" {
			full.RGMbid = c.RGMbid
		}
		full.mb = flattenMedia(rel)
		scoreCandidate(la, &full)
		out = append(out, full)
	}
	return out
}

// topGroups picks the release groups AcoustID voted for strongly enough to be
// worth a browse request.
func topGroups(votes map[string]int, tracks int) []string {
	if len(votes) == 0 || tracks == 0 {
		return nil
	}
	type kv struct {
		id string
		n  int
	}
	var all []kv
	for id, n := range votes {
		if float64(n) >= fpVoteShare*float64(tracks) {
			all = append(all, kv{id, n})
		}
	}
	// Ties broken by id so the request sequence is deterministic; map order
	// otherwise makes two identical libraries fetch different things.
	sort.Slice(all, func(i, j int) bool {
		if all[i].n != all[j].n {
			return all[i].n > all[j].n
		}
		return all[i].id < all[j].id
	})
	var out []string
	for i := 0; i < len(all) && i < fpMaxGroups; i++ {
		out = append(out, all[i].id)
	}
	return out
}

// candidateOf projects an mbRelease (from a search, a browse or a full fetch)
// onto the scoring model's candidate.
func candidateOf(rel mbRelease, source string) candidate {
	c := candidate{
		Mbid: rel.ID, Title: rel.Title, Date: rel.Date, Country: rel.Country,
		Disambiguation: rel.Disambiguation, Source: source,
		Artist: joinCredit(rel.ArtistCredit), Media: len(rel.Media),
	}
	if rel.ReleaseGroup != nil {
		c.RGMbid = rel.ReleaseGroup.ID
	}
	// Search hits carry a top-level track-count; browse and full fetches carry
	// it per medium. Whichever is present is the same number.
	if rel.TrackCount != nil {
		c.Tracks = *rel.TrackCount
	}
	for _, m := range rel.Media {
		if rel.TrackCount == nil {
			c.Tracks += m.TrackCount
		}
	}
	return c
}

// joinCredit flattens an artist credit with its own join phrases. Presentation
// policy (the classical composer/performer split) is deliberately NOT applied:
// this string is compared against the ALBUMARTIST tag, and the tag is the naive
// join too.
func joinCredit(cs []mbArtistCredit) string {
	out := ""
	for _, c := range cs {
		out += c.Name + c.JoinPhrase
	}
	return out
}

// flattenMedia turns the release's media into the flat, medium-position-tagged
// track list the pairing rules consume.
func flattenMedia(rel *mbRelease) []mbTrack {
	media := append([]mbMedium(nil), rel.Media...)
	sort.SliceStable(media, func(i, j int) bool { return media[i].Position < media[j].Position })
	var out []mbTrack
	for mi, m := range media {
		pos := m.Position
		if pos == 0 {
			pos = mi + 1 // MB always sets it; a missing one must not collapse two media onto disc 0
		}
		for ti, t := range m.Tracks {
			mt := mbTrack{Medium: pos, Pos: t.Position, Title: t.Title}
			if mt.Pos == 0 {
				mt.Pos = ti + 1
			}
			if t.Length != nil {
				mt.LengthMS = *t.Length
			}
			if t.Recording != nil {
				mt.RecID = t.Recording.ID
			}
			out = append(out, mt)
		}
	}
	return out
}

// alignedTracks answers "which local file is which track of this release",
// keyed by tracks-row id, using the identical pure pairing that chose the
// release in the first place. Empty when the release carries no track list.
//
// This is what lets enrichAlbum stop doing `if t.MBRecordingID == nil { continue
// }`. That guard meant credits only ever reached libraries already run through
// Picard, because the join was the FILE's own recording tag; taking the
// alignment from the match instead means a never-tagged library gets credits —
// and corrected titles and track numbers — for the first time.
func alignedTracks(ts []repo.Track, rel *mbRelease) map[string]mbTrack {
	c := candidateOf(*rel, "")
	c.mb = flattenMedia(rel)
	if len(c.mb) == 0 {
		return nil
	}
	la := localAlbumOf(ts)
	p, _, _ := bestPairing(la, &c)
	out := make(map[string]mbTrack, len(p.pairs))
	for _, pr := range p.pairs {
		out[la.Tracks[pr[0]].id] = c.mb[pr[1]]
	}
	return out
}

// PinAlbumMatch records a user-chosen release as a permanent decision: pinned
// rows are excluded from PendingAlbums forever, so the matcher never argues with
// it. mbid == "" deletes the row instead, which puts the album back in the
// queue for a fresh decision.
func (e *Enricher) PinAlbumMatch(ctx context.Context, albumID, mbid string) error {
	if e.matches == nil {
		return nil
	}
	if mbid == "" {
		return e.matches.Delete(ctx, albumID)
	}
	sig, err := e.matches.TrackSig(ctx, albumID)
	if err != nil {
		return err
	}
	return e.matches.Put(ctx, repo.Decision{
		AlbumID: albumID, State: "matched", Reason: "pinned",
		ReleaseMbid: &mbid, Pinned: true, TrackSig: sig, DecidedAt: nowISO(),
	})
}

func abs(n int) int {
	if n < 0 {
		return -n
	}
	return n
}
