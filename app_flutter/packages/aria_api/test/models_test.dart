import 'dart:convert';
import 'dart:io';

import 'package:aria_api/aria_api.dart';
import 'package:test/test.dart';

Map<String, dynamic> trackJson({
  String id = 'a1b2c3',
  String albumId = 'alb1',
  Map<String, dynamic> extra = const {},
}) =>
    {
      'id': id,
      'albumId': albumId,
      'addedAt': '2026-01-01T00:00:00.000Z',
      'title': 'Song',
      'artist': 'Artist',
      'albumArtist': 'Album Artist',
      'album': 'The Album',
      'year': 1975,
      'genre': 'Rock; Pop',
      'trackNo': 3,
      'discNo': 1,
      'duration': 241.5,
      'format': 'FLAC',
      'sampleRate': 96000,
      'bitsPerSample': 24,
      'channels': 2,
      'lossless': true,
      'hasArt': true,
      'composer': null,
      'conductor': null,
      'work': null,
      'movement': null,
      'mbAlbumId': null,
      'mbRecordingId': null,
      'mbAlbumArtistId': null,
      'releaseType': 'Album',
      'genres': ['Rock', 'Pop'],
      'tags': ['Favorites'],
      ...extra,
    };

void main() {
  group('Track', () {
    test('parses full shape incl. format info for bit-perfect badge', () {
      final t = Track.fromJson(trackJson());
      expect(t.id, 'a1b2c3');
      expect(t.albumId, 'alb1');
      expect(t.title, 'Song');
      expect(t.year, 1975);
      expect(t.duration, 241.5);
      expect(t.codec, 'FLAC');
      expect(t.format, 'FLAC');
      expect(t.sampleRate, 96000);
      expect(t.bits, 24);
      expect(t.bitsPerSample, 24);
      expect(t.channels, 2);
      expect(t.lossless, isTrue);
      expect(t.hasArt, isTrue);
      expect(t.releaseType, 'Album');
      expect(t.genres, ['Rock', 'Pop']);
      expect(t.tags, ['Favorites']);
    });

    test('tolerates minimal / null-heavy shape', () {
      final t = Track.fromJson({'id': 'x', 'albumId': 'y'});
      expect(t.title, isNull);
      expect(t.year, isNull);
      expect(t.duration, isNull);
      expect(t.sampleRate, isNull);
      expect(t.lossless, isFalse);
      expect(t.hasArt, isFalse);
      expect(t.genres, isEmpty);
      expect(t.tags, isEmpty);
      expect(t.performers, isEmpty);
    });

    test('duration arriving as int decodes as double', () {
      final t = Track.fromJson(trackJson(extra: {'duration': 200}));
      expect(t.duration, 200.0);
    });

    test('parses enrichment credits (performers, orchestra)', () {
      final t = Track.fromJson(trackJson(extra: {
        'orchestra': 'Berlin Phil',
        'conductor': 'Karajan',
        'performers': [
          {'name': 'A. Violinist', 'role': 'violin'},
          {'name': 'No Role'},
        ],
      }));
      expect(t.orchestra, 'Berlin Phil');
      expect(t.conductor, 'Karajan');
      expect(t.performers.length, 2);
      expect(t.performers.first.role, 'violin');
      expect(t.performers.last.role, isNull);
    });
  });

  group('Album.group', () {
    test('groups by albumId like the legacy client', () {
      final tracks = [
        Track.fromJson(
            trackJson(id: 't1', albumId: 'A', extra: {'trackNo': 2})),
        Track.fromJson(trackJson(id: 't2', albumId: 'B')),
        Track.fromJson(
            trackJson(id: 't3', albumId: 'A', extra: {'trackNo': 1})),
      ];
      final albums = Album.group(tracks);
      expect(albums.length, 2);
      // first-seen order preserved
      expect(albums[0].id, 'A');
      expect(albums[1].id, 'B');
      // sorted by trackNo within album
      expect(albums[0].tracks.map((t) => t.id), ['t3', 't1']);
    });

    test('sorts by discNo before trackNo, missing disc treated as 1', () {
      final tracks = [
        Track.fromJson(trackJson(
            id: 'd2t1', albumId: 'A', extra: {'discNo': 2, 'trackNo': 1})),
        Track.fromJson(trackJson(
            id: 'd1t9', albumId: 'A', extra: {'discNo': null, 'trackNo': 9})),
        Track.fromJson(trackJson(
            id: 'd1t2', albumId: 'A', extra: {'discNo': 1, 'trackNo': 2})),
      ];
      final a = Album.group(tracks).single;
      expect(a.tracks.map((t) => t.id), ['d1t2', 'd1t9', 'd2t1']);
    });

    test('falls back for missing album/albumArtist like app.js (|| semantics)',
        () {
      final t = Track.fromJson({
        'id': 't1',
        'albumId': 'A',
        'album': '',
        'albumArtist': null,
        'artist': 'Solo Guy',
      });
      final a = Album.group([t]).single;
      expect(a.title, 'Unknown Album');
      expect(a.albumArtist, 'Solo Guy');

      final b = Album.group([
        Track.fromJson({'id': 't2', 'albumId': 'B'})
      ]).single;
      expect(b.albumArtist, 'Unknown Artist');
    });

    test('album metadata comes from the first track seen', () {
      final tracks = [
        Track.fromJson(
            trackJson(id: 't1', albumId: 'A', extra: {'year': 1969})),
        Track.fromJson(
            trackJson(id: 't2', albumId: 'A', extra: {'year': 2001})),
      ];
      final a = Album.group(tracks).single;
      expect(a.year, 1969);
      expect(a.title, 'The Album');
    });

    test('derived album helpers', () {
      final a = Album.group([
        Track.fromJson(trackJson(id: 't1', albumId: 'A')),
        Track.fromJson(
            trackJson(id: 't2', albumId: 'A', extra: {'lossless': false})),
      ]).single;
      expect(a.hasArt, isTrue);
      expect(a.duration, closeTo(483.0, 0.001));
      expect(a.lossless, isFalse); // every track must be lossless
      expect(a.releaseType, 'Album');
    });
  });

  group('Tag', () {
    test('parses with items and parent', () {
      final t = Tag.fromJson({
        'id': 'u1',
        'name': 'Chill',
        'parent': 'u0',
        'items': [
          {'kind': 'track', 'key': 'abc'},
          {'kind': 'artist', 'key': 'Miles Davis'},
        ],
        'createdAt': '2026-01-01T00:00:00.000Z',
      });
      expect(t.name, 'Chill');
      expect(t.parent, 'u0');
      expect(t.items.length, 2);
      expect(t.items[1].kind, 'artist');
      expect(t.items[1].key, 'Miles Davis');
    });
  });

  group('Playlist', () {
    test('manual playlist keeps duplicate trackIds', () {
      final p = Playlist.fromJson({
        'id': 'p1',
        'profileId': 'default',
        'type': 'manual',
        'name': 'Mix',
        'trackIds': ['a', 'b', 'a'],
        'createdAt': 'x',
        'updatedAt': 'x',
      });
      expect(p.isSmart, isFalse);
      expect(p.trackIds, ['a', 'b', 'a']);
      expect(p.rules, isNull);
    });

    test('smart playlist parses rules', () {
      final p = Playlist.fromJson({
        'id': 'p2',
        'profileId': 'default',
        'type': 'smart',
        'name': 'Fresh FLAC',
        'rules': {
          'match': 'all',
          'rules': [
            {'field': 'lossless', 'op': 'is', 'value': true},
            {'field': 'addedDays', 'op': 'within', 'value': 30},
          ],
        },
      });
      expect(p.isSmart, isTrue);
      expect(p.trackIds, isNull);
      expect(p.rules!.match, 'all');
      expect(p.rules!.rules.length, 2);
      expect(p.rules!.rules[0].value, true);
      expect(p.rules!.rules[1].value, 30);
    });
  });

  group('Profile / Stats', () {
    test('profile parses', () {
      final p = Profile.fromJson(
          {'id': 'default', 'name': 'Listener', 'color': '#6d3fd2'});
      expect(p.color, '#6d3fd2');
    });

    test('stats parses full server shape', () {
      final s = Stats.fromJson({
        'profileId': 'default',
        'history': [
          {'id': 't1', 'at': '2026-07-01T10:00:00.000Z'}
        ],
        'totalPlays': 12,
        'totalSeconds': 3600,
        'week': {'plays': 3, 'seconds': 700},
        'month': {
          'plays': 9,
          'seconds': 2000,
          'topArtist': {'name': 'Nina Simone', 'count': 4},
        },
        'playCounts': {'t1': 5, 't2': 1},
        'uniqueTracks': 7,
        'topTracks': [
          {'id': 't1', 'count': 5, 'lastAt': '2026-07-01T10:00:00.000Z'}
        ],
        'topAlbums': [
          {'albumId': 'A', 'count': 6}
        ],
        'topArtists': [
          {'name': 'Nina Simone', 'count': 4}
        ],
        'recent': [
          {'id': 't1', 'at': '2026-07-01T10:00:00.000Z'}
        ],
      });
      expect(s.totalPlays, 12);
      expect(s.week.plays, 3);
      expect(s.month.topArtist!.name, 'Nina Simone');
      expect(s.playCounts, {'t1': 5, 't2': 1});
      expect(s.topTracks.single.count, 5);
      expect(s.topAlbums.single.albumId, 'A');
      expect(s.recent.single.id, 't1');
      expect(s.history.single.at, '2026-07-01T10:00:00.000Z');
    });

    test('stats without optional blocks', () {
      final s = Stats.fromJson({
        'profileId': null,
        'totalPlays': 0,
        'totalSeconds': 0,
        'week': {'plays': 0, 'seconds': 0},
        'month': {'plays': 0, 'seconds': 0, 'topArtist': null},
        'uniqueTracks': 0,
        'topTracks': [],
        'topAlbums': [],
        'topArtists': [],
        'recent': [],
        'history': [],
      });
      expect(s.playCounts, isNull);
      expect(s.month.topArtist, isNull);
    });
  });

  group('enrichment models', () {
    test('EnrichStatus', () {
      final e = EnrichStatus.fromJson(
          {'phase': 'discographies', 'done': 3, 'total': 40, 'running': true});
      expect(e.phase, 'discographies');
      expect(e.running, isTrue);
    });

    test('ArtistInfo', () {
      final a = ArtistInfo.fromJson({
        'type': 'Group',
        'area': 'United Kingdom',
        'born': '1962',
        'died': null,
        'bio': 'A band.',
        'url': 'https://en.wikipedia.org/wiki/X',
        'image': 'https://img',
        'imgSrc': 'wikipedia',
        'similar': [
          {'name': 'Other Band', 'image': null}
        ],
        'members': ['Alice', 'Bob'],
        'bands': [],
        'instruments': ['guitar', 'voice'],
        'discography': [
          {'title': 'LP', 'cover': null, 'date': '2026-05-01', 'type': 'album'}
        ],
      });
      expect(a.type, 'Group');
      expect(a.members, ['Alice', 'Bob']);
      expect(a.similar.single.name, 'Other Band');
      expect(a.discography.single.date, '2026-05-01');
      expect(a.instruments, ['guitar', 'voice']);
      // absent for every entry cached before the Wikidata pass existed
      expect(ArtistInfo.fromJson({'type': 'Person'}).instruments, isEmpty);
    });

    test('ComposerInfo / AlbumInfo / Lyrics', () {
      final c = ComposerInfo.fromJson({
        'fullName': 'Johann Sebastian Bach',
        'epoch': 'Baroque',
        'portrait': 'https://p',
        'born': '1685',
        'died': '1750',
        'bio': 'Composer.',
      });
      expect(c.epoch, 'Baroque');

      final i = AlbumInfo.fromJson({
        'label': 'Blue Note',
        'date': '1957-03-01',
        'country': 'US',
        'catno': 'BLP 1595',
        'mbType': 'Album',
        'mbSecondary': ['Live'],
        'blurb': 'Classic.',
        'url': 'https://w',
      });
      expect(i.mbSecondary, ['Live']);
      expect(i.catno, 'BLP 1595');
      // null without a server DISCOGS_TOKEN, which must not break decoding
      expect(AlbumInfo.fromJson({'label': 'X'}).catno, isNull);

      final l = Lyrics.fromJson({'synced': '[00:01.00] hi', 'plain': 'hi'});
      expect(l.synced, startsWith('[00:01.00]'));
    });

    test('candidates and new releases', () {
      final ac = ArtistCandidate.fromJson({
        'mbid': '11111111-2222-3333-4444-555555555555',
        'name': 'X',
        'type': 'Person',
        'area': null,
        'disambiguation': 'the singer',
        'score': 100,
      });
      expect(ac.score, 100);

      final alc = AlbumCandidate.fromJson({
        'mbid': '11111111-2222-3333-4444-555555555555',
        'title': 'LP',
        'artist': 'X',
        'date': '1999',
        'country': 'US',
        'tracks': 12,
        'score': 98,
      });
      expect(alc.trackCount, 12);

      final nr = NewRelease.fromJson({
        'artist': 'X',
        'title': 'New LP',
        'cover': null,
        'date': '2026-06-20',
        'type': 'album',
      });
      expect(nr.date, '2026-06-20');
      // Discographies cached before the id was kept simply omit it.
      expect(nr.deezerId, isNull);
    });

    test('unowned albums: ExtAlbum / ListenLaterAlbum', () {
      final a = ExtAlbum.fromJson({
        'id': 'rg:aa997ea0-2936-40bd-884d-3af8a0e064dc',
        'rgMbid': 'aa997ea0-2936-40bd-884d-3af8a0e064dc',
        'upc': '886443927087',
        'deezerId': 6575789,
        'artist': 'Daft Punk',
        'title': 'Random Access Memories',
        'cover': 'https://cdn/x.jpg',
        'date': '2013-05-17',
        'type': 'album',
        'label': 'Columbia',
        'link': 'https://www.deezer.com/album/6575789',
        'tracks': [
          {'title': 'Give Life Back to Music', 'duration': 274, 'disc': 1,
              'number': 1},
        ],
        'releases': ['5000a285-b67e-4cfc-b54b-2b98f1810d2e'],
      });
      expect(a.id, startsWith('rg:'));
      expect(a.upc, '886443927087');
      expect(a.tracks.single.duration, 274);

      // MusicBrainz lags new releases, so the Deezer-keyed shape must parse
      // just as happily — including a null cover and no track listing.
      final pending = ExtAlbum.fromJson({
        'id': 'dz:650278821',
        'deezerId': 650278821,
        'artist': 'Coldplay',
        'title': 'Moon Music',
        'cover': null,
        'date': '2024-10-04',
        'type': 'album',
      });
      expect(pending.id, 'dz:650278821');
      expect(pending.upc, isNull);
      expect(pending.tracks, isEmpty);

      final e = ListenLaterAlbum.fromJson({
        'id': 'rg:1',
        'artist': 'Coldplay',
        'title': 'Moon Music',
        'cover': null,
        'date': null,
        'type': 'album',
        'upc': null,
        'deezerId': null,
        'addedAt': '2026-07-28T10:00:00.000Z',
      });
      expect(e.id, 'rg:1');
      expect(e.date, isNull);
    });
  });

  group('misc models', () {
    test('ServerStatus / Settings / RadioStation / EditState / GenreTree', () {
      final s = ServerStatus.fromJson(
          {'tracks': 1234, 'musicDir': '/music', 'version': '0.1.0'});
      expect(s.tracks, 1234);

      expect(
          Settings.fromJson({'listenbrainzToken': ''}).listenbrainzToken, '');

      final r = RadioStation.fromJson({
        'id': 'rp-main',
        'name': 'Radio Paradise Main (FLAC)',
        'url': 'https://stream.radioparadise.com/flacm',
        'genre': 'Eclectic',
        'builtin': true,
      });
      expect(r.builtin, isTrue);

      // No `source` key at all: an older server, and the editor must simply
      // not draw the provenance line rather than blow up.
      final e = EditState.fromJson({
        'original': {'title': 'Old', 'year': 1999},
        'overrides': {'title': 'New'},
      });
      expect(e.original['year'], 1999);
      expect(e.overrides['title'], 'New');
      expect(e.source, isNull);

      // Explicit null (never matched / under review / marked local).
      expect(
        EditState.fromJson({'original': {}, 'overrides': {}, 'source': null})
            .source,
        isNull,
      );

      final matched = EditState.fromJson({
        'original': {'album': 'MB Album'},
        'overrides': {},
        'source': {
          'kind': 'musicbrainz',
          'releaseMbid': 'ec17a59b-6ca3-4817-9ca9-67b137550819',
          'releaseTitle': 'Barber, Bruch: Violin Concertos',
          'pinned': false,
        },
      });
      expect(matched.source?['releaseTitle'], 'Barber, Bruch: Violin Concertos');
      expect(matched.source?['pinned'], isFalse);

      final g = GenreTree.fromJson({
        'tree': {'Blues': null, 'Blues Rock': 'Blues', 'Rock': null}
      });
      expect(g.topLevel, containsAll(['Blues', 'Rock']));
      expect(g.childrenOf('Blues'), ['Blues Rock']);
    });
  });

  test('round-trips through jsonEncode/jsonDecode', () {
    final decoded = jsonDecode(jsonEncode(trackJson())) as Map<String, dynamic>;
    expect(Track.fromJson(decoded).sampleRate, 96000);
  });

  // The whole review feature rests on these two models parsing what the server
  // actually sends. match_review_fixture.json is not invented — it is a
  // verbatim capture of GET /api/match/review from a 7572-track library, so
  // every shape below is one the app will really meet.
  group('MatchDecision', () {
    List<MatchDecision> fixture() => (jsonDecode(
                File('test/match_review_fixture.json').readAsStringSync())
            as List)
        .map((j) => MatchDecision.fromJson(j as Map<String, dynamic>))
        .toList();

    test('parses every decision in a real review queue', () {
      final ds = fixture();
      expect(ds, hasLength(69));
      // 41 local + 28 review, and nothing else: the endpoint is defined as
      // "not matched", so a `matched` row here would mean the server changed
      // its contract underneath us.
      expect(ds.where((d) => d.state == 'review'), hasLength(28));
      expect(ds.where((d) => d.state == 'local'), hasLength(41));
      expect(ds.where((d) => d.state == 'matched'), isEmpty);
    });

    test('a separation of zero survives arriving as a bare JSON int', () {
      // Go marshals float64(0) as `0`, not `0.0`. A cast to double throws on
      // that, which would take the whole screen down over one album in 69 —
      // and this library contains exactly one such row.
      final raw = jsonDecode(
          File('test/match_review_fixture.json').readAsStringSync()) as List;
      final ints = raw.where((j) => (j as Map)['separation'] is int).toList();
      expect(ints, isNotEmpty, reason: 'fixture must still cover the int case');

      final d = MatchDecision.fromJson(ints.first as Map<String, dynamic>);
      expect(d.separation, 0.0);
    });

    test('an unscored album keeps a null distance, never zero', () {
      // 0 is the BEST possible distance. Coercing "never scored" to 0 would
      // present the least certain albums in the library as perfect matches —
      // the same inversion that made unanalysed tracks the quietest ones.
      final unscored = fixture().where((d) => d.distance == null);
      expect(unscored, hasLength(40));
      for (final d in unscored) {
        expect(d.reason, 'no-candidates');
        expect(d.candidates, isEmpty);
        expect(d.hasNoCandidates, isTrue);
      }
    });

    test('the candidate-less majority is the dominant case, not an edge', () {
      // 58% of the queue. A detail view that only knows how to draw a picker
      // has nothing to say about most of its own contents.
      final ds = fixture();
      expect(ds.where((d) => d.hasNoCandidates).length, greaterThan(ds.length / 2));
    });

    test('scored candidates carry their breakdown', () {
      final withCandidates =
          fixture().firstWhere((d) => d.candidates.isNotEmpty);
      final c = withCandidates.candidates.first;
      expect(c.mbid, isNotEmpty);
      expect(c.distance, isNotNull);
      expect(c.why, isNotEmpty);
      // The breakdown is what turns "unsure" into "unsure because the artist
      // credit does not match".
      expect(c.why.keys, contains('artist'));
      expect(c.why.values.every((v) => v >= 0), isTrue);
    });

    test('no decision in the queue claims an accepted release', () {
      // These are by definition the albums with no accepted release, so no UI
      // element may assume releaseMbid is present.
      for (final d in fixture()) {
        expect(d.releaseMbid, isNull);
        expect(d.releaseGroupMbid, isNull);
      }
    });

    test('survives candidates arriving as literal null', () {
      // candidates is a json.RawMessage server-side: unset marshals to `null`,
      // not to `[]`.
      final d = MatchDecision.fromJson({
        'albumId': 'a',
        'state': 'local',
        'reason': 'no-candidates',
        'candidates': null,
      });
      expect(d.candidates, isEmpty);
      expect(d.distance, isNull);
      expect(d.pinned, isFalse);
    });

    test('an unknown why component is kept, a junk value is dropped', () {
      // The server may add a distance component without an app release; an
      // unknown key must still render. A value that will not coerce is dropped
      // rather than becoming 0, which would read as "this component is perfect".
      final c = MatchCandidate.fromJson({
        'mbid': 'm',
        'why': {'artist': 1, 'somethingNew': 0.5, 'broken': 'nope'},
      });
      expect(c.why['artist'], 1.0);
      expect(c.why['somethingNew'], 0.5);
      expect(c.why.containsKey('broken'), isFalse);
    });
  });
}
