import 'dart:io';

import 'mpv_ffi.dart';
import 'mpv_raw.dart';

/// Native host bindings for [AriaPlayer]. The web twin of this file
/// (mpv_host_web.dart) reports no engine, which is why player.dart imports
/// this pair conditionally instead of reaching for dart:io and dart:ffi
/// directly — those two libraries are the whole reason the package could not
/// be compiled for the web.
MpvRaw defaultRawFactory() => FfiMpvRaw.load();

/// True on an Android host. Gates the two places mpv must behave differently
/// there (audio-exclusive, and the pre-initialize option set).
bool get isAndroidHost => Platform.isAndroid;
