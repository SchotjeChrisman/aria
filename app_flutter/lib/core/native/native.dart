/// The app's single door to `dart:io`.
///
/// Every file that used to `import 'dart:io'` imports this instead, so the web
/// build gets in-memory stand-ins for the handful of io types the app touches
/// — File, Directory, Platform, Process, HttpClient — without a single change
/// to the logic that uses them.
///
/// On every native platform this is `dart:io` itself, re-exported: same
/// classes, same behaviour, nothing wrapped.
library;

export 'native_io.dart' if (dart.library.js_interop) 'native_web.dart';
