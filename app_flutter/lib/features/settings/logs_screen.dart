import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/log.dart';
import '../../core/log_sync.dart';
import '../../core/theme.dart';

const _levels = ['debug', 'info', 'warn', 'error'];

/// Debug view over the in-memory ring buffer: newest first, level filter
/// chips, manual upload trigger. Plain and small by design.
class LogsScreen extends ConsumerStatefulWidget {
  const LogsScreen({super.key});

  @override
  ConsumerState<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends ConsumerState<LogsScreen> {
  String? _level; // null = all
  bool _syncing = false;

  Future<void> _syncNow() async {
    setState(() => _syncing = true);
    await ref.read(logSyncProvider).syncNow();
    if (!mounted) return;
    setState(() => _syncing = false);
    // syncNow never throws; failures retry quietly on the next tick.
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Log sync attempted.')));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Logs'),
        actions: [
          TextButton(
            onPressed: _syncing ? null : _syncNow,
            child: Text(_syncing ? 'Syncing…' : 'Sync now'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AriaSpace.s4,
              vertical: AriaSpace.s2,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Wrap(
                    spacing: AriaSpace.s2,
                    children: [
                      ChoiceChip(
                        label: const Text('all'),
                        selected: _level == null,
                        onSelected: (_) => setState(() => _level = null),
                      ),
                      for (final l in _levels)
                        ChoiceChip(
                          label: Text(l),
                          selected: _level == l,
                          onSelected: (_) => setState(() => _level = l),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ValueListenableBuilder(
              valueListenable: Log.revision,
              builder: (context, _, _) {
                final entries = Log.entries.reversed
                    .where((e) => _level == null || e.level == _level)
                    .toList();
                if (entries.isEmpty) {
                  return Center(
                    child: Text(
                      'No log entries.',
                      style: theme.textTheme.bodySmall,
                    ),
                  );
                }
                return ListView.builder(
                  itemCount: entries.length,
                  itemBuilder: (context, i) {
                    final e = entries[i];
                    return ListTile(
                      dense: true,
                      leading: Text(
                        e.level[0].toUpperCase(),
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: e.level == 'error'
                              ? theme.colorScheme.error
                              : null,
                        ),
                      ),
                      title: Text('${e.tag}: ${e.msg}'),
                      subtitle: Text(
                        e.extra == null ? e.ts : '${e.ts}\n${e.extra}',
                        style: theme.textTheme.bodySmall,
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
