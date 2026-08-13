//! Wire types for the Aria HTTP API.
//!
//! Every field is `#[serde(default)]` on purpose. `/api/tracks` is a merged
//! view — file tags, then enrichment blobs, then album corrections, then user
//! edits, each layer spreading arbitrary keys over the last — so the server can
//! and does add keys. A client that hard-failed on an unknown or absent field
//! would break on a server upgrade; a client that treats absence as "unknown"
//! keeps working.

use serde::{Deserialize, Serialize};

/// One row of `GET /api/tracks`.
///
/// Note `duration` is seconds as a float and may be null on a track whose tags
/// never carried one. `path` is stripped by the server and is never present.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Track {
    pub id: String,
    pub title: String,
    pub artist: String,
    pub album_artist: String,
    pub album: String,
    pub album_id: String,
    pub added_at: String,
    pub track_no: Option<i64>,
    pub disc_no: Option<i64>,
    pub year: Option<i64>,
    pub genre: Option<String>,
    pub composer: Option<String>,
    pub conductor: Option<String>,
    pub work: Option<String>,
    pub movement: Option<String>,
    pub duration: Option<f64>,
    pub format: String,
    pub sample_rate: Option<i64>,
    pub bits_per_sample: Option<i64>,
    pub channels: Option<i64>,
    pub lossless: bool,
    pub has_art: bool,
    pub favourite: bool,
    /// Derived per album: Album / EP / Single / Live / Compilation.
    pub release_type: String,
    /// Split and normalised from the raw `genre` tag, plus album-level genres.
    pub genres: Vec<String>,
    /// Names of every tag matching this track directly, via its album, or via
    /// its artist — ancestor tags included.
    pub tags: Vec<String>,
    /// The album page's fuller credit line. Only present under the classical
    /// display policy, and dropped when a user edit sets `albumArtist`.
    pub album_artists: Vec<String>,
    /// ReplayGain, derived from measured loudness. Null until the analysis pass
    /// has seen the file — and null must stay null rather than becoming 0 dB,
    /// which would apply gain on no evidence.
    pub track_gain_db: Option<f64>,
    pub album_gain_db: Option<f64>,
    pub loudness_lufs: Option<f64>,
    pub dynamic_range_lu: Option<f64>,
    /// False on an unanalysed track means "nothing has contradicted the
    /// container yet", not "verified genuine".
    pub suspect: bool,
}

impl Track {
    pub fn duration_secs(&self) -> f64 {
        self.duration.unwrap_or(0.0)
    }

    /// The artist to show in a track list: the track artist, falling back to
    /// the album artist when a file carries only the latter.
    pub fn display_artist(&self) -> &str {
        if self.artist.is_empty() {
            &self.album_artist
        } else {
            &self.artist
        }
    }

    /// A short technical badge, e.g. "FLAC 24/96" or "MP3".
    pub fn quality_badge(&self) -> String {
        let fmt = self.format.to_uppercase();
        match (self.bits_per_sample, self.sample_rate) {
            (Some(bits), Some(rate)) if self.lossless => {
                format!("{fmt} {bits}/{:.3}", rate as f64 / 1000.0)
                    .trim_end_matches('0')
                    .trim_end_matches('.')
                    .to_string()
            }
            _ => fmt,
        }
    }
}

/// An album, folded from the track list client-side. The server has no album
/// list endpoint — `/api/tracks` is the whole library in one document, and
/// grouping by `albumId` is how every Aria client builds its album view.
#[derive(Debug, Clone, Default)]
pub struct Album {
    pub id: String,
    pub title: String,
    pub album_artist: String,
    pub year: Option<i64>,
    /// The album's most recent addition, so a release that gained a missing
    /// track floats back up a "recently added" list. Empty when no track
    /// carried a timestamp.
    pub added_at: String,
    pub release_type: String,
    pub track_count: usize,
    pub duration: f64,
    pub has_art: bool,
    pub genres: Vec<String>,
    /// Indices into the library's track vector, in disc/track order.
    pub track_ids: Vec<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Profile {
    pub id: String,
    pub name: String,
    /// `#rrggbb`. The server validates the format on write and rejects
    /// anything else.
    pub color: String,
    pub created_at: String,
}

/// A playlist. Playlists belong to a profile, so `GET /api/playlists` must be
/// called with `?profileId=` or it lists nothing useful.
///
/// The two types are disjoint on the wire: a `manual` playlist carries
/// `trackIds` and no `rules`, a `smart` one carries `rules` and no `trackIds`.
/// The server refuses track add/remove on a smart playlist with a 400.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Playlist {
    pub id: String,
    pub profile_id: String,
    pub name: String,
    /// "manual" or "smart".
    #[serde(rename = "type")]
    pub kind: String,
    pub created_at: String,
    pub updated_at: String,
    /// Manual playlists only. Order is the stored order; duplicates are legal.
    pub track_ids: Vec<String>,
    /// Smart playlists only: the saved rule set, passed through untouched.
    pub rules: Option<serde_json::Value>,
}

impl Playlist {
    pub fn is_smart(&self) -> bool {
        self.kind == "smart"
    }
}

/// A listen-later entry. This is *not* a library track — it is an upcoming or
/// external release saved off the new-releases feed, identified by artist and
/// title rather than by a track id. Per profile.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct ListenLaterItem {
    pub id: String,
    pub profile_id: String,
    pub artist: String,
    pub title: String,
    pub title_key: String,
    pub upc: Option<String>,
    pub deezer_id: Option<i64>,
    pub cover: Option<String>,
    pub date: Option<String>,
    #[serde(rename = "type")]
    pub kind: String,
    pub added_at: String,
}

/// What a tag is attached to. `key` is a track id, an album id, or a
/// free-form artist name depending on `kind`.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct TagItem {
    pub kind: String,
    pub key: String,
}

/// A tag, or a folder of tags. Folders nest exactly one level and never hold
/// items themselves.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Tag {
    pub id: String,
    pub name: String,
    /// The containing folder's id, or `None` when the tag sits at top level.
    pub parent: Option<String>,
    pub folder: bool,
    pub items: Vec<TagItem>,
    pub created_at: String,
}

/// `GET /api/status` — the header line, and the capability probe that decides
/// whether the transcode tiers are worth offering.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct Status {
    pub version: String,
    pub tracks: i64,
    #[serde(rename = "musicDir")]
    pub music_dir: String,
    /// False when the server has no ffmpeg. The high/low stream tiers then
    /// answer 501, so the client must stay on the original.
    #[serde(rename = "transcode")]
    pub transcode: bool,
    /// Whether the loudness-analysis pass is available.
    #[serde(rename = "analyze")]
    pub analyze: bool,
    #[serde(rename = "fingerprint")]
    pub fingerprint: bool,
}

/// A play to report. `profile_id` is mandatory server-side: `POST /api/plays`
/// answers 400 without it.
#[derive(Debug, Clone, Serialize)]
pub struct PlayReport {
    #[serde(rename = "trackId")]
    pub track_id: String,
    #[serde(rename = "profileId")]
    pub profile_id: String,
    /// Must be the millisecond-precision `2006-01-02T15:04:05.000Z` layout —
    /// the server rejects anything else, and the stats window cutoffs compare
    /// these lexicographically.
    #[serde(rename = "at", skip_serializing_if = "Option::is_none")]
    pub at: Option<String>,
}

/// Which encoding to ask `/api/stream/{id}` for.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Tier {
    /// Bit-perfect passthrough of the original file. The server treats any
    /// unrecognised tier this way, but sending nothing is the honest request.
    #[default]
    Original,
    /// ~192 kbps Opus.
    High,
    /// ~96 kbps Opus.
    Low,
}

impl Tier {
    /// The `tier` query value, or `None` for the original (which takes no
    /// parameter).
    pub fn query_value(self) -> Option<&'static str> {
        match self {
            Tier::Original => None,
            Tier::High => Some("high"),
            Tier::Low => Some("low"),
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Tier::Original => "original",
            Tier::High => "high",
            Tier::Low => "low",
        }
    }

    pub fn parse(s: &str) -> Option<Tier> {
        match s.to_ascii_lowercase().as_str() {
            "original" | "" => Some(Tier::Original),
            "high" => Some(Tier::High),
            "low" => Some(Tier::Low),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn track_decodes_from_a_minimal_row() {
        // The server omits nothing in practice, but a client must survive a
        // trimmed row rather than dropping the whole library.
        let t: Track = serde_json::from_str(r#"{"id":"t1","title":"Song"}"#).unwrap();
        assert_eq!(t.id, "t1");
        assert_eq!(t.title, "Song");
        assert_eq!(t.duration, None);
        assert!(!t.favourite);
        assert!(t.tags.is_empty());
    }

    #[test]
    fn unknown_keys_do_not_break_decoding() {
        // Enrichment blobs spread arbitrary keys onto the row.
        let t: Track =
            serde_json::from_str(r#"{"id":"t1","orchestra":"LSO","somethingNew":42}"#).unwrap();
        assert_eq!(t.id, "t1");
    }

    #[test]
    fn null_gain_stays_none_rather_than_zero() {
        let t: Track =
            serde_json::from_str(r#"{"id":"t1","trackGainDb":null,"albumGainDb":null}"#).unwrap();
        assert_eq!(t.track_gain_db, None, "0 dB would be DSP on no evidence");
        assert_eq!(t.album_gain_db, None);
    }

    #[test]
    fn camel_case_fields_map_to_snake_case() {
        let t: Track = serde_json::from_str(
            r#"{"id":"t1","albumId":"a1","albumArtist":"AA","trackNo":3,
                "sampleRate":96000,"bitsPerSample":24,"releaseType":"Album",
                "hasArt":true,"addedAt":"2026-01-01T00:00:00.000Z"}"#,
        )
        .unwrap();
        assert_eq!(t.album_id, "a1");
        assert_eq!(t.album_artist, "AA");
        assert_eq!(t.track_no, Some(3));
        assert_eq!(t.sample_rate, Some(96000));
        assert_eq!(t.bits_per_sample, Some(24));
        assert_eq!(t.release_type, "Album");
        assert!(t.has_art);
    }

    #[test]
    fn display_artist_falls_back_to_album_artist() {
        let mut t = Track {
            album_artist: "Miles Davis".into(),
            ..Default::default()
        };
        assert_eq!(t.display_artist(), "Miles Davis");
        t.artist = "Miles Davis Quintet".into();
        assert_eq!(t.display_artist(), "Miles Davis Quintet");
    }

    #[test]
    fn quality_badge_reads_as_a_listener_would_write_it() {
        let hi = Track {
            format: "flac".into(),
            lossless: true,
            bits_per_sample: Some(24),
            sample_rate: Some(96000),
            ..Default::default()
        };
        assert_eq!(hi.quality_badge(), "FLAC 24/96");

        let cd = Track {
            format: "flac".into(),
            lossless: true,
            bits_per_sample: Some(16),
            sample_rate: Some(44100),
            ..Default::default()
        };
        assert_eq!(cd.quality_badge(), "FLAC 16/44.1");

        let lossy = Track {
            format: "mp3".into(),
            ..Default::default()
        };
        assert_eq!(lossy.quality_badge(), "MP3");
    }

    #[test]
    fn original_tier_sends_no_query_parameter() {
        assert_eq!(Tier::Original.query_value(), None);
        assert_eq!(Tier::High.query_value(), Some("high"));
        assert_eq!(Tier::Low.query_value(), Some("low"));
    }

    #[test]
    fn tier_parses_from_config_strings() {
        assert_eq!(Tier::parse("HIGH"), Some(Tier::High));
        assert_eq!(Tier::parse("original"), Some(Tier::Original));
        assert_eq!(Tier::parse(""), Some(Tier::Original));
        assert_eq!(Tier::parse("bogus"), None);
    }

    #[test]
    fn profile_decodes_its_camel_case_timestamp() {
        // Regression: without rename_all, `createdAt` never reached
        // `created_at` and every profile looked freshly unstamped.
        let p: Profile = serde_json::from_str(
            r##"{"id":"default","name":"Listener","color":"#6d3fd2",
                "createdAt":"2026-08-13T09:16:35Z"}"##,
        )
        .unwrap();
        assert_eq!(p.id, "default");
        assert_eq!(p.name, "Listener");
        assert_eq!(p.created_at, "2026-08-13T09:16:35Z");
    }

    #[test]
    fn play_report_omits_absent_timestamp() {
        let p = PlayReport {
            track_id: "t1".into(),
            profile_id: "p1".into(),
            at: None,
        };
        let s = serde_json::to_string(&p).unwrap();
        assert!(s.contains(r#""trackId":"t1""#));
        assert!(s.contains(r#""profileId":"p1""#));
        assert!(
            !s.contains("\"at\""),
            "absent `at` means the server stamps it"
        );
    }
}
