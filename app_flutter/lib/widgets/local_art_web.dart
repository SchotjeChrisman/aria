import 'package:flutter/material.dart';

/// Web twin of local_art_io.dart. Downloads never land on disk in a browser,
/// so there is no offline cover to fall back to — go straight to the
/// placeholder.
Widget localArtImage({
  required String path,
  required BoxFit fit,
  required Widget fallback,
}) =>
    fallback;
