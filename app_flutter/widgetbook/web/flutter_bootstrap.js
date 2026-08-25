{{flutter_js}}
{{flutter_build_config}}

// Overrides Flutter's default, which fetches CanvasKit from
// https://www.gstatic.com/flutter-canvaskit. `flutter build web` already
// writes a copy into build/web/canvaskit/, and tool/serve.dart serves it from
// the same origin — so the catalogue loads with no network access at all.
_flutter.loader.load({
  config: {
    canvasKitBaseUrl: "canvaskit/",
  },
  serviceWorkerSettings: {
    serviceWorkerVersion: {{flutter_service_worker_version}},
  },
});
