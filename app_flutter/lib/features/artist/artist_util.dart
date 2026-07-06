import 'package:aria_api/aria_api.dart';

/// Path contracts with sibling features (features never import each other).
String artistPath(String name) => '/artist/${Uri.encodeComponent(name)}';
String composerPath(String name) => '/composer/${Uri.encodeComponent(name)}';
String albumPath(String albumId) => '/album/${Uri.encodeComponent(albumId)}';

/// See album feature: go_router params are decoded defensively.
String decodeArtistRouteParam(String v) {
  try {
    return Uri.decodeComponent(v);
  } catch (_) {
    return v;
  }
}

// Release-type ordering/labels, ported verbatim from legacy app.js.
const rtOrder = ['Album', 'EP', 'Single', 'Live', 'Compilation'];
const rtHeadings = {
  'Album': 'Albums',
  'EP': 'EPs',
  'Single': 'Singles',
  'Live': 'Live',
  'Compilation': 'Compilations',
};

/// Discography section order: (lowercase type, heading).
const discTypes = [
  ('album', 'Albums'),
  ('ep', 'EPs'),
  ('single', 'Singles'),
  ('compilation', 'Compilations'),
  ('live', 'Live'),
];

const knownDiscTypes = {'album', 'ep', 'single', 'compilation', 'live'};

/// Edition-tolerant title key (legacy normTitle):
/// "Brothers in Arms (Remastered)" == "Brothers in Arms".
/// Deviation: no NFD diacritic folding (Dart has no built-in normalizer), so
/// "Björk" keys as "bj rk" — dedupe is slightly weaker on accented titles.
String normTitle(String? s) {
  var x = (s ?? '').toLowerCase();
  x = x.replaceAll(
    RegExp(
      r'\s*[(\[][^)\]]*(remaster|deluxe|edition|version|anniversary|expanded|bonus|live|mono|stereo|\b\d{4}\b)[^)\]]*[)\]]',
      caseSensitive: false,
    ),
    '',
  );
  return x.replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
}

/// Canonical genres of a track (legacy tg()): server-annotated list, raw file
/// tag as fallback.
List<String> trackGenres(Track t) =>
    t.genres.isNotEmpty ? t.genres : [if ((t.genre ?? '').isNotEmpty) t.genre!];

// ---------------------------------------------------------------- full bio

final _bioStop = RegExp(
  r'^(references|external links|see also|notes|sources|bibliography|further reading|discography|filmography|awards.*|tours)$',
  caseSensitive: false,
);
final _bioHeading = RegExp(r'^=+\s*(.*?)\s*=+$');

class BioBlock {
  const BioBlock(this.heading, this.text);

  final bool heading;
  final String text;
}

/// Plaintext Wikipedia extract → paragraphs; "== Heading ==" → heading blocks;
/// stops at the list-y reference tail (legacy fullBioHtml).
List<BioBlock> bioBlocks(String txt) {
  final out = <BioBlock>[];
  for (final raw in txt.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    final h = _bioHeading.firstMatch(line);
    if (h != null) {
      if (_bioStop.hasMatch(h.group(1)!)) break;
      out.add(BioBlock(true, h.group(1)!));
    } else {
      out.add(BioBlock(false, line));
    }
  }
  return out;
}

// ------------------------------------------------------------------- works

// Legacy WORK_SPLIT_RE: "Work: Movement" / "Work - I. ..." shapes.
final _workSplitRe = RegExp(
  r'^(.+?)(?::|\s[-–—])\s+((?:[IVXLCDM]+|No\.?\s*\d+|\d+)[.):]\s*.+)$',
);
final _trailingParens = RegExp(r'\s*[(\[][^)\]]*[)\]]\s*$');

/// Group a composer's tracks into works: explicit t.work wins; otherwise
/// strip trailing (...)/[...] performance junk from the title and split
/// "Work: Movement" shapes. Heuristic, good enough (legacy composerWorks).
/// Returns work title -> albumId -> tracks (each album group = one recording).
Map<String, Map<String, List<Track>>> composerWorks(
  List<Track> tracks,
  String name,
) {
  final works = <String, Map<String, List<Track>>>{};
  for (final t in tracks) {
    if (t.composer != name) continue;
    var w = t.work;
    if (w == null || w.isEmpty) {
      final clean = (t.title ?? '').replaceFirst(_trailingParens, '').trim();
      final sp = _workSplitRe.firstMatch(clean);
      w = (sp != null ? sp.group(1)! : clean).trim();
      if (w.isEmpty) w = t.title ?? 'Unknown work';
    }
    ((works[w] ??= {})[t.albumId] ??= []).add(t);
  }
  for (final perAlb in works.values) {
    for (final ts in perAlb.values) {
      ts.sort((x, y) {
        final d = (x.discNo ?? 1) - (y.discNo ?? 1);
        return d != 0 ? d : (x.trackNo ?? 0) - (y.trackNo ?? 0);
      });
    }
  }
  return works;
}
