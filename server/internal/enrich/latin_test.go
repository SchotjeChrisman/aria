package enrich

import "testing"

// isLatin decides whether a name needs resolving at all: letters only, so
// digits and punctuation never make a Latin name look foreign.
func TestIsLatin(t *testing.T) {
	cases := []struct {
		in   string
		want bool
	}{
		{"Mark Knopfler", true},
		{"Sigur Rós", true},
		{"Василий Петренко", false},
		{"坂本龍一", false},
		{"AC/DC", true},
		{"2Pac", true},
		{"!!!", true}, // no letters at all
		{"", true},
		{"Мельдоний 2", false},
	}
	for _, c := range cases {
		if got := isLatin(c.in); got != c.want {
			t.Errorf("isLatin(%q) = %v, want %v", c.in, got, c.want)
		}
	}
}

// De-inversion has to be type-aware: "Family, Given" and "Name, The" are
// different conventions that happen to share a comma.
func TestDeInvert(t *testing.T) {
	cases := []struct {
		sortName, artistType, want string
	}{
		{"Petrenko, Vasily", "Person", "Vasily Petrenko"},
		{"Vaughan Williams, Ralph", "Person", "Ralph Vaughan Williams"},
		{"Beatles, The", "Group", "The Beatles"},
		{"Rolling Stones, The", "Group", "The Rolling Stones"},
		// a blind de-inversion yields "Wind & Fire Earth" — the whole reason
		// the rule is type-aware
		{"Earth, Wind & Fire", "Group", "Earth, Wind & Fire"},
		{"Royal Philharmonic Orchestra", "Orchestra", "Royal Philharmonic Orchestra"},
		{"Sigur Rós", "Group", "Sigur Rós"},
		{"Smith, John, Jr.", "Person", "Smith, John, Jr."}, // more than one ", "
		{"Los Lobos", "Group", "Los Lobos"},
		{"Lobos, Los", "Group", "Los Lobos"},
		{"Bach, Johann Sebastian", "", "Johann Sebastian Bach"}, // unknown type reads as a person
	}
	for _, c := range cases {
		if got := deInvert(c.sortName, c.artistType); got != c.want {
			t.Errorf("deInvert(%q, %q) = %q, want %q", c.sortName, c.artistType, got, c.want)
		}
	}
}

// The acceptance case: MB artist 7de3202f-0e33-4485-a27c-ec1302df73aa must
// read "Vasily Petrenko" through every rung of the chain independently.
func TestLatinName(t *testing.T) {
	petrenkoAlias := mbAlias{Name: "Vasily Petrenko", SortName: "Petrenko, Vasily", Locale: "en", Type: "Artist name", Primary: true}
	cases := []struct {
		name        string
		in          mbArtist
		want, want2 string
	}{
		{
			name: "petrenko full data",
			in: mbArtist{Name: "Василий Петренко", SortName: "Petrenko, Vasily", Type: "Person",
				Aliases: []mbAlias{petrenkoAlias}},
			want: "Vasily Petrenko", want2: "alias-en",
		},
		{
			name: "petrenko without the alias",
			in:   mbArtist{Name: "Василий Петренко", SortName: "Petrenko, Vasily", Type: "Person"},
			want: "Vasily Petrenko", want2: "sortname",
		},
		{
			name: "petrenko with neither alias nor sort-name",
			in:   mbArtist{Name: "Василий Петренко", Type: "Person"},
			want: "Vasiliy Petrenko", want2: "translit", // approximate, and it says so
		},
		{
			// the empty result is what terminates the backfill sentinel
			name: "already latin",
			in:   mbArtist{Name: "Mark Knopfler", SortName: "Knopfler, Mark", Type: "Person"},
			want: "", want2: "same",
		},
		{
			name: "non-latin alias falls through to sort-name",
			in: mbArtist{Name: "Василий Петренко", SortName: "Petrenko, Vasily", Type: "Person",
				Aliases: []mbAlias{{Name: "Вася Петренко", Locale: "ru", Type: "Artist name"}}},
			want: "Vasily Petrenko", want2: "sortname",
		},
		{
			// rung 1, with a decoy that must not be reached first
			name: "en primary alias beats a non-primary search-hint alias",
			in: mbArtist{Name: "Василий Петренко", SortName: "Petrenko, Vasily", Type: "Person",
				Aliases: []mbAlias{{Name: "V. Petrenko", Locale: "en", Type: "Search hint"}, petrenkoAlias}},
			want: "Vasily Petrenko", want2: "alias-en",
		},
		{
			// the real-world shape: the artist-name alias carries no locale, so it
			// only wins if a bare en-locale alias is NOT a rung of its own
			name: "artist-name alias beats an en search hint",
			in: mbArtist{Name: "Василий Петренко", SortName: "Petrenko, Vasily", Type: "Person",
				Aliases: []mbAlias{
					{Name: "V. Petrenko", Locale: "en", Type: "Search hint"},
					{Name: "Vasily Petrenko", Type: "Artist name", Primary: true},
				}},
			want: "Vasily Petrenko", want2: "alias",
		},
		{
			// MB search hints are misspellings and abbreviations, never display
			// names: the Latin sort-name is a better answer than any of them
			name: "search hint loses to the sort-name floor",
			in: mbArtist{Name: "Пётр Ильич Чайковский", SortName: "Tchaikovsky, Pyotr Ilyich", Type: "Person",
				Aliases: []mbAlias{{Name: "Peter Tschaikowski", Locale: "en", Type: "Search hint"}}},
			want: "Pyotr Ilyich Tchaikovsky", want2: "sortname",
		},
		{
			name: "two english aliases, the primary one wins",
			in: mbArtist{Name: "Василий Петренко", Type: "Person",
				Aliases: []mbAlias{{Name: "Wassily Petrenko", Locale: "en"}, {Name: "Vasily Petrenko", Locale: "en", Primary: true}}},
			want: "Vasily Petrenko", want2: "alias-en",
		},
		{
			name: "latin artist-name alias with no locale",
			in: mbArtist{Name: "Василий Петренко", Type: "Person",
				Aliases: []mbAlias{{Name: "Vasily Petrenko", Type: "Artist name", Primary: true}}},
			want: "Vasily Petrenko", want2: "alias",
		},
		{
			// no Cyrillic table hit: honest failure beats garbage
			name: "no resolution available",
			in:   mbArtist{Name: "坂本龍一", Type: "Person"},
			want: "", want2: "none",
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, src := latinName(&c.in)
			if got != c.want || src != c.want2 {
				t.Errorf("latinName(%q) = (%q, %q), want (%q, %q)", c.in.Name, got, src, c.want, c.want2)
			}
		})
	}
}

// setLatin is what the enricher stores: never resolves a name that is already
// Latin, and uses MB's own (Latin) name when the tag's spelling is not.
func TestSetLatin(t *testing.T) {
	var ent ArtistEntry
	setLatin(&ent, "Mark Knopfler", &mbArtist{Name: "Someone Else"})
	if ent.NameLatin != "" || ent.NameLatinSrc != "same" {
		t.Errorf("latin name for a Latin tag = (%q, %q), want (%q, %q)", ent.NameLatin, ent.NameLatinSrc, "", "same")
	}

	ent = ArtistEntry{}
	setLatin(&ent, "Пётр Ильич Чайковский", &mbArtist{Name: "Pyotr Ilyich Tchaikovsky", Type: "Person"})
	if ent.NameLatin != "Pyotr Ilyich Tchaikovsky" || ent.NameLatinSrc != "mbname" {
		t.Errorf("latin name from MB = (%q, %q), want (%q, %q)", ent.NameLatin, ent.NameLatinSrc, "Pyotr Ilyich Tchaikovsky", "mbname")
	}
}
