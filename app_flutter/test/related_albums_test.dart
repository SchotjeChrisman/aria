import 'package:aria/features/album/providers.dart';
import 'package:aria_api/aria_api.dart';
import 'package:flutter_test/flutter_test.dart';

Album album(
  String id,
  String artist,
  List<String> genres, {
  int? year,
  String? title,
}) => Album(
  id: id,
  title: title ?? id,
  albumArtist: artist,
  year: year,
  tracks: [Track(id: '$id-1', albumId: id, genres: genres, year: year)],
);

void main() {
  group('relatedAlbums', () {
    final target = album('t', 'Miles Davis', ['Jazz', 'Bebop'], year: 1959);

    test('excludes self, same artist (case-insensitive), no shared genre', () {
      final out = relatedAlbums(target, [
        target,
        album('a', 'MILES DAVIS', ['Jazz'], year: 1959),
        album('b', 'Slayer', ['Metal'], year: 1959),
        album('c', 'John Coltrane', ['Jazz'], year: 1960),
      ]);
      expect(out.map((a) => a.id), ['c']);
    });

    test('orders by shared genres then year proximity, ties by title', () {
      final out = relatedAlbums(target, [
        // 1 genre, close year: 3 + 2 = 5
        album('a', 'X', ['Jazz'], year: 1960, title: 'A'),
        // 2 genres, far year: 6 + 0 = 6
        album('b', 'Y', ['Jazz', 'Bebop'], year: 1990, title: 'B'),
        // 1 genre, no year: 3
        album('c', 'Z', ['Bebop'], title: 'C'),
        // 1 genre, close year, tie with a — title sorts first
        album('d', 'W', ['Jazz'], year: 1958, title: '0'),
      ]);
      expect(out.map((a) => a.id), ['b', 'd', 'a', 'c']);
    });

    test('caps at 12', () {
      final out = relatedAlbums(target, [
        for (var i = 0; i < 20; i++) album('a$i', 'X$i', ['Jazz']),
      ]);
      expect(out.length, 12);
    });
  });
}
