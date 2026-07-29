package genres

import (
	"reflect"
	"testing"
)

func TestSplit(t *testing.T) {
	tests := []struct {
		raw  string
		want []string
	}{
		{"", []string{}},
		{"Rock", []string{"Rock"}},
		{"rock", []string{"Rock"}},          // canonicalized case
		{"Klassiek", []string{"Classical"}}, // Dutch alias
		{"Instrumental", []string{}},        // dropped token
		{"Soul/R&B", []string{"Soul/R&B"}},  // splits then re-canonicalizes both halves
		{"Rock; Pop, Jazz/Blues", []string{"Rock", "Pop", "Jazz", "Blues"}}, // all separators
		{"folk blues pop rock", []string{"Folk", "Blues", "Pop", "Rock"}},   // space-mashed alias
		{"Texas Blues", []string{"Blues"}},                                  // unknown sub-genre folds into head word
		{"Math Rock;Krautrock", []string{"Rock", "Progressive Rock"}},       // "Math Rock" inferred from head word; "Krautrock" is one word, so only the alias reaches it
		{"Post-Rock;Zydeco", []string{"Rock"}},                              // inference still carries un-aliased compounds, and still drops the unrecognizable
		{"Alternative-Rock", []string{"Alternative Rock"}},                  // hyphen/space normalized
		{"Vocale muziek (wereldlijk en religieus)", []string{"Choral"}},     // Dutch alias
		{"Zydeco", []string{}},                                              // no recognizable word: dropped, never a new top-level
		{"Rock;Rock", []string{"Rock"}},                                     // dedup
		{" ; , ", []string{}},
	}
	for _, tt := range tests {
		if got := Split(tt.raw); !reflect.DeepEqual(got, tt.want) {
			t.Errorf("Split(%q) = %v, want %v", tt.raw, got, tt.want)
		}
	}
}

// The enrichment sources hand over names the closed tree used to drop
// silently. One case per alias added for them, so a future edit to the alias
// map can't quietly un-map a genre the browse now depends on.
func TestEnrichmentAliases(t *testing.T) {
	tests := []struct {
		raw  string
		want []string
	}{
		{"Britpop", []string{"Alternative Rock"}},
		{"Shoegaze", []string{"Alternative Rock"}},
		{"Emo", []string{"Alternative Rock"}},
		{"Krautrock", []string{"Progressive Rock"}},
		{"New Wave", []string{"Rock"}},
		{"Trip Hop", []string{"Electronic"}},
		{"Downtempo", []string{"Electronic"}},
		{"Ambient", []string{"Electronic"}},
		{"House", []string{"Electronic"}},
		{"Techno", []string{"Electronic"}},
		{"Trance", []string{"Electronic"}},
		{"Drum and Bass", []string{"Electronic"}},
		{"Dubstep", []string{"Electronic"}},
		{"IDM", []string{"Electronic"}},
		{"Ska", []string{"Reggae"}},
		{"Dub", []string{"Reggae"}},
		{"Dancehall", []string{"Reggae"}},
		{"Afrobeat", []string{"World"}},
		{"Rap", []string{"Hip-Hop"}},
		{"Grime", []string{"Hip-Hop"}},
		{"Singer/Songwriter", []string{"Singer-Songwriter"}}, // Discogs' spelling: `/` splits it in two
		{"singer-songwriter", []string{"Singer-Songwriter"}}, // MusicBrainz's: already canonical
		// still-inferred, deliberately NOT aliased — a row for these would be
		// a second place to keep in sync
		{"Post-Punk", []string{"Punk"}},
		{"Garage Rock", []string{"Rock"}},
		{"Nu Metal", []string{"Metal"}},
		{"Euro-Disco", []string{"Disco"}},      // a Discogs style
		{"Deep House", []string{"Electronic"}}, // alias reached by head word
	}
	for _, tt := range tests {
		if got := Split(tt.raw); !reflect.DeepEqual(got, tt.want) {
			t.Errorf("Split(%q) = %v, want %v", tt.raw, got, tt.want)
		}
	}
}

func TestSplitAll(t *testing.T) {
	tests := []struct {
		name string
		raws []string
		want []string
	}{
		{"nil", nil, []string{}},
		{"empty strings", []string{"", ""}, []string{}},
		// dedup ACROSS the inputs: MB votes "rock", Discogs says "Rock" too
		{"dedup across sources", []string{"rock", "Rock", "alternative rock"},
			[]string{"Rock", "Alternative Rock"}},
		// order preserved: MB genres first, then Discogs genres, then styles
		{"order preserved", []string{"alternative rock", "Electronic", "Euro-Disco"},
			[]string{"Alternative Rock", "Electronic", "Disco"}},
		{"multi-valued member", []string{"Rock;Pop"}, []string{"Rock", "Pop"}},
		{"unrecognizable dropped", []string{"Zydeco", "Jazz"}, []string{"Jazz"}},
	}
	for _, tt := range tests {
		if got := SplitAll(tt.raws); !reflect.DeepEqual(got, tt.want) {
			t.Errorf("%s: SplitAll(%v) = %v, want %v", tt.name, tt.raws, got, tt.want)
		}
	}
}

// MatchesList must be exactly what Matches always was, or every saved
// smart-playlist rule changes meaning on upgrade.
func TestMatchesListParity(t *testing.T) {
	raws := []string{"", "Blues Rock", "Klassiek", "Symfonische Muziek", "soul",
		"Louisiana Blues", "Rock;Pop", "Zydeco", "Symphonic Metal"}
	wanted := []string{"Blues", "Blues Rock", "Classical", "Rock", "Pop", "soul", "Metal", "Zydeco"}
	for _, raw := range raws {
		for _, w := range wanted {
			if got, want := MatchesList(Split(raw), w), Matches(raw, w); got != want {
				t.Errorf("MatchesList(Split(%q), %q) = %v, Matches = %v", raw, w, got, want)
			}
		}
	}
	// and the point of it existing: a list carrying more than the raw tag did
	if !MatchesList([]string{"Rock", "Alternative Rock"}, "Alternative Rock") {
		t.Error("MatchesList missed a genre only the merged array carries")
	}
	if Matches("Rock", "Alternative Rock") {
		t.Error("Matches on the raw tag should not have found it")
	}
}

func TestMatches(t *testing.T) {
	tests := []struct {
		raw, wanted string
		want        bool
	}{
		{"Blues Rock", "Blues", true},  // parent matches descendant
		{"Blues", "Blues Rock", false}, // not the other way
		{"Klassiek", "Classical", true},
		{"Symfonische Muziek", "Classical", true}, // alias -> child -> parent
		{"Rock", "Pop", false},
		{"soul", "Soul/R&B", true}, // alias on the track side
		{"Blues Rock", "soul", false},
		{"Louisiana Blues", "Blues", true}, // inferred sub-genre matches its parent
		{"Symphonic Metal", "Metal", true},
		{"", "Rock", false},
	}
	for _, tt := range tests {
		if got := Matches(tt.raw, tt.wanted); got != tt.want {
			t.Errorf("Matches(%q, %q) = %v, want %v", tt.raw, tt.wanted, got, tt.want)
		}
	}
}
