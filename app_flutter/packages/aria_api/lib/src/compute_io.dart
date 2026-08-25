import 'dart:isolate';

/// Runs [fn] on a background isolate. A 100k-row track payload must not parse
/// on the UI isolate.
Future<T> runOffThread<T>(T Function() fn) => Isolate.run(fn);
