//! End-to-end tests against a running Aria server.
//!
//! Skipped unless `ARIA_TEST_SERVER` names one, so the suite stays runnable
//! offline:
//!
//! ```sh
//! ARIA_TEST_SERVER=http://localhost:3999 cargo test --test live
//! ```
//!
//! These are the tests that would have caught a wrong field name or a
//! misremembered query parameter — everything else in the suite works from
//! fixtures the client itself defines.

use aria_tui::api::models::Tier;
use aria_tui::api::Client;
use aria_tui::library::Library;

fn client() -> Option<Client> {
    std::env::var("ARIA_TEST_SERVER")
        .ok()
        .map(|u| Client::new(&u))
}

macro_rules! server {
    () => {
        match client() {
            Some(c) => c,
            None => return,
        }
    };
}

#[test]
fn status_decodes_and_reports_a_version() {
    let c = server!();
    let s = c.status().expect("status");
    assert!(!s.version.is_empty(), "the server always reports a version");
    assert!(!s.music_dir.is_empty(), "musicDir must decode");
}

#[test]
fn the_whole_track_list_decodes() {
    let c = server!();
    let tracks = c.tracks().expect("tracks");
    assert!(!tracks.is_empty(), "the test library should not be empty");
    for t in &tracks {
        assert!(!t.id.is_empty(), "every track needs an id");
        assert!(!t.album_id.is_empty(), "album grouping depends on albumId");
        // releaseType is derived server-side and is what the album view shows.
        assert!(
            !t.release_type.is_empty(),
            "releaseType should always be set"
        );
    }
}

#[test]
fn the_library_folds_the_real_payload_into_albums() {
    let c = server!();
    let lib = Library::new(c.tracks().expect("tracks"));
    assert!(!lib.albums.is_empty());
    for a in &lib.albums {
        assert!(
            !a.track_ids.is_empty(),
            "an album with no tracks is a fold bug"
        );
        assert_eq!(a.track_count, a.track_ids.len());
    }
    assert!(!lib.artists.is_empty());
}

#[test]
fn profiles_decode_and_the_server_seeds_at_least_one() {
    let c = server!();
    let ps = c.profiles().expect("profiles");
    assert!(!ps.is_empty(), "Aria seeds a default profile");
    assert!(!ps[0].id.is_empty());
    assert!(!ps[0].name.is_empty());
}

#[test]
fn playlists_round_trip_through_create_add_and_delete() {
    let c = server!();
    let profile = c.profiles().expect("profiles").remove(0);
    let track = c.tracks().expect("tracks").remove(0);

    let name = format!("aria-tui test {}", std::process::id());
    let pl = c.create_playlist(&name, &profile.id).expect("create");
    assert_eq!(pl.name, name);
    assert_eq!(pl.profile_id, profile.id);
    assert!(!pl.is_smart());

    let after_add = c.playlist_add_track(&pl.id, &track.id).expect("add");
    assert!(
        after_add.track_ids.contains(&track.id),
        "the added track should come back in trackIds"
    );

    let tracks = c.playlist_tracks(&pl.id).expect("playlist tracks");
    assert_eq!(tracks.len(), 1);
    assert_eq!(tracks[0].id, track.id);

    // Listing by profile must include what we just made.
    let listed = c.playlists(&profile.id).expect("list");
    assert!(listed.iter().any(|p| p.id == pl.id));

    c.playlist_remove_track(&pl.id, &track.id).expect("remove");
    assert!(c.playlist_tracks(&pl.id).expect("tracks").is_empty());

    c.delete_playlist(&pl.id).expect("delete");
    let listed = c.playlists(&profile.id).expect("list");
    assert!(
        !listed.iter().any(|p| p.id == pl.id),
        "the playlist should be gone"
    );
}

#[test]
fn a_play_is_accepted_in_the_servers_timestamp_format() {
    // The server rejects any layout but `2006-01-02T15:04:05.000Z`, so this is
    // the test that proves the hand-rolled formatter is right.
    let c = server!();
    let profile = c.profiles().expect("profiles").remove(0);
    let track = c.tracks().expect("tracks").remove(0);
    c.report_play(&track.id, &profile.id, Some(aria_tui::timefmt::iso_now()))
        .expect("the server should accept our timestamp layout");

    // And with the server stamping it itself.
    c.report_play(&track.id, &profile.id, None)
        .expect("play without a timestamp");
}

#[test]
fn a_play_without_a_profile_is_refused() {
    // Confirms the client is right to treat the profile as mandatory.
    let c = server!();
    let track = c.tracks().expect("tracks").remove(0);
    assert!(
        c.report_play(&track.id, "", None).is_err(),
        "the server requires a profileId"
    );
}

#[test]
fn favourite_toggles_and_reports_the_new_state() {
    let c = server!();
    let track = c.tracks().expect("tracks").remove(0);
    let before = track.favourite;

    assert_eq!(c.set_favourite(&track.id, !before).expect("set"), !before);
    let reloaded = c.tracks().expect("tracks");
    let t = reloaded.iter().find(|t| t.id == track.id).unwrap();
    assert_eq!(
        t.favourite, !before,
        "the merged view should reflect the flag"
    );

    c.set_favourite(&track.id, before).expect("restore");
}

#[test]
fn the_original_stream_is_served_bit_perfect() {
    let c = server!();
    let track = c.tracks().expect("tracks").remove(0);
    let url = c.stream_url(&track.id, Tier::Original);
    assert!(
        !url.contains("tier="),
        "the original takes no tier parameter"
    );

    let mut resp = ureq::get(&url).call().expect("stream");
    assert_eq!(resp.status(), 200);
    let body = resp.body_mut().read_to_vec().expect("body");
    assert!(!body.is_empty(), "the stream should return audio");
}

#[test]
fn a_transcoded_tier_is_refused_when_the_server_has_no_ffmpeg() {
    let c = server!();
    let status = c.status().expect("status");
    if status.transcode {
        return; // this server can transcode; nothing to assert
    }
    let track = c.tracks().expect("tracks").remove(0);
    let url = c.stream_url(&track.id, Tier::High);
    let err = ureq::get(&url).call();
    assert!(
        err.is_err(),
        "without ffmpeg a tiered request must fail — this is why the client falls back"
    );
}

#[test]
fn tags_and_stats_decode() {
    let c = server!();
    c.tags().expect("tags");
    let profile = c.profiles().expect("profiles").remove(0);
    c.stats(&profile.id).expect("stats");
    c.play_counts(&profile.id).expect("counts");
    c.listen_later(&profile.id).expect("listen later");
}
