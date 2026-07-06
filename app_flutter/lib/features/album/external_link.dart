import 'dart:io';

/// Open a web link in the system browser. Desktop-only for now — GAP: add
/// url_launcher to the app pubspec for Android support (dep additions are
/// outside this feature's ownership).
Future<void> openExternal(String url) async {
  if (!url.startsWith('http://') && !url.startsWith('https://')) return;
  if (Platform.isLinux) {
    await Process.run('xdg-open', [url]);
  } else if (Platform.isMacOS) {
    await Process.run('open', [url]);
  }
}
