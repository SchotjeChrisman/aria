// Package genres is the canonical genre taxonomy (port of genres.js): raw file
// tags (combined, translated, misspelled) are decomposed into clean canonical
// genres arranged in a 2-level hierarchy, Roon-style. The client gets the tree
// via /api/genres and per-track canonical `genres` arrays via /api/tracks.
package genres

import (
	"strings"
	"sync"
)

func of(s string) *string { return &s }

// Tree maps canonical genre -> parent (nil = top-level).
var Tree = map[string]*string{
	"Blues": nil, "Blues Rock": of("Blues"),
	"Rock": nil, "Classic Rock": of("Rock"), "Alternative Rock": of("Rock"), "Soft Rock": of("Rock"),
	"Pop Rock": of("Rock"), "Folk Rock": of("Rock"),
	"Pop":       nil,
	"Classical": nil, "Symphony": of("Classical"), "Orchestral": of("Classical"),
	"Romantic Classical": of("Classical"), "Modern Classical": of("Classical"),
	"Contemporary Classical": of("Classical"), "Cinematic Classical": of("Classical"),
	"Jazz": nil, "Vocal Jazz": of("Jazz"), "Swing": of("Jazz"), "Big Band": of("Jazz"),
	"Soul/R&B": nil, "Blue-Eyed Soul": of("Soul/R&B"), "Disco": of("Soul/R&B"),
	"Country": nil, "Contemporary Country": of("Country"), "Honky Tonk": of("Country"),
	"Folk": nil, "Singer-Songwriter": of("Folk"),
	"Easy Listening": nil,
	"Stage & Screen": nil,
}

// lowercase raw token -> canonical name(s); empty slice drops the token.
var aliases = map[string][]string{
	"klassiek":            {"Classical"}, // Dutch
	"symfonische muziek":  {"Symphony"},  // Dutch
	"international pop":   {"Pop"},
	"ballad":              {"Pop"}, // song form, but sometimes the only tag
	"instrumental":        {},      // format descriptor, not a genre
	"soul":                {"Soul/R&B"},
	"r&b":                 {"Soul/R&B"},
	"folk blues pop rock": {"Folk", "Blues", "Pop", "Rock"}, // space-mashed multi-tag
}

var canon = func() map[string]string {
	m := make(map[string]string, len(Tree))
	for g := range Tree {
		m[strings.ToLower(g)] = g
	}
	return m
}()

var cache sync.Map // raw tag string -> []string (immutable once stored)

// Split turns a raw tag into canonical genres: split on ; , / then
// alias/canonicalize each token. Unknown tokens are kept verbatim as ad-hoc
// top-level genres so nothing vanishes. Never returns nil.
func Split(raw string) []string {
	if raw == "" {
		return []string{}
	}
	if v, ok := cache.Load(raw); ok {
		return v.([]string)
	}
	out := []string{}
	for _, part := range strings.FieldsFunc(raw, func(r rune) bool { return r == ';' || r == ',' || r == '/' }) {
		token := strings.TrimSpace(part)
		if token == "" {
			continue
		}
		names, ok := aliases[strings.ToLower(token)]
		if !ok {
			if c, hit := canon[strings.ToLower(token)]; hit {
				names = []string{c}
			} else {
				names = []string{token}
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

// Matches reports whether the wanted canonical genre matches a raw tag:
// any of the tag's canonical genres is `wanted` or a descendant of it
// (Blues matches Blues Rock). `wanted` is alias-canonicalized too, so old
// saved rules like "Klassiek" or "Soul" keep working.
func Matches(raw, wanted string) bool {
	wl := strings.ToLower(wanted)
	var wants []string
	if names, ok := aliases[wl]; ok {
		for _, n := range names {
			wants = append(wants, strings.ToLower(n))
		}
	} else if c, ok := canon[wl]; ok {
		wants = []string{strings.ToLower(c)}
	} else {
		wants = []string{wl}
	}
	for _, g := range Split(raw) {
		for x := g; x != ""; {
			xl := strings.ToLower(x)
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
