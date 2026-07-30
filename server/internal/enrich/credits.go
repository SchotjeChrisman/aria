package enrich

import "strings"

// roleOf classifies an artist relation. Shared by creditsByRecording
// (recording level) and displayArtist (release level) so both classify
// identically; "" is "not a performance role we care about".
func roleOf(r mbRelation) string {
	switch {
	case r.Type == "conductor":
		return "conductor"
	case r.Type == "instrument" || r.Type == "vocal":
		return "soloist"
	case strings.Contains(r.Type, "orchestra"):
		return "orchestra"
	case strings.Contains(r.Type, "chorus") || strings.Contains(r.Type, "choir"):
		return "choir"
	case r.Type == "performer":
		return "performer"
	}
	return ""
}

// roleRank orders the display-artist preference: soloist > conductor >
// orchestra/choir > performer > anyone with no relation at all.
func roleRank(role string) int {
	switch role {
	case "soloist":
		return 0
	case "conductor":
		return 1
	case "orchestra", "choir":
		return 2
	case "performer":
		return 3
	}
	return 4
}

// splitArtistCredit splits at the "; " joinphrase, MusicBrainz's structural
// separator between composers and performers on a classical release. No ";"
// joinphrase means an ordinary release: no composers, everyone is a performer.
func splitArtistCredit(ac []mbArtistCredit) (composers, performers []mbArtistCredit) {
	for i, c := range ac {
		if strings.TrimSpace(c.JoinPhrase) == ";" {
			return ac[:i+1], ac[i+1:]
		}
	}
	return nil, ac
}

func creditName(c mbArtistCredit) string {
	if c.Name != "" {
		return c.Name
	}
	return c.Artist.Name
}

// isEnsemble is the artist.Type test that hoists the groups above the people
// in an album-header credit list. MB's type vocabulary here is small and
// closed; anything else ("Person", "Character", "") is a person.
func isEnsemble(t string) bool {
	switch t {
	case "Orchestra", "Choir", "Chorus", "Group":
		return true
	}
	return false
}

// displayArtist picks the credited performer to show, by role from the
// release's own artist-rels: soloist > conductor > orchestra/choir >
// performer. Names come back in their original script; Latinisation is a
// separate, display-time step. Ties break on artist-credit order, never on map
// iteration order.
//
// performers is the ordered album-header list, and is only returned for a real
// composer/performer split — on an ordinary release the file's own tags are the
// better header than MB's credit order. The order is
// [lead] + [ensembles among the rest] + [remaining people], which is what Qobuz
// and Deezer both display: for ec17a59b that is Esther Yoo, Royal Philharmonic
// Orchestra, Василий Петренко — the orchestra ahead of the conductor.
//
// Empirical note on the roleRank pass below: across 23 probed releases (13 pop,
// 10 classical, Karajan and the Berliner Philharmoniker included) ZERO carried a
// performance-role relation AT RELEASE LEVEL — MusicBrainz keeps conductor,
// soloist and orchestra rels on the RECORDINGS. So the ranking is correct but
// effectively never fires, and in practice the lead is the first performer
// credit and the ordering comes from artist-credit order plus artist.Type. It
// stays because a release that does carry the rels must still be ordered by
// them, and because creditsByRecording shares the same classifier.
func displayArtist(rel *mbRelease) (artist string, composers []string, performers []string) {
	credited, perf := splitArtistCredit(rel.ArtistCredit)
	for _, c := range credited {
		composers = append(composers, creditName(c))
	}
	rank := map[string]int{}
	for _, r := range rel.Relations {
		if r.Artist == nil || r.Artist.ID == "" {
			continue
		}
		k := roleRank(roleOf(r))
		if old, ok := rank[r.Artist.ID]; k < 4 && (!ok || k < old) {
			rank[r.Artist.ID] = k
		}
	}
	best, bestRank := -1, 5
	for i, c := range perf {
		k, ok := rank[c.Artist.ID]
		if !ok {
			k = 4
		}
		if k < bestRank {
			best, bestRank = i, k
		}
	}
	if best < 0 {
		if len(rel.ArtistCredit) > 0 { // no performers at all: today's behaviour
			return creditName(rel.ArtistCredit[0]), composers, nil
		}
		return "", composers, nil
	}
	artist = creditName(perf[best])
	if len(composers) == 0 {
		return artist, nil, nil // ordinary release: no header list to publish
	}
	performers = []string{artist}
	var people []string // non-ensembles, held back so the groups come first
	for i, c := range perf {
		if i == best {
			continue
		}
		if isEnsemble(c.Artist.Type) {
			performers = append(performers, creditName(c))
		} else {
			people = append(people, creditName(c))
		}
	}
	return artist, composers, append(performers, people...)
}
