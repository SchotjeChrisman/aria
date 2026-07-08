import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfrx/pdfrx.dart';

import 'providers.dart';

/// In-app album booklet viewer — pdfrx defaults (pinch/scroll/zoom for free).
class BookletScreen extends ConsumerWidget {
  const BookletScreen({
    super.key,
    required this.albumId,
    required this.name,
  });

  final String albumId;
  final String name; // booklet file name from /booklets

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final url = ref.watch(albumApiProvider).bookletUrl(albumId, name);
    return Scaffold(
      appBar: AppBar(title: Text(name)),
      body: PdfViewer.uri(Uri.parse(url)),
    );
  }
}
