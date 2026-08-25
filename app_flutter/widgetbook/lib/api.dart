import 'package:aria_api/aria_api.dart';

/// The client every use case and provider in the catalogue talks to, pointed
/// at the loopback stub. Assigned once by `main()` before `runApp`.
late final AriaClient storybookClient;

/// Cover URL for a fixture album, built by the app's own URL builder so the
/// catalogue exercises the real `artUrl` shape (cache-bust token included)
/// rather than a hand-written path.
String artUrlFor(String albumId) =>
    storybookClient.artUrl(albumId, version: 1);
