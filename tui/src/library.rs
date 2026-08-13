//! The in-memory library.
//!
//! Aria serves the whole merged track view from `/api/tracks` and has no album,
//! artist or search endpoint — grouping and searching are the client's job. So
//! the library is folded once on load and every view reads from these indexes.

use std::collections::HashMap;

use crate::api::models::{Album, Track};

#[derive(Debug, Clone, Default)]
pub struct Artist {
    pub name: String,
    pub album_ids: Vec<String>,
    pub track_count: usize,
}

#[derive(Debug, Default)]
pub struct Library {
    pub tracks: Vec<Track>,
    by_track_id: HashMap<String, usize>,
    pub albums: Vec<Album>,
    by_album_id: HashMap<String, usize>,
    pub artists: Vec<Artist>,
    /// Lowercased, de-accented haystack per track, built once so that typing
    /// in the search box does not re-normalise the library on every keystroke.
    search_keys: Vec<String>,
}

impl Library {
    pub fn new(tracks: Vec<Track>) -> Self {
        let mut lib = Library {
            search_keys: tracks.iter().map(search_key).collect(),
            tracks,
            ..Default::default()
        };
        lib.reindex();
        lib
    }

    pub fn is_empty(&self) -> bool {
        self.tracks.is_empty()
    }

    pub fn track(&self, id: &str) -> Option<&Track> {
        self.by_track_id.get(id).and_then(|&i| self.tracks.get(i))
    }

    pub fn track_index(&self, id: &str) -> Option<usize> {
        self.by_track_id.get(id).copied()
    }

    pub fn album(&self, id: &str) -> Option<&Album> {
        self.by_album_id.get(id).and_then(|&i| self.albums.get(i))
    }

    /// Updates one track in place and refreshes only what depends on it.
    /// Used for the favourite toggle, which must not cost a full reload.
    pub fn set_favourite(&mut self, track_id: &str, favourite: bool) {
        if let Some(&i) = self.by_track_id.get(track_id) {
            self.tracks[i].favourite = favourite;
        }
    }

    fn reindex(&mut self) {
        self.by_track_id = self
            .tracks
            .iter()
            .enumerate()
            .map(|(i, t)| (t.id.clone(), i))
            .collect();

        // Group by albumId. Aria derives album identity from the directory, so
        // albumId is stable and is the only correct grouping key — folding on
        // (album, albumArtist) text would merge distinct releases that share a
        // title and split ones whose tags disagree.
        let mut order: Vec<String> = Vec::new();
        let mut grouped: HashMap<String, Vec<usize>> = HashMap::new();
        for (i, t) in self.tracks.iter().enumerate() {
            if !grouped.contains_key(&t.album_id) {
                order.push(t.album_id.clone());
            }
            grouped.entry(t.album_id.clone()).or_default().push(i);
        }

        self.albums = order
            .into_iter()
            .map(|id| {
                let mut idx = grouped.remove(&id).unwrap_or_default();
                idx.sort_by(|&a, &b| track_order(&self.tracks[a], &self.tracks[b]));
                let first = &self.tracks[idx[0]];
                let mut genres: Vec<String> = Vec::new();
                for i in &idx {
                    for g in &self.tracks[*i].genres {
                        if !genres.iter().any(|x| x == g) {
                            genres.push(g.clone());
                        }
                    }
                }
                Album {
                    id: id.clone(),
                    title: first.album.clone(),
                    album_artist: if first.album_artist.is_empty() {
                        first.artist.clone()
                    } else {
                        first.album_artist.clone()
                    },
                    // Albums are routinely tagged with a per-track year; the
                    // earliest is the release, later ones are reissue noise.
                    year: idx.iter().filter_map(|&i| self.tracks[i].year).min(),
                    release_type: first.release_type.clone(),
                    track_count: idx.len(),
                    duration: idx.iter().map(|&i| self.tracks[i].duration_secs()).sum(),
                    has_art: idx.iter().any(|&i| self.tracks[i].has_art),
                    genres,
                    track_ids: idx.iter().map(|&i| self.tracks[i].id.clone()).collect(),
                }
            })
            .collect();

        self.albums.sort_by(|a, b| {
            sort_key(&a.album_artist)
                .cmp(&sort_key(&b.album_artist))
                .then(a.year.cmp(&b.year))
                .then(sort_key(&a.title).cmp(&sort_key(&b.title)))
        });
        self.by_album_id = self
            .albums
            .iter()
            .enumerate()
            .map(|(i, a)| (a.id.clone(), i))
            .collect();

        let mut artists: HashMap<String, Artist> = HashMap::new();
        for album in &self.albums {
            let e = artists
                .entry(album.album_artist.clone())
                .or_insert_with(|| Artist {
                    name: album.album_artist.clone(),
                    ..Default::default()
                });
            e.album_ids.push(album.id.clone());
            e.track_count += album.track_count;
        }
        self.artists = artists.into_values().collect();
        self.artists.sort_by_key(|a| sort_key(&a.name));
    }

    /// Track indexes matching `query`, best first.
    ///
    /// An empty query matches everything, in library order — which is what the
    /// search view wants before the user has typed anything.
    pub fn search(&self, query: &str) -> Vec<usize> {
        let q = normalize(query);
        let terms: Vec<&str> = q.split_whitespace().collect();
        if terms.is_empty() {
            return (0..self.tracks.len()).collect();
        }
        let mut hits: Vec<(i32, usize)> = Vec::new();
        for (i, key) in self.search_keys.iter().enumerate() {
            // Every term must appear somewhere: typing more words narrows,
            // never widens.
            if !terms.iter().all(|t| key.contains(t)) {
                continue;
            }
            hits.push((score(&self.tracks[i], &terms), i));
        }
        hits.sort_by(|a, b| b.0.cmp(&a.0).then(a.1.cmp(&b.1)));
        hits.into_iter().map(|(_, i)| i).collect()
    }
}

/// Disc, then track number, then title. Tracks with no number sort last
/// rather than first, so an untagged bonus track does not head the album.
fn track_order(a: &Track, b: &Track) -> std::cmp::Ordering {
    a.disc_no
        .unwrap_or(1)
        .cmp(&b.disc_no.unwrap_or(1))
        .then(
            a.track_no
                .unwrap_or(i64::MAX)
                .cmp(&b.track_no.unwrap_or(i64::MAX)),
        )
        .then(sort_key(&a.title).cmp(&sort_key(&b.title)))
}

/// Sorting ignores case, accents, and a leading article — "The Beatles" files
/// under B, as it would on a shelf.
pub fn sort_key(s: &str) -> String {
    let n = normalize(s);
    for article in ["the ", "a ", "an "] {
        if let Some(rest) = n.strip_prefix(article) {
            return rest.to_string();
        }
    }
    n
}

/// Lowercase and fold the Latin-1 accents. Aria stores names as tagged, and a
/// listener searching "bjork" or "dvorak" expects to find them.
pub fn normalize(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars().flat_map(|c| c.to_lowercase()) {
        out.push(match c {
            'á' | 'à' | 'â' | 'ä' | 'ã' | 'å' | 'ā' => 'a',
            'é' | 'è' | 'ê' | 'ë' | 'ē' => 'e',
            'í' | 'ì' | 'î' | 'ï' | 'ī' => 'i',
            'ó' | 'ò' | 'ô' | 'ö' | 'õ' | 'ø' | 'ō' => 'o',
            'ú' | 'ù' | 'û' | 'ü' | 'ū' => 'u',
            'ý' | 'ÿ' => 'y',
            'ñ' => 'n',
            'ç' => 'c',
            'š' => 's',
            'ž' => 'z',
            'ř' => 'r',
            'č' => 'c',
            'ď' => 'd',
            'ť' => 't',
            'ů' => 'u',
            'æ' => 'a',
            'ß' => 's',
            other => other,
        });
    }
    out
}

fn search_key(t: &Track) -> String {
    normalize(&format!(
        "{} {} {} {} {} {}",
        t.title,
        t.artist,
        t.album_artist,
        t.album,
        t.composer.as_deref().unwrap_or(""),
        t.genres.join(" "),
    ))
}

/// Ranks a match. A title hit beats an artist hit, which beats an album hit,
/// and a prefix beats a hit buried mid-word — so searching "kind of blue"
/// surfaces the album's tracks above a song that merely mentions it.
fn score(t: &Track, terms: &[&str]) -> i32 {
    let title = normalize(&t.title);
    let artist = normalize(t.display_artist());
    let album = normalize(&t.album);
    let mut total = 0;
    for term in terms {
        total += field_score(&title, term) * 3
            + field_score(&artist, term) * 2
            + field_score(&album, term) * 2;
    }
    if t.favourite {
        total += 1;
    }
    total
}

fn field_score(field: &str, term: &str) -> i32 {
    if field == term {
        10
    } else if field.starts_with(term) {
        6
    } else if field.split_whitespace().any(|w| w.starts_with(term)) {
        4
    } else if field.contains(term) {
        2
    } else {
        0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn t(id: &str, title: &str, artist: &str, album: &str, album_id: &str, no: i64) -> Track {
        Track {
            id: id.into(),
            title: title.into(),
            artist: artist.into(),
            album_artist: artist.into(),
            album: album.into(),
            album_id: album_id.into(),
            track_no: Some(no),
            duration: Some(200.0),
            ..Default::default()
        }
    }

    fn sample() -> Library {
        Library::new(vec![
            t(
                "3",
                "Blue in Green",
                "Miles Davis",
                "Kind of Blue",
                "al1",
                3,
            ),
            t("1", "So What", "Miles Davis", "Kind of Blue", "al1", 1),
            t(
                "2",
                "Freddie Freeloader",
                "Miles Davis",
                "Kind of Blue",
                "al1",
                2,
            ),
            t(
                "9",
                "Take Five",
                "The Dave Brubeck Quartet",
                "Time Out",
                "al2",
                1,
            ),
        ])
    }

    #[test]
    fn albums_fold_by_album_id() {
        let lib = sample();
        assert_eq!(lib.albums.len(), 2);
        let kob = lib.album("al1").unwrap();
        assert_eq!(kob.title, "Kind of Blue");
        assert_eq!(kob.track_count, 3);
        assert_eq!(kob.duration, 600.0);
    }

    #[test]
    fn album_tracks_come_back_in_disc_and_track_order() {
        let lib = sample();
        assert_eq!(lib.album("al1").unwrap().track_ids, vec!["1", "2", "3"]);
    }

    #[test]
    fn untagged_track_numbers_sort_last_not_first() {
        let mut a = t("a", "Bonus", "X", "Alb", "al", 1);
        a.track_no = None;
        let lib = Library::new(vec![a, t("b", "Opener", "X", "Alb", "al", 1)]);
        assert_eq!(lib.album("al").unwrap().track_ids, vec!["b", "a"]);
    }

    #[test]
    fn multi_disc_albums_order_by_disc_first() {
        let mut d2 = t("d2t1", "Disc two opener", "X", "Alb", "al", 1);
        d2.disc_no = Some(2);
        let mut d1 = t("d1t9", "Disc one closer", "X", "Alb", "al", 9);
        d1.disc_no = Some(1);
        let lib = Library::new(vec![d2, d1]);
        assert_eq!(lib.album("al").unwrap().track_ids, vec!["d1t9", "d2t1"]);
    }

    #[test]
    fn album_year_is_the_earliest_tagged_year() {
        let mut a = t("a", "One", "X", "Alb", "al", 1);
        a.year = Some(1997);
        let mut b = t("b", "Two", "X", "Alb", "al", 2);
        b.year = Some(1959); // an original date on a reissue-tagged album
        let lib = Library::new(vec![a, b]);
        assert_eq!(lib.album("al").unwrap().year, Some(1959));
    }

    #[test]
    fn artists_collect_their_albums() {
        let lib = sample();
        let miles = lib
            .artists
            .iter()
            .find(|a| a.name == "Miles Davis")
            .unwrap();
        assert_eq!(miles.album_ids, vec!["al1"]);
        assert_eq!(miles.track_count, 3);
    }

    #[test]
    fn sorting_ignores_a_leading_article() {
        let lib = sample();
        // "The Dave Brubeck Quartet" files under D, so it precedes Miles.
        assert_eq!(lib.artists[0].name, "The Dave Brubeck Quartet");
        assert_eq!(lib.artists[1].name, "Miles Davis");
    }

    #[test]
    fn search_finds_by_title_artist_and_album() {
        let lib = sample();
        assert_eq!(lib.tracks[lib.search("so what")[0]].title, "So What");
        assert_eq!(lib.search("brubeck").len(), 1);
        assert_eq!(lib.search("kind of blue").len(), 3);
    }

    #[test]
    fn search_terms_narrow_rather_than_widen() {
        let lib = sample();
        assert_eq!(lib.search("miles").len(), 3);
        assert_eq!(lib.search("miles freddie").len(), 1);
    }

    #[test]
    fn search_ignores_accents_and_case() {
        let lib = Library::new(vec![t("1", "Jóga", "Björk", "Homogenic", "al", 1)]);
        assert_eq!(lib.search("bjork").len(), 1);
        assert_eq!(lib.search("JOGA").len(), 1);
    }

    #[test]
    fn a_title_hit_outranks_an_album_hit() {
        let lib = Library::new(vec![
            t("1", "Something Else", "A", "Blue Train", "al1", 1),
            t("2", "Blue Train", "B", "Other", "al2", 1),
        ]);
        let hits = lib.search("blue train");
        assert_eq!(
            lib.tracks[hits[0]].id, "2",
            "the track actually called it comes first"
        );
    }

    #[test]
    fn empty_query_matches_the_whole_library() {
        let lib = sample();
        assert_eq!(lib.search("").len(), 4);
        assert_eq!(lib.search("   ").len(), 4);
    }

    #[test]
    fn a_query_matching_nothing_returns_nothing() {
        assert!(sample().search("zzzzz").is_empty());
    }

    #[test]
    fn favourite_updates_in_place() {
        let mut lib = sample();
        assert!(!lib.track("1").unwrap().favourite);
        lib.set_favourite("1", true);
        assert!(lib.track("1").unwrap().favourite);
    }

    #[test]
    fn an_empty_library_indexes_without_panicking() {
        let lib = Library::new(vec![]);
        assert!(lib.is_empty());
        assert!(lib.albums.is_empty());
        assert!(lib.artists.is_empty());
        assert!(lib.search("anything").is_empty());
    }
}
