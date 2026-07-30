package api

import (
	"strings"
	"testing"
)

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

// Both cases below are REAL blobs from a production library, found by reading
// what the fix actually rendered rather than by imagining failures.
func TestMergeAlbumArtistsRejectsAWrongDeezerAlbum(t *testing.T) {
	// Tchaikovsky's "The Symphonies". Deezer answered with a BRAHMS record by
	// the same orchestra: the institution agrees, the conductor does not, and
	// without a second agreeing performer Gardiner and Brahms both land on a
	// Tchaikovsky album.
	got := mergeAlbumArtists(
		[]string{"Royal Concertgebouw Orchestra", "Bernard Haitink"},
		[]string{"Tchaikovsky"},
		[]string{"Royal Concertgebouw Orchestra", "Johannes Brahms", "John Eliot Gardiner"},
		nil)
	want := []string{"Royal Concertgebouw Orchestra", "Bernard Haitink"}
	if len(got) != len(want) {
		t.Fatalf("got %q, want the MusicBrainz list untouched %q", got, want)
	}
	for i := range got {
		if got[i] != want[i] {
			t.Errorf("[%d] = %q, want %q", i, got[i], want[i])
		}
	}
}

func TestMergeAlbumArtistsDropsAComposerSpelledInFull(t *testing.T) {
	// "Beethoven and Beyond": MB credits the composer as "Beethoven", Deezer
	// sends "Ludwig van Beethoven". Equality misses; the composer then appears
	// among the performers.
	got := mergeAlbumArtists(
		[]string{"María Dueñas", "Wiener Symphoniker", "Manfred Honeck"},
		[]string{"Beethoven"},
		[]string{"María Dueñas", "Ludwig van Beethoven", "Wiener Symphoniker", "Manfred Honeck"},
		nil)
	for _, n := range got {
		if strings.Contains(strings.ToLower(n), "beethoven") {
			t.Errorf("composer %q survived into the performer list: %q", n, got)
		}
	}
	if len(got) != 3 {
		t.Errorf("got %q, want the three performers", got)
	}
}

// The word boundary is what makes the containment check safe.
func TestComposerFilterDoesNotSwallowASimilarName(t *testing.T) {
	got := mergeAlbumArtists(
		[]string{"Gina Bachauer", "London Symphony Orchestra"},
		[]string{"Bach"},
		[]string{"Gina Bachauer", "London Symphony Orchestra", "Antal Doráti"},
		nil)
	if len(got) != 3 || got[2] != "Antal Doráti" {
		t.Fatalf("got %q, want Doráti appended", got)
	}
}
