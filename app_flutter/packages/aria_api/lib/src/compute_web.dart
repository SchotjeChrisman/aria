/// Web twin of compute_io.dart. `dart:isolate` does not exist in a browser,
/// so the work runs inline. That blocks the single JS thread for the duration
/// of the parse, which is the honest trade: the web target exists for the
/// component catalogue, not for a 100k-track library.
Future<T> runOffThread<T>(T Function() fn) async => fn();
