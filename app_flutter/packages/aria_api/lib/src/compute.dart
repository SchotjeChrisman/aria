/// Off-thread execution, or the closest a platform can get to it.
library;

export 'compute_io.dart' if (dart.library.js_interop) 'compute_web.dart';
