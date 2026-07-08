import 'package:aria/features/now_playing/now_playing_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('art fills the width on a typical phone', () {
    // 390-wide portrait body: width minus screen padding wins.
    expect(nowPlayingArtEdge(const Size(390, 700)), 350);
  });

  test('short landscape window leaves room for text + controls', () {
    // 900x560 desktop-ish window: height minus the ~340 reserve wins.
    expect(nowPlayingArtEdge(const Size(900, 560)), 220);
    expect(nowPlayingArtEdge(const Size(900, 640)), 300);
  });

  test('clamped on tiny and huge windows', () {
    expect(nowPlayingArtEdge(const Size(200, 300)), 220); // floor
    expect(nowPlayingArtEdge(const Size(1600, 1200)), 560); // ceiling
  });
}
