package api

import "testing"

// After Latinisation the merged view carries the Latin spelling; raw maps it
// back to the original script the DB and any pre-existing rule still hold.
var petrenkoRaw = map[string]string{"vasily petrenko": "василий петренко"}

func rule(field, op string, value any) map[string]any {
	return map[string]any{"field": field, "op": op, "value": value}
}

// A smart rule is free text, so it may name either spelling: one written before
// Latinisation says "Василий Петренко", one written after says "Vasily
// Petrenko". Both must select the same tracks.
func TestEvalRuleBothSpellings(t *testing.T) {
	track := map[string]any{
		"id":     "t1",
		"artist": "Vasily Petrenko",
		"album":  "Barber, Bruch",
		"performers": []any{
			map[string]any{"name": "Esther Yoo", "role": "violin"},
		},
	}
	for _, tc := range []struct {
		name string
		r    map[string]any
		raw  map[string]string
		want bool
	}{
		{"latin is", rule("artist", "is", "Vasily Petrenko"), petrenkoRaw, true},
		{"raw is", rule("artist", "is", "Василий Петренко"), petrenkoRaw, true},
		{"raw is, case-insensitive", rule("artist", "is", "ВАСИЛИЙ ПЕТРЕНКО"), petrenkoRaw, true},
		{"latin isNot", rule("artist", "isNot", "Vasily Petrenko"), petrenkoRaw, false},
		{"raw isNot must not match either", rule("artist", "isNot", "Василий Петренко"), petrenkoRaw, false},
		{"isNot a different name", rule("artist", "isNot", "Esther Yoo"), petrenkoRaw, true},
		{"latin contains", rule("artist", "contains", "petrenko"), petrenkoRaw, true},
		{"raw substring contains", rule("artist", "contains", "Петренко"), petrenkoRaw, true},
		{"raw anyOf", rule("artist", "anyOf", []any{"Nobody", "Василий Петренко"}), petrenkoRaw, true},
		{"mixed allOf", rule("artist", "allOf", []any{"Vasily", "Петренко"}), petrenkoRaw, true},
		{"credited raw", rule("credited", "is", "Василий Петренко"), petrenkoRaw, true},
		{"credited latin", rule("credited", "is", "Vasily Petrenko"), petrenkoRaw, true},
		{"credited untouched performer", rule("credited", "is", "Esther Yoo"), petrenkoRaw, true},
		{"credited isNot raw must not match", rule("credited", "isNot", "Василий Петренко"), petrenkoRaw, false},

		// Control: without the map the raw spelling cannot match. These are the
		// cases that fail if the both-spellings code is reverted.
		{"no map, latin still matches", rule("artist", "is", "Vasily Petrenko"), nil, true},
		{"no map, raw misses", rule("artist", "is", "Василий Петренко"), nil, false},
		{"no map, credited raw misses", rule("credited", "is", "Василий Петренко"), nil, false},

		// A field that was never Latinised is unaffected either way.
		{"album is", rule("album", "is", "Barber, Bruch"), petrenkoRaw, true},
		{"album isNot", rule("album", "isNot", "Barber, Bruch"), petrenkoRaw, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := evalRule(track, tc.r, nil, tc.raw); got != tc.want {
				t.Errorf("evalRule(%v) = %v, want %v", tc.r, got, tc.want)
			}
		})
	}
}

// A null field keeps its documented semantics: is/contains false, isNot true,
// regardless of the spelling map.
func TestEvalRuleNullFieldWithRawMap(t *testing.T) {
	track := map[string]any{"id": "t1", "composer": (*string)(nil)}
	for _, tc := range []struct {
		op   string
		want bool
	}{{"is", false}, {"contains", false}, {"isNot", true}} {
		t.Run(tc.op, func(t *testing.T) {
			if got := evalRule(track, rule("composer", tc.op, "Василий Петренко"), nil, petrenkoRaw); got != tc.want {
				t.Errorf("composer %s on null = %v, want %v", tc.op, got, tc.want)
			}
		})
	}
}

// The genre rule evaluates against the merged `genres` array, which since the
// sources phase carries MusicBrainz genre tags and Discogs styles on top of
// the file tag's own. Every case below with only `genre` set is a
// pre-enrichment row and must behave exactly as it always did.
func TestEvalRuleGenreUsesMergedArray(t *testing.T) {
	enriched := map[string]any{
		"id": "t1", "genre": "Rock",
		// what buildMergedTracks now produces: file tag first, then MB's
		// voted "alternative rock" and Discogs' "Euro-Disco" style
		"genres": []string{"Rock", "Alternative Rock", "Disco"},
	}
	legacy := map[string]any{"id": "t2", "genre": "Rock"} // no array at all
	jsonRow := map[string]any{                            // the same row after a JSON round trip
		"id": "t3", "genre": "Rock", "genres": []any{"Rock", "Alternative Rock"},
	}
	for _, tc := range []struct {
		name  string
		track map[string]any
		r     map[string]any
		want  bool
	}{
		{"enrichment genre matches", enriched, rule("genre", "is", "Alternative Rock"), true},
		{"file tag still matches", enriched, rule("genre", "is", "Rock"), true},
		{"parent of an enrichment genre", enriched, rule("genre", "is", "Soul/R&B"), false},
		{"hierarchy through the array", enriched, rule("genre", "contains", "Soul/R&B"), true}, // Disco is a child
		{"anyOf over the array", enriched, rule("genre", "anyOf", []any{"Nope", "Disco"}), true},
		{"allOf over the array", enriched, rule("genre", "allOf", []any{"Rock", "Disco"}), true},
		{"isNot excludes an enrichment genre", enriched, rule("genre", "isNot", "Alternative Rock"), false},
		{"[]any decodes too", jsonRow, rule("genre", "is", "Alternative Rock"), true},

		// unchanged behaviour for rows with no derived array
		{"legacy falls back to the raw tag", legacy, rule("genre", "is", "Rock"), true},
		{"legacy does not gain genres", legacy, rule("genre", "is", "Alternative Rock"), false},
		{"legacy hierarchy still works", legacy, rule("genre", "contains", "Rock"), true},
		{"legacy isNot", legacy, rule("genre", "isNot", "Jazz"), true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := evalRule(tc.track, tc.r, nil, nil); got != tc.want {
				t.Errorf("got %v, want %v", got, tc.want)
			}
		})
	}
}

// The quality predicates the health/analysis work buys. The interesting case
// is not that they match — it is that a track nothing has decoded yet fails
// every one of them, including `lt`: toNum reads null as 0 (JS Number(null)),
// which without the null guard would make every unanalysed track quieter than
// any threshold and land the whole un-decoded library in the playlist.
func TestEvalRuleQualityPredicates(t *testing.T) {
	analysed := map[string]any{
		"id": "t1", "loudnessLufs": -9.4, "dynamicRangeLu": 4.2,
		"sampleRate": 44100, "bitsPerSample": 16, "suspect": true, "lossless": true,
	}
	unanalysed := map[string]any{"id": "t2", "lossless": true, "suspect": false}
	for _, tc := range []struct {
		name  string
		track map[string]any
		r     map[string]any
		want  bool
	}{
		{"loud master", analysed, rule("loudness", "gt", -14), true},
		{"not quiet", analysed, rule("loudness", "lt", -14), false},
		{"compressed", analysed, rule("dynamicRange", "lt", 6), true},
		{"redbook", analysed, rule("sampleRate", "is", 44100), true},
		{"not hi-res", analysed, rule("sampleRate", "gt", 48000), false},
		{"16 bit", analysed, rule("bitsPerSample", "lt", 24), true},
		{"is a transcode", analysed, rule("suspect", "is", true), true},
		{"exclude transcodes drops it", analysed, rule("suspect", "is", false), false},

		// every operator fails on an unmeasured track — `lt` especially
		{"unanalysed fails lt", unanalysed, rule("loudness", "lt", -14), false},
		{"unanalysed fails gt", unanalysed, rule("loudness", "gt", -14), false},
		{"unanalysed fails is", unanalysed, rule("dynamicRange", "is", 0), false},
		{"unanalysed fails sampleRate", unanalysed, rule("sampleRate", "gt", 0), false},
		// but it is not "suspect": nothing has contradicted the container
		{"unanalysed is not suspect", unanalysed, rule("suspect", "is", false), true},

		// a non-numeric rule value fails rather than comparing against 0
		{"garbage value", analysed, rule("loudness", "gt", "loud"), false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := evalRule(tc.track, tc.r, nil, nil); got != tc.want {
				t.Errorf("got %v, want %v", got, tc.want)
			}
		})
	}
}

// The compatibility guarantee for the whole predicate change: every rule shape
// the form could emit before it must still validate AND evaluate to exactly
// what it did. `year` in particular stopped being its own case and now runs
// through evalNumeric with the other measured fields.
func TestExistingRuleShapesUnchanged(t *testing.T) {
	track := map[string]any{
		"id": "t1", "title": "Come Together", "artist": "The Beatles",
		"albumArtist": "The Beatles", "album": "Abbey Road", "genre": "Rock",
		"composer": "Lennon/McCartney", "format": "flac", "year": 1969,
		"lossless": true, "releaseType": "Album", "addedAt": nowISO(),
		"tags": []string{"Favourites"},
	}
	nullYear := map[string]any{"id": "t2", "year": nil}
	for _, tc := range []struct {
		name string
		r    map[string]any
		want bool
	}{
		{"title contains", rule("title", "contains", "come"), true},
		{"artist anyOf", rule("artist", "anyOf", []any{"Beatles", "Stones"}), true},
		{"albumArtist is", rule("albumArtist", "is", "the beatles"), true},
		{"album isNot", rule("album", "isNot", "Revolver"), true},
		{"genre is", rule("genre", "is", "Rock"), true},
		{"composer contains", rule("composer", "contains", "lennon"), true},
		{"format is", rule("format", "is", "flac"), true},
		{"credited contains", rule("credited", "contains", "beatles"), true},
		{"year is", rule("year", "is", 1969), true},
		{"year gt", rule("year", "gt", 1968), true},
		{"year lt", rule("year", "lt", 1969), false},
		{"lossless is", rule("lossless", "is", true), true},
		{"releaseType is", rule("releaseType", "is", "Album"), true},
		{"playCount is 0", rule("playCount", "is", 0), true},
		{"addedDays within", rule("addedDays", "within", 30), true},
		{"tag is", rule("tag", "is", "Favourites"), true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if !validRules(map[string]any{"match": "all", "rules": []any{tc.r}}) {
				t.Fatalf("%v no longer validates", tc.r)
			}
			if got := evalRule(track, tc.r, nil, nil); got != tc.want {
				t.Errorf("got %v, want %v", got, tc.want)
			}
		})
	}
	// the null-year rule that predates every measured field
	for _, op := range []string{"is", "gt", "lt"} {
		if evalRule(nullYear, rule("year", op, 1969), nil, nil) {
			t.Errorf("null year matched %q", op)
		}
	}
}
