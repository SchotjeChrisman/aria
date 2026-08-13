//! Rendering tests.
//!
//! ratatui's `TestBackend` draws into a plain buffer, so the whole UI can be
//! exercised without a terminal. These assert the things a user would notice
//! immediately — that a view shows its content, that the transport reflects
//! playback, and that nothing panics at awkward sizes.

use ratatui::backend::TestBackend;
use ratatui::Terminal;

use aria_tui::api::models::{Playlist, Profile, Track};
use aria_tui::app::{App, Detail, Modal, View};
use aria_tui::config::Config;
use aria_tui::library::Library;
use aria_tui::player::Player;
use aria_tui::ui;

fn track(id: &str, title: &str, artist: &str, album: &str, album_id: &str, no: i64) -> Track {
    Track {
        id: id.into(),
        title: title.into(),
        artist: artist.into(),
        album_artist: artist.into(),
        album: album.into(),
        album_id: album_id.into(),
        track_no: Some(no),
        duration: Some(225.0),
        format: "flac".into(),
        lossless: true,
        bits_per_sample: Some(24),
        sample_rate: Some(96000),
        release_type: "Album".into(),
        ..Default::default()
    }
}

fn app() -> App {
    let mut a = App::new(
        Config::default(),
        std::env::temp_dir().join("aria-tui-render-test.toml"),
        Player::disabled(),
    );
    a.lib = Library::new(vec![
        track("t1", "So What", "Miles Davis", "Kind of Blue", "al1", 1),
        track(
            "t2",
            "Freddie Freeloader",
            "Miles Davis",
            "Kind of Blue",
            "al1",
            2,
        ),
        track("t3", "Take Five", "Dave Brubeck", "Time Out", "al2", 1),
    ]);
    a.cfg.profile_name = "Listener".into();
    a.cfg.profile_id = "p1".into();
    a.rerun_search();
    a
}

/// Renders one frame and returns it as plain text, one line per row.
fn render(app: &mut App, width: u16, height: u16) -> String {
    let mut terminal = Terminal::new(TestBackend::new(width, height)).unwrap();
    terminal.draw(|f| ui::draw(f, app)).unwrap();
    let buf = terminal.backend().buffer().clone();
    (0..buf.area.height)
        .map(|y| {
            (0..buf.area.width)
                .map(|x| buf[(x, y)].symbol().to_string())
                .collect::<String>()
        })
        .collect::<Vec<_>>()
        .join("\n")
}

#[test]
fn the_album_view_lists_albums_with_their_artists() {
    let mut a = app();
    let out = render(&mut a, 100, 30);
    assert!(out.contains("Albums"), "{out}");
    assert!(out.contains("Kind of Blue"), "{out}");
    assert!(out.contains("Time Out"), "{out}");
    assert!(out.contains("Miles Davis"), "{out}");
}

#[test]
fn every_view_renders_its_own_heading() {
    for (view, expected) in [
        (View::Albums, "Albums"),
        (View::Artists, "Artists"),
        (View::Tracks, "Tracks"),
        (View::Search, "Search"),
        (View::Queue, "Queue"),
        (View::Playlists, "Playlists"),
        (View::Tags, "Tags"),
        (View::Stats, "Stats"),
    ] {
        let mut a = app();
        a.view = view;
        let out = render(&mut a, 100, 30);
        assert!(
            out.contains(expected),
            "view {expected} did not render:\n{out}"
        );
    }
}

#[test]
fn the_tab_bar_shows_the_profile_name() {
    let mut a = app();
    let out = render(&mut a, 120, 20);
    assert!(out.contains("Listener"), "{out}");
}

#[test]
fn an_album_detail_shows_its_tracks_in_order() {
    let mut a = app();
    a.detail = Detail::Album("al1".into());
    let out = render(&mut a, 100, 30);
    assert!(out.contains("So What"), "{out}");
    assert!(out.contains("Freddie Freeloader"), "{out}");
    let so_what = out.find("So What").unwrap();
    let freddie = out.find("Freddie Freeloader").unwrap();
    assert!(so_what < freddie, "track 1 must come before track 2");
}

#[test]
fn the_transport_shows_the_playing_track_and_its_quality() {
    let mut a = app();
    a.play_tracks(vec!["t1".into()], 0);
    let out = render(&mut a, 120, 30);
    assert!(out.contains("So What"), "{out}");
    assert!(
        out.contains("FLAC 24/96"),
        "the quality badge should be visible:\n{out}"
    );
}

#[test]
fn an_empty_queue_says_so_rather_than_rendering_blank() {
    let mut a = app();
    a.view = View::Queue;
    let out = render(&mut a, 100, 20);
    assert!(out.contains("empty"), "{out}");
    assert!(out.contains("nothing playing"), "{out}");
}

#[test]
fn the_help_modal_lists_the_bindings() {
    let mut a = app();
    a.modal = Modal::Help;
    let out = render(&mut a, 100, 40);
    assert!(out.contains("Keys"), "{out}");
    assert!(out.contains("play / pause"), "{out}");
    assert!(out.contains("quit"), "{out}");
}

#[test]
fn the_profile_picker_renders_the_choices() {
    let mut a = app();
    a.profiles = vec![
        Profile {
            id: "p1".into(),
            name: "Alex".into(),
            ..Default::default()
        },
        Profile {
            id: "p2".into(),
            name: "Sam".into(),
            ..Default::default()
        },
    ];
    a.modal = Modal::ProfilePicker { selected: 1 };
    let out = render(&mut a, 100, 20);
    assert!(out.contains("Choose a profile"), "{out}");
    assert!(out.contains("Alex") && out.contains("Sam"), "{out}");
}

#[test]
fn the_playlist_picker_hides_smart_playlists() {
    // The server rejects adding a track to a smart playlist, so offering one
    // would be a guaranteed error.
    let mut a = app();
    a.playlists = vec![
        Playlist {
            id: "1".into(),
            name: "Mine".into(),
            kind: "manual".into(),
            ..Default::default()
        },
        Playlist {
            id: "2".into(),
            name: "Auto Rules".into(),
            kind: "smart".into(),
            ..Default::default()
        },
    ];
    a.modal = Modal::AddToPlaylist {
        track_ids: vec!["t1".into()],
        selected: 0,
    };
    let out = render(&mut a, 100, 20);
    assert!(out.contains("Mine"), "{out}");
    assert!(
        !out.contains("Auto Rules"),
        "a smart playlist must not be offered:\n{out}"
    );
}

#[test]
fn search_results_render_as_they_are_typed() {
    let mut a = app();
    a.view = View::Search;
    a.search_input = "brubeck".into();
    a.rerun_search();
    let out = render(&mut a, 100, 30);
    assert!(out.contains("Take Five"), "{out}");
    assert!(
        !out.contains("So What"),
        "non-matching tracks must be filtered out:\n{out}"
    );
}

#[test]
fn stats_resolve_album_and_track_ids_through_the_library() {
    // The real `/api/stats` payload: artists carry a name, but albums and
    // tracks carry only ids, and `week`/`month` are objects rather than counts.
    let mut a = app();
    a.stats = Some(serde_json::json!({
        "totalPlays": 5,
        "totalSeconds": 900,
        "uniqueTracks": 2,
        "week": { "plays": 4, "seconds": 700 },
        "month": { "plays": 5, "seconds": 900 },
        "topArtists": [ { "name": "Miles Davis", "count": 4 } ],
        "topAlbums": [ { "albumId": "al1", "count": 4 }, { "albumId": "gone", "count": 1 } ],
        "topTracks": [ { "id": "t1", "count": 4, "lastAt": "2026-08-13T09:21:21.051Z" } ],
    }));
    a.view = View::Stats;
    let out = render(&mut a, 110, 30);

    assert!(out.contains("plays 5"), "{out}");
    assert!(
        out.contains("this week 4"),
        "week is {{plays,seconds}}, not a number:\n{out}"
    );
    assert!(out.contains("Miles Davis"), "{out}");
    assert!(
        out.contains("Kind of Blue"),
        "an albumId must resolve to a title:\n{out}"
    );
    assert!(
        out.contains("So What"),
        "a track id must resolve to a title:\n{out}"
    );
    assert!(
        out.contains("not in library"),
        "an id the library no longer has should say so:\n{out}"
    );
}

#[test]
fn stats_with_no_plays_say_so() {
    let mut a = app();
    a.stats = Some(serde_json::json!({ "totalPlays": 0, "topArtists": [] }));
    a.view = View::Stats;
    let out = render(&mut a, 100, 20);
    assert!(out.contains("no plays recorded yet"), "{out}");
}

#[test]
fn scan_progress_takes_over_the_status_line() {
    let mut a = app();
    a.progress = Some(("scan".into(), 40, 100));
    let out = render(&mut a, 100, 20);
    assert!(out.contains("40/100"), "{out}");
}

#[test]
fn an_error_is_shown_on_the_status_line() {
    let mut a = app();
    a.error = Some("cannot reach server".into());
    let out = render(&mut a, 100, 20);
    assert!(out.contains("cannot reach server"), "{out}");
}

#[test]
fn a_loading_library_says_so() {
    let mut a = App::new(Config::default(), "/tmp/x.toml".into(), Player::disabled());
    a.loading = true;
    let out = render(&mut a, 80, 20);
    assert!(out.contains("Loading library"), "{out}");
}

#[test]
fn rendering_survives_a_very_small_terminal() {
    // A pane can end up with zero rows; every widget has to cope.
    for (w, h) in [(20u16, 8u16), (10, 6), (40, 5), (1, 1), (200, 4)] {
        for view in View::ALL {
            let mut a = app();
            a.view = view;
            render(&mut a, w, h);
        }
    }
}

#[test]
fn rendering_survives_an_empty_library() {
    for view in View::ALL {
        let mut a = App::new(Config::default(), "/tmp/x.toml".into(), Player::disabled());
        a.view = view;
        render(&mut a, 80, 24);
    }
}

#[test]
fn a_queued_track_missing_from_the_library_is_shown_not_dropped() {
    // The library can be reloaded while a queue references a deleted track.
    let mut a = app();
    a.play_tracks(vec!["t1".into(), "gone".into()], 0);
    a.view = View::Queue;
    let out = render(&mut a, 100, 20);
    assert!(out.contains("missing from library"), "{out}");
}

#[test]
fn long_metadata_does_not_overflow_the_columns() {
    let mut a = app();
    a.lib = Library::new(vec![track(
        "t1",
        "A Title That Is Considerably Longer Than Any Sensible Terminal Column Width",
        "An Artist With An Equally Unreasonable And Very Long Name Indeed",
        "And The Album Name Is No Better In This Regard At All",
        "al1",
        1,
    )]);
    a.view = View::Tracks;
    let width = 80;
    let out = render(&mut a, width, 20);
    for line in out.lines() {
        assert_eq!(
            line.chars().count(),
            width as usize,
            "a row overflowed its width:\n{line}"
        );
    }
}
