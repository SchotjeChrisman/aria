import 'album.dart';
import 'artist.dart';
import 'catalogue.dart';
import 'components.dart';
import 'foundations.dart';
import 'home.dart';
import 'library.dart';
import 'now_playing.dart';
import 'pages.dart';
import 'playlists.dart';
import 'profiles.dart';
import 'radio.dart';
import 'release.dart';
import 'review.dart';
import 'search.dart';
import 'settings.dart';
import 'shell.dart';
import 'stats.dart';
import 'tags.dart';

/// Every component and every page in the catalogue, by category.
///
/// Three bands: the design system first (tokens, then the shared widgets in
/// `../lib/widgets`), then the app chrome the features are mounted inside,
/// then one category per feature.
///
/// Each feature category holds its components first and its destinations
/// under a `Pages` folder at the end — the parts, then the thing built out of
/// them. Page entries all live in `pages.dart`; keeping them in one file is
/// what makes "is every destination catalogued" a question you can answer by
/// reading one list.
final catalogue = <String, List<Entry>>{
  'Foundations': foundationEntries,
  'Components': componentEntries,
  'Shell': [...shellEntries, ...shellPages],
  'Home': [...homeEntries, ...homePages],
  'Library': [...libraryEntries, ...libraryPages],
  'Listen later': listenLaterPages,
  'Album': [...albumEntries, ...albumPages],
  'Artist': [...artistEntries, ...artistPages],
  'Now playing': [...nowPlayingEntries, ...nowPlayingPages],
  'Playlists': [...playlistEntries, ...playlistPages],
  'Profiles': profileEntries,
  'Radio': [...radioEntries, ...radioPages],
  'Release': [...releaseEntries, ...releasePages],
  'Review': [...reviewEntries, ...reviewPages],
  'Search': [...searchEntries, ...searchPages],
  'Settings': [...settingsEntries, ...settingsPages],
  'Stats': [...statsEntries, ...statsPages],
  'Tags': [...tagEntries, ...tagPages],
};

/// Flat list, for the test that renders all of them.
final allEntries = [for (final entries in catalogue.values) ...entries];
