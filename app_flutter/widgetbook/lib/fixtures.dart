import 'package:aria_api/aria_api.dart';

/// Sample library for the catalogue.
///
/// Written as JSON and decoded through the app's own `fromJson` — not built
/// with the constructors. The same maps are what [FakeAriaServer] serves, so
/// a use case and the fake server can never disagree about a track, and a
/// field added to the wire format shows up here as a decode failure rather
/// than as a fixture that quietly lost a column.
///
/// The four albums are chosen to cover the states the widgets actually branch
/// on: hi-res lossless, plain CD lossless, lossy, and missing artwork. The
/// classical one exercises composer/work/movement and the album-artists split.

const _kBlue = 'a-kind-of-blue';
const _kSunday = 'sunday-at-the-village-vanguard';
const _kGoldberg = 'goldberg-variations-1981';
const _kBootleg = 'live-at-the-plugged-nickel';

Map<String, dynamic> _track({
  required String id,
  required String albumId,
  required String title,
  required String artist,
  String? albumArtist,
  required String album,
  int? year,
  int? trackNo,
  int? discNo,
  double? duration,
  String format = 'FLAC',
  int? sampleRate = 44100,
  int? bitsPerSample = 16,
  bool lossless = true,
  bool hasArt = true,
  bool favourite = false,
  String? composer,
  String? work,
  String? movement,
  String? releaseType = 'Album',
  List<String> genres = const [],
  List<String> tags = const [],
  List<String> albumArtists = const [],
  List<Map<String, String>> performers = const [],
}) => {
      'id': id,
      'albumId': albumId,
      'title': title,
      'artist': artist,
      'albumArtist': albumArtist ?? artist,
      'album': album,
      'year': year,
      'trackNo': trackNo,
      'discNo': discNo,
      'duration': duration,
      'format': format,
      'sampleRate': sampleRate,
      'bitsPerSample': bitsPerSample,
      'lossless': lossless,
      'hasArt': hasArt,
      'artVersion': 1,
      'favourite': favourite,
      'composer': composer,
      'work': work,
      'movement': movement,
      'releaseType': releaseType,
      'genres': genres,
      'tags': tags,
      'albumArtists': albumArtists,
      'performers': performers,
      'addedAt': '2026-02-11T09:14:00Z',
    };

/// Raw `/api/tracks` payload — the wire shape, served verbatim.
final List<Map<String, dynamic>> fixtureTrackJson = [
  // Hi-res lossless (24/192): the FormatBadge's heavier hi-res weight.
  _track(
    id: 'blue-1',
    albumId: _kBlue,
    title: 'So What',
    artist: 'Miles Davis',
    album: 'Kind of Blue',
    year: 1959,
    trackNo: 1,
    duration: 545.5,
    sampleRate: 192000,
    bitsPerSample: 24,
    favourite: true,
    genres: ['Jazz', 'Modal Jazz'],
    tags: ['Desert Island'],
  ),
  _track(
    id: 'blue-2',
    albumId: _kBlue,
    title: 'Freddie Freeloader',
    artist: 'Miles Davis',
    album: 'Kind of Blue',
    year: 1959,
    trackNo: 2,
    duration: 586.0,
    sampleRate: 192000,
    bitsPerSample: 24,
    genres: ['Jazz'],
  ),
  _track(
    id: 'blue-3',
    albumId: _kBlue,
    title: 'Blue in Green',
    artist: 'Miles Davis',
    album: 'Kind of Blue',
    year: 1959,
    trackNo: 3,
    duration: 337.0,
    sampleRate: 192000,
    bitsPerSample: 24,
    genres: ['Jazz'],
  ),

  // Redbook lossless (16/44.1) — the ordinary case.
  _track(
    id: 'vanguard-1',
    albumId: _kSunday,
    title: 'Gloria’s Step',
    artist: 'Bill Evans Trio',
    album: 'Sunday at the Village Vanguard',
    year: 1961,
    trackNo: 1,
    duration: 366.0,
    releaseType: 'Live',
    genres: ['Jazz'],
    favourite: true,
  ),
  _track(
    id: 'vanguard-2',
    albumId: _kSunday,
    title: 'My Man’s Gone Now',
    artist: 'Bill Evans Trio',
    album: 'Sunday at the Village Vanguard',
    year: 1961,
    trackNo: 2,
    duration: 386.0,
    releaseType: 'Live',
    genres: ['Jazz'],
  ),

  // Classical: composer / work / movement and the album-artists split, plus a
  // very long title for the ellipsis behaviour.
  _track(
    id: 'goldberg-1',
    albumId: _kGoldberg,
    title: 'Goldberg Variations, BWV 988: Aria',
    artist: 'Glenn Gould',
    albumArtist: 'Johann Sebastian Bach',
    album: 'Goldberg Variations (1981)',
    year: 1981,
    trackNo: 1,
    duration: 190.0,
    sampleRate: 96000,
    bitsPerSample: 24,
    composer: 'Johann Sebastian Bach',
    work: 'Goldberg Variations, BWV 988',
    movement: 'Aria',
    genres: ['Classical'],
    albumArtists: ['Johann Sebastian Bach', 'Glenn Gould'],
    performers: [
      {'name': 'Glenn Gould', 'role': 'piano'},
    ],
  ),
  _track(
    id: 'goldberg-2',
    albumId: _kGoldberg,
    title: 'Goldberg Variations, BWV 988: Variatio 1 a 1 Clav.',
    artist: 'Glenn Gould',
    albumArtist: 'Johann Sebastian Bach',
    album: 'Goldberg Variations (1981)',
    year: 1981,
    trackNo: 2,
    duration: 68.0,
    sampleRate: 96000,
    bitsPerSample: 24,
    composer: 'Johann Sebastian Bach',
    work: 'Goldberg Variations, BWV 988',
    movement: 'Variatio 1 a 1 Clav.',
    genres: ['Classical'],
    albumArtists: ['Johann Sebastian Bach', 'Glenn Gould'],
  ),

  // Lossy MP3 with no artwork — drives the green lossy marker and the
  // initials placeholder in ArtImage.
  _track(
    id: 'nickel-1',
    albumId: _kBootleg,
    title: 'If I Were a Bell',
    artist: 'Miles Davis Quintet',
    album: 'Live at the Plugged Nickel',
    year: 1965,
    trackNo: 1,
    duration: 1002.0,
    format: 'MPEG',
    sampleRate: 44100,
    bitsPerSample: null,
    lossless: false,
    hasArt: false,
    releaseType: 'Live',
    genres: ['Jazz'],
  ),
];

/// The same rows the fake server serves, as the app's own model objects.
final List<Track> fixtureTracks =
    fixtureTrackJson.map(Track.fromJson).toList(growable: false);

/// Grouped exactly the way the app groups them — `Album.group` is the real
/// derivation, so an album fixture cannot drift from album behaviour.
final List<Album> fixtureAlbums = Album.group(fixtureTracks);

Album albumById(String id) => fixtureAlbums.firstWhere((a) => a.id == id);

/// 24/192 lossless, in a hi-res-flagged album.
Track get hiResTrack => fixtureTracks.first;

/// 16/44.1 lossless — the ordinary badge.
Track get losslessTrack =>
    fixtureTracks.firstWhere((t) => t.id == 'vanguard-1');

/// Lossy, artless.
Track get lossyTrack => fixtureTracks.firstWhere((t) => t.id == 'nickel-1');

/// Long enough to ellipsize in a card and a row.
Track get longTitleTrack =>
    fixtureTracks.firstWhere((t) => t.id == 'goldberg-2');

// ------------------------------------------------------------------ people

const List<String> fixtureArtists = [
  'Miles Davis',
  'Bill Evans Trio',
  'Glenn Gould',
  'John Coltrane',
  'Thelonious Monk',
  'Ella Fitzgerald',
];

/// `/api/people` — name -> portrait URL. The values are only ever passed back
/// to the same fake server, which answers any path with a generated portrait.
final Map<String, String> fixturePeopleJson = {
  for (final name in fixtureArtists) name: '/api/people/img/$name',
};

// -------------------------------------------------------------------- tags

final List<Map<String, dynamic>> fixtureTagJson = [
  {'id': 'folder-moods', 'name': 'Moods', 'folder': true, 'items': []},
  {
    'id': 'tag-late-night',
    'name': 'Late night',
    'parent': 'folder-moods',
    'items': [
      {'kind': 'album', 'key': _kBlue},
      {'kind': 'track', 'key': 'vanguard-1'},
    ],
  },
  {
    'id': 'tag-focus',
    'name': 'Focus',
    'parent': 'folder-moods',
    'items': [
      {'kind': 'album', 'key': _kGoldberg},
    ],
  },
  {
    'id': 'tag-desert-island',
    'name': 'Desert Island',
    'items': [
      {'kind': 'track', 'key': 'blue-1'},
    ],
  },
  {'id': 'tag-vinyl-rip', 'name': 'Vinyl rip', 'items': []},
];

final List<Tag> fixtureTags =
    fixtureTagJson.map(Tag.fromJson).toList(growable: false);

// --------------------------------------------------------------- playlists

const _kProfile = 'profile-1';

final List<Map<String, dynamic>> fixturePlaylistJson = [
  {
    'id': 'pl-morning',
    'profileId': _kProfile,
    'name': 'Morning',
    'type': 'manual',
    'trackIds': ['blue-1', 'goldberg-1', 'vanguard-1'],
  },
  {
    'id': 'pl-after-hours',
    'profileId': _kProfile,
    'name': 'After hours',
    'type': 'manual',
    'trackIds': ['vanguard-1', 'vanguard-2'],
  },
  {
    'id': 'pl-hi-res',
    'profileId': _kProfile,
    'name': 'Hi-res only',
    'type': 'smart',
    'rules': {
      'match': 'all',
      'rules': [
        {'field': 'lossless', 'op': 'is', 'value': true},
        {'field': 'year', 'op': 'gt', 'value': 1950},
      ],
    },
  },
];

final List<Playlist> fixturePlaylists =
    fixturePlaylistJson.map(Playlist.fromJson).toList(growable: false);

final List<Map<String, dynamic>> fixtureProfileJson = [
  {'id': _kProfile, 'name': 'Chris', 'color': '#D13B58'},
  {'id': 'profile-2', 'name': 'Guest', 'color': '#15803D'},
];

// ------------------------------------------------------ unowned / external

/// Albums the library does not have — New Releases, Listen Later, discography
/// ghosts. `cover` points at the fake server's external-image proxy so the
/// card's real proxy-then-CDN chain is exercised.
const List<({String artist, String title, String subtitle, String cover})>
    fixtureUnowned = [
  (
    artist: 'Vijay Iyer',
    title: 'Compassion',
    subtitle: '2024 · Not in library',
    cover: 'https://cdn.example/compassion.jpg',
  ),
  (
    artist: 'Ambrose Akinmusire',
    title: 'Owl Song',
    subtitle: '2023 · Not in library',
    cover: 'https://cdn.example/owl-song.jpg',
  ),
  (
    artist: 'Mary Halvorson',
    title: 'Cloudward',
    subtitle: '2024 · Not in library',
    cover: 'https://cdn.example/cloudward.jpg',
  ),
  (
    artist: 'Shabaka',
    title: 'Perceive Its Beauty',
    subtitle: '2024 · Not in library',
    cover: '',
  ),
];

// ------------------------------------------------------------------- plays

/// An ISO timestamp [d] days back, at a fixed hour.
///
/// Relative to the wall clock on purpose: every play chart buckets against
/// `DateTime.now()`, and a frozen date would leave all thirty bars at zero —
/// a chart with nothing in it says nothing about the chart. The cost is that
/// the stories drawing them cannot be golden-matched, and the render test
/// lists them as render-only for exactly this reason.
String _daysAgo(int d, {int hour = 20}) => DateTime.now()
    .toUtc()
    .subtract(Duration(days: d))
    .copyWith(minute: 0, second: 0, millisecond: 0, microsecond: 0)
    .add(Duration(hours: hour - DateTime.now().toUtc().hour))
    .toIso8601String();

/// Plays per fixture track, in fixture order — enough spread that a top-5 and
/// a 30-day chart both have shape.
const List<int> _playWeights = [17, 6, 9, 13, 4, 8, 5, 11];

final Map<String, int> fixturePlayCounts = {
  for (final (i, t) in fixtureTracks.indexed) t.id: _playWeights[i],
};

/// `/api/stats` history: one entry per play, spread over the last 30 days.
final List<Map<String, dynamic>> fixturePlayJson = [
  for (final (i, t) in fixtureTracks.indexed)
    for (var n = 0; n < _playWeights[i]; n++)
      {'id': t.id, 'at': _daysAgo((n * 3 + i * 2) % 30, hour: 8 + (n % 14))},
];

int _secondsOf(String id) =>
    (fixtureTracks.firstWhere((t) => t.id == id).duration ?? 0).round();

final int _totalPlays = _playWeights.reduce((a, b) => a + b);

final int _totalSeconds = fixtureTracks.indexed
    .map((e) => _secondsOf(e.$2.id) * _playWeights[e.$1])
    .reduce((a, b) => a + b);

final Map<String, dynamic> fixtureStatsJson = {
  'profileId': _kProfile,
  'totalPlays': _totalPlays,
  'totalSeconds': _totalSeconds,
  'uniqueTracks': fixtureTracks.length,
  'week': {'plays': 19, 'seconds': 19 * 420},
  'month': {
    'plays': _totalPlays,
    'seconds': _totalSeconds,
    'topArtist': {'name': 'Miles Davis', 'count': 26},
  },
  'history': fixturePlayJson,
  'topTracks': [
    for (final (i, t) in fixtureTracks.indexed)
      {'id': t.id, 'count': _playWeights[i], 'lastAt': _daysAgo(i)},
  ]..sort((a, b) => (b['count']! as int).compareTo(a['count']! as int)),
  'topAlbums': [
    {'albumId': _kBlue, 'count': 32},
    {'albumId': _kSunday, 'count': 17},
    {'albumId': _kGoldberg, 'count': 13},
    {'albumId': _kBootleg, 'count': 11},
  ],
  'topArtists': [
    {'name': 'Miles Davis', 'count': 32},
    {'name': 'Bill Evans Trio', 'count': 17},
    {'name': 'Glenn Gould', 'count': 13},
    {'name': 'Miles Davis Quintet', 'count': 11},
  ],
  'recent': fixturePlayJson.take(10).toList(),
  'playCounts': fixturePlayCounts,
};

final Stats fixtureStats = Stats.fromJson(fixtureStatsJson);

/// `/api/mixes` — the four ranked lists the home mixes shelf reads.
final Map<String, dynamic> fixtureMixesJson = {
  'daily': ['blue-1', 'vanguard-1', 'goldberg-1', 'nickel-1'],
  'weekly': ['vanguard-2', 'blue-2', 'blue-3'],
  'monthly': ['goldberg-2', 'blue-1', 'vanguard-1'],
  'yearly': ['blue-1', 'blue-2', 'vanguard-1', 'goldberg-1', 'nickel-1'],
};

// ------------------------------------------------------------------ health

/// One of each issue kind the health screen branches on, plus a clean
/// counter block — the page's two halves in a single fixture.
final Map<String, dynamic> fixtureHealthJson = {
  'counts': {
    'tracks': fixtureTracks.length,
    'albums': fixtureAlbums.length,
    'analysed': 6,
    'fingerprinted': 5,
    'identified': 3,
  },
  'issues': [
    {
      'kind': 'unmatched',
      'count': 2,
      'items': [
        {
          'albumId': _kBootleg,
          'title': 'Live at the Plugged Nickel',
          'subtitle': 'Miles Davis Quintet',
          'detail': 'no plausible candidate',
        },
      ],
    },
    {
      'kind': 'lowSeparation',
      'count': 1,
      'items': [
        {
          'albumId': _kSunday,
          'title': 'Sunday at the Village Vanguard',
          'subtitle': 'Bill Evans Trio',
          'detail': 'two releases scored 0.02 apart',
        },
      ],
    },
    {
      'kind': 'missingArt',
      'count': 1,
      'items': [
        {
          'albumId': _kBootleg,
          'title': 'Live at the Plugged Nickel',
          'subtitle': 'Miles Davis Quintet',
        },
      ],
    },
    {
      'kind': 'clipping',
      'count': 1,
      'items': [
        {
          'albumId': _kBlue,
          'trackId': 'blue-2',
          'title': 'Freddie Freeloader',
          'subtitle': 'Kind of Blue',
          'detail': 'true peak +1.4 dBTP',
        },
      ],
    },
    {'kind': 'unanalysed', 'count': 0, 'items': <Object>[]},
  ],
};

final LibraryHealth fixtureHealth = LibraryHealth.fromJson(fixtureHealthJson);

/// A byte-identical pair and an AcoustID-only pair — the two cases the
/// duplicates list styles differently.
final List<Map<String, dynamic>> fixtureDuplicateJson = [
  {
    'key': 'md5:9f2c',
    'exact': true,
    'tracks': [
      {
        'id': 'blue-1',
        'albumId': _kBlue,
        'title': 'So What',
        'artist': 'Miles Davis',
        'album': 'Kind of Blue',
        'format': 'FLAC',
        'lossless': true,
        'duration': 545.5,
        'sampleRate': 192000,
        'bitsPerSample': 24,
      },
      {
        'id': 'blue-1-copy',
        'albumId': _kBlue,
        'title': 'So What',
        'artist': 'Miles Davis',
        'album': 'Kind of Blue (Remaster)',
        'format': 'FLAC',
        'lossless': true,
        'duration': 545.5,
        'sampleRate': 192000,
        'bitsPerSample': 24,
      },
    ],
  },
  {
    'key': 'acoustid:5b71',
    'exact': false,
    'tracks': [
      {
        'id': 'vanguard-1',
        'albumId': _kSunday,
        'title': 'Gloria’s Step',
        'artist': 'Bill Evans Trio',
        'album': 'Sunday at the Village Vanguard',
        'format': 'FLAC',
        'lossless': true,
        'duration': 366.0,
        'sampleRate': 44100,
        'bitsPerSample': 16,
      },
      {
        'id': 'vanguard-1-mp3',
        'albumId': _kSunday,
        'title': 'Gloria’s Step (take 2)',
        'artist': 'Bill Evans Trio',
        'album': 'The Complete Village Vanguard Recordings',
        'format': 'MPEG',
        'lossless': false,
        'duration': 368.0,
        'sampleRate': 44100,
      },
    ],
  },
];

final List<DuplicateGroup> fixtureDuplicates =
    fixtureDuplicateJson.map(DuplicateGroup.fromJson).toList(growable: false);

// ------------------------------------------------------------ match review

/// The review queue's two halves: a `review` row with rival candidates to
/// choose between, and a `local` row with nothing to choose at all.
final List<Map<String, dynamic>> fixtureDecisionJson = [
  {
    'albumId': _kSunday,
    'state': 'review',
    'reason': 'low-separation',
    'album': 'Sunday at the Village Vanguard',
    'albumArtist': 'Bill Evans Trio',
    'distance': 0.08,
    'separation': 0.02,
    'attempts': 2,
    'decidedAt': '2026-06-02T11:20:00Z',
    'candidates': [
      {
        'mbid': 'f1d1-0001',
        'rgMbid': 'rg-0001',
        'title': 'Sunday at the Village Vanguard',
        'artist': 'Bill Evans Trio',
        'date': '1961-06-25',
        'country': 'US',
        'disambiguation': 'original Riverside pressing',
        'tracks': 6,
        'media': 1,
        'source': 'acoustid',
        'distance': 0.08,
        'why': {'album': 0.0, 'artist': 0.0, 'year': 0.04, 'trackLength': 0.04},
      },
      {
        'mbid': 'f1d1-0002',
        'rgMbid': 'rg-0002',
        'title': 'Sunday at the Village Vanguard',
        'artist': 'Bill Evans Trio',
        'date': '1987-01-01',
        'country': 'JP',
        'disambiguation': 'OJC reissue',
        'tracks': 6,
        'media': 1,
        'source': 'search',
        'distance': 0.10,
        'why': {'album': 0.0, 'artist': 0.0, 'year': 0.10},
      },
    ],
  },
  {
    'albumId': _kBootleg,
    'state': 'local',
    'reason': 'no-candidates',
    'album': 'Live at the Plugged Nickel',
    'albumArtist': 'Miles Davis Quintet',
    'attempts': 4,
    'decidedAt': '2026-06-01T08:00:00Z',
    'retryAfter': '2026-06-08T08:00:00Z',
    'candidates': <Object>[],
  },
];

final List<MatchDecision> fixtureDecisions =
    fixtureDecisionJson.map(MatchDecision.fromJson).toList(growable: false);

/// The `review` row — the one with candidates to weigh.
MatchDecision get reviewDecision => fixtureDecisions.first;

/// The `local` row — nothing found, nothing to pick.
MatchDecision get localDecision => fixtureDecisions.last;

// ------------------------------------------------------------------- radio

final List<Map<String, dynamic>> fixtureStationJson = [
  {
    'id': 'st-jazz24',
    'name': 'Jazz24',
    'url': 'https://live.example/jazz24.mp3',
    'genre': 'Jazz',
    'builtin': true,
  },
  {
    'id': 'st-concertzender',
    'name': 'Concertzender Klassiek',
    'url': 'https://live.example/klassiek.mp3',
    'genre': 'Classical',
    'builtin': true,
  },
  {
    'id': 'st-nts',
    'name': 'NTS 1',
    'url': 'https://live.example/nts1.mp3',
    'genre': 'Eclectic',
    'createdAt': '2026-03-04T18:00:00Z',
  },
  {
    'id': 'st-untagged',
    'name': 'Local mystery stream',
    'url': 'https://live.example/mystery.mp3',
    'createdAt': '2026-05-19T21:30:00Z',
  },
];

final List<RadioStation> fixtureStations =
    fixtureStationJson.map(RadioStation.fromJson).toList(growable: false);

// -------------------------------------------------- unowned album payloads

final List<Map<String, dynamic>> fixtureNewReleaseJson = [
  for (final (i, u) in fixtureUnowned.indexed)
    {
      'artist': u.artist,
      'title': u.title,
      'cover': u.cover.isEmpty ? null : u.cover,
      'date': '2026-0${(i % 9) + 1}-14',
      'type': i.isEven ? 'album' : 'ep',
      'deezerId': 1000 + i,
    },
];

final List<NewRelease> fixtureNewReleases =
    fixtureNewReleaseJson.map(NewRelease.fromJson).toList(growable: false);

final List<Map<String, dynamic>> fixtureListenLaterJson = [
  for (final (i, u) in fixtureUnowned.take(3).indexed)
    {
      'id': 'rg:ll-$i',
      'artist': u.artist,
      'title': u.title,
      'cover': u.cover.isEmpty ? null : u.cover,
      'date': '2024-0${i + 3}-01',
      'type': 'album',
      'deezerId': 2000 + i,
      'addedAt': '2026-06-0${i + 1}T10:00:00Z',
    },
];

final List<ListenLaterAlbum> fixtureListenLater = fixtureListenLaterJson
    .map(ListenLaterAlbum.fromJson)
    .toList(growable: false);

final Map<String, dynamic> fixtureExtAlbumJson = {
  'id': 'rg:compassion-2024',
  'artist': 'Vijay Iyer',
  'title': 'Compassion',
  'cover': 'https://cdn.example/compassion.jpg',
  'date': '2024-02-02',
  'type': 'album',
  'label': 'ECM',
  'link': 'https://example.org/compassion',
  'upc': '602445987654',
  'deezerId': 1000,
  'tracks': [
    {'title': 'Arch', 'duration': 384, 'disc': 1, 'number': 1},
    {'title': 'Prelude: Orison', 'duration': 121, 'disc': 1, 'number': 2},
    {'title': 'Compassion', 'duration': 447, 'disc': 1, 'number': 3},
    {'title': 'Nonaah', 'duration': 298, 'disc': 1, 'number': 4},
  ],
};

final ExtAlbum fixtureExtAlbum = ExtAlbum.fromJson(fixtureExtAlbumJson);

// ------------------------------------------------------------- enrichment

final Map<String, dynamic> fixtureAlbumInfoJson = {
  'label': 'Columbia',
  'date': '1959-08-17',
  'country': 'US',
  'catno': 'CL 1355',
  'mbType': 'Album',
  'mbSecondary': <String>[],
  'blurb': 'Recorded in two sessions at Columbia’s 30th Street Studio, and '
      'built on modal scales rather than chord changes — the best-selling '
      'jazz record ever pressed.',
  'url': 'https://en.wikipedia.org/wiki/Kind_of_Blue',
};

final Map<String, dynamic> fixtureArtistInfoJson = {
  'type': 'Person',
  'area': 'United States',
  'born': '1926-05-26',
  'died': '1991-09-28',
  'bio': 'Trumpeter, bandleader and composer whose records mark most of the '
      'turns jazz took between bebop and fusion. He led the first great '
      'quintet, recorded Kind of Blue with a sextet reading modal sketches at '
      'sight, and returned in the seventies with electric bands that split his '
      'audience in half.',
  'url': 'https://en.wikipedia.org/wiki/Miles_Davis',
  'image': '/api/people/img/Miles Davis',
  'imgSrc': 'wikipedia',
  'instruments': ['trumpet', 'flugelhorn'],
  'members': <String>[],
  'bands': ['Miles Davis Quintet'],
  'similar': [
    {'name': 'John Coltrane', 'image': '/api/people/img/John Coltrane'},
    {'name': 'Bill Evans Trio', 'image': '/api/people/img/Bill Evans Trio'},
    {'name': 'Thelonious Monk', 'image': '/api/people/img/Thelonious Monk'},
  ],
  'discography': [
    {
      'title': 'Kind of Blue',
      'cover': 'https://cdn.example/kob.jpg',
      'date': '1959-08-17',
      'type': 'album',
      'deezerId': 3001,
    },
    {
      'title': 'Bitches Brew',
      'cover': 'https://cdn.example/brew.jpg',
      'date': '1970-03-30',
      'type': 'album',
      'deezerId': 3002,
    },
    {
      'title': 'In a Silent Way',
      'cover': 'https://cdn.example/silent.jpg',
      'date': '1969-07-30',
      'type': 'album',
      'deezerId': 3003,
    },
  ],
};

final ArtistInfo fixtureArtistInfo = ArtistInfo.fromJson(fixtureArtistInfoJson);

final Map<String, dynamic> fixtureComposerInfoJson = {
  'fullName': 'Johann Sebastian Bach',
  'epoch': 'Baroque',
  'portrait': '/api/people/img/Johann Sebastian Bach',
  'born': '1685',
  'died': '1750',
  'bio': 'Organist and Kapellmeister whose keyboard cycles — the Well-Tempered '
      'Clavier, the Goldberg Variations — were written as much to teach as to '
      'be heard.',
  'url': 'https://en.wikipedia.org/wiki/Johann_Sebastian_Bach',
};

/// Both halves of `/api/lyrics/:id`: LRC for the synced view, plain text for
/// the fallback.
const Map<String, dynamic> fixtureLyricsJson = {
  'synced': '[00:00.40]So what\n'
      '[00:12.10]Two chords, sixteen bars apart\n'
      '[00:24.50]Paul Chambers asks\n'
      '[00:36.20]and the horns answer\n'
      '[00:48.00]D dorian, then E flat\n'
      '[01:02.30]nothing else moves\n',
  'plain': 'So what\nTwo chords, sixteen bars apart\nPaul Chambers asks\n'
      'and the horns answer\nD dorian, then E flat\nnothing else moves\n',
};

final Map<String, dynamic> fixtureGenreTreeJson = {
  'tree': {
    'Jazz': null,
    'Modal Jazz': 'Jazz',
    'Hard Bop': 'Jazz',
    'Classical': null,
    'Baroque': 'Classical',
  },
};

const Map<String, dynamic> fixtureEnrichStatusJson = {
  'phase': 'discographies',
  'done': 3,
  'total': 4,
  'running': true,
};

// ---------------------------------------------------------------------- eq

/// One OPRA product per vendor, each with a couple of community curves.
final Map<String, dynamic> fixtureOpraJson = {
  'products': [
    {
      'vendor': 'Sennheiser',
      'product': 'HD 600',
      'eqs': [
        {
          'name': 'Harman 2018',
          'author': 'oratory1990',
          'gainDb': -3.2,
          'bands': [
            {'type': 'low_shelf', 'frequency': 105, 'gainDb': 3.4, 'q': 0.7},
            {'type': 'peak_dip', 'frequency': 3200, 'gainDb': -2.1, 'q': 1.4},
            {'type': 'high_shelf', 'frequency': 9000, 'gainDb': 1.8, 'q': 0.7},
          ],
        },
        {
          'name': 'Diffuse field',
          'author': 'crinacle',
          'gainDb': -2.0,
          'bands': [
            {'type': 'peak_dip', 'frequency': 220, 'gainDb': -1.5, 'q': 1.0},
            {'type': 'peak_dip', 'frequency': 6000, 'gainDb': 2.4, 'q': 2.0},
          ],
        },
      ],
    },
    {
      'vendor': 'Sony',
      'product': 'MDR-7506',
      'eqs': [
        {
          'name': 'Harman 2018',
          'author': 'oratory1990',
          'gainDb': -5.4,
          'bands': [
            {'type': 'low_shelf', 'frequency': 90, 'gainDb': 4.8, 'q': 0.7},
            {'type': 'peak_dip', 'frequency': 8000, 'gainDb': -6.2, 'q': 3.0},
          ],
        },
      ],
    },
  ],
};

final List<OpraProduct> fixtureOpraProducts = [
  for (final p in fixtureOpraJson['products']! as List)
    OpraProduct.fromJson(p as Map<String, dynamic>),
];

final EqProfile fixtureEqProfile = fixtureOpraProducts.first.eqs.first;

final List<Profile> fixtureProfiles =
    fixtureProfileJson.map(Profile.fromJson).toList(growable: false);
