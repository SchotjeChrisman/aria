import 'dart:convert';
import 'dart:io';

import 'package:aria_api/aria_api.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/connection.dart';
import '../../core/library_providers.dart';
import '../../core/profiles_providers.dart';

/// Core client/caches under this feature's historical names — one HTTP
/// client and one /api/tracks fetch shared app-wide.
final artistApiProvider = apiClientProvider;
final artistTracksProvider = libraryTracksProvider;

final artistAlbumsProvider = FutureProvider<List<Album>>((ref) async {
  final tracks = await ref.watch(artistTracksProvider.future);
  return Album.group(tracks);
});

/// Enriched person/band info; unknown names are researched on demand
/// server-side (a few seconds the first time). null = nothing found.
final artistInfoProvider = FutureProvider.family<ArtistInfo?, String>(
  (ref, name) => ref.watch(artistApiProvider).artist(name),
);

final composerInfoProvider = FutureProvider.family<ComposerInfo?, String>(
  (ref, name) => ref.watch(artistApiProvider).composer(name),
);

/// name -> portrait URL for avatars.
final artistPeopleProvider = peopleProvider;

/// Play stats for the top-tracks section, scoped to the active profile and
/// re-fetched on profile switch (legacy: stats are private per profile).
final artistStatsProvider = FutureProvider<Stats>((ref) async {
  await ref.watch(profilesProvider.future);
  final pid = ref.watch(activeProfileIdProvider);
  return ref.watch(artistApiProvider).stats(profileId: pid);
});

/// Full-article plain text straight from Wikipedia (legacy fetchFullBio),
/// keyed by page URL. The server only caches the summary; the full article is
/// fetched client-side. Uses dart:io directly to avoid new pubspec deps.
final fullBioProvider = FutureProvider.family<String?, String>((
  ref,
  url,
) async {
  final path = Uri.parse(url).path;
  final idx = path.indexOf('/wiki/');
  if (idx < 0) return null;
  final title = Uri.decodeComponent(path.substring(idx + 6));
  if (title.isEmpty) return null;
  final api = Uri.https('en.wikipedia.org', '/w/api.php', {
    'action': 'query',
    'prop': 'extracts',
    'explaintext': '1',
    'redirects': '1',
    'format': 'json',
    'titles': title,
  });
  final client = HttpClient();
  try {
    final req = await client.getUrl(api);
    final res = await req.close();
    if (res.statusCode != 200) return null;
    final body = await res.transform(utf8.decoder).join();
    final j = jsonDecode(body);
    final query = j is Map ? j['query'] : null;
    final pages = query is Map ? query['pages'] : null;
    if (pages is! Map || pages.isEmpty) return null;
    final page = pages.values.first;
    return page is Map ? page['extract'] as String? : null;
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
});
