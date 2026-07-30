package enrich

import "testing"

// The ALBUMARTIST tag names ONE credited artist; candidate.Artist is all of them
// joined. Comparing only against the joined string penalises every real tagging
// convention for not being the others — measured at 0.85 on a CORRECT classical
// match, which cost it enough separation to fall out of `matched` into review.
func TestArtistDistTakesTheBestCreditedName(t *testing.T) {
	// MusicBrainz files classical as "composers; performers", and the credit name
	// is routinely the short form of a longer artist name.
	beethoven := candidate{
		Artist:      "Beethoven; Arturo Toscanini",
		ArtistNames: []string{"Ludwig van Beethoven", "Beethoven", "Arturo Toscanini"},
	}
	barber := candidate{
		Artist: "Barber, Bruch; Esther Yoo, Royal Philharmonic Orchestra",
		ArtistNames: []string{"Samuel Barber", "Barber", "Max Bruch", "Bruch",
			"Esther Yoo", "Royal Philharmonic Orchestra"},
	}
	cases := []struct {
		name string
		tag  string
		c    candidate
		want float64
	}{
		{"composer tag, short credit name", "Ludwig van Beethoven", beethoven, 0},
		{"performer tag on the same release", "Arturo Toscanini", beethoven, 0},
		{"the whole joined credit", "Beethoven; Arturo Toscanini", beethoven, 0},
		{"composer tag on a multi-composer release", "Samuel Barber", barber, 0},
		{"the soloist", "Esther Yoo", barber, 0},
		{"the orchestra", "Royal Philharmonic Orchestra", barber, 0},
		// an ordinary release is a single credit: nothing changes for it
		{"single artist", "AC/DC", candidate{Artist: "AC/DC", ArtistNames: []string{"AC/DC"}}, 0},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := artistDist(tc.tag, &tc.c); got != tc.want {
				t.Errorf("artistDist(%q) = %v, want %v", tc.tag, got, tc.want)
			}
		})
	}
}

// The point of the signal is still to DISAGREE when the artist is wrong.
// Without this, "take the best of many names" would drift into "always 0".
func TestArtistDistStillRejectsAWrongArtist(t *testing.T) {
	c := candidate{
		Artist:      "Beethoven; Arturo Toscanini",
		ArtistNames: []string{"Ludwig van Beethoven", "Beethoven", "Arturo Toscanini"},
	}
	if got := artistDist("Pink Floyd", &c); got < 0.5 {
		t.Errorf("a wrong artist scored %v, want a real penalty", got)
	}
}

// Candidates persisted before this field existed unmarshal with no ArtistNames;
// they must still score exactly as they did, off the joined string alone.
func TestArtistDistFallsBackToTheJoinedCredit(t *testing.T) {
	c := candidate{Artist: "Portishead"}
	if got := artistDist("Portishead", &c); got != 0 {
		t.Errorf("got %v, want 0", got)
	}
	if got := artistDist("Massive Attack", &c); got == 0 {
		t.Error("a wrong artist with no ArtistNames scored 0")
	}
}
