//! The in-memory library.
//!
//! Aria serves the whole merged track view from `/api/tracks` and has no album,
//! artist or search endpoint — grouping and searching are the client's job. So
//! the library is folded once on load and every view reads from these indexes.

use std::cmp::Ordering;
use std::collections::HashMap;

use crate::api::models::{Album, Track};

/// Which library list a sort applies to. The three are kept apart because they
/// are browsed for different reasons: albums by year, tracks by length, and
/// remembering one choice for all three would make each of them wrong.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ListKind {
    Albums,
    Artists,
    Tracks,
}

impl ListKind {
    /// The fields this list can be sorted by, in cycle order. The first is the
    /// default, and is the order the list had before sorting was settable.
    pub fn fields(self) -> &'static [SortField] {
        use SortField::*;
        match self {
            ListKind::Albums => &[Artist, Title, Year, Added, Tracks, Plays],
            ListKind::Artists => &[Artist, Tracks, Plays],
            ListKind::Tracks => &[Artist, Title, Album, Year, Added, Length, Plays],
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SortField {
    Artist,
    Title,
    Album,
    Year,
    Added,
    Length,
    Tracks,
    Plays,
}

impl SortField {
    pub fn label(self) -> &'static str {
        match self {
            SortField::Artist => "artist",
            SortField::Title => "title",
            SortField::Album => "album",
            SortField::Year => "year",
            SortField::Added => "added",
            SortField::Length => "length",
            SortField::Tracks => "tracks",
            SortField::Plays => "plays",
        }
    }

    /// The direction the field is normally wanted in. Reaching for "recently
    /// added" and landing on the oldest imports is never the intent, so a date
    /// or a count starts descending; a name starts at A.
    pub fn wants_desc(self) -> bool {
        matches!(
            self,
            SortField::Added | SortField::Length | SortField::Tracks | SortField::Plays
        )
    }

    fn parse(s: &str) -> Option<SortField> {
        use SortField::*;
        [Artist, Title, Album, Year, Added, Length, Tracks, Plays]
            .into_iter()
            .find(|f| f.label() == s)
    }
}

/// A field and a direction.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Sort {
    pub field: SortField,
    pub desc: bool,
}

impl Default for Sort {
    fn default() -> Self {
        Sort::new(SortField::Artist)
    }
}

impl Sort {
    pub fn new(field: SortField) -> Self {
        Sort {
            field,
            desc: field.wants_desc(),
        }
    }

    /// The next field this list offers, wrapping. A field the list does not
    /// offer counts as "before the first", so cycling from a stale config
    /// value lands on the default rather than going nowhere.
    pub fn next(self, kind: ListKind) -> Sort {
        let fields = kind.fields();
        let i = fields.iter().position(|f| *f == self.field);
        Sort::new(fields[i.map_or(0, |i| (i + 1) % fields.len())])
    }

    /// Falls back to the list's default when the field is not one it offers,
    /// so a hand-edited config cannot label a list with an order it is not in.
    pub fn valid_for(self, kind: ListKind) -> Sort {
        if kind.fields().contains(&self.field) {
            self
        } else {
            Sort::new(kind.fields()[0])
        }
    }

    pub fn reversed(self) -> Sort {
        Sort {
            desc: !self.desc,
            ..self
        }
    }

    /// How the order reads in a list header: "artist ↑".
    pub fn label(self) -> String {
        format!(
            "{} {}",
            self.field.label(),
            if self.desc { "↓" } else { "↑" }
        )
    }

    /// The config-file form. A leading `-` is descending, so the whole setting
    /// is one readable word.
    pub fn as_str(self) -> String {
        format!("{}{}", if self.desc { "-" } else { "" }, self.field.label())
    }

    pub fn parse(s: &str) -> Option<Sort> {
        let s = s.trim();
        let (desc, name) = match s.strip_prefix('-') {
            Some(rest) => (true, rest),
            None => (false, s),
        };
        SortField::parse(name).map(|field| Sort { field, desc })
    }
}

/// The sort in force for each list.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Sorts {
    pub albums: Sort,
    pub artists: Sort,
    pub tracks: Sort,
}

impl Sorts {
    pub fn get(&self, kind: ListKind) -> Sort {
        match kind {
            ListKind::Albums => self.albums,
            ListKind::Artists => self.artists,
            ListKind::Tracks => self.tracks,
        }
    }

    pub fn set(&mut self, kind: ListKind, sort: Sort) {
        match kind {
            ListKind::Albums => self.albums = sort,
            ListKind::Artists => self.artists = sort,
            ListKind::Tracks => self.tracks = sort,
        }
    }
}

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

    sorts: Sorts,
    /// Display order per list, as indexes into the vectors above. Sorting is
    /// layered rather than applied in place because `by_track_id`, the album
    /// track lists and the search hits all hold positions into those vectors —
    /// reordering them underneath would silently point every one of them at
    /// the wrong row.
    album_order: Vec<usize>,
    artist_order: Vec<usize>,
    track_order: Vec<usize>,

    /// Plays per track for the current profile, empty until something asks to
    /// sort by them. A track that has never been played is absent, not zero —
    /// the server sends one row per played track and the library keeps that
    /// shape rather than materialising a zero for every track it owns.
    play_counts: HashMap<String, u32>,
    /// Plays folded up to the album and the artist, parallel to `albums` and
    /// `artists`. Precomputed because summing an album inside the comparator
    /// would redo that work on every one of the O(n log n) comparisons.
    track_plays: Vec<u32>,
    album_plays: Vec<u32>,
    artist_plays: Vec<u32>,
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

    pub fn sorts(&self) -> Sorts {
        self.sorts
    }

    pub fn sort(&self, kind: ListKind) -> Sort {
        self.sorts.get(kind)
    }

    /// Row order for a list: indexes into `albums`, `artists` or `tracks`.
    pub fn order(&self, kind: ListKind) -> &[usize] {
        match kind {
            ListKind::Albums => &self.album_order,
            ListKind::Artists => &self.artist_order,
            ListKind::Tracks => &self.track_order,
        }
    }

    /// The item at a display row, as an index into the underlying vector.
    pub fn row(&self, kind: ListKind, row: usize) -> Option<usize> {
        self.order(kind).get(row).copied()
    }

    /// Where an item sits now, so a re-sort can put the cursor back on it.
    pub fn row_of(&self, kind: ListKind, index: usize) -> Option<usize> {
        self.order(kind).iter().position(|&i| i == index)
    }

    pub fn set_sorts(&mut self, sorts: Sorts) {
        self.sorts = sorts;
        self.resort();
    }

    /// Plays for one track, for the play-count column.
    pub fn plays(&self, track_id: &str) -> u32 {
        self.play_counts.get(track_id).copied().unwrap_or(0)
    }

    pub fn album_plays(&self, index: usize) -> u32 {
        self.album_plays.get(index).copied().unwrap_or(0)
    }

    pub fn artist_plays(&self, index: usize) -> u32 {
        self.artist_plays.get(index).copied().unwrap_or(0)
    }

    pub fn set_play_counts(&mut self, counts: HashMap<String, u32>) {
        self.play_counts = counts;
        self.fold_plays();
        self.resort();
    }

    /// Drops the counts, for a profile change: plays belong to the profile
    /// that made them, so keeping them would rank the new listener's library
    /// by the old listener's history.
    pub fn clear_play_counts(&mut self) {
        self.play_counts.clear();
        self.fold_plays();
        self.resort();
    }

    fn fold_plays(&mut self) {
        let track_plays: Vec<u32> = self.tracks.iter().map(|t| self.plays(&t.id)).collect();
        let album_plays: Vec<u32> = self
            .albums
            .iter()
            .map(|a| a.track_ids.iter().map(|id| self.plays(id)).sum())
            .collect();
        // An artist's plays come through their albums rather than through the
        // track artist, because that is how this list defines an artist in the
        // first place — a guest credit belongs to the album that carries it.
        let artist_plays: Vec<u32> = self
            .artists
            .iter()
            .map(|artist| {
                artist
                    .album_ids
                    .iter()
                    .filter_map(|id| self.by_album_id.get(id))
                    .map(|&i| album_plays.get(i).copied().unwrap_or(0))
                    .sum()
            })
            .collect();
        self.track_plays = track_plays;
        self.album_plays = album_plays;
        self.artist_plays = artist_plays;
    }

    fn resort(&mut self) {
        // Plays are passed in per pair rather than looked up in the
        // comparator: the fold is done once, and a comparison stays a
        // comparison instead of a hash lookup repeated n log n times.
        let plays = |v: &[u32], i: usize| v.get(i).copied().unwrap_or(0);

        self.album_order = (0..self.albums.len()).collect();
        let s = self.sorts.albums;
        self.album_order.sort_by(|&a, &b| {
            cmp_albums(
                &self.albums[a],
                &self.albums[b],
                s,
                (plays(&self.album_plays, a), plays(&self.album_plays, b)),
            )
        });

        self.artist_order = (0..self.artists.len()).collect();
        let s = self.sorts.artists;
        self.artist_order.sort_by(|&a, &b| {
            cmp_artists(
                &self.artists[a],
                &self.artists[b],
                s,
                (plays(&self.artist_plays, a), plays(&self.artist_plays, b)),
            )
        });

        self.track_order = (0..self.tracks.len()).collect();
        let s = self.sorts.tracks;
        self.track_order.sort_by(|&a, &b| {
            cmp_tracks(
                &self.tracks[a],
                &self.tracks[b],
                s,
                (plays(&self.track_plays, a), plays(&self.track_plays, b)),
            )
        });
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
                idx.sort_by(|&a, &b| disc_track_order(&self.tracks[a], &self.tracks[b]));
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
                    added_at: idx
                        .iter()
                        .map(|&i| self.tracks[i].added_at.as_str())
                        .max()
                        .unwrap_or_default()
                        .to_string(),
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

        self.fold_plays();
        self.resort();
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

fn dir(o: Ordering, desc: bool) -> Ordering {
    if desc {
        o.reverse()
    } else {
        o
    }
}

/// Orders a value that may be missing. Unknowns sort last in *both*
/// directions: a track with no year is not the oldest one, and reversing the
/// list should not park a wall of blanks at the top.
fn opt<T: Ord>(a: Option<T>, b: Option<T>, desc: bool) -> Ordering {
    match (a, b) {
        (None, None) => Ordering::Equal,
        (None, Some(_)) => Ordering::Greater,
        (Some(_), None) => Ordering::Less,
        (Some(x), Some(y)) => dir(x.cmp(&y), desc),
    }
}

/// Aria writes `addedAt` as an RFC 3339 timestamp, which compares correctly as
/// text. An empty one means the server never recorded it.
fn added(s: &str) -> Option<&str> {
    Some(s).filter(|s| !s.is_empty())
}

/// Every comparator falls through to a stable tiebreak, so two albums released
/// the same year keep a fixed order instead of shuffling on each redraw. Only
/// the leading term takes the direction: reversing "by artist" reverses the
/// artists, not the track order inside each of their albums.
fn cmp_albums(a: &Album, b: &Album, sort: Sort, plays: (u32, u32)) -> Ordering {
    let d = sort.desc;
    let by_artist = || sort_key(&a.album_artist).cmp(&sort_key(&b.album_artist));
    let by_title = || sort_key(&a.title).cmp(&sort_key(&b.title));
    match sort.field {
        // The default, and the order albums had before this was settable.
        SortField::Artist => dir(by_artist(), d)
            .then_with(|| a.year.cmp(&b.year))
            .then_with(by_title),
        SortField::Title => dir(by_title(), d).then_with(by_artist),
        SortField::Year => opt(a.year, b.year, d)
            .then_with(by_artist)
            .then_with(by_title),
        SortField::Added => opt(added(&a.added_at), added(&b.added_at), d)
            .then_with(by_artist)
            .then_with(by_title),
        SortField::Tracks => dir(a.track_count.cmp(&b.track_count), d)
            .then_with(by_artist)
            .then_with(by_title),
        SortField::Plays => dir(plays.0.cmp(&plays.1), d)
            .then_with(by_artist)
            .then_with(by_title),
        // Not offered for albums; hold the default rather than inventing one.
        SortField::Album | SortField::Length => {
            cmp_albums(a, b, Sort::new(SortField::Artist), plays)
        }
    }
}

fn cmp_artists(a: &Artist, b: &Artist, sort: Sort, plays: (u32, u32)) -> Ordering {
    let by_name = || sort_key(&a.name).cmp(&sort_key(&b.name));
    match sort.field {
        SortField::Tracks => dir(a.track_count.cmp(&b.track_count), sort.desc).then_with(by_name),
        SortField::Plays => dir(plays.0.cmp(&plays.1), sort.desc).then_with(by_name),
        _ => dir(by_name(), sort.desc),
    }
}

fn cmp_tracks(a: &Track, b: &Track, sort: Sort, plays: (u32, u32)) -> Ordering {
    let d = sort.desc;
    let by_artist = || sort_key(a.display_artist()).cmp(&sort_key(b.display_artist()));
    let by_album = || sort_key(&a.album).cmp(&sort_key(&b.album));
    let by_title = || sort_key(&a.title).cmp(&sort_key(&b.title));
    match sort.field {
        SortField::Artist => dir(by_artist(), d)
            .then_with(by_album)
            .then_with(|| disc_track_order(a, b)),
        SortField::Title => dir(by_title(), d).then_with(by_artist),
        SortField::Album => dir(by_album(), d).then_with(|| disc_track_order(a, b)),
        SortField::Year => opt(a.year, b.year, d)
            .then_with(by_artist)
            .then_with(by_album)
            .then_with(|| disc_track_order(a, b)),
        SortField::Added => opt(added(&a.added_at), added(&b.added_at), d)
            .then_with(by_artist)
            .then_with(by_title),
        // A missing duration is unknown, not zero, so it sorts with the other
        // unknowns rather than heading a "shortest first" list.
        SortField::Length => match (a.duration, b.duration) {
            (None, None) => Ordering::Equal,
            (None, Some(_)) => Ordering::Greater,
            (Some(_), None) => Ordering::Less,
            (Some(x), Some(y)) => dir(x.total_cmp(&y), d),
        }
        .then_with(by_artist)
        .then_with(by_title),
        SortField::Plays => dir(plays.0.cmp(&plays.1), d)
            .then_with(by_artist)
            .then_with(by_title),
        SortField::Tracks => cmp_tracks(a, b, Sort::new(SortField::Artist), plays),
    }
}

/// Disc, then track number, then title. Tracks with no number sort last
/// rather than first, so an untagged bonus track does not head the album.
fn disc_track_order(a: &Track, b: &Track) -> std::cmp::Ordering {
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
        assert!(lib.order(ListKind::Albums).is_empty());
        assert!(lib.row(ListKind::Tracks, 0).is_none());
    }

    // ---- sorting --------------------------------------------------------

    /// Track titles in the order the Tracks view would draw them.
    fn track_titles(lib: &Library) -> Vec<&str> {
        lib.order(ListKind::Tracks)
            .iter()
            .map(|&i| lib.tracks[i].title.as_str())
            .collect()
    }

    fn album_titles(lib: &Library) -> Vec<&str> {
        lib.order(ListKind::Albums)
            .iter()
            .map(|&i| lib.albums[i].title.as_str())
            .collect()
    }

    fn sorted(lib: &mut Library, kind: ListKind, field: SortField, desc: bool) {
        let mut s = lib.sorts();
        s.set(kind, Sort { field, desc });
        lib.set_sorts(s);
    }

    #[test]
    fn tracks_default_to_artist_then_album_then_disc_order() {
        let lib = sample();
        assert_eq!(
            track_titles(&lib),
            // Brubeck files under D, and each album keeps its own track order.
            vec![
                "Take Five",
                "So What",
                "Freddie Freeloader",
                "Blue in Green"
            ]
        );
    }

    #[test]
    fn sorting_by_title_ignores_the_leading_article() {
        let mut lib = Library::new(vec![
            t("1", "Zulu", "X", "Alb", "al", 1),
            t("2", "The Ballad", "X", "Alb", "al", 2),
        ]);
        sorted(&mut lib, ListKind::Tracks, SortField::Title, false);
        assert_eq!(track_titles(&lib), vec!["The Ballad", "Zulu"]);

        sorted(&mut lib, ListKind::Tracks, SortField::Title, true);
        assert_eq!(track_titles(&lib), vec!["Zulu", "The Ballad"]);
    }

    #[test]
    fn a_missing_year_sorts_last_in_both_directions() {
        let mut a = t("a", "Dated", "X", "Alb", "al1", 1);
        a.year = Some(1970);
        let b = t("b", "Untagged", "X", "Other", "al2", 1); // year: None
        let mut c = t("c", "Newer", "X", "Third", "al3", 1);
        c.year = Some(1999);
        let mut lib = Library::new(vec![b, a, c]);

        sorted(&mut lib, ListKind::Tracks, SortField::Year, false);
        assert_eq!(track_titles(&lib), vec!["Dated", "Newer", "Untagged"]);

        sorted(&mut lib, ListKind::Tracks, SortField::Year, true);
        assert_eq!(
            track_titles(&lib),
            vec!["Newer", "Dated", "Untagged"],
            "reversing must not float the unknowns to the top"
        );
    }

    #[test]
    fn a_missing_duration_is_unknown_rather_than_zero() {
        let mut short = t("a", "Short", "X", "Alb", "al", 1);
        short.duration = Some(60.0);
        let mut none = t("b", "Untimed", "X", "Alb", "al", 2);
        none.duration = None;
        let mut lib = Library::new(vec![none, short]);

        sorted(&mut lib, ListKind::Tracks, SortField::Length, false);
        assert_eq!(
            track_titles(&lib),
            vec!["Short", "Untimed"],
            "an untimed track is not the shortest one"
        );
    }

    #[test]
    fn reversing_by_artist_reverses_the_artists_not_the_albums() {
        let mut lib = sample();
        sorted(&mut lib, ListKind::Tracks, SortField::Artist, true);
        assert_eq!(
            track_titles(&lib),
            // Miles now leads, but his album still plays 1, 2, 3.
            vec![
                "So What",
                "Freddie Freeloader",
                "Blue in Green",
                "Take Five"
            ]
        );
    }

    #[test]
    fn an_albums_added_date_is_its_most_recent_track() {
        let mut early = t("a", "First", "X", "Alb", "al", 1);
        early.added_at = "2024-01-01T00:00:00Z".into();
        let mut late = t("b", "Filled in later", "X", "Alb", "al", 2);
        late.added_at = "2026-05-01T00:00:00Z".into();
        let lib = Library::new(vec![early, late]);
        assert_eq!(lib.album("al").unwrap().added_at, "2026-05-01T00:00:00Z");
    }

    #[test]
    fn albums_sort_newest_first_when_asked_for_by_added() {
        let mut old = t("a", "Track", "X", "Old", "al1", 1);
        old.added_at = "2020-03-04T00:00:00Z".into();
        let mut new = t("b", "Track", "Y", "New", "al2", 1);
        new.added_at = "2026-08-01T00:00:00Z".into();
        let unknown = t("c", "Track", "Z", "Undated", "al3", 1); // added_at: ""
        let mut lib = Library::new(vec![old, new, unknown]);

        // `Sort::new` picks the direction, which for a date is newest first.
        let mut s = lib.sorts();
        s.set(ListKind::Albums, Sort::new(SortField::Added));
        lib.set_sorts(s);
        assert_eq!(album_titles(&lib), vec!["New", "Old", "Undated"]);
    }

    #[test]
    fn albums_can_be_ordered_by_size() {
        let mut lib = Library::new(vec![
            t("a", "One", "X", "Single", "al1", 1),
            t("b", "One", "Y", "Long", "al2", 1),
            t("c", "Two", "Y", "Long", "al2", 2),
        ]);
        sorted(&mut lib, ListKind::Albums, SortField::Tracks, true);
        assert_eq!(album_titles(&lib), vec!["Long", "Single"]);
    }

    #[test]
    fn sorting_leaves_the_id_lookups_and_album_track_order_alone() {
        let mut lib = sample();
        sorted(&mut lib, ListKind::Albums, SortField::Title, true);
        sorted(&mut lib, ListKind::Tracks, SortField::Title, true);

        // This is what sorting by index protects: ids still resolve, and an
        // album still plays in disc order however its list is shown.
        assert_eq!(lib.track("2").unwrap().title, "Freddie Freeloader");
        assert_eq!(lib.album("al1").unwrap().title, "Kind of Blue");
        assert_eq!(lib.album("al1").unwrap().track_ids, vec!["1", "2", "3"]);
    }

    #[test]
    fn a_row_maps_back_to_the_item_it_shows() {
        let mut lib = sample();
        sorted(&mut lib, ListKind::Tracks, SortField::Title, false);
        let row = lib.row_of(ListKind::Tracks, lib.track_index("9").unwrap());
        // "Take Five" is last of the four by title.
        assert_eq!(row, Some(3));
        assert_eq!(lib.row(ListKind::Tracks, 3), lib.track_index("9"));
    }

    #[test]
    fn cycling_wraps_through_the_fields_a_list_offers() {
        let fields = ListKind::Artists.fields();
        assert_eq!(
            fields,
            [SortField::Artist, SortField::Tracks, SortField::Plays]
        );

        let mut s = Sort::new(SortField::Artist);
        for expected in [SortField::Tracks, SortField::Plays, SortField::Artist] {
            s = s.next(ListKind::Artists);
            assert_eq!(s.field, expected);
        }
    }

    #[test]
    fn cycling_from_a_field_the_list_does_not_offer_lands_on_its_default() {
        // `length` is a track field; the Albums list has never offered it.
        let s = Sort::new(SortField::Length).next(ListKind::Albums);
        assert_eq!(s.field, SortField::Artist);
        assert_eq!(
            Sort::new(SortField::Length)
                .valid_for(ListKind::Albums)
                .field,
            SortField::Artist
        );
        assert_eq!(
            Sort::new(SortField::Year).valid_for(ListKind::Albums).field,
            SortField::Year,
            "a field it does offer is left alone"
        );
    }

    #[test]
    fn a_date_or_a_count_starts_descending_and_a_name_starts_at_a() {
        assert!(Sort::new(SortField::Added).desc);
        assert!(Sort::new(SortField::Tracks).desc);
        assert!(Sort::new(SortField::Length).desc);
        assert!(!Sort::new(SortField::Artist).desc);
        assert!(!Sort::new(SortField::Title).desc);
        assert!(!Sort::new(SortField::Year).desc);
    }

    #[test]
    fn a_sort_round_trips_through_its_config_form() {
        for field in [
            SortField::Artist,
            SortField::Title,
            SortField::Album,
            SortField::Year,
            SortField::Added,
            SortField::Length,
            SortField::Tracks,
        ] {
            for desc in [false, true] {
                let s = Sort { field, desc };
                assert_eq!(Sort::parse(&s.as_str()), Some(s), "{}", s.as_str());
            }
        }
        assert_eq!(Sort::parse("-added").unwrap().field, SortField::Added);
        assert!(Sort::parse("-added").unwrap().desc);
        assert!(!Sort::parse("  year  ").unwrap().desc);
        assert_eq!(Sort::parse("sideways"), None);
        assert_eq!(Sort::parse(""), None);
    }

    #[test]
    fn plays_rank_tracks_albums_and_artists() {
        let mut lib = Library::new(vec![
            t("a", "Hit", "Zebra", "Popular", "al1", 1),
            t("b", "Deep cut", "Zebra", "Popular", "al1", 2),
            t("c", "Only track", "Apple", "Ignored", "al2", 1),
        ]);
        lib.set_play_counts(HashMap::from([("a".into(), 40), ("c".into(), 7)]));

        // Counts alone change nothing; the lists are still ranked by artist.
        assert_eq!(album_titles(&lib), vec!["Ignored", "Popular"]);

        let mut s = lib.sorts();
        s.set(ListKind::Albums, Sort::new(SortField::Plays));
        s.set(ListKind::Tracks, Sort::new(SortField::Plays));
        s.set(ListKind::Artists, Sort::new(SortField::Plays));
        lib.set_sorts(s);
        // Album plays are the sum of their tracks: Popular has 40, Ignored 7.
        assert_eq!(album_titles(&lib), vec!["Popular", "Ignored"]);
        assert_eq!(track_titles(&lib)[0], "Hit", "most played track leads");
        assert_eq!(
            lib.order(ListKind::Artists)
                .iter()
                .map(|&i| lib.artists[i].name.as_str())
                .collect::<Vec<_>>(),
            vec!["Zebra", "Apple"],
            "an artist's plays come through their albums"
        );
        assert_eq!(track_titles(&lib), vec!["Hit", "Only track", "Deep cut"]);
    }

    #[test]
    fn an_unplayed_track_counts_as_zero_rather_than_unknown() {
        let mut lib = Library::new(vec![
            t("a", "Played", "X", "Alb", "al", 1),
            t("b", "Never", "X", "Alb", "al", 2),
        ]);
        lib.set_play_counts(HashMap::from([("a".into(), 3)]));
        sorted(&mut lib, ListKind::Tracks, SortField::Plays, false);
        assert_eq!(
            track_titles(&lib),
            vec!["Never", "Played"],
            "ascending puts the never-played first: zero is a real count, \
             unlike a missing year"
        );
        assert_eq!(lib.plays("b"), 0);
        assert_eq!(lib.plays("gone"), 0);
    }

    #[test]
    fn dropping_the_counts_leaves_the_list_ranked_by_nothing_but_names() {
        let mut lib = Library::new(vec![
            t("a", "Zed", "X", "Alb", "al", 1),
            t("b", "Alpha", "X", "Alb", "al", 2),
        ]);
        lib.set_play_counts(HashMap::from([("a".into(), 9)]));
        sorted(&mut lib, ListKind::Tracks, SortField::Plays, true);
        assert_eq!(track_titles(&lib), vec!["Zed", "Alpha"]);

        // A profile change: the counts are the other listener's.
        lib.clear_play_counts();
        assert_eq!(lib.plays("a"), 0);
        assert_eq!(
            track_titles(&lib),
            vec!["Alpha", "Zed"],
            "with every count equal the tiebreak decides, in title order"
        );
    }

    #[test]
    fn a_reindex_refolds_the_plays_it_already_holds() {
        let mut lib = Library::new(vec![t("a", "One", "X", "Alb", "al", 1)]);
        lib.set_play_counts(HashMap::from([("a".into(), 5)]));
        assert_eq!(lib.album_plays(0), 5);
        assert_eq!(lib.artist_plays(0), 5);
    }

    #[test]
    fn the_label_names_the_field_and_the_direction() {
        assert_eq!(Sort::new(SortField::Year).label(), "year ↑");
        assert_eq!(Sort::new(SortField::Year).reversed().label(), "year ↓");
    }
}
