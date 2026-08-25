import 'fake_server.dart';

/// Native: boot the stub in-process and hand back its loopback URL.
Future<String> startStubBackend() async =>
    (await FakeAriaServer.start()).baseUrl;
