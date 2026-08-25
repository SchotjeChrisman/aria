/// Web: there is nothing to start. `tool/serve.dart` is already serving both
/// the catalogue and `/api/*` from this origin, which is the whole reason the
/// two share a port — a second server would mean CORS headers and a second
/// command to remember.
///
/// fake_server.dart is deliberately not imported here: it is a dart:io
/// HttpServer, and importing it would drag dart:io into the web bundle.
Future<String> startStubBackend() async => Uri.base.origin;
