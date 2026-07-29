package enrich

import (
	"fmt"
	"math"
	"testing"
)

func TestNormAndStrDist(t *testing.T) {
	cases := []struct {
		a, b string
		want float64 // -1 = "just assert > 0"
	}{
		{"", "", 0},
		{"Abbey Road", "", 1},
		{"", "Abbey Road", 1},
		{"Abbey Road", "Abbey Road", 0},
		{"Abbey Road", "abbey road", 0},
		{"The Beatles", "Beatles", 0},          // leading article stripped
		{"Sgt. Pepper's!", "Sgt Peppers", 0},   /* punctuation is noise */
		{"Kind of Blue", "Kind  of   Blue", 0}, // whitespace collapsed
		{"Down the Road Wherever Tour",
			"Down The Road Wherever Tour 2019 - Madrid (2019-05-06)", -1},
		{"Abbey Road", "Let It Be", -1},
	}
	for _, c := range cases {
		got := strDist(c.a, c.b)
		if got < 0 || got > 1 {
			t.Fatalf("strDist(%q,%q) = %v, out of [0,1]", c.a, c.b, got)
		}
		if c.want >= 0 && got != c.want {
			t.Errorf("strDist(%q,%q) = %v, want %v", c.a, c.b, got, c.want)
		}
		if c.want < 0 && got == 0 {
			t.Errorf("strDist(%q,%q) = 0, want a real difference", c.a, c.b)
		}
	}
}

// The duration ramp is what separates two nights of one tour, so its shape is
// load-bearing: free to 10 s, linear, saturated at 30 s.
func TestLengthPenalty(t *testing.T) {
	cases := []struct {
		deltaMS int
		want    float64
	}{
		{0, 0}, {9_000, 0}, {10_000, 0},
		{20_000, 0.5}, {30_000, 1}, {60_000, 1},
		{-20_000, 0.5}, // symmetric
	}
	for _, c := range cases {
		if got := lengthPenalty(180_000+c.deltaMS, 180_000); math.Abs(got-c.want) > 1e-9 {
			t.Errorf("lengthPenalty(delta=%d) = %v, want %v", c.deltaMS, got, c.want)
		}
	}
}

func TestDistAccumulator(t *testing.T) {
	var d dist
	if d.value() != 1 {
		t.Errorf("empty dist = %v, want 1 (no evidence is the worst answer, never the best)", d.value())
	}
	d.add(3, 0)
	d.add(1, 1)
	if got := d.value(); math.Abs(got-0.25) > 1e-9 {
		t.Errorf("value = %v, want 0.25", got)
	}
}

// ---- fixtures ---------------------------------------------------------------

// album builds a local album of n tracks, each `base+i*30` seconds long.
func album(title, artist string, n int, discs int) localAlbum {
	la := localAlbum{Album: title, AlbumArtist: artist, Year: 2019, Discs: discs}
	per := n / max(discs, 1)
	for i := 0; i < n; i++ {
		la.Tracks = append(la.Tracks, localTrack{
			Title:    fmt.Sprintf("Song %02d", i+1),
			Disc:     i/max(per, 1) + 1,
			Num:      i%max(per, 1) + 1,
			LengthMS: 180_000 + i*30_000,
		})
	}
	return la
}

// release mirrors album on the MusicBrainz side, with a per-track ms offset
// applied by jitter(i).
func release(mbid, rg, title, artist string, n, discs int, jitter func(int) int) candidate {
	c := candidate{Mbid: mbid, RGMbid: rg, Title: title, Artist: artist,
		Date: "2019-05-06", Tracks: n, Media: discs, Source: "search"}
	per := n / max(discs, 1)
	for i := 0; i < n; i++ {
		c.mb = append(c.mb, mbTrack{
			Medium:   i/max(per, 1) + 1,
			Pos:      i%max(per, 1) + 1,
			Title:    fmt.Sprintf("Song %02d", i+1),
			LengthMS: 180_000 + i*30_000 + jitter(i),
		})
	}
	return c
}

func noJitter(int) int { return 0 }

// tourJitter is night i's per-track drift from the local files: 5-45 s, which
// is what two live performances of one song actually differ by once applause,
// banter and jams are in. Deterministic — no RNG, because a flaky calibration
// test is worse than no test.
func tourJitter(i int) func(int) int {
	return func(k int) int { return ((k*13+i*7)%41 + 5) * 1000 }
}

// ---- scoring ----------------------------------------------------------------

func TestScoreExactMatchIsNearZero(t *testing.T) {
	la := album("Abbey Road", "The Beatles", 12, 1)
	c := release("mb-1", "rg-1", "Abbey Road", "The Beatles", 12, 1, func(i int) int { return 2000 })
	scoreCandidate(la, &c)
	if c.Distance > 0.02 {
		t.Errorf("distance = %v, want < 0.02 for an exact match with 2 s drift", c.Distance)
	}
}

// A folder tagged 1..24 straight through a 2-disc release must score the same
// as one tagged per-medium. This is the entire reason two pairings are scored
// and the lower taken.
func TestContinuousNumberingScoresLikePerMedium(t *testing.T) {
	perMedium := album("Big Box", "Someone", 24, 2)

	continuous := perMedium
	continuous.Tracks = append([]localTrack(nil), perMedium.Tracks...)
	for i := range continuous.Tracks {
		continuous.Tracks[i].Disc = 1 // one folder, no disc tags
		continuous.Tracks[i].Num = i + 1
	}

	a := release("mb-1", "rg-1", "Big Box", "Someone", 24, 2, noJitter)
	b := a
	b.mb = append([]mbTrack(nil), a.mb...)
	scoreCandidate(perMedium, &a)
	scoreCandidate(continuous, &b)

	if a.Distance > 0.02 {
		t.Fatalf("per-medium numbering scored %v, want < 0.02", a.Distance)
	}
	if b.Distance > 0.02 {
		t.Errorf("continuous 1..24 numbering scored %v, want < 0.02 (sequential pairing must rescue it)", b.Distance)
	}
}

// A folder missing one track in the middle must still pair correctly, which
// only the keyed pairing can do.
func TestMissingTrackPairsByNumber(t *testing.T) {
	la := album("Abbey Road", "The Beatles", 12, 1)
	la.Tracks = append(la.Tracks[:2], la.Tracks[3:]...) // lose track 3
	c := release("mb-1", "rg-1", "Abbey Road", "The Beatles", 12, 1, noJitter)
	scoreCandidate(la, &c)
	// One missing track out of twelve costs the missing_tracks component only.
	if c.Distance > 0.02 {
		t.Errorf("distance = %v, want < 0.02 — a gap must not de-align every later track", c.Distance)
	}
}

// ---- the gates --------------------------------------------------------------

func TestDecideGates(t *testing.T) {
	cands := func(ds ...float64) []candidate {
		var out []candidate
		for i, d := range ds {
			out = append(out, candidate{Mbid: fmt.Sprint("mb-", i), RGMbid: fmt.Sprint("rg-", i), Distance: d})
		}
		return out
	}
	cases := []struct {
		name       string
		cs         []candidate
		wantState  string
		wantReason string
	}{
		{"nothing at all", nil, "local", "no-candidates"},
		{"clean win", cands(0.01, 0.60), "matched", "ok"},
		{"good but crowded", cands(0.02, 0.10), "review", "low-separation"},
		{"nothing plausible", cands(0.80, 0.90), "local", "no-plausible-candidate"},
		{"weak and alone", cands(0.20), "review", "weak-match"},
		{"weak, two rivals only", cands(0.20, 0.22), "review", "weak-match"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, _, _, state, reason := decide(tc.cs, 0.10, 0.25)
			if state != tc.wantState || reason != tc.wantReason {
				t.Errorf("decide = %s/%s, want %s/%s", state, reason, tc.wantState, tc.wantReason)
			}
		})
	}
}

// The veto must NOT fire on a deluxe edition: same release group, so the
// identity everything downstream consumes is not ambiguous at all — only the
// pressing is, and taking the better-scoring pressing is correct.
func TestDeluxeTwinDoesNotTripTheVeto(t *testing.T) {
	la := album("Abbey Road", "The Beatles", 12, 1)
	std := release("mb-std", "rg-abbey", "Abbey Road", "The Beatles", 12, 1, noJitter)
	deluxe := release("mb-deluxe", "rg-abbey", "Abbey Road", "The Beatles", 13, 1, noJitter)
	scoreCandidate(la, &std)
	scoreCandidate(la, &deluxe)

	winner, d1, sep, state, reason := decide([]candidate{deluxe, std}, 0.10, 0.25)
	if state != "matched" || reason != "ok" {
		t.Fatalf("state = %s/%s (d1=%v sep=%v), want matched/ok — a same-group twin is not an ambiguity",
			state, reason, d1, sep)
	}
	if winner.Mbid != "mb-std" {
		t.Errorf("winner = %s, want mb-std (the edition with the right track count)", winner.Mbid)
	}
}

// A genuine ambiguity across TWO release groups: the winner is good enough on
// its own but the runner-up is right behind it. Gate A passes, Gate B vetoes.
// This is the case a distance threshold alone cannot see.
func TestSeparationVetoFiresOnDistinctGroups(t *testing.T) {
	winner, d1, sep, state, reason := decide([]candidate{
		{Mbid: "mb-a", RGMbid: "rg-a", Distance: 0.03},
		{Mbid: "mb-b", RGMbid: "rg-b", Distance: 0.06},
	}, 0.10, 0.25)
	if d1 > 0.10 {
		t.Fatalf("d1 = %v; the point of this case is that gate A PASSES", d1)
	}
	if state != "review" || reason != "low-separation" {
		t.Errorf("state = %s/%s (winner %s, sep %v), want review/low-separation",
			state, reason, winner.Mbid, sep)
	}
}

// The spec's own traced failure. MusicBrainz holds thirteen releases titled
// "Down The Road Wherever Tour 2019 - <City> (<date>)" and no Amsterdam show.
// Every night has the same setlist and the same track count; only the
// performance durations differ, independently, by seconds to tens of seconds.
//
// The right answer is "I don't know", and specifically the `local` conclusion:
// no fingerprint match, many tightly clustered text candidates from distinct
// release groups, durations fitting none of them. Anything that confidently
// returns Madrid here is the bug this whole phase exists to prevent.
func TestThirteenTourNightsResolveToIDontKnow(t *testing.T) {
	la := album("Down the Road Wherever Tour", "Dire Straits", 22, 1)

	cities := []string{"Madrid", "Barcelona", "Lisbon", "Porto", "Bordeaux", "Paris", "Lille",
		"Brussels", "Cologne", "Hamburg", "Berlin", "Prague", "Vienna"}
	var cands []candidate
	for i, city := range cities {
		// Deterministic pseudo-jitter: every night drifts from the local files
		// by a different amount per track, in the tens of seconds. No RNG — a
		// flaky calibration test would be worse than no test.
		c := release(fmt.Sprint("mb-", i), fmt.Sprint("rg-", i),
			"Down The Road Wherever Tour 2019 - "+city+" (2019-05-06)",
			"Dire Straits", 22, 1, tourJitter(i))
		scoreCandidate(la, &c)
		cands = append(cands, c)
	}

	_, d1, _, state, reason := decide(cands, 0.10, 0.25)

	// The whole cluster must be within noise of each other — that is the
	// premise, and if it stops being true this test stops testing anything.
	lo, hi := math.Inf(1), math.Inf(-1)
	for _, c := range cands {
		lo, hi = math.Min(lo, c.Distance), math.Max(hi, c.Distance)
	}
	if hi-lo > 0.05 {
		t.Fatalf("cluster spread %v (%.4f..%.4f); the thirteen nights are supposed to be indistinguishable", hi-lo, lo, hi)
	}
	if state == "matched" {
		t.Fatalf("state = matched (d1=%v) — this is the Amsterdam-matched-to-Madrid bug", d1)
	}
	if state != "local" || reason != "indistinguishable-siblings" {
		t.Errorf("state = %s/%s (d1=%v, spread %v), want local/indistinguishable-siblings",
			state, reason, d1, hi-lo)
	}
}

// Same cluster, but with the thresholds relaxed to where D1 would sail through
// gate A. The veto alone must still stop it — proof that the two gates really
// are independent and neither can compensate for the other.
func TestTourNightsStillVetoedWhenGateAIsGenerous(t *testing.T) {
	la := album("Down the Road Wherever Tour", "Dire Straits", 22, 1)
	var cands []candidate
	for i := 0; i < 13; i++ {
		c := release(fmt.Sprint("mb-", i), fmt.Sprint("rg-", i),
			"Down the Road Wherever Tour", "Dire Straits", 22, 1, tourJitter(i))
		scoreCandidate(la, &c)
		cands = append(cands, c)
	}
	_, d1, sep, state, _ := decide(cands, 0.90 /* absurdly generous */, 0.25)
	if state == "matched" {
		t.Fatalf("state = matched with maxDistance=0.9 (d1=%v, sep=%v); the veto must not be buyable by a good D1", d1, sep)
	}
}
