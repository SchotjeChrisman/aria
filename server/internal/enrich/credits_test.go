package enrich

import (
	"slices"
	"testing"
)

// credit builds one artist-credit entry; id is what the release's artist-rels
// are keyed by. The optional typ is MB's artist type ("Orchestra", "Person", …),
// which only arrives when the lookup asked for artist-credits.
func credit(id, name, join string, typ ...string) mbArtistCredit {
	c := mbArtistCredit{Name: name, JoinPhrase: join}
	c.Artist.ID, c.Artist.Name = id, name
	if len(typ) > 0 {
		c.Artist.Type = typ[0]
	}
	return c
}

func rel(id, relType string, attrs ...string) mbRelation {
	r := mbRelation{Type: relType, Attributes: attrs}
	r.Artist = &struct {
		ID   string `json:"id"`
		Name string `json:"name"`
	}{ID: id}
	return r
}

func names(cs []mbArtistCredit) []string {
	var out []string
	for _, c := range cs {
		out = append(out, creditName(c))
	}
	return out
}

// The real release ec17a59b-6ca3-4817-9ca9-67b137550819 ("Barber, Bruch").
func barberBruch() []mbArtistCredit {
	return []mbArtistCredit{
		credit("mb-barber", "Barber", ", "),
		credit("mb-bruch", "Bruch", "; "), // MB's structural composer/performer split
		credit("mb-yoo", "Esther Yoo", ", ", "Person"),
		credit("mb-petrenko", "Василий Петренко", ", ", "Person"),
		credit("mb-rpo", "Royal Philharmonic Orchestra", "", "Orchestra"),
	}
}

// The "; " joinphrase is the only structural signal for "composers end here".
func TestSplitArtistCredit(t *testing.T) {
	cases := []struct {
		name                          string
		in                            []mbArtistCredit
		wantComposers, wantPerformers []string
	}{
		{
			name: "barber bruch", in: barberBruch(),
			wantComposers:  []string{"Barber", "Bruch"},
			wantPerformers: []string{"Esther Yoo", "Василий Петренко", "Royal Philharmonic Orchestra"},
		},
		{
			name: "ordinary pop credit", in: []mbArtistCredit{credit("a", "Dire Straits", " feat. "), credit("b", "Someone", "")},
			wantComposers: nil, wantPerformers: []string{"Dire Straits", "Someone"},
		},
		{
			name: "split on the first credit", in: []mbArtistCredit{credit("a", "Bach", "; "), credit("b", "Glenn Gould", "")},
			wantComposers: []string{"Bach"}, wantPerformers: []string{"Glenn Gould"},
		},
		{
			name: "split on the last credit", in: []mbArtistCredit{credit("a", "Bach", ", "), credit("b", "Handel", "; ")},
			wantComposers: []string{"Bach", "Handel"}, wantPerformers: nil,
		},
		{
			name:          "two split points, the first wins",
			in:            []mbArtistCredit{credit("a", "Bach", "; "), credit("b", "Gould", "; "), credit("c", "CBC Orchestra", "")},
			wantComposers: []string{"Bach"}, wantPerformers: []string{"Gould", "CBC Orchestra"},
		},
		{name: "empty", in: nil, wantComposers: nil, wantPerformers: nil},
		{
			name: "bare semicolon still splits", in: []mbArtistCredit{credit("a", "Bach", ";"), credit("b", "Gould", "")},
			wantComposers: []string{"Bach"}, wantPerformers: []string{"Gould"},
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			comps, perfs := splitArtistCredit(c.in)
			if got := names(comps); !slices.Equal(got, c.wantComposers) {
				t.Errorf("composers = %v, want %v", got, c.wantComposers)
			}
			if got := names(perfs); !slices.Equal(got, c.wantPerformers) {
				t.Errorf("performers = %v, want %v", got, c.wantPerformers)
			}
		})
	}
}

// One classifier for both the recording-level and release-level relations —
// creditsByRecording and displayArtist must agree.
func TestRoleOf(t *testing.T) {
	cases := []struct{ relType, want string }{
		{"conductor", "conductor"},
		{"instrument", "soloist"},
		{"vocal", "soloist"},
		{"performer", "performer"},
		{"performing orchestra", "orchestra"},
		{"orchestra", "orchestra"},
		{"chorus master", "choir"},
		{"choir", "choir"},
		{"engineer", ""},
	}
	for _, c := range cases {
		if got := roleOf(mbRelation{Type: c.relType}); got != c.want {
			t.Errorf("roleOf(%q) = %q, want %q", c.relType, got, c.want)
		}
	}
}

// The acceptance case: "Barber, Bruch" must display as Esther Yoo, with Barber
// and Bruch as composers — and never the naive joined credit string.
// The header list is the Qobuz/Deezer order: lead, then the ensembles, then
// everyone else — never the raw credit order, which buries the orchestra behind
// the conductor.
func TestDisplayArtist(t *testing.T) {
	cases := []struct {
		name                          string
		in                            mbRelease
		wantArtist                    string
		wantComposers, wantPerformers []string
	}{
		{
			name: "barber bruch: soloist wins",
			in: mbRelease{ArtistCredit: barberBruch(), Relations: []mbRelation{
				rel("mb-yoo", "instrument", "violin"),
				rel("mb-petrenko", "conductor"),
				rel("mb-rpo", "orchestra"),
			}},
			wantArtist: "Esther Yoo", wantComposers: []string{"Barber", "Bruch"},
			wantPerformers: []string{"Esther Yoo", "Royal Philharmonic Orchestra", "Василий Петренко"},
		},
		{
			name: "no soloist: the conductor wins",
			in: mbRelease{ArtistCredit: []mbArtistCredit{
				credit("mb-bruch", "Bruch", "; "), credit("mb-rpo", "Royal Philharmonic Orchestra", ", ", "Orchestra"), credit("mb-petrenko", "Петренко", "", "Person"),
			}, Relations: []mbRelation{rel("mb-rpo", "orchestra"), rel("mb-petrenko", "conductor")}},
			wantArtist: "Петренко", wantComposers: []string{"Bruch"},
			wantPerformers: []string{"Петренко", "Royal Philharmonic Orchestra"},
		},
		{
			name: "orchestra and choir only: credit order breaks the rank tie",
			in: mbRelease{ArtistCredit: []mbArtistCredit{
				credit("mb-bruch", "Bruch", "; "), credit("mb-rpo", "Royal Philharmonic Orchestra", ", ", "Orchestra"), credit("mb-choir", "RPO Chorus", "", "Choir"),
			}, Relations: []mbRelation{rel("mb-choir", "chorus"), rel("mb-rpo", "orchestra")}},
			wantArtist: "Royal Philharmonic Orchestra", wantComposers: []string{"Bruch"},
			wantPerformers: []string{"Royal Philharmonic Orchestra", "RPO Chorus"},
		},
		{
			name:       "no relations at all: first performer credit",
			in:         mbRelease{ArtistCredit: barberBruch()},
			wantArtist: "Esther Yoo", wantComposers: []string{"Barber", "Bruch"},
			// the real ec17a59b case: MB publishes no release-level performance
			// rels, so this — not the ranked branch above — is what actually runs
			wantPerformers: []string{"Esther Yoo", "Royal Philharmonic Orchestra", "Василий Петренко"},
		},
		{
			name: "ensemble-free classical credit keeps plain credit order",
			in: mbRelease{ArtistCredit: []mbArtistCredit{
				credit("mb-bach", "Bach", "; "), credit("mb-gould", "Glenn Gould", ", ", "Person"),
				credit("mb-mm", "Yehudi Menuhin", "", "Person"),
			}},
			wantArtist: "Glenn Gould", wantComposers: []string{"Bach"},
			wantPerformers: []string{"Glenn Gould", "Yehudi Menuhin"},
		},
		{
			name:       "ordinary release: today's behaviour, unchanged",
			in:         mbRelease{ArtistCredit: []mbArtistCredit{credit("a", "Dire Straits", "")}},
			wantArtist: "Dire Straits", wantComposers: nil, wantPerformers: nil,
		},
		{
			name: "no split: a multi-artist pop credit publishes no header list",
			in: mbRelease{ArtistCredit: []mbArtistCredit{
				credit("a", "Queen", " & ", "Group"), credit("b", "David Bowie", "", "Person"),
			}},
			wantArtist: "Queen", wantComposers: nil, wantPerformers: nil,
		},
		{
			name: "relation for an artist that isn't credited is ignored",
			in: mbRelease{ArtistCredit: barberBruch(), Relations: []mbRelation{
				rel("mb-nobody", "instrument", "kazoo"), rel("mb-petrenko", "conductor"),
			}},
			wantArtist: "Василий Петренко", wantComposers: []string{"Barber", "Bruch"},
			wantPerformers: []string{"Василий Петренко", "Royal Philharmonic Orchestra", "Esther Yoo"},
		},
		{
			name:       "no credits at all",
			in:         mbRelease{Relations: []mbRelation{rel("mb-yoo", "instrument")}},
			wantArtist: "", wantComposers: nil, wantPerformers: nil,
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			artist, composers, performers := displayArtist(&c.in)
			if artist != c.wantArtist {
				t.Errorf("displayArtist = %v, want %v", artist, c.wantArtist)
			}
			if !slices.Equal(composers, c.wantComposers) {
				t.Errorf("composers = %v, want %v", composers, c.wantComposers)
			}
			if !slices.Equal(performers, c.wantPerformers) {
				t.Errorf("performers = %v, want %v", performers, c.wantPerformers)
			}
		})
	}

	// two soloists: the earlier artist-credit position wins, never map
	// iteration order — so the same release always displays the same name
	two := mbRelease{ArtistCredit: []mbArtistCredit{
		credit("mb-bruch", "Bruch", "; "), credit("mb-yoo", "Esther Yoo", ", "), credit("mb-other", "Janine Jansen", ""),
	}, Relations: []mbRelation{rel("mb-other", "instrument", "violin"), rel("mb-yoo", "instrument", "violin")}}
	for i := 0; i < 20; i++ {
		if artist, _, _ := displayArtist(&two); artist != "Esther Yoo" {
			t.Fatalf("two soloists run %d = %v, want %v", i, artist, "Esther Yoo")
		}
	}
}
