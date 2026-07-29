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
