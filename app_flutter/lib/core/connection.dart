import 'package:aria_api/aria_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'theme.dart';

const kDefaultServerUrl = 'http://localhost:3000';
const _prefsKeyServerUrl = 'aria.serverUrl';

/// Overridden with a real instance in main() before runApp.
final sharedPrefsProvider = Provider<SharedPreferences>(
  (ref) => throw UnimplementedError('overridden in main()'),
);

/// Persisted server base URL. null = first run — the router redirects to /setup.
final serverUrlProvider = NotifierProvider<ServerUrlNotifier, String?>(
  ServerUrlNotifier.new,
);

class ServerUrlNotifier extends Notifier<String?> {
  @override
  String? build() =>
      ref.read(sharedPrefsProvider).getString(_prefsKeyServerUrl);

  Future<void> set(String url) async {
    final normalized = normalizeServerUrl(url);
    state = normalized;
    await ref
        .read(sharedPrefsProvider)
        .setString(_prefsKeyServerUrl, normalized);
  }
}

/// "192.168.1.5:3000" -> "http://192.168.1.5:3000", strips trailing slashes.
String normalizeServerUrl(String raw) {
  var url = raw.trim().replaceAll(RegExp(r'/+$'), '');
  if (!url.startsWith(RegExp(r'https?://'))) url = 'http://$url';
  return url;
}

/// Throws until a server URL is configured; the /setup redirect guarantees
/// nothing watches this before then.
final apiClientProvider = Provider<AriaClient>((ref) {
  final url = ref.watch(serverUrlProvider);
  if (url == null) throw StateError('server URL not configured');
  final client = AriaClient(baseUrl: url);
  ref.onDispose(client.close);
  return client;
});

/// One status ping. Refresh with ref.invalidate(serverStatusProvider).
final serverStatusProvider = FutureProvider<ServerStatus>(
  (ref) => ref.watch(apiClientProvider).status(),
);

/// First-run screen: enter the server URL, test it, save. Also reachable
/// later from settings to repoint the app.
class ServerSetupScreen extends ConsumerStatefulWidget {
  const ServerSetupScreen({super.key});

  @override
  ConsumerState<ServerSetupScreen> createState() => _ServerSetupScreenState();
}

class _ServerSetupScreenState extends ConsumerState<ServerSetupScreen> {
  late final TextEditingController _ctrl = TextEditingController(
    text: ref.read(serverUrlProvider) ?? kDefaultServerUrl,
  );
  bool _testing = false;
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() {
      _testing = true;
      _error = null;
    });
    final url = normalizeServerUrl(_ctrl.text);
    final client = AriaClient(baseUrl: url);
    try {
      final status = await client.status();
      if (!mounted) return;
      await ref.read(serverUrlProvider.notifier).set(url);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Connected — ${status.tracks} tracks')),
      );
      // Router redirect leaves /setup once serverUrl is set.
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not reach the server at $url');
      }
    } finally {
      client.close();
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AriaColors.of(context);
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Padding(
            padding: const EdgeInsets.all(AriaSpace.s6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'ARIA',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 20,
                    letterSpacing: 6,
                    color: c.fg,
                  ),
                ),
                const SizedBox(height: AriaSpace.s8),
                Text(
                  'Server address',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
                const SizedBox(height: AriaSpace.s2),
                TextField(
                  controller: _ctrl,
                  autofocus: true,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    hintText: kDefaultServerUrl,
                  ),
                  onSubmitted: (_) => _connect(),
                ),
                if (_error != null) ...[
                  const SizedBox(height: AriaSpace.s3),
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                const SizedBox(height: AriaSpace.s6),
                FilledButton(
                  onPressed: _testing ? null : _connect,
                  child: Text(_testing ? 'Connecting…' : 'Connect'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
