package enrich

import (
	"math"
	"sort"
	"strconv"
	"strings"
	"unicode"
)

// Album matching: the pure half. No context, no clock, no I/O, nothing that can
// fail — so the whole decision is testable without a network, which is the only
// way the thirteen-tour-nights case can be a unit test instead of a war story.
//
// The scoring model is beets'. The weights below are its shipped defaults
// (config_default.yaml, verified against beetbox/beets master), not invented
// numbers: a decade of other people's libraries has already calibrated them.

// dist is beets' Distance accumulator: a weighted mean of penalties, each in
// [0,1], so the result is in [0,1] too. Components that have no evidence are
// simply never added, which is why the weight is accumulated alongside the sum
// rather than being a fixed denominator.
type dist struct{ sum, w float64 }

func (d *dist) add(weight, penalty float64) {
	d.sum += weight * penalty
	d.w += weight
}

// value is 1 — the worst possible distance — when nothing was comparable at
// all. "No evidence" must never read as "perfect match".
func (d dist) value() float64 {
	if d.w == 0 {
		return 1
	}
	return d.sum / d.w
}

// beets' shipped distance_weights.
const (
	wAlbum           = 3.0
	wArtist          = 3.0
	wYear            = 1.0
	wMediums         = 1.0
	wAlbumID         = 5.0 // reward only; see scoreWith
	wMissingTracks   = 0.9
	wUnmatchedTracks = 0.6
	wTrackTitle      = 3.0
	wTrackLength     = 2.0
	wTrackIndex      = 1.0
	wTrackID         = 5.0 // reward only

	// beets' track_length_grace / track_length_max. Under 10 s apart is free
	// (CD pre-gap, fade handling, a different mastering); 30 s apart is a
	// different performance.
	lengthGraceMS = 10_000
	lengthMaxMS   = 30_000

	// localThreshold is the distance past which no candidate is plausibly this
	// album at all, so the answer is "not in MusicBrainz" rather than "ask the
	// user". Deliberately loose so `review` stays the default outcome.
	// ponytail: 0.35 is the one number here with no external precedent. It is
	// the first thing to move after running this over a real library.
	localThreshold = 0.35

	// siblingBand is how close rivals must be to D1 to count as
	// indistinguishable. Three of them from three different release groups is
	// the Amsterdam evidence pattern.
	siblingBand = 0.05
)

// localTrack is the file side of one comparison. Everything is a plain value
// with an explicit zero meaning "the tag was absent" — the pairing rules need
// to distinguish "track 0" from "no track number", and nothing here should be
// carrying pointers into repo.Track.
type localTrack struct {
	Title    string
	Disc     int // 0 = untagged; treated as disc 1 when keying
	Num      int // 0 = untagged
	LengthMS int // 0 = unknown
	RecID    string

	// The tracks-row id this came from. Unexported and untouched by every
	// scoring rule: it exists only so bestPairing's answer can be turned back
	// into "which FILE is this release track", which is what the enricher needs
	// to write corrections against.
	id string
}

// localAlbum is the album side. MBAlbumID is any release MBID the files were
// already tagged with; it only ever earns a reward, never a penalty.
type localAlbum struct {
	Album       string
	AlbumArtist string
	Year        int
	Discs       int
	MBAlbumID   string
	Tracks      []localTrack
}

// mbTrack is one flattened MusicBrainz track. Medium/Pos are MB's own 1-based
// positions, which the keyed pairing matches against (disc, trackNo).
type mbTrack struct {
	Medium, Pos int
	Title       string
	LengthMS    int
	RecID       string
}

// candidate is one release under consideration plus the evidence for it. The
// exported fields are exactly what is stored in match_decisions.candidates and
// shown in the review queue — a bare number is not enough for a user to say
// "these thirteen all match on titles and disagree on durations".
type candidate struct {
	Mbid           string             `json:"mbid"`
	RGMbid         string             `json:"rgMbid"`
	Title          string             `json:"title"`
	Artist         string             `json:"artist"`
	Date           string             `json:"date"`
	Country        string             `json:"country"`
	Disambiguation string             `json:"disambiguation,omitempty"`
	Tracks         int                `json:"tracks"`
	Media          int                `json:"media"`
	Source         string             `json:"source"` // tag | acoustid | search
	Distance       float64            `json:"distance"`
	Why            map[string]float64 `json:"why,omitempty"`

	mb []mbTrack // populated by the verification fetch; not persisted
}

// ---- string distance --------------------------------------------------------

// norm strips everything that is punctuation-, case- or article-noise so that
// "The Beatles" and "beatles" are the same string. No dependency: this is a
// dozen lines of stdlib and a fuzzy-matching library would be a whole tree.
func norm(s string) string {
	var b strings.Builder
	prevSpace := true
	for _, r := range strings.ToLower(s) {
		switch {
		case unicode.IsLetter(r) || unicode.IsDigit(r):
			b.WriteRune(r)
			prevSpace = false
		case r == '\'' || r == '’':
			// Apostrophes are DELETED, not spaced: taggers disagree constantly
			// about "Sgt. Pepper's" vs "Sgt Peppers" and about the straight
			// vs curly glyph, and splitting the word there invents a difference
			// that is not in the titles.
		case !prevSpace:
			b.WriteRune(' ')
			prevSpace = true
		}
	}
	out := strings.TrimSpace(b.String())
	return strings.TrimPrefix(out, "the ")
}

// levenshtein is the two-row edit distance over runes. Two rows, not a full
// matrix: these are titles, but a 2-disc opera box is 60 comparisons per
// candidate per pairing and the allocation is the only cost worth caring about.
func levenshtein(a, b []rune) int {
	if len(a) < len(b) {
		a, b = b, a
	}
	prev := make([]int, len(b)+1)
	cur := make([]int, len(b)+1)
	for j := range prev {
		prev[j] = j
	}
	for i := 1; i <= len(a); i++ {
		cur[0] = i
		for j := 1; j <= len(b); j++ {
			cost := 1
			if a[i-1] == b[j-1] {
				cost = 0
			}
			cur[j] = min(prev[j]+1, min(cur[j-1]+1, prev[j-1]+cost))
		}
		prev, cur = cur, prev
	}
	return prev[len(b)]
}

// strDist is a normalised edit distance in [0,1]. Both empty is 0 (two absent
// fields agree); exactly one empty is 1 (one side knows something the other
// does not, which is real disagreement).
func strDist(a, b string) float64 {
	na, nb := norm(a), norm(b)
	if na == "" && nb == "" {
		return 0
	}
	if na == "" || nb == "" {
		return 1
	}
	if na == nb {
		return 0
	}
	ra, rb := []rune(na), []rune(nb)
	return float64(levenshtein(ra, rb)) / float64(max(len(ra), len(rb)))
}

// lengthPenalty is beets' track_length curve: free inside the grace window,
// then linear to 1 at the max. This is the component that separates two nights
// of one tour — the setlist is identical, the performances are not.
func lengthPenalty(a, b int) float64 {
	d := a - b
	if d < 0 {
		d = -d
	}
	if d <= lengthGraceMS {
		return 0
	}
	return math.Min(1, float64(d-lengthGraceMS)/float64(lengthMaxMS-lengthGraceMS))
}

// yearPenalty treats a one-year gap as half-wrong: reissues and regional
// release-date lag routinely move a year without changing the album.
func yearPenalty(a, b int) float64 {
	switch d := a - b; {
	case d == 0:
		return 0
	case d == 1 || d == -1:
		return 0.5
	}
	return 1
}

// year extracts the leading YYYY of an MB date ("2019-05-06"); 0 when absent.
func yearOf(date string) int {
	if len(date) < 4 {
		return 0
	}
	n, err := strconv.Atoi(date[:4])
	if err != nil {
		return 0
	}
	return n
}

// ---- pairing ----------------------------------------------------------------

// pairing is one hypothesis about which local file is which MB track.
type pairing struct {
	pairs                     [][2]int // {local index, mb index}
	unpairedLocal, unpairedMB int
}

// pairKeyed matches on (disc, track number). Correct when the tags are right,
// and the only pairing that scores a folder with a missing track 3 properly.
// nil when fewer than 90 % of the files carry a track number — guessing at that
// point produces a pairing worse than sequential every time.
func pairKeyed(local []localTrack, mb []mbTrack) *pairing {
	numbered := 0
	for _, t := range local {
		if t.Num > 0 {
			numbered++
		}
	}
	if len(local) == 0 || float64(numbered) < 0.9*float64(len(local)) {
		return nil
	}
	type key struct{ d, n int }
	byKey := make(map[key]int, len(mb))
	for i, t := range mb {
		byKey[key{t.Medium, t.Pos}] = i
	}
	var p pairing
	used := make([]bool, len(mb))
	for i, t := range local {
		d := t.Disc
		if d == 0 {
			d = 1
		}
		j, ok := byKey[key{d, t.Num}]
		if !ok || used[j] {
			p.unpairedLocal++
			continue
		}
		used[j] = true
		p.pairs = append(p.pairs, [2]int{i, j})
	}
	for _, u := range used {
		if !u {
			p.unpairedMB++
		}
	}
	return &p
}

// pairSeq matches position i to position i over both sides in their natural
// order. This is what saves a 2-disc set tagged 1..24 continuously, where MB
// restarts numbering on each medium and the keyed pairing therefore matches
// almost nothing.
func pairSeq(local []localTrack, mb []mbTrack) *pairing {
	n := min(len(local), len(mb))
	p := pairing{unpairedLocal: len(local) - n, unpairedMB: len(mb) - n}
	for i := 0; i < n; i++ {
		p.pairs = append(p.pairs, [2]int{i, i})
	}
	return &p
}

// ---- scoring ----------------------------------------------------------------

// scoreWith computes the full album+track distance under one pairing, and the
// per-component breakdown the review UI renders. Pure.
func scoreWith(la localAlbum, c *candidate, p *pairing) (float64, map[string]float64) {
	var d dist
	why := map[string]float64{}

	pen := func(name string, weight, penalty float64) {
		d.add(weight, penalty)
		why[name] = penalty
	}

	pen("album", wAlbum, strDist(la.Album, c.Title))

	// Compilations legitimately disagree about the album artist ("Various
	// Artists" vs the first credited performer), so the field carries no signal
	// there and is dropped rather than penalised.
	if !isVarious(la.AlbumArtist) && !isVarious(c.Artist) {
		pen("artist", wArtist, strDist(la.AlbumArtist, c.Artist))
	}
	if y := yearOf(c.Date); la.Year > 0 && y > 0 {
		pen("year", wYear, yearPenalty(la.Year, y))
	}
	if c.Media > 0 && la.Discs > 0 {
		v := 1.0
		if c.Media == la.Discs {
			v = 0
		}
		pen("mediums", wMediums, v)
	}
	// album_id is a reward, never a penalty: files tagged with a DIFFERENT
	// release MBID are extremely common (Picard picked another pressing) and
	// must not be evidence against the right album. Only agreement counts.
	if la.MBAlbumID != "" && la.MBAlbumID == c.Mbid {
		d.add(wAlbumID, 0)
	}

	if len(c.mb) > 0 {
		pen("missing", wMissingTracks, float64(p.unpairedMB)/float64(len(c.mb)))
	}
	if len(la.Tracks) > 0 {
		pen("unmatched", wUnmatchedTracks, float64(p.unpairedLocal)/float64(len(la.Tracks)))
	}

	// Per-pair components are accumulated into the same weighted mean, so an
	// album with 22 tracks is dominated by its tracks and a single-track album
	// is dominated by its title — which is the correct balance in both cases.
	var title, length, index float64
	var nLength, nIndex int
	for _, pr := range p.pairs {
		lt, mt := la.Tracks[pr[0]], c.mb[pr[1]]
		tp := strDist(lt.Title, mt.Title)
		d.add(wTrackTitle, tp)
		title += tp
		if lt.LengthMS > 0 && mt.LengthMS > 0 {
			lp := lengthPenalty(lt.LengthMS, mt.LengthMS)
			d.add(wTrackLength, lp)
			length += lp
			nLength++
		}
		if lt.Num > 0 {
			ld := lt.Disc
			if ld == 0 {
				ld = 1
			}
			ip := 1.0
			if ld == mt.Medium && lt.Num == mt.Pos {
				ip = 0
			}
			d.add(wTrackIndex, ip)
			index += ip
			nIndex++
		}
		if lt.RecID != "" && lt.RecID == mt.RecID {
			d.add(wTrackID, 0)
		}
	}
	if n := len(p.pairs); n > 0 {
		why["trackTitle"] = title / float64(n)
	}
	if nLength > 0 {
		why["trackLength"] = length / float64(nLength)
	}
	if nIndex > 0 {
		why["trackIndex"] = index / float64(nIndex)
	}
	return d.value(), why
}

// scoreCandidate scores both pairing hypotheses and keeps the better one.
//
// Two fixed pairings and take the min, rather than an optimal assignment: two
// pure passes over ≤30 tracks, zero extra requests, and it removes a whole class
// of false reviews (continuous numbering across media, and folders with a gap).
// ponytail: the ceiling is a folder that is BOTH out of order and incomplete —
// it pairs badly, which raises its distance and routes it to review. That is the
// safe direction to be wrong in; the upgrade is Hungarian assignment.
func scoreCandidate(la localAlbum, c *candidate) {
	_, c.Distance, c.Why = bestPairing(la, c)
}

// bestPairing is scoreCandidate's guts, returning the winning pairing as well as
// its score. Split out because applying corrections needs the very same
// alignment that chose this release — recomputed rather than persisted in the
// decision row, because it is two pure passes over ≤30 tracks and a stored
// alignment would rot silently the moment a file was added to the folder.
// Never returns nil: pairSeq always produces a pairing.
func bestPairing(la localAlbum, c *candidate) (*pairing, float64, map[string]float64) {
	best := math.Inf(1)
	var bestP *pairing
	var bestWhy map[string]float64
	for _, p := range []*pairing{pairKeyed(la.Tracks, c.mb), pairSeq(la.Tracks, c.mb)} {
		if p == nil {
			continue
		}
		if v, why := scoreWith(la, c, p); v < best {
			best, bestP, bestWhy = v, p, why
		}
	}
	return bestP, best, bestWhy
}

func isVarious(s string) bool { return norm(s) == "various artists" || norm(s) == "various" }

// ---- the decision -----------------------------------------------------------

// decide applies the two ANDed gates and routes everything that fails them.
//
// The veto is a SEPARATE gate, not a term in the distance, because separation is
// a property of the candidate SET and the distance is a function of one
// candidate — no function of D1 alone can express it. Folding it in would also
// reintroduce the exact failure it exists to stop: a strong D1 buying off
// ambiguity is how the Amsterdam show got matched to Madrid.
//
// Separation is measured against the best candidate in a DIFFERENT release
// group. Deluxe/remaster twins share a group, and picking the best-scoring
// pressing within a group is correct — the identity everything downstream
// consumes (art, credits, release group) is not ambiguous there at all. Thirteen
// tour nights are thirteen distinct groups, so the veto fires on exactly the
// case it was built for.
//
// cands must already be scored. Returns the winner (nil when there was none),
// D1, the separation (+Inf when no rival group existed), and the routing.
func decide(cands []candidate, maxDistance, minSeparation float64) (winner *candidate, d1, separation float64, state, reason string) {
	if len(cands) == 0 {
		return nil, 1, math.Inf(1), "local", "no-candidates"
	}
	sort.SliceStable(cands, func(i, j int) bool { return cands[i].Distance < cands[j].Distance })
	winner = &cands[0]
	d1 = winner.Distance

	// An unknown release group counts as a rival group, including against
	// another unknown: the conservative direction is to veto, not to assume two
	// unidentified groups are the same one.
	separation = math.Inf(1)
	for i := 1; i < len(cands); i++ {
		if winner.RGMbid == "" || cands[i].RGMbid != winner.RGMbid {
			separation = cands[i].Distance - d1
			break
		}
	}

	if d1 <= maxDistance && separation >= minSeparation {
		return winner, d1, separation, "matched", "ok"
	}
	if d1 > localThreshold {
		return winner, d1, separation, "local", "no-plausible-candidate"
	}
	// The Amsterdam pattern: several near-identical candidates from several
	// different release groups, none of them good enough. That is positive
	// evidence the album is not in MusicBrainz, not a failure to retry forever.
	if d1 > maxDistance && countSiblingGroups(cands, d1) >= 3 {
		return winner, d1, separation, "local", "indistinguishable-siblings"
	}
	if d1 <= maxDistance {
		return winner, d1, separation, "review", "low-separation"
	}
	return winner, d1, separation, "review", "weak-match"
}

// countSiblingGroups counts the distinct release groups represented among the
// candidates within siblingBand of D1.
func countSiblingGroups(cands []candidate, d1 float64) int {
	seen := map[string]bool{}
	n := 0
	for _, c := range cands {
		if c.Distance-d1 > siblingBand {
			break // sorted
		}
		g := c.RGMbid
		if g == "" {
			n++ // unknown group: its own, every time
			continue
		}
		if !seen[g] {
			seen[g] = true
			n++
		}
	}
	return n
}
