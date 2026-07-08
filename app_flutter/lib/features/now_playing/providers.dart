import 'dart:math';

import 'package:aria_api/aria_api.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/connection.dart';
import '../../core/player_providers.dart';
import '../../core/profiles_providers.dart';
import '../artist/providers.dart' show artistStatsProvider;
import '../home/home_providers.dart' show homeStatsProvider;
import '../library/library_providers.dart' show playCountsProvider;
import '../stats/stats_providers.dart' show statsProvider;
import 'lrc.dart';

// Providers that belong to now-playing but sit on top of core's player/queue
// state. The active profile id is core-owned (core/profiles_providers.dart).

const _prefsKeyVolume = 'aria.volume';

/// Ensures the libmpv engine is initialized exactly once and applies the
/// persisted volume and exclusive-access flag. Watched by [TransportBar];
/// initialize() is idempotent.
final playerInitProvider = FutureProvider<void>((ref) async {
  final player = ref.watch(ariaPlayerProvider);
  await player.initialize();
  player.setVolume(ref.read(volumeProvider));
  // Constructor already set the option pre-init; re-assert the persisted
  // flag as a property so the engine and the Settings switch always agree.
  player.setAudioExclusive(ref.read(audioExclusiveProvider));
});

/// Duration as reported by mpv once decode starts (core only exposes
/// position). Junk/zero values are filtered at the read site.
final playbackDurationProvider = StreamProvider<double>(
  (ref) => ref.watch(ariaPlayerProvider).duration,
);

/// Audio-output failures (engine already stopped playback). TransportBar
/// listens and shows a snackbar.
final audioErrorProvider = StreamProvider<String>(
  (ref) => ref.watch(ariaPlayerProvider).audioError,
);

/// Engine-reported duration when valid, else the track's tagged duration
/// (legacy curDur semantics: streams report junk durations).
final currentDurationProvider = Provider<double>((ref) {
  final d = ref.watch(playbackDurationProvider).value;
  if (d != null && d > 0) return d;
  return ref.watch(currentTrackProvider)?.duration ?? 0;
});

/// 0–100, persisted; legacy volume slider defaulted to 80.
final volumeProvider = NotifierProvider<VolumeNotifier, double>(
  VolumeNotifier.new,
);

class VolumeNotifier extends Notifier<double> {
  @override
  double build() =>
      ref.read(sharedPrefsProvider).getDouble(_prefsKeyVolume) ?? 80;

  void set(double v) {
    state = v.clamp(0, 100);
    ref.read(ariaPlayerProvider).setVolume(state);
    ref.read(sharedPrefsProvider).setDouble(_prefsKeyVolume, state);
  }
}

/// Legacy maybeLogPlay: report a play once per track, after 30s or half the
/// duration (whichever is less); best-effort, never for an empty profile.
/// Kept alive by TransportBar watching it.
final playReporterProvider = Provider<void>((ref) {
  // Per-track latch (legacy playLogged, inverted): id of the track that has
  // not been reported yet. Re-arms on every track change.
  String? unreportedId = ref.read(currentTrackProvider)?.id;

  ref.listen(currentTrackProvider, (prev, next) {
    if (prev?.id != next?.id) unreportedId = next?.id;
  });

  ref.listen(playbackPositionProvider, (_, pos) async {
    final t = ref.read(currentTrackProvider);
    final p = pos.value;
    if (t == null || p == null || unreportedId != t.id) return;
    final d = (t.duration ?? 0) > 0 ? t.duration! : 60.0;
    if (p < min(30.0, d / 2)) return;
    unreportedId = null; // latch before the awaits — one report per track
    try {
      // Core's reactive id: switching profiles re-attributes immediately
      // (legacy switchProfile). Wait for profiles once on cold start.
      await ref.read(profilesProvider.future);
      final profileId = ref.read(activeProfileIdProvider);
      if (profileId == null) {
        // No profile yet (cold start): re-arm so the play isn't lost — but
        // only if the track hasn't changed and re-armed the latch meanwhile.
        unreportedId ??= t.id;
        return;
      }
      await ref
          .read(apiClientProvider)
          .recordPlay(trackId: t.id, profileId: profileId);
      // The play is in the DB — refetch everything that renders play data,
      // so stats/most-played update live instead of on the next app start.
      ref.invalidate(statsProvider);
      ref.invalidate(homeStatsProvider);
      ref.invalidate(artistStatsProvider);
      ref.invalidate(playCountsProvider);
    } catch (_) {
      // best-effort, like legacy fetch(...).catch(() => {})
    }
  });
});

/// Lyrics per track, parsed once. Null = server has none (404).
final lyricsProvider = FutureProvider.family<LoadedLyrics?, String>((
  ref,
  trackId,
) async {
  final l = await ref.watch(apiClientProvider).lyrics(trackId);
  if (l == null) return null;
  return LoadedLyrics(
    lines: l.synced == null ? null : parseLrc(l.synced!),
    plain: l.plain,
  );
});

// ---- now-bar text, ported from legacy updateNowBar/updateNP --------------

bool _has(String? s) => s != null && s.isNotEmpty;

/// Classical work+movement shows the movement as the title.
String trackTitleLine(Track t) =>
    _has(t.work) && _has(t.movement) ? t.movement! : (t.title ?? '—');

/// "Composer: Work · Conductor" for classical, "Artist — Album" otherwise.
String trackSubLine(Track t) {
  if (_has(t.work) && _has(t.movement)) {
    final composer = _has(t.composer) ? '${t.composer}: ' : '';
    final conductor = _has(t.conductor) ? ' · ${t.conductor}' : '';
    return '$composer${t.work}$conductor';
  }
  final album = _has(t.album) ? ' — ${t.album}' : '';
  return '${t.artist ?? ''}$album';
}
