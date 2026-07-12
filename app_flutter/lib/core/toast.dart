import 'package:flutter/material.dart';

import 'theme.dart';

/// App toast: a top-anchored, fully-opaque SnackBar. Centralised so every
/// message reads the same — neutral notices on a solid charcoal surface,
/// errors on the pink accent — and clears the floating transport at the
/// bottom by riding at the top of the screen instead.
///
/// Capture a [Toaster] *before* any `await` (like the old captured-messenger
/// pattern) so it survives the context being unmounted; call [show] after.
class Toaster {
  const Toaster(this._messenger, this._height, this._topInset, this._colors);

  final ScaffoldMessengerState _messenger;
  final double _height;
  final double _topInset;
  final AriaColors _colors;

  factory Toaster.of(BuildContext context) {
    final mq = MediaQuery.of(context);
    return Toaster(
      ScaffoldMessenger.of(context),
      mq.size.height,
      mq.padding.top,
      AriaColors.of(context),
    );
  }

  void show(String message, {bool error = false, Duration? duration}) {
    _messenger.clearSnackBars();
    _messenger.showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: const TextStyle(color: Colors.white),
        ),
        backgroundColor: error ? _colors.accent : _colors.fg,
        duration: duration ?? Duration(seconds: error ? 6 : 4),
        behavior: SnackBarBehavior.floating,
        // A floating SnackBar sits at the bottom; a near-full bottom margin
        // lifts it to just under the top safe area. ponytail: layout hack for
        // "top" — Flutter has no native top anchor for SnackBars.
        margin: EdgeInsets.only(
          left: AriaSpace.s4,
          right: AriaSpace.s4,
          bottom: (_height - _topInset - 96).clamp(0, double.infinity),
        ),
      ),
    );
  }
}

/// One-shot toast from a still-mounted context. For post-`await` sites capture
/// [Toaster.of] before the await and call [Toaster.show] instead.
void showToast(BuildContext context, String message, {bool error = false}) =>
    Toaster.of(context).show(message, error: error);
