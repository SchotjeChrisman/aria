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
		{"Math Rock;Krautrock", []string{"Rock"}},                           // inferred + dedup ("Krautrock" is one word, no match -> dropped)
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
