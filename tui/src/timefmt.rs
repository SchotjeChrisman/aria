//! Time formatting, hand-rolled to keep the client dependency-free.
//!
//! The important one is [`iso_now`]: `POST /api/plays` accepts a client
//! timestamp only in the exact millisecond-precision layout JavaScript's
//! `toISOString()` produces, and rejects anything else with a 400. The stats
//! window cutoffs then compare those strings lexicographically, so the layout
//! is load-bearing rather than cosmetic.

use std::time::{SystemTime, UNIX_EPOCH};

/// `2026-08-13T09:41:07.250Z` — exactly what the server parses.
pub fn iso_now() -> String {
    iso_from_millis(
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0),
    )
}

/// Formats Unix milliseconds as the server's timestamp layout.
pub fn iso_from_millis(ms: i64) -> String {
    let (days, ms_of_day) = {
        let d = ms.div_euclid(86_400_000);
        let r = ms.rem_euclid(86_400_000);
        (d, r)
    };
    let (y, mo, d) = civil_from_days(days);
    let secs_of_day = ms_of_day / 1000;
    let (h, mi, s) = (
        secs_of_day / 3600,
        (secs_of_day % 3600) / 60,
        secs_of_day % 60,
    );
    format!(
        "{y:04}-{mo:02}-{d:02}T{h:02}:{mi:02}:{s:02}.{:03}Z",
        ms_of_day % 1000
    )
}

/// Howard Hinnant's civil-from-days: days since the Unix epoch to a calendar
/// date, correct for the proleptic Gregorian calendar including leap years.
fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u64; // [0, 146096]
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365; // [0, 399]
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
    let mp = (5 * doy + 2) / 153; // [0, 11]
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32; // [1, 31]
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32; // [1, 12]
    (if m <= 2 { y + 1 } else { y }, m, d)
}

/// `3:07` or `1:02:33` — how a listener reads a track length.
pub fn hms(seconds: f64) -> String {
    if !seconds.is_finite() || seconds < 0.0 {
        return "0:00".into();
    }
    let total = seconds.round() as u64;
    let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60);
    if h > 0 {
        format!("{h}:{m:02}:{s:02}")
    } else {
        format!("{m}:{s:02}")
    }
}

/// A long duration in words, for album and queue totals.
pub fn human_duration(seconds: f64) -> String {
    let total = seconds.max(0.0).round() as u64;
    let (h, m) = (total / 3600, (total % 3600) / 60);
    match (h, m) {
        (0, 0) => format!("{total} sec"),
        (0, m) => format!("{m} min"),
        (h, 0) => format!("{h} hr"),
        (h, m) => format!("{h} hr {m} min"),
    }
}

/// The point at which a play counts, in seconds into the track.
///
/// Aria enforces nothing server-side, so the client applies the usual
/// convention: half the track, capped at 30 seconds. A track with no tagged
/// duration is treated as a typical 60-second-plus one and reports at 30s
/// rather than never reporting at all.
pub fn scrobble_threshold(duration: Option<f64>, fraction: f64) -> f64 {
    let d = match duration {
        Some(d) if d > 0.0 => d,
        _ => 60.0,
    };
    (d * fraction.clamp(0.05, 1.0)).min(30.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn iso_layout_matches_what_the_server_parses() {
        // The server parses exactly "2006-01-02T15:04:05.000Z".
        let s = iso_from_millis(0);
        assert_eq!(s, "1970-01-01T00:00:00.000Z");
        assert_eq!(s.len(), 24);
        assert!(s.ends_with('Z'));
    }

    #[test]
    fn iso_handles_a_real_timestamp() {
        assert_eq!(
            iso_from_millis(1_786_599_667_250),
            "2026-08-13T05:41:07.250Z"
        );
    }

    #[test]
    fn iso_handles_leap_days() {
        // 2024-02-29T12:00:00.000Z
        assert_eq!(
            iso_from_millis(1_709_208_000_000),
            "2024-02-29T12:00:00.000Z"
        );
    }

    #[test]
    fn iso_handles_a_century_non_leap_year() {
        // 1900 was not a leap year; 2000 was. 2000-03-01T00:00:00.000Z
        assert_eq!(iso_from_millis(951_868_800_000), "2000-03-01T00:00:00.000Z");
    }

    #[test]
    fn iso_milliseconds_are_zero_padded() {
        assert_eq!(iso_from_millis(5), "1970-01-01T00:00:00.005Z");
        assert_eq!(iso_from_millis(50), "1970-01-01T00:00:00.050Z");
    }

    #[test]
    fn iso_now_is_the_right_shape() {
        let s = iso_now();
        assert_eq!(s.len(), 24, "{s}");
        let b = s.as_bytes();
        assert_eq!(b[4], b'-');
        assert_eq!(b[7], b'-');
        assert_eq!(b[10], b'T');
        assert_eq!(b[13], b':');
        assert_eq!(b[16], b':');
        assert_eq!(b[19], b'.');
        assert_eq!(b[23], b'Z');
        assert!(s.starts_with("20"), "expected a current year, got {s}");
    }

    #[test]
    fn timestamps_sort_lexicographically_in_time_order() {
        // The stats cutoffs depend on this.
        let a = iso_from_millis(1_700_000_000_000);
        let b = iso_from_millis(1_800_000_000_000);
        assert!(a < b);
    }

    #[test]
    fn hms_reads_like_a_track_length() {
        assert_eq!(hms(0.0), "0:00");
        assert_eq!(hms(7.0), "0:07");
        assert_eq!(hms(187.0), "3:07");
        assert_eq!(hms(3753.0), "1:02:33");
    }

    #[test]
    fn hms_survives_nonsense_input() {
        // mpv reports no duration as 0, and time-pos can arrive negative
        // during a seek.
        assert_eq!(hms(-5.0), "0:00");
        assert_eq!(hms(f64::NAN), "0:00");
        assert_eq!(hms(f64::INFINITY), "0:00");
    }

    #[test]
    fn human_duration_reads_naturally() {
        assert_eq!(human_duration(45.0), "45 sec");
        assert_eq!(human_duration(600.0), "10 min");
        assert_eq!(human_duration(7200.0), "2 hr");
        assert_eq!(human_duration(3900.0), "1 hr 5 min");
    }

    #[test]
    fn scrobble_threshold_is_half_a_track_capped_at_thirty_seconds() {
        assert_eq!(scrobble_threshold(Some(40.0), 0.5), 20.0);
        assert_eq!(
            scrobble_threshold(Some(600.0), 0.5),
            30.0,
            "a long track still counts at 30s"
        );
    }

    #[test]
    fn an_untagged_duration_still_reports_rather_than_never() {
        assert_eq!(scrobble_threshold(None, 0.5), 30.0);
        assert_eq!(scrobble_threshold(Some(0.0), 0.5), 30.0);
    }
}
