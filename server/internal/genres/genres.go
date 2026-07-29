// Package genres is the canonical genre taxonomy (port of genres.js): raw file
// tags (combined, translated, misspelled) are decomposed into clean canonical
// genres arranged in a 2-level hierarchy, Roon-style. The client gets the tree
// via /api/genres and per-track canonical `genres` arrays via /api/tracks.
//
// The top level is a CLOSED set: raw tags can never mint a new top-level
// genre. Unknown tokens are attached under an existing genre by head-word
// inference ("Louisiana Blues" -> Blues) and dropped if nothing matches, so
// the tree stays clean no matter what releases are added.
package genres

import (
	"slices"
	"strings"
	"sync"
)

func of(s string) *string { return &s }

// Tree maps canonical genre -> parent (nil = top-level).
var Tree = map[string]*string{
	"Blues": nil, "Blues Rock": of("Blues"), "Electric Blues": of("Blues"),
	"Delta Blues": of("Blues"), "Chicago Blues": of("Blues"), "Country Blues": of("Blues"),
	"British Blues": of("Blues"), "Soul Blues": of("Blues"), "Piano Blues": of("Blues"),
	"Jazz Blues": of("Blues"), "Louisiana Blues": of("Blues"),

	"Rock": nil, "Classic Rock": of("Rock"), "Alternative Rock": of("Rock"), "Soft Rock": of("Rock"),
	"Pop Rock": of("Rock"), "Folk Rock": of("Rock"), "Hard Rock": of("Rock"),
	"Southern Rock": of("Rock"), "Roots Rock": of("Rock"), "Progressive Rock": of("Rock"),
	"Indie Rock": of("Rock"), "Country Rock": of("Rock"), "Swamp Rock": of("Rock"),
	"Arena Rock": of("Rock"), "Boogie Rock": of("Rock"), "Rock & Roll": of("Rock"),
	"Rockabilly": of("Rock"), "Psychedelic Rock": of("Rock"), "Christian Rock": of("Rock"),
	"Grunge": of("Rock"), "Post-Grunge": of("Rock"), "Yacht Rock": of("Rock"),
	"AOR": of("Rock"), "Punk": of("Rock"),

	"Pop": nil, "Traditional Pop": of("Pop"), "Dance-Pop": of("Pop"), "Synth-Pop": of("Pop"),
	"Operatic Pop": of("Pop"), "Folk Pop": of("Pop"), "Chamber Pop": of("Pop"),

	"Classical": nil, "Symphony": of("Classical"), "Orchestral": of("Classical"),
	"Romantic Classical": of("Classical"), "Modern Classical": of("Classical"),
	"Contemporary Classical": of("Classical"), "Cinematic Classical": of("Classical"),
	"Opera": of("Classical"), "Baroque": of("Classical"), "Concerto": of("Classical"),
	"Art Song": of("Classical"), "Chamber Music": of("Classical"), "Choral": of("Classical"),
	"Classical Crossover": of("Classical"),

	"Jazz": nil, "Vocal Jazz": of("Jazz"), "Swing": of("Jazz"), "Big Band": of("Jazz"),
	"Dixieland": of("Jazz"), "Cool Jazz": of("Jazz"), "Hard Bop": of("Jazz"),
	"Post-Bop": of("Jazz"), "Bebop": of("Jazz"), "Jazz Fusion": of("Jazz"),
	"Smooth Jazz": of("Jazz"), "Soul Jazz": of("Jazz"),
	"Jazz-Funk": of("Jazz"), "Jazz Pop": of("Jazz"), "Third Stream": of("Jazz"),
	"Bossa Nova": of("Jazz"), "Contemporary Jazz": of("Jazz"),

	"Soul/R&B": nil, "Blue-Eyed Soul": of("Soul/R&B"), "Disco": of("Soul/R&B"),
	"Motown": of("Soul/R&B"), "Funk": of("Soul/R&B"), "Quiet Storm": of("Soul/R&B"),
	"Smooth Soul": of("Soul/R&B"), "Pop Soul": of("Soul/R&B"), "Philly Soul": of("Soul/R&B"),
	"Contemporary R&B": of("Soul/R&B"),

	"Country": nil, "Contemporary Country": of("Country"), "Honky Tonk": of("Country"),
	"Country Pop": of("Country"), "Bro-Country": of("Country"),
	"Neo-Traditional Country": of("Country"), "Bluegrass": of("Country"),

	"Folk": nil, "Singer-Songwriter": of("Folk"), "Chamber Folk": of("Folk"), "Celtic": of("Folk"),

	"Metal": nil, "Heavy Metal": of("Metal"), "Symphonic Metal": of("Metal"),
	"Gothic Metal": of("Metal"), "Alternative Metal": of("Metal"),

	"Christian & Gospel": nil, "Gospel": of("Christian & Gospel"),
	"Contemporary Christian": of("Christian & Gospel"),

	"Electronic": nil,
	"Hip-Hop":    nil,
	"Reggae":     nil,
	"Latin":      nil, "Tango": of("Latin"),
	"World":   nil,
	"New Age": nil,

	"Easy Listening": nil,
	"Stage & Screen": nil, "Musical": of("Stage & Screen"), "Soundtrack": of("Stage & Screen"),
}

// normalized raw token -> canonical name(s); empty slice drops the token.
var aliases = map[string][]string{
	"klassiek":           {"Classical"}, // Dutch
	"symfonische muziek": {"Symphony"},  // Dutch
	"vocale muziek (wereldlijk en religieus)": {"Choral"}, // Dutch
	"international pop":                       {"Pop"},
	"ballad":                                  {"Pop"}, // song form, but sometimes the only tag
	"instrumental":                            {},      // format descriptor, not a genre
	"soul":                                    {"Soul/R&B"},
	"r&b":                                     {"Soul/R&B"},
	"rnb":                                     {"Soul/R&B"},
	"rock and roll":                           {"Rock & Roll"},
	"rock n roll":                             {"Rock & Roll"},
	"rock 'n' roll":                           {"Rock & Roll"},
	"psychedelic":                             {"Psychedelic Rock"},
	"fusion":                                  {"Jazz Fusion"},
	"soundtracks":                             {"Soundtrack"},
	"film score":                              {"Soundtrack"},
	"folk blues pop rock":                     {"Folk", "Blues", "Pop", "Rock"}, // space-mashed multi-tag

	// Names the enrichment sources hand us that head-word inference drops
	// entirely: single words, or compounds whose rightmost word means nothing
	// to the tree ("trip hop", "drum and bass"). Anything inference already
	// gets right is deliberately absent — "post-punk", "garage rock",
	// "indie pop", "nu metal", "math rock" all resolve on their head word, and
	// an alias row for them would be a second place to keep in sync.
	//
	// ponytail: hand-picked from the MusicBrainz genre vocabulary rather than
	// imported. The ceiling is that a long-tail MB genre still vanishes
	// silently; the upgrade path is `ws/2/genre/all?fmt=txt` (2,180 names,
	// live) — but importing it would either mint 2,000 nodes into a
	// deliberately CLOSED tree or add 2,000 rows most of which say exactly what
	// inference already concludes.
	"britpop":       {"Alternative Rock"},
	"shoegaze":      {"Alternative Rock"},
	"emo":           {"Alternative Rock"},
	"krautrock":     {"Progressive Rock"},
	"new wave":      {"Rock"},
	"trip hop":      {"Electronic"},
	"downtempo":     {"Electronic"},
	"ambient":       {"Electronic"},
	"house":         {"Electronic"},
	"techno":        {"Electronic"},
	"trance":        {"Electronic"},
	"drum and bass": {"Electronic"},
	"dubstep":       {"Electronic"},
	"idm":           {"Electronic"},
	"ska":           {"Reggae"},
	"dub":           {"Reggae"},
	"dancehall":     {"Reggae"},
	"afrobeat":      {"World"},
	"rap":           {"Hip-Hop"},
	"grime":         {"Hip-Hop"},
	// Discogs writes the style as "Singer/Songwriter", and `/` is one of
	// Split's separators — so it arrives as two orphan tokens, never as the
	// canonical "singer songwriter" MusicBrainz sends.
	"singer":     {"Singer-Songwriter"},
	"songwriter": {"Singer-Songwriter"},
}

// norm is the lookup key: lowercase, hyphens as spaces, collapsed whitespace,
// so "Alternative-Rock", "alternative rock" and "Alternative Rock" all agree.
func norm(s string) string {
	return strings.Join(strings.Fields(strings.ReplaceAll(strings.ToLower(s), "-", " ")), " ")
}

var canon = func() map[string]string {
	m := make(map[string]string, len(Tree))
	for g := range Tree {
		m[norm(g)] = g
	}
	return m
}()

// resolve maps one normalized token to canonical name(s), or nil if unknown.
func resolve(key string) []string {
	if names, ok := aliases[key]; ok {
		return names
	}
	if c, ok := canon[key]; ok {
		return []string{c}
	}
	return nil
}

var cache sync.Map // raw tag string -> []string (immutable once stored)

// Split turns a raw tag into canonical genres: split on ; , / then
// alias/canonicalize each token. Unknown tokens map to the genre of their
// rightmost recognizable word ("Louisiana Blues" -> Blues); tokens with no
// recognizable word are dropped so they can't pollute the tree.
// Never returns nil.
func Split(raw string) []string {
	if raw == "" {
		return []string{}
	}
	if v, ok := cache.Load(raw); ok {
		return v.([]string)
	}
	out := []string{}
	for _, part := range strings.FieldsFunc(raw, func(r rune) bool { return r == ';' || r == ',' || r == '/' }) {
		token := norm(part)
		if token == "" {
			continue
		}
		names := resolve(token)
		if names == nil {
			// ponytail: head-word inference folds unknown sub-genres into
			// their broad genre; add a Tree entry when one deserves its own node.
			words := strings.Fields(token)
			for i := len(words) - 1; i >= 0 && names == nil; i-- {
				names = resolve(words[i])
			}
		}
		for _, n := range names {
			dup := false
			for _, o := range out {
				if o == n {
					dup = true
					break
				}
			}
			if !dup {
				out = append(out, n)
			}
		}
	}
	cache.Store(raw, out)
	return out
}

// SplitAll is Split over several raw strings, deduped and order-preserving.
// The enrichment sources hand us lists — MusicBrainz genre tags, Discogs
// genres and styles — rather than one semicolon-mashed tag string.
func SplitAll(raws []string) []string {
	out := []string{}
	for _, raw := range raws {
		for _, g := range Split(raw) {
			if !slices.Contains(out, g) {
				out = append(out, g)
			}
		}
	}
	return out
}

// Matches reports whether the wanted canonical genre matches a raw tag:
// any of the tag's canonical genres is `wanted` or a descendant of it
// (Blues matches Blues Rock). `wanted` is alias-canonicalized too, so old
// saved rules like "Klassiek" or "Soul" keep working.
func Matches(raw, wanted string) bool { return MatchesList(Split(raw), wanted) }

// MatchesList is Matches against an ALREADY-canonical list, for callers that
// hold the derived `genres` array. It exists because that array is no longer
// derivable from the raw tag alone — enrichment merges MusicBrainz genre tags
// and Discogs styles into it — so re-Splitting the raw string would silently
// evaluate against less than the truth. Matches(raw,w) == MatchesList(Split(raw),w).
func MatchesList(canon []string, wanted string) bool {
	wl := norm(wanted)
	var wants []string
	if names := resolve(wl); names != nil {
		for _, n := range names {
			wants = append(wants, norm(n))
		}
	} else {
		wants = []string{wl}
	}
	for _, g := range canon {
		for x := g; x != ""; {
			xl := norm(x)
			for _, w := range wants {
				if w == xl {
					return true
				}
			}
			p, ok := Tree[x]
			if !ok || p == nil {
				break
			}
			x = *p
		}
	}
	return false
}
