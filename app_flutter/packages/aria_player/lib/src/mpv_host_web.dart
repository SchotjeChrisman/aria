import 'mpv_raw.dart';

/// Web twin of mpv_host_io.dart. There is no libmpv in a browser, so the
/// factory throws the same exception a missing library throws natively —
/// [AriaPlayer.initialize] already catches it and reports
/// `isAvailable == false`, so every command becomes a no-op rather than a
/// crash. Nothing else in the package needs to know.
MpvRaw defaultRawFactory() => throw PlayerUnavailableException(
      'libmpv is unavailable on the web — audio playback is native only.',
    );

bool get isAndroidHost => false;
