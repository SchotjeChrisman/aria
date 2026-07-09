import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/quality.dart';
import '../../core/theme.dart';
import 'settings_providers.dart';
import 'quality_selector.dart';

/// Data & Downloads settings: per-network stream/download gates, streaming
/// and download quality tiers, and the offline-downloads entry.
class DataScreen extends ConsumerWidget {
  const DataScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final quality = ref.watch(qualityProvider);
    final notifier = ref.read(qualityProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: const Text('Data & Downloads')),
      body: ListView(
        padding: const EdgeInsets.all(AriaSpace.s6),
        children: [
          const _DataUsageSection(),
          const SizedBox(height: AriaSpace.s6),
          Text('Streaming quality', style: theme.textTheme.titleMedium),
          const SizedBox(height: AriaSpace.s2),
          QualitySelector(
            label: 'Wi-Fi',
            value: quality.tierWifi,
            onChanged: (t) =>
                notifier.set(quality.copyWith(tierWifi: t)),
          ),
          QualitySelector(
            label: 'Cellular',
            value: quality.tierCellular,
            onChanged: (t) =>
                notifier.set(quality.copyWith(tierCellular: t)),
          ),
          const SizedBox(height: AriaSpace.s6),
          Text('Download quality', style: theme.textTheme.titleMedium),
          const SizedBox(height: AriaSpace.s2),
          QualitySelector(
            label: 'Tier',
            value: quality.tierDownload,
            onChanged: (t) =>
                notifier.set(quality.copyWith(tierDownload: t)),
          ),
          const SizedBox(height: AriaSpace.s6),
          const _DownloadsTile(),
        ],
      ),
    );
  }
}

/// Per-network stream/download switches. Shown on every platform — a wifi
/// only desktop just never hits the cellular rows.
class _DataUsageSection extends ConsumerWidget {
  const _DataUsageSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final kind = ref.watch(networkKindProvider).value;
    final usage = ref.watch(dataUsageProvider);
    final notifier = ref.read(dataUsageProvider.notifier);

    Widget subheader(String label) => Padding(
      padding: const EdgeInsets.only(top: AriaSpace.s3),
      child: Text(label, style: theme.textTheme.labelLarge),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Current network: ${switch (kind) {
            NetKind.wifi => 'Wi-Fi',
            NetKind.cellular => 'Cellular',
            NetKind.offline => 'Offline',
            NetKind.other => 'Other',
            null => 'Checking…',
          }}',
          style: theme.textTheme.bodySmall,
        ),
        subheader('Wi-Fi'),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Stream music'),
          value: usage.streamOnWifi,
          onChanged: (v) => notifier.set(usage.copyWith(streamOnWifi: v)),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Download music'),
          value: usage.downloadOnWifi,
          onChanged: (v) => notifier.set(usage.copyWith(downloadOnWifi: v)),
        ),
        subheader('Cellular'),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Stream music'),
          value: usage.streamOnCellular,
          onChanged: (v) => notifier.set(usage.copyWith(streamOnCellular: v)),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Download music'),
          value: usage.downloadOnCellular,
          onChanged: (v) =>
              notifier.set(usage.copyWith(downloadOnCellular: v)),
        ),
      ],
    );
  }
}

/// Offline downloads entry; management lives on /settings/downloads.
class _DownloadsTile extends ConsumerWidget {
  const _DownloadsTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // select: only the count matters here, not progress ticks.
    final count = ref.watch(downloadsProvider.select((s) => s.index.length));
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: const Text('Downloads'),
      subtitle: Text(
        count == 0
            ? 'No tracks downloaded'
            : '$count track${count == 1 ? '' : 's'} available offline',
      ),
      onTap: () => context.push('/settings/downloads'),
    );
  }
}
