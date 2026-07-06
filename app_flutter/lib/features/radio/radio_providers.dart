import 'package:aria_api/aria_api.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/connection.dart';

// Radio playback state lives in core so the transport bar can show the
// station (name / LIVE / stream signal path) and pause/stop it.
export '../../core/player_providers.dart'
    show RadioPlaybackNotifier, radioPlaybackProvider;

/// Built-in stations first, then user stations (server order).
final radioStationsProvider = FutureProvider<List<RadioStation>>(
  (ref) => ref.watch(apiClientProvider).radioStations(),
);

/// Verbs for user stations; refresh the list on success.
final radioActionsProvider = Provider<RadioActions>(RadioActions.new);

class RadioActions {
  RadioActions(this._ref);

  final Ref _ref;

  Future<void> add({
    required String name,
    required String url,
    String? genre,
  }) async {
    await _ref
        .read(apiClientProvider)
        .addRadioStation(
          name: name,
          url: url,
          genre: (genre == null || genre.isEmpty) ? null : genre,
        );
    _ref.invalidate(radioStationsProvider);
  }

  Future<void> delete(String id) async {
    await _ref.read(apiClientProvider).deleteRadioStation(id);
    _ref.invalidate(radioStationsProvider);
  }
}
