package api

import "testing"

// The Deezer supplement is only ever reached for a list enrich.contributorsAgree
// already accepted, and that check keys on norm(). Every pair below is one
// contributorsAgree treats as the SAME name; if normName splits any of them the
// supplement appends a duplicate and the album header shows one ensemble twice.
func TestMergeAlbumArtistsDedupesTheWayTheAgreementCheckDid(t *testing.T) {
	cases := []struct {
		name       string
		performers []string
		dz         []string
		want       []string
	}{{
		name:       "period in an abbreviation",
		performers: []string{"Academy of St Martin in the Fields"},
		dz:         []string{"Academy of St. Martin in the Fields"},
		want:       []string{"Academy of St Martin in the Fields"},
	}, {
		name:       "curly versus straight apostrophe",
		performers: []string{"Marc Minkowski", "Orchestre de l’Opéra national de Paris"},
		dz:         []string{"Marc Minkowski", "Orchestre de l'Opéra national de Paris"},
		want:       []string{"Marc Minkowski", "Orchestre de l’Opéra national de Paris"},
	}, {
		name:       "leading article",
		performers: []string{"Esther Yoo", "The Royal Philharmonic Orchestra"},
		dz:         []string{"Esther Yoo", "Royal Philharmonic Orchestra", "Vasily Petrenko"},
		want:       []string{"Esther Yoo", "The Royal Philharmonic Orchestra", "Vasily Petrenko"},
	}, {
		name:       "a genuinely new name is still appended",
		performers: []string{"Arturo Toscanini"},
		dz:         []string{"Arturo Toscanini", "NBC Symphony Orchestra"},
		want:       []string{"Arturo Toscanini", "NBC Symphony Orchestra"},
	}}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := mergeAlbumArtists(tc.performers, nil, tc.dz, nil)
			if len(got) != len(tc.want) {
				t.Fatalf("got %q, want %q", got, tc.want)
			}
			for i := range got {
				if got[i] != tc.want[i] {
					t.Errorf("[%d] = %q, want %q (full: %q)", i, got[i], tc.want[i], got)
				}
			}
		})
	}
}

// normName must not borrow normTitle's edition stripping: "(Live)" is noise in a
// release title and part of the name in an ensemble like "Live Orchestra".
func TestNormNameKeepsEditionWords(t *testing.T) {
	if normName("Berlin Live Orchestra") == normName("Berlin Orchestra") {
		t.Error("normName stripped an edition-looking word out of an ensemble name")
	}
}
