// Legacy transliteration pass (app.js TL/translit): GOST 7.79-2000 System B
// (simplified: ъ/ь dropped) + uk/be extras, sr/mk letters, pre-reform
// Cyrillic, and Greek (romanized, accents stripped) — so "tchaikovsky"-style
// latin queries can hit "Чайковский"-tagged files.

const _tl = <String, String>{
  'а': 'a', 'б': 'b', 'в': 'v', 'г': 'g', 'д': 'd', 'е': 'e', 'ё': 'yo',
  'ж': 'zh', 'з': 'z', 'и': 'i', 'й': 'j', 'к': 'k', 'л': 'l', 'м': 'm',
  'н': 'n', 'о': 'o', 'п': 'p', 'р': 'r', 'с': 's', 'т': 't', 'у': 'u',
  'ф': 'f', 'х': 'kh', 'ц': 'ts', 'ч': 'ch', 'ш': 'sh', 'щ': 'shch',
  'ъ': '', 'ы': 'y', 'ь': '', 'э': 'e', 'ю': 'yu', 'я': 'ya', 'і': 'i',
  'ї': 'yi', 'є': 'ye', 'ґ': 'g', 'ў': 'u',
  // Serbian / Macedonian
  'ђ': 'dj', 'ј': 'j', 'љ': 'lj', 'њ': 'nj', 'ћ': 'c', 'џ': 'dz',
  'ѓ': 'gj', 'ќ': 'kj', 'ѕ': 'dz',
  // pre-reform Cyrillic
  'ѣ': 'e', 'ѳ': 'f', 'ѵ': 'i', 'ѐ': 'e', 'ѝ': 'i',
  // Greek
  'α': 'a', 'β': 'v', 'γ': 'g', 'δ': 'd', 'ε': 'e', 'ζ': 'z', 'η': 'i',
  'θ': 'th', 'ι': 'i', 'κ': 'k', 'λ': 'l', 'μ': 'm', 'ν': 'n', 'ξ': 'x',
  'ο': 'o', 'π': 'p', 'ρ': 'r', 'σ': 's', 'ς': 's', 'τ': 't', 'υ': 'y',
  'φ': 'f', 'χ': 'ch', 'ψ': 'ps', 'ω': 'o',
  'ά': 'a', 'έ': 'e', 'ή': 'i', 'ί': 'i', 'ό': 'o', 'ύ': 'y', 'ώ': 'o',
  'ϊ': 'i', 'ϋ': 'y', 'ΐ': 'i', 'ΰ': 'y',
};

final _nonLatin = RegExp(r'[Ѐ-ӿͰ-Ͽἀ-῿]');

/// Latin transliteration, or null when [s] has nothing to transliterate.
String? translit(String? s) {
  if (s == null || !_nonLatin.hasMatch(s)) return null;
  final out = StringBuffer();
  for (final ch in s.runes) {
    final c = String.fromCharCode(ch);
    final lo = c.toLowerCase();
    final t = _tl[lo];
    if (t == null) {
      out.write(c);
    } else if (c != lo && t.isNotEmpty) {
      out.write(t[0].toUpperCase() + t.substring(1));
    } else {
      out.write(t);
    }
  }
  return out.toString();
}

/// Legacy matches(): lowercase contains on the value or its transliteration.
/// [query] must already be lowercased.
bool matchesQuery(String? value, String query) {
  if (query.isEmpty) return true;
  final v = (value ?? '').toLowerCase();
  if (v.contains(query)) return true;
  final t = translit(v);
  return t != null && t.toLowerCase().contains(query);
}
