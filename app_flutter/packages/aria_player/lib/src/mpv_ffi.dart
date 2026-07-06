import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'mpv_constants.dart';
import 'mpv_raw.dart';

// -------------------------------------------------------------- C structs

final class _MpvEvent extends Struct {
  @Int32()
  external int eventId;

  @Int32()
  external int error;

  @Uint64()
  external int replyUserdata;

  external Pointer<Void> data;
}

final class _MpvEventProperty extends Struct {
  external Pointer<Utf8> name;

  @Int32()
  external int format;

  external Pointer<Void> data;
}

// mpv_event_end_file: only `reason` (first int) is read — later fields were
// added across API versions and reading them is not layout-safe.

// ------------------------------------------------------------- typedefs

typedef _CreateC = Pointer<Void> Function();
typedef _CreateD = Pointer<Void> Function();
typedef _InitC = Int32 Function(Pointer<Void>);
typedef _InitD = int Function(Pointer<Void>);
typedef _SetOptionStringC =
    Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>);
typedef _SetOptionStringD =
    int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>);
typedef _SetPropertyC =
    Int32 Function(Pointer<Void>, Pointer<Utf8>, Int32, Pointer<Void>);
typedef _SetPropertyD =
    int Function(Pointer<Void>, Pointer<Utf8>, int, Pointer<Void>);
typedef _CommandC = Int32 Function(Pointer<Void>, Pointer<Pointer<Utf8>>);
typedef _CommandD = int Function(Pointer<Void>, Pointer<Pointer<Utf8>>);
typedef _ObservePropertyC =
    Int32 Function(Pointer<Void>, Uint64, Pointer<Utf8>, Int32);
typedef _ObservePropertyD =
    int Function(Pointer<Void>, int, Pointer<Utf8>, int);
typedef _WaitEventC = Pointer<_MpvEvent> Function(Pointer<Void>, Double);
typedef _WaitEventD = Pointer<_MpvEvent> Function(Pointer<Void>, double);
typedef _TerminateDestroyC = Void Function(Pointer<Void>);
typedef _TerminateDestroyD = void Function(Pointer<Void>);
typedef _SetLocaleC = Pointer<Utf8> Function(Int32, Pointer<Utf8>);
typedef _SetLocaleD = Pointer<Utf8> Function(int, Pointer<Utf8>);

// --------------------------------------------------------------- loader

String _dirname(String path) => File(path).parent.path;

List<String> libmpvCandidates() {
  final sep = Platform.pathSeparator;
  final exeDir = _dirname(Platform.resolvedExecutable);
  final override = Platform.environment['MPV_LIBRARY_PATH'];
  return <String>[
    if (override != null && override.isNotEmpty) override,
    // Android: media_kit_libs_android_audio ships libmpv.so in the APK's
    // jniLibs, resolved by the system linker by soname alone.
    if (Platform.isAndroid) 'libmpv.so',
    if (Platform.isLinux) ...[
      // media_kit_libs_linux bundles libmpv into the app bundle's lib dir.
      '$exeDir${sep}lib${sep}libmpv.so',
      // System fallbacks.
      'libmpv.so.2',
      'libmpv.so.1',
      'libmpv.so',
    ],
    if (Platform.isMacOS) ...[
      // media_kit_libs_macos_audio ships Mpv.framework inside the bundle;
      // executable lives at Contents/MacOS/, frameworks at Contents/Frameworks/.
      '${_dirname(exeDir)}${sep}Frameworks${sep}Mpv.framework${sep}Versions${sep}A${sep}Mpv',
      '${_dirname(exeDir)}${sep}Frameworks${sep}Mpv.framework${sep}Mpv',
      'Mpv.framework/Mpv',
      'libmpv.dylib',
      '/opt/homebrew/lib/libmpv.dylib',
      '/usr/local/lib/libmpv.dylib',
    ],
  ];
}

/// dlopen libmpv from the first working candidate.
/// Throws [PlayerUnavailableException] — never crashes the app — when no
/// candidate loads (e.g. desktop host without libmpv and no bundle).
DynamicLibrary loadLibmpvLibrary() {
  final candidates = libmpvCandidates();
  for (final candidate in candidates) {
    try {
      return DynamicLibrary.open(candidate);
    } catch (_) {
      // Try the next candidate.
    }
  }
  throw PlayerUnavailableException(
    Platform.isLinux
        // Bundled on macOS/Android; Linux gets it from the distro (README).
        ? 'libmpv not found — install it to enable playback '
            '(Fedora: sudo dnf install mpv-libs · Debian/Ubuntu: '
            'sudo apt install libmpv2), then restart Aria.'
        : 'libmpv could not be loaded; playback is disabled. '
            'Tried: ${candidates.join(', ')}',
  );
}

/// libmpv refuses to work under a non-"C" LC_NUMERIC (mpv_create fails or
/// misparses floats). Flutter may have set the user locale, so force it back.
void _forceNumericLocaleC() {
  try {
    final setlocale = DynamicLibrary.process()
        .lookupFunction<_SetLocaleC, _SetLocaleD>('setlocale');
    // glibc/bionic: LC_NUMERIC == 1; BSD libc (macOS): LC_NUMERIC == 4.
    final lcNumeric = Platform.isMacOS ? 4 : 1;
    final c = 'C'.toNativeUtf8();
    setlocale(lcNumeric, c);
    calloc.free(c);
  } catch (_) {
    // Best effort; mpv_create will surface any real problem.
  }
}

// ---------------------------------------------------------- implementation

/// Real libmpv binding. Constructed via [FfiMpvRaw.load]; everything above
/// this class talks to [MpvRaw] only.
class FfiMpvRaw implements MpvRaw {
  FfiMpvRaw(DynamicLibrary lib)
    : _create = lib.lookupFunction<_CreateC, _CreateD>('mpv_create'),
      _initialize = lib.lookupFunction<_InitC, _InitD>('mpv_initialize'),
      _setOptionString = lib
          .lookupFunction<_SetOptionStringC, _SetOptionStringD>(
            'mpv_set_option_string',
          ),
      _setProperty = lib.lookupFunction<_SetPropertyC, _SetPropertyD>(
        'mpv_set_property',
      ),
      _command = lib.lookupFunction<_CommandC, _CommandD>('mpv_command'),
      _observeProperty = lib
          .lookupFunction<_ObservePropertyC, _ObservePropertyD>(
            'mpv_observe_property',
          ),
      _waitEvent = lib.lookupFunction<_WaitEventC, _WaitEventD>(
        'mpv_wait_event',
      ),
      _terminateDestroy = lib
          .lookupFunction<_TerminateDestroyC, _TerminateDestroyD>(
            'mpv_terminate_destroy',
          );

  static FfiMpvRaw load() => FfiMpvRaw(loadLibmpvLibrary());

  final _CreateD _create;
  final _InitD _initialize;
  final _SetOptionStringD _setOptionString;
  final _SetPropertyD _setProperty;
  final _CommandD _command;
  final _ObservePropertyD _observeProperty;
  final _WaitEventD _waitEvent;
  final _TerminateDestroyD _terminateDestroy;

  Pointer<Void> _h(int handle) => Pointer<Void>.fromAddress(handle);

  @override
  int create() {
    _forceNumericLocaleC();
    return _create().address;
  }

  @override
  int initialize(int handle) => _initialize(_h(handle));

  @override
  int setOptionString(int handle, String name, String value) {
    final n = name.toNativeUtf8();
    final v = value.toNativeUtf8();
    try {
      return _setOptionString(_h(handle), n, v);
    } finally {
      calloc.free(n);
      calloc.free(v);
    }
  }

  @override
  int setPropertyString(int handle, String name, String value) {
    final n = name.toNativeUtf8();
    final v = value.toNativeUtf8();
    // MPV_FORMAT_STRING passes a char** as data.
    final vp = calloc<Pointer<Utf8>>()..value = v;
    try {
      return _setProperty(_h(handle), n, MpvFormat.string, vp.cast());
    } finally {
      calloc.free(vp);
      calloc.free(v);
      calloc.free(n);
    }
  }

  @override
  int setPropertyDouble(int handle, String name, double value) {
    final n = name.toNativeUtf8();
    final vp = calloc<Double>()..value = value;
    try {
      return _setProperty(_h(handle), n, MpvFormat.doubleValue, vp.cast());
    } finally {
      calloc.free(vp);
      calloc.free(n);
    }
  }

  @override
  int command(int handle, List<String> args) {
    final array = calloc<Pointer<Utf8>>(args.length + 1);
    final strings = <Pointer<Utf8>>[];
    try {
      for (var i = 0; i < args.length; i++) {
        final s = args[i].toNativeUtf8();
        strings.add(s);
        array[i] = s;
      }
      array[args.length] = nullptr;
      return _command(_h(handle), array);
    } finally {
      for (final s in strings) {
        calloc.free(s);
      }
      calloc.free(array);
    }
  }

  @override
  int observeProperty(int handle, int replyUserdata, String name, int format) {
    final n = name.toNativeUtf8();
    try {
      return _observeProperty(_h(handle), replyUserdata, n, format);
    } finally {
      calloc.free(n);
    }
  }

  @override
  MpvEventData? waitEvent(int handle, double timeoutSeconds) {
    final evPtr = _waitEvent(_h(handle), timeoutSeconds);
    if (evPtr == nullptr) return null;
    final ev = evPtr.ref;
    if (ev.eventId == MpvEventId.none) return null;

    switch (ev.eventId) {
      case MpvEventId.propertyChange:
        final prop = ev.data.cast<_MpvEventProperty>().ref;
        final name = prop.name == nullptr ? '' : prop.name.toDartString();
        Object? value;
        switch (prop.format) {
          case MpvFormat.flag:
            value = prop.data.cast<Int32>().value != 0;
          case MpvFormat.int64:
            value = prop.data.cast<Int64>().value;
          case MpvFormat.doubleValue:
            value = prop.data.cast<Double>().value;
          case MpvFormat.string:
            final sp = prop.data.cast<Pointer<Utf8>>().value;
            value = sp == nullptr ? null : sp.toDartString();
          default:
            value = null; // MPV_FORMAT_NONE: property became unavailable.
        }
        return MpvEventData(
          ev.eventId,
          replyUserdata: ev.replyUserdata,
          propertyName: name,
          propertyValue: value,
        );
      case MpvEventId.endFile:
        final reason = ev.data == nullptr
            ? MpvEndFileReason.eof
            : ev.data.cast<Int32>().value;
        return MpvEventData(ev.eventId, endFileReason: reason);
      default:
        return MpvEventData(ev.eventId, replyUserdata: ev.replyUserdata);
    }
  }

  @override
  void terminateDestroy(int handle) => _terminateDestroy(_h(handle));
}
