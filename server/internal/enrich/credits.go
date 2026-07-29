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

// displayArtist picks the credited performer to show, by role from the
// release's own artist-rels: soloist > conductor > orchestra/choir >
// performer. Names come back in their original script; Latinisation is a
// separate, display-time step. Ties break on artist-credit order, never on map
// iteration order.
func displayArtist(rel *mbRelease) (artist string, composers []string) {
	credited, performers := splitArtistCredit(rel.ArtistCredit)
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
	for i, c := range performers {
		k, ok := rank[c.Artist.ID]
		if !ok {
			k = 4
		}
		if k < bestRank {
			best, bestRank = i, k
		}
	}
	if best >= 0 {
		return creditName(performers[best]), composers
	}
	if len(rel.ArtistCredit) > 0 { // no performers at all: today's behaviour
		return creditName(rel.ArtistCredit[0]), composers
	}
	return "", composers
}
