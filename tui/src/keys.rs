//! Key bindings.
//!
//! Split from [`crate::app`] so the binding table is one readable surface, and
//! so the modal and text-entry layers are visibly ahead of the global keys —
//! typing a playlist name must never trigger "p: previous track".

use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

use crate::api::models::Tier;
use crate::app::{App, ConfirmAction, Detail, Modal, Msg, PromptKind, View};

pub fn handle_key(app: &mut App, key: KeyEvent) {
    // A modal owns the keyboard completely.
    if app.modal != Modal::None {
        return handle_modal(app, key);
    }
    // So does the search box while it is being edited.
    if app.search_editing {
        return handle_search_input(app, key);
    }
    handle_global(app, key);
}

fn ctrl(key: &KeyEvent) -> bool {
    key.modifiers.contains(KeyModifiers::CONTROL)
}

fn alt(key: &KeyEvent) -> bool {
    key.modifiers.contains(KeyModifiers::ALT)
}

fn shift(key: &KeyEvent) -> bool {
    key.modifiers.contains(KeyModifiers::SHIFT)
}

/// Rows in the list the cursor is currently in.
fn current_len(app: &App) -> usize {
    match &app.detail {
        Detail::Album(id) => app.lib.album(id).map(|a| a.track_ids.len()).unwrap_or(0),
        Detail::Artist(name) => app.artist_tracks(name).len(),
        Detail::Playlist(_) => app.playlist_tracks.len(),
        Detail::Tag(name) => app.tag_tracks(name).len(),
        Detail::None => match app.view {
            View::Albums => app.lib.albums.len(),
            View::Artists => app.lib.artists.len(),
            View::Tracks => app.lib.tracks.len(),
            View::Search => app.search_hits.len(),
            View::Queue => app.queue.len(),
            View::Playlists => app.playlists.len(),
            View::Tags => app.tags.len(),
            View::Stats => 0,
        },
    }
}

fn list_mut(app: &mut App) -> &mut crate::app::ListState {
    if app.detail != Detail::None {
        return &mut app.detail_list;
    }
    match app.view {
        View::Albums => &mut app.albums_list,
        View::Artists => &mut app.artists_list,
        View::Tracks => &mut app.tracks_list,
        View::Search => &mut app.search_list,
        View::Queue => &mut app.queue_list,
        View::Playlists => &mut app.playlists_list,
        View::Tags => &mut app.tags_list,
        View::Stats => &mut app.detail_list,
    }
}

fn move_selection(app: &mut App, delta: isize) {
    let len = current_len(app);
    list_mut(app).move_by(delta, len);
}

fn handle_global(app: &mut App, key: KeyEvent) {
    match key.code {
        // ---- quitting ----
        KeyCode::Char('q') => app.should_quit = true,
        KeyCode::Char('c') if ctrl(&key) => app.should_quit = true,

        // ---- views ----
        KeyCode::Char(c @ '1'..='8') => {
            let idx = c as usize - '1' as usize;
            app.view = View::ALL[idx];
            app.detail = Detail::None;
            if app.view == View::Stats {
                app.load_stats();
            }
            if app.view == View::Tags && app.tags.is_empty() {
                app.load_tags();
            }
        }
        KeyCode::Tab => {
            let i = View::ALL.iter().position(|v| *v == app.view).unwrap_or(0);
            app.view = View::ALL[(i + 1) % View::ALL.len()];
            app.detail = Detail::None;
        }
        KeyCode::BackTab => {
            let i = View::ALL.iter().position(|v| *v == app.view).unwrap_or(0);
            app.view = View::ALL[(i + View::ALL.len() - 1) % View::ALL.len()];
            app.detail = Detail::None;
        }

        // ---- movement ----
        KeyCode::Char('j') | KeyCode::Down => move_selection(app, 1),
        KeyCode::Char('k') | KeyCode::Up => move_selection(app, -1),
        KeyCode::Char('d') if ctrl(&key) => move_selection(app, 10),
        KeyCode::Char('u') if ctrl(&key) => move_selection(app, -10),
        KeyCode::PageDown => move_selection(app, 20),
        KeyCode::PageUp => move_selection(app, -20),
        KeyCode::Char('g') | KeyCode::Home => {
            list_mut(app).selected = 0;
        }
        KeyCode::Char('G') | KeyCode::End => {
            let len = current_len(app);
            list_mut(app).selected = len.saturating_sub(1);
        }

        // ---- open / play ----
        KeyCode::Enter => activate(app),
        KeyCode::Esc => {
            if app.detail != Detail::None {
                app.detail = Detail::None;
            } else {
                app.error = None;
            }
        }

        // ---- transport ----
        KeyCode::Char(' ') => app.player.toggle_pause(),
        KeyCode::Char('n') if app.view == View::Playlists && app.detail == Detail::None => {
            app.modal = Modal::Prompt {
                kind: PromptKind::NewPlaylist,
                label: "New playlist name".into(),
                input: String::new(),
            };
        }
        KeyCode::Char('n') => app.play_next(),
        KeyCode::Char('p') => app.play_prev(),
        KeyCode::Char('x') => {
            app.player.stop();
            app.queue.clear();
        }
        KeyCode::Right if shift(&key) => app.player.seek_relative(30.0),
        KeyCode::Left if shift(&key) => app.player.seek_relative(-30.0),
        KeyCode::Right => app.player.seek_relative(5.0),
        KeyCode::Left => app.player.seek_relative(-5.0),
        KeyCode::Char('=') | KeyCode::Char('+') => {
            let v = app.player.state().volume + 5.0;
            app.player.set_volume(v);
            app.cfg.volume = v.clamp(0.0, 130.0);
        }
        KeyCode::Char('-') | KeyCode::Char('_') => {
            let v = app.player.state().volume - 5.0;
            app.player.set_volume(v);
            app.cfg.volume = v.clamp(0.0, 130.0);
        }
        KeyCode::Char('s') => {
            let on = app.queue.toggle_shuffle();
            // The shuffled order is a new playlist for mpv, so it is pushed.
            app.rebuild_player_queue_preserving_position();
            app.toast(if on { "shuffle on" } else { "shuffle off" });
        }
        KeyCode::Char('r') => {
            let mode = app.queue.cycle_repeat();
            app.apply_repeat();
            app.toast(format!("repeat {}", mode.label()));
        }

        // ---- queueing ----
        KeyCode::Char('a') => {
            let ids = app.selection();
            app.enqueue(ids, false);
        }
        KeyCode::Char('A') => {
            let ids = app.selection();
            app.enqueue(ids, true);
        }
        KeyCode::Char('f') => {
            if let Some(id) = current_track_id(app) {
                app.toggle_favourite(&id);
            }
        }
        KeyCode::Char('P') => {
            let ids = app.selection();
            if ids.is_empty() {
                app.toast("nothing selected");
            } else if app.cfg.profile_id.is_empty() {
                app.toast("choose a profile first");
            } else {
                app.modal = Modal::AddToPlaylist {
                    track_ids: ids,
                    selected: 0,
                };
            }
        }
        KeyCode::Char('d') => remove_selected(app),

        // ---- sorting ----
        // Adjacent keys for one idea: `,` picks the field, `.` flips it. The
        // list header names the order in force, so neither key has to be
        // remembered to know what the list is doing.
        KeyCode::Char(',') => app.cycle_sort(),
        KeyCode::Char('.') => app.reverse_sort(),

        // ---- search ----
        KeyCode::Char('/') => {
            app.view = View::Search;
            app.detail = Detail::None;
            app.search_editing = true;
        }

        // ---- misc ----
        KeyCode::Char('t') => {
            let next: String = match app.cfg.tier() {
                Tier::Original => "high",
                Tier::High => "low",
                Tier::Low => "original",
            }
            .into();
            app.persist_tier(next);
            let t = app.effective_tier();
            if t != app.cfg.tier() {
                app.toast("server cannot transcode — staying on the original");
            } else {
                app.toast(format!("stream tier: {}", t.label()));
            }
        }
        KeyCode::Char('R') => {
            app.load_library();
            app.load_status();
            app.toast("reloading library…");
        }
        KeyCode::Char('S') => {
            app.modal = Modal::Confirm {
                label: "Rescan the server's music library?".into(),
                action: ConfirmAction::Rescan,
            };
        }
        // Pre-filled with the current URL: changing a port or a hostname is
        // the common case, and retyping the whole thing to do it is not.
        KeyCode::Char('o') => {
            app.modal = Modal::Prompt {
                kind: PromptKind::ServerUrl,
                label: "Server URL".into(),
                input: app.cfg.server.clone(),
            };
        }
        KeyCode::Char('U') => {
            if app.profiles.is_empty() {
                app.load_profiles();
                app.toast("loading profiles…");
            } else {
                app.modal = Modal::ProfilePicker { selected: 0 };
            }
        }
        KeyCode::Char('?') => app.modal = Modal::Help,
        _ => {}
    }
}

/// The track under the cursor, for actions that act on exactly one.
fn current_track_id(app: &App) -> Option<String> {
    match (&app.detail, app.view) {
        (Detail::None, View::Albums) | (Detail::None, View::Artists) => {
            // On a collection row, the favourite key applies to what is
            // playing rather than to a whole album.
            app.current_track().map(|t| t.id.clone())
        }
        _ => app.selection().first().cloned(),
    }
}

fn activate(app: &mut App) {
    match app.detail.clone() {
        // Inside a collection, Enter plays the whole thing from the cursor —
        // playing one track and stopping is never what is wanted here.
        Detail::Album(id) => {
            if let Some(a) = app.lib.album(&id).cloned() {
                let start = app.detail_list.selected;
                app.play_tracks(a.track_ids, start);
            }
        }
        Detail::Artist(name) => {
            let ids = app.artist_tracks(&name);
            let start = app.detail_list.selected;
            app.play_tracks(ids, start);
        }
        Detail::Playlist(_) => {
            let ids: Vec<String> = app.playlist_tracks.iter().map(|t| t.id.clone()).collect();
            let start = app.detail_list.selected;
            app.play_tracks(ids, start);
        }
        Detail::Tag(name) => {
            let ids = app.tag_tracks(&name);
            let start = app.detail_list.selected;
            app.play_tracks(ids, start);
        }
        Detail::None => match app.view {
            View::Albums => {
                if let Some(a) = app.album_at(app.albums_list.selected) {
                    let id = a.id.clone();
                    app.detail = Detail::Album(id);
                    app.detail_list = Default::default();
                }
            }
            View::Artists => {
                if let Some(a) = app.artist_at(app.artists_list.selected) {
                    let name = a.name.clone();
                    app.detail = Detail::Artist(name);
                    app.detail_list = Default::default();
                }
            }
            View::Tags => {
                if let Some(t) = app.tags.get(app.tags_list.selected) {
                    let name = t.name.clone();
                    app.detail = Detail::Tag(name);
                    app.detail_list = Default::default();
                }
            }
            View::Playlists => {
                if let Some(p) = app.playlists.get(app.playlists_list.selected) {
                    let id = p.id.clone();
                    app.open_playlist(&id);
                }
            }
            // In a flat track list, Enter plays that list from the cursor, so
            // the rest of the view becomes the queue — in the order it is
            // shown in, not the order the library happens to hold.
            View::Tracks => {
                let ids: Vec<String> = (0..app.lib.tracks.len())
                    .filter_map(|row| app.track_at(row))
                    .map(|t| t.id.clone())
                    .collect();
                let start = app.tracks_list.selected;
                app.play_tracks(ids, start);
            }
            View::Search => {
                let ids: Vec<String> = app
                    .search_hits
                    .iter()
                    .filter_map(|&i| app.lib.tracks.get(i))
                    .map(|t| t.id.clone())
                    .collect();
                let start = app.search_list.selected;
                app.play_tracks(ids, start);
            }
            View::Queue => {
                let i = app.queue_list.selected;
                if i < app.queue.len() {
                    app.queue.select(i);
                    app.player.play_index(i);
                }
            }
            View::Stats => {}
        },
    }
}

/// `d` removes from the queue, or from a manual playlist — the two places
/// where removal is meaningful and reversible.
fn remove_selected(app: &mut App) {
    match app.detail.clone() {
        Detail::Playlist(pid) => {
            let Some(t) = app.playlist_tracks.get(app.detail_list.selected) else {
                return;
            };
            let tid = t.id.clone();
            let is_smart = app
                .playlists
                .iter()
                .find(|p| p.id == pid)
                .map(|p| p.is_smart())
                .unwrap_or(false);
            if is_smart {
                app.toast("a smart playlist is defined by its rules, not its tracks");
                return;
            }
            let tx = app.sender();
            let client = std::sync::Arc::clone(&app.client);
            std::thread::spawn(move || {
                let r = client.playlist_remove_track(&pid, &tid);
                let _ = tx.send(Msg::PlaylistChanged(r));
            });
            app.toast("removed from playlist");
        }
        Detail::None if app.view == View::Queue => {
            app.remove_from_queue(app.queue_list.selected);
        }
        Detail::None if app.view == View::Playlists => {
            if let Some(p) = app.playlists.get(app.playlists_list.selected) {
                app.modal = Modal::Confirm {
                    label: format!("Delete playlist \"{}\"?", p.name),
                    action: ConfirmAction::DeletePlaylist(p.id.clone()),
                };
            }
        }
        _ => {}
    }
}

fn handle_search_input(app: &mut App, key: KeyEvent) {
    match key.code {
        KeyCode::Esc | KeyCode::Enter => app.search_editing = false,
        KeyCode::Backspace => {
            app.search_input.pop();
            app.rerun_search();
        }
        KeyCode::Char('u') if ctrl(&key) => {
            app.search_input.clear();
            app.rerun_search();
        }
        KeyCode::Down => {
            app.search_editing = false;
            move_selection(app, 1);
        }
        // Ctrl-C still quits from inside the search box, and no other chord
        // may arrive as a literal letter.
        KeyCode::Char('c') if ctrl(&key) => app.should_quit = true,
        KeyCode::Char(_) if ctrl(&key) || alt(&key) => {}
        KeyCode::Char(c) => {
            app.search_input.push(c);
            app.rerun_search();
        }
        _ => {}
    }
}

fn handle_modal(app: &mut App, key: KeyEvent) {
    let modal = app.modal.clone();
    match modal {
        Modal::Help => {
            if matches!(
                key.code,
                KeyCode::Esc | KeyCode::Char('?') | KeyCode::Char('q')
            ) {
                app.modal = Modal::None;
            }
        }

        Modal::ProfilePicker { selected } => match key.code {
            KeyCode::Char('j') | KeyCode::Down => {
                let n = app.profiles.len();
                app.modal = Modal::ProfilePicker {
                    selected: (selected + 1).min(n.saturating_sub(1)),
                };
            }
            KeyCode::Char('k') | KeyCode::Up => {
                app.modal = Modal::ProfilePicker {
                    selected: selected.saturating_sub(1),
                };
            }
            KeyCode::Char('N') => {
                app.modal = Modal::Prompt {
                    kind: PromptKind::NewProfile,
                    label: "New profile name".into(),
                    input: String::new(),
                };
            }
            KeyCode::Enter => {
                if let Some(p) = app.profiles.get(selected).cloned() {
                    app.set_profile(&p);
                    app.modal = Modal::None;
                }
            }
            // Deliberately not escapable: without a profile the client cannot
            // record plays or list playlists, so the choice has to be made.
            _ => {}
        },

        Modal::AddToPlaylist {
            track_ids,
            selected,
        } => {
            let choices: Vec<crate::api::models::Playlist> = app
                .playlists
                .iter()
                .filter(|p| !p.is_smart())
                .cloned()
                .collect();
            match key.code {
                KeyCode::Esc => app.modal = Modal::None,
                KeyCode::Char('j') | KeyCode::Down => {
                    app.modal = Modal::AddToPlaylist {
                        track_ids,
                        selected: (selected + 1).min(choices.len().saturating_sub(1)),
                    };
                }
                KeyCode::Char('k') | KeyCode::Up => {
                    app.modal = Modal::AddToPlaylist {
                        track_ids,
                        selected: selected.saturating_sub(1),
                    };
                }
                KeyCode::Enter => {
                    if let Some(p) = choices.get(selected) {
                        let pid = p.id.clone();
                        let n = track_ids.len();
                        let tx = app.sender();
                        let client = std::sync::Arc::clone(&app.client);
                        // One request per track: the server takes a single
                        // trackId per call.
                        std::thread::spawn(move || {
                            for tid in &track_ids {
                                if let Err(e) = client.playlist_add_track(&pid, tid) {
                                    let _ = tx.send(Msg::Done(String::new(), Err(e)));
                                    return;
                                }
                            }
                            let _ = tx.send(Msg::Done(
                                format!("added {n} track{}", if n == 1 { "" } else { "s" }),
                                Ok(()),
                            ));
                        });
                        app.modal = Modal::None;
                        app.load_playlists();
                    }
                }
                _ => {}
            }
        }

        Modal::Prompt {
            kind,
            label,
            mut input,
        } => match key.code {
            KeyCode::Esc => {
                // Cancelling out of the first-run profile prompt returns to the
                // picker rather than leaving the app with no profile.
                app.modal = if kind == PromptKind::NewProfile && app.cfg.profile_id.is_empty() {
                    Modal::ProfilePicker { selected: 0 }
                } else {
                    Modal::None
                };
            }
            KeyCode::Backspace => {
                input.pop();
                app.modal = Modal::Prompt { kind, label, input };
            }
            KeyCode::Char('c') if ctrl(&key) => app.should_quit = true,
            KeyCode::Char('u') if ctrl(&key) => {
                input.clear();
                app.modal = Modal::Prompt { kind, label, input };
            }
            KeyCode::Char(_) if ctrl(&key) || alt(&key) => {
                app.modal = Modal::Prompt { kind, label, input };
            }
            KeyCode::Char(c) => {
                input.push(c);
                app.modal = Modal::Prompt { kind, label, input };
            }
            KeyCode::Enter => {
                let text = input.trim().to_string();
                if text.is_empty() {
                    // Closing outright would strand a first run with no
                    // profile and no way back to the picker.
                    app.modal = if kind == PromptKind::NewProfile && app.cfg.profile_id.is_empty() {
                        Modal::ProfilePicker { selected: 0 }
                    } else {
                        Modal::None
                    };
                    return;
                }
                match kind {
                    PromptKind::NewPlaylist => {
                        let pid = app.cfg.profile_id.clone();
                        if pid.is_empty() {
                            app.toast("choose a profile first");
                        } else {
                            let tx = app.sender();
                            let client = std::sync::Arc::clone(&app.client);
                            std::thread::spawn(move || {
                                let r = client.create_playlist(&text, &pid);
                                let _ = tx.send(Msg::PlaylistChanged(r));
                            });
                        }
                    }
                    PromptKind::NewProfile => {
                        let tx = app.sender();
                        let client = std::sync::Arc::clone(&app.client);
                        std::thread::spawn(move || {
                            // The server requires a #rrggbb colour.
                            let r = client.create_profile(&text, "#7aa2f7");
                            let _ = tx.send(Msg::ProfileCreated(r));
                        });
                    }
                    PromptKind::ServerUrl => app.switch_server(text),
                }
                app.modal = Modal::None;
            }
            _ => {}
        },

        Modal::Confirm { action, .. } => match key.code {
            KeyCode::Char('y') | KeyCode::Char('Y') => {
                match action {
                    ConfirmAction::DeletePlaylist(id) => {
                        let tx = app.sender();
                        let client = std::sync::Arc::clone(&app.client);
                        std::thread::spawn(move || {
                            let r = client.delete_playlist(&id);
                            let _ = tx.send(Msg::Done("playlist deleted".into(), r));
                        });
                        app.detail = Detail::None;
                        app.load_playlists();
                    }
                    ConfirmAction::Rescan => {
                        let tx = app.sender();
                        let client = std::sync::Arc::clone(&app.client);
                        // The server runs the scan synchronously, so this
                        // request stays open for its whole duration; progress
                        // arrives separately on the SSE stream.
                        std::thread::spawn(move || {
                            let r = client.scan().map(|_| ());
                            let _ = tx.send(Msg::Done("scan finished".into(), r));
                        });
                        app.toast("scan started…");
                    }
                }
                app.modal = Modal::None;
            }
            _ => app.modal = Modal::None,
        },

        Modal::None => {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::Config;
    use crate::player::Player;
    use crossterm::event::KeyEventKind;

    fn app() -> App {
        let mut a = App::new(
            Config::default(),
            "/tmp/aria-tui-test.toml".into(),
            Player::disabled(),
        );
        a.lib = crate::library::Library::new(vec![
            track("t1", "One", "al1", 1),
            track("t2", "Two", "al1", 2),
            track("t3", "Three", "al2", 1),
        ]);
        a.rerun_search();
        a
    }

    fn track(id: &str, title: &str, album_id: &str, no: i64) -> crate::api::models::Track {
        crate::api::models::Track {
            id: id.into(),
            title: title.into(),
            artist: "Artist".into(),
            album_artist: "Artist".into(),
            album: format!("Album {album_id}"),
            album_id: album_id.into(),
            track_no: Some(no),
            duration: Some(180.0),
            ..Default::default()
        }
    }

    fn k(code: KeyCode) -> KeyEvent {
        KeyEvent {
            code,
            modifiers: KeyModifiers::NONE,
            kind: KeyEventKind::Press,
            state: crossterm::event::KeyEventState::NONE,
        }
    }

    fn kc(code: KeyCode, m: KeyModifiers) -> KeyEvent {
        KeyEvent {
            modifiers: m,
            ..k(code)
        }
    }

    #[test]
    fn number_keys_switch_views() {
        let mut a = app();
        handle_key(&mut a, k(KeyCode::Char('5')));
        assert_eq!(a.view, View::Queue);
        handle_key(&mut a, k(KeyCode::Char('1')));
        assert_eq!(a.view, View::Albums);
    }

    #[test]
    fn tab_cycles_and_wraps() {
        let mut a = app();
        for _ in 0..View::ALL.len() {
            handle_key(&mut a, k(KeyCode::Tab));
        }
        assert_eq!(a.view, View::Albums, "a full cycle returns to the start");
    }

    #[test]
    fn movement_is_clamped_to_the_list() {
        let mut a = app();
        a.view = View::Tracks;
        for _ in 0..10 {
            handle_key(&mut a, k(KeyCode::Char('j')));
        }
        assert_eq!(
            a.tracks_list.selected, 2,
            "3 tracks means index 2 is the last"
        );
        handle_key(&mut a, k(KeyCode::Char('g')));
        assert_eq!(a.tracks_list.selected, 0);
        handle_key(&mut a, k(KeyCode::Char('G')));
        assert_eq!(a.tracks_list.selected, 2);
    }

    #[test]
    fn enter_opens_an_album_then_plays_from_the_cursor() {
        let mut a = app();
        a.view = View::Albums;
        handle_key(&mut a, k(KeyCode::Enter));
        assert!(
            matches!(a.detail, Detail::Album(_)),
            "first Enter drills in"
        );

        handle_key(&mut a, k(KeyCode::Char('j')));
        handle_key(&mut a, k(KeyCode::Enter));
        assert_eq!(a.queue.len(), 2, "the whole album is queued");
        assert_eq!(a.queue.pos(), Some(1), "playback starts at the cursor");
    }

    #[test]
    fn escape_leaves_a_detail_view() {
        let mut a = app();
        a.view = View::Albums;
        handle_key(&mut a, k(KeyCode::Enter));
        handle_key(&mut a, k(KeyCode::Esc));
        assert_eq!(a.detail, Detail::None);
    }

    #[test]
    fn slash_opens_search_and_typing_filters() {
        let mut a = app();
        handle_key(&mut a, k(KeyCode::Char('/')));
        assert_eq!(a.view, View::Search);
        assert!(a.search_editing);

        for c in "three".chars() {
            handle_key(&mut a, k(KeyCode::Char(c)));
        }
        assert_eq!(a.search_input, "three");
        assert_eq!(a.search_hits.len(), 1);
    }

    #[test]
    fn typing_in_search_does_not_trigger_transport_keys() {
        // 'n' is next-track globally; inside the search box it is a letter.
        let mut a = app();
        handle_key(&mut a, k(KeyCode::Char('/')));
        for c in "no one".chars() {
            handle_key(&mut a, k(KeyCode::Char(c)));
        }
        assert_eq!(a.search_input, "no one");
        assert!(a.queue.is_empty(), "no playback should have been triggered");
    }

    #[test]
    fn escape_leaves_the_search_box_editable_again() {
        let mut a = app();
        handle_key(&mut a, k(KeyCode::Char('/')));
        handle_key(&mut a, k(KeyCode::Esc));
        assert!(!a.search_editing);
        // Now the global bindings are back.
        handle_key(&mut a, k(KeyCode::Char('1')));
        assert_eq!(a.view, View::Albums);
    }

    #[test]
    fn backspace_and_ctrl_u_edit_the_query() {
        let mut a = app();
        handle_key(&mut a, k(KeyCode::Char('/')));
        for c in "one".chars() {
            handle_key(&mut a, k(KeyCode::Char(c)));
        }
        handle_key(&mut a, k(KeyCode::Backspace));
        assert_eq!(a.search_input, "on");
        handle_key(&mut a, kc(KeyCode::Char('u'), KeyModifiers::CONTROL));
        assert_eq!(a.search_input, "");
    }

    #[test]
    fn help_opens_and_closes() {
        let mut a = app();
        handle_key(&mut a, k(KeyCode::Char('?')));
        assert_eq!(a.modal, Modal::Help);
        handle_key(&mut a, k(KeyCode::Esc));
        assert_eq!(a.modal, Modal::None);
    }

    #[test]
    fn a_modal_swallows_global_keys() {
        let mut a = app();
        handle_key(&mut a, k(KeyCode::Char('?')));
        handle_key(&mut a, k(KeyCode::Char('3')));
        assert_eq!(
            a.view,
            View::Albums,
            "the view must not change behind the modal"
        );
        assert!(!a.should_quit);
    }

    #[test]
    fn the_profile_picker_cannot_be_escaped() {
        // Without a profile there is no play reporting and no playlist list,
        // so the choice is mandatory.
        let mut a = app();
        a.modal = Modal::ProfilePicker { selected: 0 };
        handle_key(&mut a, k(KeyCode::Esc));
        assert!(matches!(a.modal, Modal::ProfilePicker { .. }));
    }

    #[test]
    fn q_quits_but_not_while_typing() {
        let mut a = app();
        handle_key(&mut a, k(KeyCode::Char('/')));
        handle_key(&mut a, k(KeyCode::Char('q')));
        assert!(!a.should_quit, "q is a letter inside the search box");
        assert_eq!(a.search_input, "q");

        handle_key(&mut a, k(KeyCode::Esc));
        handle_key(&mut a, k(KeyCode::Char('q')));
        assert!(a.should_quit);
    }

    #[test]
    fn n_creates_a_playlist_in_the_playlist_view_but_skips_tracks_elsewhere() {
        let mut a = app();
        a.view = View::Playlists;
        handle_key(&mut a, k(KeyCode::Char('n')));
        assert!(
            matches!(
                a.modal,
                Modal::Prompt {
                    kind: PromptKind::NewPlaylist,
                    ..
                }
            ),
            "n opens the new-playlist prompt here"
        );

        let mut b = app();
        b.view = View::Tracks;
        handle_key(&mut b, k(KeyCode::Char('n')));
        assert_eq!(b.modal, Modal::None, "elsewhere n is next-track");
    }

    #[test]
    fn a_queues_the_selection_without_starting_playback_elsewhere() {
        let mut a = app();
        a.view = View::Tracks;
        handle_key(&mut a, k(KeyCode::Char('a')));
        assert_eq!(a.queue.len(), 1);
    }

    #[test]
    fn shuffle_and_repeat_toggle() {
        let mut a = app();
        assert!(!a.queue.shuffle());
        handle_key(&mut a, k(KeyCode::Char('s')));
        assert!(a.queue.shuffle());
        handle_key(&mut a, k(KeyCode::Char('r')));
        assert_eq!(a.queue.repeat(), crate::queue::Repeat::All);
    }

    #[test]
    fn tier_cycles_through_the_three_values() {
        let mut a = app();
        assert_eq!(a.cfg.tier(), Tier::Original);
        handle_key(&mut a, k(KeyCode::Char('t')));
        assert_eq!(a.cfg.tier(), Tier::High);
        handle_key(&mut a, k(KeyCode::Char('t')));
        assert_eq!(a.cfg.tier(), Tier::Low);
        handle_key(&mut a, k(KeyCode::Char('t')));
        assert_eq!(a.cfg.tier(), Tier::Original);
    }

    #[test]
    fn removing_from_the_queue_keeps_the_list_consistent() {
        let mut a = app();
        a.view = View::Tracks;
        handle_key(&mut a, k(KeyCode::Enter)); // queue all three
        a.view = View::Queue;
        a.queue_list.selected = 1;
        handle_key(&mut a, k(KeyCode::Char('d')));
        assert_eq!(a.queue.len(), 2);
        assert!(a.queue_list.selected < a.queue.len());
    }

    #[test]
    fn removing_the_last_queue_entry_stops_playback() {
        // Regression: the queue emptied but mpv was left playing the entry,
        // because the resync bailed out on an empty queue.
        let mut a = app();
        a.view = View::Tracks;
        handle_key(&mut a, k(KeyCode::Enter));
        a.view = View::Queue;
        for _ in 0..3 {
            a.queue_list.selected = 0;
            handle_key(&mut a, k(KeyCode::Char('d')));
        }
        assert!(a.queue.is_empty());
        assert_eq!(a.queue.pos(), None);
        assert!(
            a.current_track().is_none(),
            "nothing should still be playing"
        );
    }

    #[test]
    fn removing_the_playing_entry_moves_to_the_next_track() {
        let mut a = app();
        a.view = View::Tracks;
        handle_key(&mut a, k(KeyCode::Enter)); // queue all three, playing t1
        assert_eq!(a.queue.current().unwrap(), "t1");
        a.view = View::Queue;
        a.queue_list.selected = 0;
        handle_key(&mut a, k(KeyCode::Char('d')));
        assert_eq!(
            a.queue.current().unwrap(),
            "t2",
            "the next track takes over"
        );
        assert_eq!(a.queue.len(), 2);
    }

    #[test]
    fn ctrl_chords_are_not_typed_into_the_search_box() {
        // Regression: Char(c) had no modifier guard, so Ctrl-A/Ctrl-W/Ctrl-C
        // arrived as literal letters in the query.
        let mut a = app();
        handle_key(&mut a, k(KeyCode::Char('/')));
        for c in "so".chars() {
            handle_key(&mut a, k(KeyCode::Char(c)));
        }
        for c in ['a', 'w', 'e', 'k'] {
            handle_key(&mut a, kc(KeyCode::Char(c), KeyModifiers::CONTROL));
        }
        assert_eq!(a.search_input, "so", "no chord may become text");
    }

    #[test]
    fn ctrl_c_quits_even_while_typing() {
        // Regression: the text layer swallowed every Char, so the only quit
        // binding was unreachable with the search box open.
        let mut a = app();
        handle_key(&mut a, k(KeyCode::Char('/')));
        handle_key(&mut a, kc(KeyCode::Char('c'), KeyModifiers::CONTROL));
        assert!(a.should_quit);
        assert_eq!(a.search_input, "", "and it must not type a 'c' first");
    }

    #[test]
    fn ctrl_c_quits_from_a_text_prompt() {
        let mut a = app();
        a.view = View::Playlists;
        handle_key(&mut a, k(KeyCode::Char('n')));
        handle_key(&mut a, k(KeyCode::Char('x')));
        handle_key(&mut a, kc(KeyCode::Char('c'), KeyModifiers::CONTROL));
        assert!(a.should_quit);
    }

    #[test]
    fn an_empty_new_profile_name_returns_to_the_picker() {
        // Regression: it closed the modal outright, leaving a first run with
        // no profile and no way to reach the picker again.
        let mut a = app();
        a.cfg.profile_id.clear();
        a.modal = Modal::ProfilePicker { selected: 0 };
        handle_key(&mut a, k(KeyCode::Char('N')));
        assert!(matches!(a.modal, Modal::Prompt { .. }));

        handle_key(&mut a, k(KeyCode::Enter)); // nothing typed
        assert!(
            matches!(a.modal, Modal::ProfilePicker { .. }),
            "the mandatory choice must still be offered, got {:?}",
            a.modal
        );
    }

    #[test]
    fn the_profile_picker_can_be_reopened_to_switch_profiles() {
        let mut a = app();
        a.profiles = vec![crate::api::models::Profile {
            id: "p1".into(),
            name: "Alex".into(),
            ..Default::default()
        }];
        handle_key(&mut a, k(KeyCode::Char('U')));
        assert!(matches!(a.modal, Modal::ProfilePicker { .. }));
    }

    #[test]
    fn ctrl_c_quits() {
        let mut a = app();
        handle_key(&mut a, kc(KeyCode::Char('c'), KeyModifiers::CONTROL));
        assert!(a.should_quit);
    }

    #[test]
    fn stats_view_has_no_list_to_move_and_does_not_panic() {
        let mut a = app();
        a.view = View::Stats;
        handle_key(&mut a, k(KeyCode::Char('j')));
        handle_key(&mut a, k(KeyCode::Char('G')));
        handle_key(&mut a, k(KeyCode::Enter));
    }

    #[test]
    fn actions_on_an_empty_library_do_not_panic() {
        let mut a = App::new(Config::default(), "/tmp/x.toml".into(), Player::disabled());
        for key in [
            KeyCode::Enter,
            KeyCode::Char('a'),
            KeyCode::Char('f'),
            KeyCode::Char('d'),
            KeyCode::Char('j'),
            KeyCode::Char('G'),
            KeyCode::Char(','),
            KeyCode::Char('.'),
        ] {
            handle_key(&mut a, k(key));
        }
    }

    #[test]
    fn the_sort_keys_cycle_the_field_and_flip_the_direction() {
        use crate::library::{ListKind, SortField};
        let mut a = app();
        a.view = View::Tracks;

        handle_key(&mut a, k(KeyCode::Char(',')));
        assert_eq!(a.lib.sort(ListKind::Tracks).field, SortField::Title);
        assert!(!a.lib.sort(ListKind::Tracks).desc);

        handle_key(&mut a, k(KeyCode::Char('.')));
        assert!(a.lib.sort(ListKind::Tracks).desc);
        assert_eq!(
            a.lib.sort(ListKind::Tracks).field,
            SortField::Title,
            "reversing does not move on to the next field"
        );
    }

    #[test]
    fn enter_plays_the_track_list_in_the_order_it_is_shown() {
        use crate::library::{ListKind, Sort, SortField};
        let mut a = app();
        a.view = View::Tracks;
        let mut s = a.lib.sorts();
        s.set(ListKind::Tracks, Sort::new(SortField::Title).reversed());
        a.lib.set_sorts(s);

        handle_key(&mut a, k(KeyCode::Enter));
        // Titles are One, Two, Three; reversed by title that is Two, Three, One.
        assert_eq!(
            a.queue.items(),
            &["t2".to_string(), "t3".to_string(), "t1".to_string()],
            "queueing a sorted list must follow the screen, not the load order"
        );
    }
}
