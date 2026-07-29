package enrich

import (
	"strings"
	"unicode"
)

// isLatin reports whether every letter in s is Latin script. Digits, spaces
// and punctuation are ignored, so "AC/DC" and "2Pac" are Latin, "Мельдоний 2"
// is not, and "Sigur Rós" is.
func isLatin(s string) bool {
	for _, r := range s {
		if unicode.IsLetter(r) && !unicode.Is(unicode.Latin, r) {
			return false
		}
	}
	return true
}

// leading articles that MusicBrainz moves to the end of a group's sort-name.
var articles = map[string]bool{
	"the": true, "a": true, "an": true, "los": true, "las": true, "les": true,
	"la": true, "le": true, "el": true, "die": true, "der": true, "das": true,
	"de": true, "het": true,
}

// deInvert undoes MusicBrainz sort-name inversion. Type-aware, because the two
// conventions are different rules that happen to share a comma: a person's
// sort-name is "Family, Given", a group's is "Name, The". Blindly swapping
// would turn "Earth, Wind & Fire" into "Wind & Fire Earth".
func deInvert(sortName, artistType string) string {
	head, tail, ok := strings.Cut(sortName, ", ")
	if !ok || strings.Contains(tail, ", ") { // no comma, or more than one
		return sortName
	}
	switch artistType {
	case "Person", "Character", "": // unknown type reads as a person
		return tail + " " + head
	}
	if articles[strings.ToLower(tail)] {
		return tail + " " + head
	}
	return sortName
}

// latinName resolves a display name for a. Returns ("", "same") when the name
// is already Latin — the empty result is what makes the backfill sentinel
// settle instead of retrying every artist forever.
func latinName(a *mbArtist) (name, source string) {
	if isLatin(a.Name) {
		return "", "same"
	}
	// one pass, four candidates; first rung that holds wins. A non-primary
	// en-locale alias is deliberately not a rung: MusicBrainz "Search hint"
	// aliases are misspellings and abbreviations, not display names, and letting
	// one in makes the conductor read "V. Petrenko".
	var enPrimaryArtist, enPrimary, artistPrimary, artistAny string
	for _, al := range a.Aliases {
		if al.Name == "" || !isLatin(al.Name) {
			continue
		}
		isEn, isArtistName := al.Locale == "en", al.Type == "Artist name"
		if isEn && al.Primary && isArtistName && enPrimaryArtist == "" {
			enPrimaryArtist = al.Name
		}
		if isEn && al.Primary && enPrimary == "" {
			enPrimary = al.Name
		}
		if isArtistName && al.Primary && artistPrimary == "" {
			artistPrimary = al.Name
		}
		if isArtistName && artistAny == "" {
			artistAny = al.Name
		}
	}
	if v := firstOf(enPrimaryArtist, enPrimary); v != "" {
		return v, "alias-en"
	}
	if v := firstOf(artistPrimary, artistAny); v != "" {
		return v, "alias"
	}
	// sort-name is Latin by MB guideline: the reliable universal floor
	if a.SortName != "" && isLatin(a.SortName) {
		return deInvert(a.SortName, a.Type), "sortname"
	}
	if t := translit(a.Name); t != a.Name {
		return t, "translit" // approximate, and the source says so
	}
	return "", "none"
}

// ponytail: Cyrillic only — that's the reported case. Add a script when one
// shows up; a real transliteration library means golang.org/x/text, which this
// module does not have.
var cyrillic = map[rune]string{
	'а': "a", 'б': "b", 'в': "v", 'г': "g", 'д': "d", 'е': "e", 'ё': "yo",
	'ж': "zh", 'з': "z", 'и': "i", 'й': "y", 'к': "k", 'л': "l", 'м': "m",
	'н': "n", 'о': "o", 'п': "p", 'р': "r", 'с': "s", 'т': "t", 'у': "u",
	'ф': "f", 'х': "kh", 'ц': "ts", 'ч': "ch", 'ш': "sh", 'щ': "shch",
	'ъ': "", 'ы': "y", 'ь': "", 'э': "e", 'ю': "yu", 'я': "ya",
	'і': "i", 'ї': "yi", 'є': "ye", 'ґ': "g",
}

// translit romanises Cyrillic; every other rune passes through unchanged.
func translit(s string) string {
	var b strings.Builder
	for _, r := range s {
		v, ok := cyrillic[unicode.ToLower(r)]
		if !ok {
			b.WriteRune(r)
			continue
		}
		if unicode.IsUpper(r) && v != "" {
			v = strings.ToUpper(v[:1]) + v[1:]
		}
		b.WriteString(v)
	}
	return b.String()
}

// setLatin stores the display name for the raw tag name on ent. The MB
// entity's own name can already be Latin where the tag's spelling is not
// (Чайковский vs Tchaikovsky), which counts as a resolution too.
func setLatin(ent *ArtistEntry, name string, ar *mbArtist) {
	if isLatin(name) {
		ent.NameLatinSrc = "same" // nothing to resolve, and never retried
		return
	}
	ent.NameLatin, ent.NameLatinSrc = latinName(ar)
	if ent.NameLatinSrc == "same" {
		ent.NameLatin, ent.NameLatinSrc = ar.Name, "mbname"
	}
}
