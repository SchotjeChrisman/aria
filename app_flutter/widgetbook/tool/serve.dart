import 'dart:io';

import 'package:aria_widgetbook/fake_server.dart';

/// Serves the built catalogue and its stub data on one port, on every
/// interface.
///
///   flutter build web
///   dart run tool/serve.dart [port]
///
/// One origin for both means no CORS headers and one URL to open. The web
/// build finds the API automatically — stub_backend_web.dart uses
/// `Uri.base.origin`, so whichever address a phone or tablet used to load the
/// page is the same address its API calls go back to. Nothing to configure.
///
/// Binding 0.0.0.0 puts this on the local network. Everything it serves is the
/// component catalogue and its fixtures — there is no library, no credentials
/// and no real server behind it.
Future<void> main(List<String> args) async {
  final port = args.isEmpty ? 8080 : int.parse(args.first);
  final webRoot = Directory('build/web');

  if (!webRoot.existsSync()) {
    stderr.writeln('No build/web — run `flutter build web` first.');
    exit(1);
  }

  final server = await FakeAriaServer.start(
    port: port,
    webRoot: webRoot,
    hostname: InternetAddress.anyIPv4,
  );

  stdout.writeln('Aria design system catalogue');
  stdout.writeln('  http://localhost:$port          (this machine)');
  for (final (name, address) in await _lanAddresses()) {
    final url = 'http://$address:$port';
    stdout.writeln('  ${url.padRight(30)}($name)');
  }
  stdout.writeln('  stub API and cover art on the same origin under /api/');
  stdout.writeln('Ctrl-C to stop.');

  await ProcessSignal.sigint.watch().first;
  await server.close();
}

/// Every non-loopback IPv4 address, so the address to type into a phone is on
/// screen rather than left to `ifconfig`.
Future<List<(String, String)>> _lanAddresses() async {
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
    includeLoopback: false,
    includeLinkLocal: false,
  );
  return [
    for (final i in interfaces)
      for (final a in i.addresses) (i.name, a.address),
  ];
}
