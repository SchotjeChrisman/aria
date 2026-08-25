import 'dart:io';

import 'package:flutter/material.dart';

/// The offline cover an [ArtImage] falls back to when the network fails.
///
/// Split out because `Image.file` is bound to a real `dart:io` File and cannot
/// take the in-memory stand-in the web build uses — this is the one place the
/// io seam in core/native could not cover.
Widget localArtImage({
  required String path,
  required BoxFit fit,
  required Widget fallback,
}) =>
    Image.file(
      File(path),
      fit: fit,
      errorBuilder: (_, _, _) => fallback,
    );
