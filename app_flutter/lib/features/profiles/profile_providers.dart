/// Profile state lives in core (lib/core/profiles_providers.dart) so plays,
/// playlists and stats all re-scope the moment the user switches profiles —
/// legacy switchProfile() semantics. This shim keeps feature-local imports
/// working.
library;

export '../../core/profiles_providers.dart';
