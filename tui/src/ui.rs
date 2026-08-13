//! Rendering. Pure functions of [`App`] — no state of their own, so what is on
//! screen is always exactly what the app holds.

use ratatui::layout::{Alignment, Constraint, Direction, Layout, Rect};
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, BorderType, Clear, Gauge, List, ListItem, Paragraph, Tabs, Wrap};
use ratatui::Frame;

use crate::app::{App, Detail, Modal, View};
use crate::library::{ListKind, SortField};
use crate::theme::Theme;
use crate::timefmt::{hms, human_duration};

pub fn draw(f: &mut Frame, app: &mut App) {
    let theme = Theme::from_name(&app.cfg.theme);
    let area = f.area();

    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(1), // tab bar
            Constraint::Min(3),    // content
            Constraint::Length(4), // now playing
            Constraint::Length(1), // status line
        ])
        .split(area);

    draw_tabs(f, app, &theme, chunks[0]);
    draw_content(f, app, &theme, chunks[1]);
    draw_now_playing(f, app, &theme, chunks[2]);
    draw_status(f, app, &theme, chunks[3]);

    match app.modal.clone() {
        Modal::None => {}
        Modal::Help => draw_help(f, &theme, area),
        Modal::ProfilePicker { selected } => draw_profile_picker(f, app, &theme, area, selected),
        Modal::AddToPlaylist { selected, .. } => {
            draw_playlist_picker(f, app, &theme, area, selected)
        }
        Modal::Prompt { label, input, .. } => draw_prompt(f, &theme, area, &label, &input),
        Modal::Confirm { label, .. } => draw_confirm(f, &theme, area, &label),
    }
}

fn draw_tabs(f: &mut Frame, app: &App, theme: &Theme, area: Rect) {
    // The tab strip needs ~85 columns for all eight entries, so the right-hand
    // identity block is kept narrow and its contents truncated rather than
    // letting it push "Stats" off the screen.
    let cols = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Min(20), Constraint::Length(22)])
        .split(area);

    let titles: Vec<Line> = View::ALL
        .iter()
        .enumerate()
        .map(|(i, v)| {
            Line::from(vec![
                Span::styled(format!("{}", i + 1), theme.dimmed()),
                Span::raw(" "),
                Span::raw(v.title()),
            ])
        })
        .collect();
    let idx = View::ALL.iter().position(|v| *v == app.view).unwrap_or(0);
    f.render_widget(
        Tabs::new(titles)
            .select(idx)
            .highlight_style(theme.title())
            .divider(Span::styled("│", theme.dimmed())),
        cols[0],
    );

    let profile = if app.cfg.profile_name.is_empty() {
        "no profile".to_string()
    } else {
        truncate(&app.cfg.profile_name, 12)
    };
    let version = app
        .status
        .as_ref()
        .map(|s| s.version.clone())
        .unwrap_or_else(|| "…".into());
    f.render_widget(
        Paragraph::new(Line::from(vec![
            Span::styled(profile, Style::default().fg(theme.accent)),
            Span::styled(" · ", theme.dimmed()),
            Span::styled(version, theme.dimmed()),
        ]))
        .alignment(Alignment::Right),
        cols[1],
    );
}

fn block<'a>(theme: &Theme, title: String) -> Block<'a> {
    Block::bordered()
        .border_type(BorderType::Rounded)
        .border_style(Style::default().fg(theme.border))
        .title(Span::styled(format!(" {title} "), theme.title()))
}

/// A row that is both selected and playing must still read as selected, so the
/// selection style wins and the playing marker carries the other meaning.
fn row_style(theme: &Theme, selected: bool, playing: bool) -> Style {
    if selected {
        theme.selected()
    } else if playing {
        theme.playing_row()
    } else {
        theme.base()
    }
}

fn draw_content(f: &mut Frame, app: &mut App, theme: &Theme, area: Rect) {
    if app.lib.is_empty() && app.loading {
        f.render_widget(
            Paragraph::new("Loading library…")
                .block(block(theme, "Library".into()))
                .alignment(Alignment::Center),
            area,
        );
        return;
    }

    match app.detail.clone() {
        Detail::Album(id) => return draw_album_detail(f, app, theme, area, &id),
        Detail::Artist(name) => return draw_artist_detail(f, app, theme, area, &name),
        Detail::Playlist(id) => return draw_playlist_detail(f, app, theme, area, &id),
        Detail::Tag(name) => return draw_tag_detail(f, app, theme, area, &name),
        Detail::None => {}
    }

    match app.view {
        View::Albums => draw_albums(f, app, theme, area),
        View::Artists => draw_artists(f, app, theme, area),
        View::Tracks => draw_tracks(f, app, theme, area),
        View::Search => draw_search(f, app, theme, area),
        View::Queue => draw_queue(f, app, theme, area),
        View::Playlists => draw_playlists(f, app, theme, area),
        View::Tags => draw_tags(f, app, theme, area),
        View::Stats => draw_stats(f, app, theme, area),
    }
}

/// Renders a list of pre-built lines with the app's own scrolling, so the
/// offset stays in the app and survives a redraw at a different size.
fn render_rows(
    f: &mut Frame,
    theme: &Theme,
    area: Rect,
    title: String,
    rows: Vec<Line<'static>>,
    state: &mut crate::app::ListState,
) {
    let b = block(theme, title);
    let inner = b.inner(area);
    f.render_widget(b, area);
    let height = inner.height as usize;
    state.clamp(rows.len());
    state.scroll_into_view(height);
    let visible: Vec<ListItem> = rows
        .into_iter()
        .skip(state.offset)
        .take(height)
        .map(ListItem::new)
        .collect();
    f.render_widget(List::new(visible), inner);
}

/// Shortens to `width` characters with an ellipsis, without padding.
fn truncate(s: &str, width: usize) -> String {
    if s.chars().count() <= width {
        s.to_string()
    } else {
        let mut out: String = s.chars().take(width.saturating_sub(1)).collect();
        out.push('…');
        out
    }
}

fn pad(s: &str, width: usize) -> String {
    let n = s.chars().count();
    if n >= width {
        // Truncate to fit, leaving room for the ellipsis.
        let keep = width.saturating_sub(1);
        let mut out: String = s.chars().take(keep).collect();
        out.push('…');
        out
    } else {
        format!("{s}{}", " ".repeat(width - n))
    }
}

/// A list header that names both the size of the list and the order it is in,
/// so the sort keys never leave the view in a state the user cannot read off
/// the screen.
fn sorted_title(app: &App, name: &str, count: usize, kind: ListKind) -> String {
    format!("{name} ({count}) — by {}", app.lib.sort(kind).label())
}

/// A play-count cell, shown only while the list is actually ranked by plays.
/// Ranking a list by a number the user cannot see would leave them no way to
/// tell a working sort from a broken one.
fn plays_cell(app: &App, kind: ListKind, plays: u32) -> String {
    if plays_width(app, kind) == 0 {
        return String::new();
    }
    if app.play_counts.is_none() {
        // Ranked by a number that has not arrived yet. Saying so beats
        // printing a column of zeroes that would read as "never played".
        return "    ?".into();
    }
    format!("{plays:>5}")
}

/// Columns the play count takes, so the other columns can give them up rather
/// than push the count off the end of the row.
fn plays_width(app: &App, kind: ListKind) -> usize {
    if app.lib.sort(kind).field == SortField::Plays {
        5
    } else {
        0
    }
}

fn draw_albums(f: &mut Frame, app: &mut App, theme: &Theme, area: Rect) {
    let w = area.width as usize;
    let artist_w = (w / 4).clamp(12, 30);
    let title_w = w
        .saturating_sub(artist_w + 30 + plays_width(app, ListKind::Albums))
        .max(12);
    let playing_album = app.current_track().map(|t| t.album_id.clone());
    let rows: Vec<Line> = (0..app.lib.albums.len())
        .filter_map(|row| app.album_at(row).map(|a| (row, a)))
        .map(|(row, a)| {
            let playing = playing_album.as_deref() == Some(a.id.as_str());
            let plays = app
                .lib
                .row(ListKind::Albums, row)
                .map(|i| app.lib.album_plays(i))
                .unwrap_or(0);
            Line::styled(
                format!(
                    "{} {} {} {:>4}  {:>3} tk  {}{}",
                    if playing { "▶" } else { " " },
                    pad(&a.album_artist, artist_w),
                    pad(&a.title, title_w),
                    a.year.map(|y| y.to_string()).unwrap_or_default(),
                    a.track_count,
                    a.release_type,
                    plays_cell(app, ListKind::Albums, plays),
                ),
                row_style(theme, row == app.albums_list.selected, playing),
            )
        })
        .collect();
    let title = sorted_title(app, "Albums", app.lib.albums.len(), ListKind::Albums);
    let mut state = app.albums_list.clone();
    render_rows(f, theme, area, title, rows, &mut state);
    app.albums_list = state;
}

fn draw_artists(f: &mut Frame, app: &mut App, theme: &Theme, area: Rect) {
    let rows: Vec<Line> = (0..app.lib.artists.len())
        .filter_map(|row| app.artist_at(row).map(|a| (row, a)))
        .map(|(row, a)| {
            let plays = app
                .lib
                .row(ListKind::Artists, row)
                .map(|i| app.lib.artist_plays(i))
                .unwrap_or(0);
            Line::styled(
                format!(
                    "  {}  {:>3} albums  {:>4} tracks{}",
                    pad(
                        &a.name,
                        (area.width as usize)
                            .saturating_sub(30 + plays_width(app, ListKind::Artists))
                            .max(10)
                    ),
                    a.album_ids.len(),
                    a.track_count,
                    plays_cell(app, ListKind::Artists, plays),
                ),
                row_style(theme, row == app.artists_list.selected, false),
            )
        })
        .collect();
    let title = sorted_title(app, "Artists", app.lib.artists.len(), ListKind::Artists);
    let mut state = app.artists_list.clone();
    render_rows(f, theme, area, title, rows, &mut state);
    app.artists_list = state;
}

/// One track row, shared by every track list.
fn track_line(
    app: &App,
    theme: &Theme,
    t: &crate::api::models::Track,
    selected: bool,
    width: usize,
    show_album: bool,
    // Only the Tracks view: the queue and the drill-downs are not ranked by
    // plays, so a count there would be a number with no meaning attached.
    show_plays: bool,
) -> Line<'static> {
    let playing = app.current_track().map(|c| c.id.as_str()) == Some(t.id.as_str());
    let fav = if t.favourite { "♥" } else { " " };
    let dur = hms(t.duration_secs());
    let cols = if show_album { 3 } else { 2 };
    let plays_w = if show_plays {
        plays_width(app, ListKind::Tracks)
    } else {
        0
    };
    let text_w = width.saturating_sub(18 + plays_w).max(12);
    let each = text_w / cols;
    let mut s = format!(
        "{} {} {}",
        if playing { "▶" } else { " " },
        fav,
        pad(&t.title, each)
    );
    s.push_str(&format!(" {}", pad(t.display_artist(), each)));
    if show_album {
        s.push_str(&format!(" {}", pad(&t.album, each)));
    }
    s.push_str(&format!(" {dur:>7}"));
    if show_plays {
        s.push_str(&plays_cell(app, ListKind::Tracks, app.lib.plays(&t.id)));
    }
    Line::styled(s, row_style(theme, selected, playing))
}

fn draw_tracks(f: &mut Frame, app: &mut App, theme: &Theme, area: Rect) {
    let w = area.width as usize;
    let sel = app.tracks_list.selected;
    let rows: Vec<Line> = (0..app.lib.tracks.len())
        .filter_map(|row| app.track_at(row).map(|t| (row, t)))
        .map(|(row, t)| track_line(app, theme, t, row == sel, w, true, true))
        .collect();
    let title = sorted_title(app, "Tracks", app.lib.tracks.len(), ListKind::Tracks);
    let mut state = app.tracks_list.clone();
    render_rows(f, theme, area, title, rows, &mut state);
    app.tracks_list = state;
}

fn draw_search(f: &mut Frame, app: &mut App, theme: &Theme, area: Rect) {
    let rows_area = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(3), Constraint::Min(1)])
        .split(area);

    let cursor = if app.search_editing { "▏" } else { "" };
    f.render_widget(
        Paragraph::new(Line::from(vec![
            Span::styled("/ ", Style::default().fg(theme.accent)),
            Span::raw(app.search_input.clone()),
            Span::styled(cursor, Style::default().fg(theme.accent)),
        ]))
        .block(
            block(theme, "Search".into()).border_style(Style::default().fg(
                if app.search_editing {
                    theme.border_focus
                } else {
                    theme.border
                },
            )),
        ),
        rows_area[0],
    );

    let w = area.width as usize;
    let sel = app.search_list.selected;
    let rows: Vec<Line> = app
        .search_hits
        .iter()
        .enumerate()
        .filter_map(|(i, &ti)| {
            app.lib
                .tracks
                .get(ti)
                .map(|t| track_line(app, theme, t, i == sel, w, true, false))
        })
        .collect();
    let title = if app.search_input.is_empty() {
        "Results — type to search".to_string()
    } else {
        format!("Results ({})", app.search_hits.len())
    };
    let mut state = app.search_list.clone();
    render_rows(
        f,
        theme,
        area.intersection(rows_area[1]),
        title,
        rows,
        &mut state,
    );
    app.search_list = state;
}

fn draw_queue(f: &mut Frame, app: &mut App, theme: &Theme, area: Rect) {
    let w = area.width as usize;
    let sel = app.queue_list.selected;
    let pos = app.queue.pos();
    let rows: Vec<Line> = app
        .queue
        .items()
        .iter()
        .enumerate()
        .map(|(i, id)| match app.lib.track(id) {
            Some(t) => {
                let mut line = track_line(app, theme, t, i == sel, w, true, false);
                if Some(i) == pos {
                    line = line.patch_style(row_style(theme, i == sel, true));
                }
                line
            }
            // A queued id with no library row means the library was reloaded
            // and the track is gone; show it rather than silently dropping it.
            None => Line::styled(
                format!("  ? {id} (missing from library)"),
                row_style(theme, i == sel, false),
            ),
        })
        .collect();
    let total: f64 = app
        .queue
        .items()
        .iter()
        .filter_map(|id| app.lib.track(id))
        .map(|t| t.duration_secs())
        .sum();
    let title = if app.queue.is_empty() {
        "Queue — empty".to_string()
    } else {
        format!("Queue ({}, {})", app.queue.len(), human_duration(total))
    };
    let mut state = app.queue_list.clone();
    render_rows(f, theme, area, title, rows, &mut state);
    app.queue_list = state;
}

fn draw_playlists(f: &mut Frame, app: &mut App, theme: &Theme, area: Rect) {
    let rows: Vec<Line> = app
        .playlists
        .iter()
        .enumerate()
        .map(|(i, p)| {
            let kind = if p.is_smart() { "smart" } else { "manual" };
            let count = if p.is_smart() {
                "—".to_string()
            } else {
                format!("{}", p.track_ids.len())
            };
            Line::styled(
                format!(
                    "  {}  {:>6}  {:>5} tracks",
                    pad(&p.name, (area.width as usize).saturating_sub(26).max(10)),
                    kind,
                    count
                ),
                row_style(theme, i == app.playlists_list.selected, false),
            )
        })
        .collect();
    let rows = if rows.is_empty() {
        vec![Line::styled(
            "  no playlists — press n to create one",
            theme.dimmed(),
        )]
    } else {
        rows
    };
    let title = format!("Playlists ({})", app.playlists.len());
    let mut state = app.playlists_list.clone();
    render_rows(f, theme, area, title, rows, &mut state);
    app.playlists_list = state;
}

fn draw_tags(f: &mut Frame, app: &mut App, theme: &Theme, area: Rect) {
    let rows: Vec<Line> = app
        .tags
        .iter()
        .enumerate()
        .map(|(i, t)| {
            let marker = if t.folder { "▸" } else { "·" };
            let n = app.tag_tracks(&t.name).len();
            Line::styled(
                format!(
                    "  {marker} {}  {:>5} tracks",
                    pad(&t.name, (area.width as usize).saturating_sub(20).max(10)),
                    n
                ),
                row_style(theme, i == app.tags_list.selected, false),
            )
        })
        .collect();
    let rows = if rows.is_empty() {
        vec![Line::styled("  no tags on this server", theme.dimmed())]
    } else {
        rows
    };
    let title = format!("Tags ({})", app.tags.len());
    let mut state = app.tags_list.clone();
    render_rows(f, theme, area, title, rows, &mut state);
    app.tags_list = state;
}

/// Plays inside a rolling window. `/api/stats` reports `week` and `month` as
/// `{plays, seconds, …}` objects rather than bare numbers.
fn window_plays(stats: &serde_json::Value, key: &str) -> u64 {
    stats
        .get(key)
        .and_then(|w| w.get("plays"))
        .and_then(|p| p.as_u64())
        .unwrap_or(0)
}

fn draw_stats(f: &mut Frame, app: &App, theme: &Theme, area: Rect) {
    let mut lines: Vec<Line> = Vec::new();
    match &app.stats {
        None => lines.push(Line::styled("  loading…", theme.dimmed())),
        Some(v) => {
            let num = |k: &str| v.get(k).and_then(|x| x.as_u64()).unwrap_or(0);
            let plays = num("totalPlays");
            if plays == 0 {
                lines.push(Line::styled("  no plays recorded yet", theme.dimmed()));
            } else {
                lines.push(Line::from(vec![
                    Span::styled("  plays ", theme.dimmed()),
                    Span::raw(plays.to_string()),
                    Span::styled("   listened ", theme.dimmed()),
                    Span::raw(human_duration(num("totalSeconds") as f64)),
                    Span::styled("   unique tracks ", theme.dimmed()),
                    Span::raw(num("uniqueTracks").to_string()),
                    // `week` and `month` are objects of their own totals, not
                    // plain counts.
                    Span::styled("   this week ", theme.dimmed()),
                    Span::raw(window_plays(v, "week").to_string()),
                    Span::styled("   this month ", theme.dimmed()),
                    Span::raw(window_plays(v, "month").to_string()),
                ]));
                lines.push(Line::raw(""));
            }

            // Each list identifies its subject differently: artists by name,
            // albums by albumId, tracks by track id. Only the first is
            // self-describing, so the other two are resolved through the
            // library the client already holds.
            for (key, label) in [
                ("topArtists", "Top artists"),
                ("topAlbums", "Top albums"),
                ("topTracks", "Top tracks"),
            ] {
                let Some(arr) = v.get(key).and_then(|x| x.as_array()) else {
                    continue;
                };
                if arr.is_empty() {
                    continue;
                }
                lines.push(Line::styled(format!("  {label}"), theme.title()));
                for item in arr.iter().take(10) {
                    let count = item.get("count").and_then(|x| x.as_u64()).unwrap_or(0);
                    let name = match key {
                        "topArtists" => item
                            .get("name")
                            .and_then(|x| x.as_str())
                            .unwrap_or("—")
                            .to_string(),
                        "topAlbums" => item
                            .get("albumId")
                            .and_then(|x| x.as_str())
                            .and_then(|id| app.lib.album(id))
                            .map(|a| format!("{} — {}", a.album_artist, a.title))
                            // An id the library no longer has: a deleted album
                            // still in the play history.
                            .unwrap_or_else(|| "(not in library)".into()),
                        _ => item
                            .get("id")
                            .and_then(|x| x.as_str())
                            .and_then(|id| app.lib.track(id))
                            .map(|t| format!("{} — {}", t.display_artist(), t.title))
                            .unwrap_or_else(|| "(not in library)".into()),
                    };
                    lines.push(Line::from(format!("    {count:>5}  {name}")));
                }
                lines.push(Line::raw(""));
            }
        }
    }
    f.render_widget(
        Paragraph::new(lines)
            .block(block(theme, "Stats".into()))
            .wrap(Wrap { trim: false }),
        area,
    );
}

// ---- detail views --------------------------------------------------------

fn draw_album_detail(f: &mut Frame, app: &mut App, theme: &Theme, area: Rect, id: &str) {
    let Some(album) = app.lib.album(id).cloned() else {
        app.detail = Detail::None;
        return;
    };
    let w = area.width as usize;
    let sel = app.detail_list.selected;
    let rows: Vec<Line> = album
        .track_ids
        .iter()
        .enumerate()
        .filter_map(|(i, tid)| {
            app.lib.track(tid).map(|t| {
                let playing = app.current_track().map(|c| c.id.as_str()) == Some(t.id.as_str());
                Line::styled(
                    format!(
                        "{} {} {:>3}. {} {:>7}",
                        if playing { "▶" } else { " " },
                        if t.favourite { "♥" } else { " " },
                        t.track_no.unwrap_or((i + 1) as i64),
                        pad(&t.title, w.saturating_sub(24).max(10)),
                        hms(t.duration_secs())
                    ),
                    row_style(theme, i == sel, playing),
                )
            })
        })
        .collect();
    let title = format!(
        "{} — {} · {} · {} tracks · {}",
        album.album_artist,
        album.title,
        album
            .year
            .map(|y| y.to_string())
            .unwrap_or_else(|| "—".into()),
        album.track_count,
        human_duration(album.duration)
    );
    let mut state = app.detail_list.clone();
    render_rows(f, theme, area, title, rows, &mut state);
    app.detail_list = state;
}

fn draw_artist_detail(f: &mut Frame, app: &mut App, theme: &Theme, area: Rect, name: &str) {
    let ids = app.artist_tracks(name);
    let w = area.width as usize;
    let sel = app.detail_list.selected;
    let rows: Vec<Line> = ids
        .iter()
        .enumerate()
        .filter_map(|(i, tid)| {
            app.lib
                .track(tid)
                .map(|t| track_line(app, theme, t, i == sel, w, true, false))
        })
        .collect();
    let title = format!("{name} ({} tracks)", ids.len());
    let mut state = app.detail_list.clone();
    render_rows(f, theme, area, title, rows, &mut state);
    app.detail_list = state;
}

fn draw_playlist_detail(f: &mut Frame, app: &mut App, theme: &Theme, area: Rect, id: &str) {
    let name = app
        .playlists
        .iter()
        .find(|p| p.id == id)
        .map(|p| p.name.clone())
        .unwrap_or_else(|| "Playlist".into());
    let w = area.width as usize;
    let sel = app.detail_list.selected;
    let rows: Vec<Line> = app
        .playlist_tracks
        .iter()
        .enumerate()
        .map(|(i, t)| track_line(app, theme, t, i == sel, w, true, false))
        .collect();
    let rows = if rows.is_empty() {
        vec![Line::styled("  empty — add tracks with P", theme.dimmed())]
    } else {
        rows
    };
    let title = format!("{name} ({} tracks)", app.playlist_tracks.len());
    let mut state = app.detail_list.clone();
    render_rows(f, theme, area, title, rows, &mut state);
    app.detail_list = state;
}

fn draw_tag_detail(f: &mut Frame, app: &mut App, theme: &Theme, area: Rect, name: &str) {
    let ids = app.tag_tracks(name);
    let w = area.width as usize;
    let sel = app.detail_list.selected;
    let rows: Vec<Line> = ids
        .iter()
        .enumerate()
        .filter_map(|(i, tid)| {
            app.lib
                .track(tid)
                .map(|t| track_line(app, theme, t, i == sel, w, true, false))
        })
        .collect();
    let title = format!("Tag: {name} ({} tracks)", ids.len());
    let mut state = app.detail_list.clone();
    render_rows(f, theme, area, title, rows, &mut state);
    app.detail_list = state;
}

// ---- transport -----------------------------------------------------------

fn draw_now_playing(f: &mut Frame, app: &App, theme: &Theme, area: Rect) {
    let st = app.player.state();
    let b = block(theme, "Now playing".into());
    let inner = b.inner(area);
    f.render_widget(b, area);

    let rows = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(1), Constraint::Length(1)])
        .split(inner);

    match app.current_track() {
        Some(t) => {
            let icon = if st.paused { "⏸" } else { "▶" };
            f.render_widget(
                Paragraph::new(Line::from(vec![
                    Span::styled(format!("{icon} "), Style::default().fg(theme.playing)),
                    Span::styled(
                        t.title.clone(),
                        Style::default().add_modifier(Modifier::BOLD),
                    ),
                    Span::styled("  ·  ", theme.dimmed()),
                    Span::raw(t.display_artist().to_string()),
                    Span::styled("  ·  ", theme.dimmed()),
                    Span::styled(t.album.clone(), theme.dimmed()),
                    Span::raw(if t.favourite { "  ♥" } else { "" }),
                    Span::styled(format!("   {}", t.quality_badge()), theme.dimmed()),
                ])),
                rows[0],
            );
        }
        None => {
            f.render_widget(
                Paragraph::new(Span::styled(
                    if app.player.is_enabled() {
                        "nothing playing"
                    } else {
                        "nothing playing — mpv not available, browse only"
                    },
                    theme.dimmed(),
                )),
                rows[0],
            );
        }
    }

    // Prefer mpv's duration over the tagged one: it is what is really playing.
    let duration = if st.duration > 0.0 {
        st.duration
    } else {
        app.current_track()
            .map(|t| t.duration_secs())
            .unwrap_or(0.0)
    };
    let ratio = if duration > 0.0 {
        (st.time_pos / duration).clamp(0.0, 1.0)
    } else {
        0.0
    };

    let bar = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Min(20), Constraint::Length(46)])
        .split(rows[1]);

    f.render_widget(
        Gauge::default()
            .gauge_style(Style::default().fg(theme.accent))
            .ratio(ratio)
            .label(format!("{} / {}", hms(st.time_pos), hms(duration))),
        bar[0],
    );

    let modes = Line::from(vec![
        Span::styled(
            if app.queue.shuffle() { " shuffle " } else { "" },
            Style::default().fg(theme.accent),
        ),
        Span::styled(
            format!(" repeat:{} ", app.queue.repeat().label()),
            if app.queue.repeat() == crate::queue::Repeat::Off {
                theme.dimmed()
            } else {
                Style::default().fg(theme.accent)
            },
        ),
        Span::styled(format!(" vol {:.0}% ", st.volume), theme.dimmed()),
        Span::styled(
            format!(" {} ", app.effective_tier().label()),
            theme.dimmed(),
        ),
    ]);
    f.render_widget(Paragraph::new(modes).alignment(Alignment::Right), bar[1]);
}

fn draw_status(f: &mut Frame, app: &App, theme: &Theme, area: Rect) {
    // Precedence: an error outlives a toast, and progress outranks both,
    // because a running scan explains why the library looks wrong.
    let line = if let Some((label, done, total)) = &app.progress {
        let pct = if *total > 0 {
            (*done as f64 / *total as f64 * 100.0).round()
        } else {
            0.0
        };
        Line::from(vec![
            Span::styled(format!(" {label} "), Style::default().fg(theme.warning)),
            Span::raw(format!("{done}/{total} ({pct:.0}%)")),
        ])
    } else if let Some(e) = &app.error {
        Line::from(vec![
            Span::styled(" error ", Style::default().fg(theme.error)),
            Span::raw(e.clone()),
        ])
    } else if let Some((t, _)) = &app.toast {
        Line::styled(format!(" {t}"), Style::default().fg(theme.accent))
    } else {
        Line::styled(
            "  ?  help    /  search    space  play/pause    n/p  next/prev    q  quit",
            theme.dimmed(),
        )
    };
    f.render_widget(Paragraph::new(line), area);
}

// ---- modals --------------------------------------------------------------

/// A centred box of the given size, clamped to the screen.
fn centered(area: Rect, width: u16, height: u16) -> Rect {
    let w = width.min(area.width);
    let h = height.min(area.height);
    Rect {
        x: area.x + (area.width.saturating_sub(w)) / 2,
        y: area.y + (area.height.saturating_sub(h)) / 2,
        width: w,
        height: h,
    }
}

const HELP: &[(&str, &str)] = &[
    ("1–8, Tab", "switch view"),
    ("j / k, ↓ / ↑", "move"),
    ("g / G", "top / bottom"),
    ("Ctrl-d / Ctrl-u", "half page down / up"),
    ("Enter", "open, or play"),
    ("Esc", "back / close"),
    ("", ""),
    ("Space", "play / pause"),
    ("n / p", "next / previous"),
    ("← / →", "seek 5s"),
    ("Shift-← / →", "seek 30s"),
    ("- / =", "volume down / up"),
    ("s", "shuffle"),
    ("r", "repeat off / all / one"),
    ("x", "stop"),
    ("", ""),
    ("a", "add to queue"),
    ("A", "play next"),
    ("f", "favourite"),
    ("P", "add to playlist"),
    ("d", "remove (queue or playlist)"),
    ("", ""),
    (",", "cycle sort field"),
    (".", "reverse the sort"),
    ("/", "search"),
    ("n (playlists)", "new playlist"),
    ("t", "cycle stream tier"),
    ("R", "reload library"),
    ("S", "rescan the server library"),
    ("U", "switch profile"),
    ("o", "change server (saved)"),
    ("?", "this help"),
    ("q", "quit"),
];

/// Width of one key/description column in the help modal.
const HELP_COL: usize = 46;

fn help_cell(theme: &Theme, (key, what): &(&str, &str)) -> Vec<Span<'static>> {
    if key.is_empty() {
        return vec![Span::raw(" ".repeat(HELP_COL))];
    }
    vec![
        Span::styled(format!("  {key:>16}  "), Style::default().fg(theme.accent)),
        Span::raw(format!("{what:<0$}", HELP_COL - 20)),
    ]
}

fn draw_help(f: &mut Frame, theme: &Theme, area: Rect) {
    // Folds to two columns when one will not fit the terminal. A help screen
    // that silently cuts off its last bindings is worse than a wide one, and
    // the bindings it would cut off are the ones nobody has memorised.
    let tall = HELP.len() as u16 + 2;
    let two_col = tall > area.height && area.width as usize >= HELP_COL * 2 + 2;

    let half = if two_col {
        HELP.len().div_ceil(2)
    } else {
        HELP.len()
    };
    let lines: Vec<Line> = (0..half)
        .map(|i| {
            let mut spans = help_cell(theme, &HELP[i]);
            if let Some(second) = HELP.get(i + half) {
                spans.extend(help_cell(theme, second));
            }
            Line::from(spans)
        })
        .collect();

    let width = if two_col {
        HELP_COL * 2 + 2
    } else {
        HELP_COL + 2
    };
    let r = centered(area, width as u16, lines.len() as u16 + 2);
    f.render_widget(Clear, r);
    f.render_widget(Paragraph::new(lines).block(block(theme, "Keys".into())), r);
}

fn draw_profile_picker(f: &mut Frame, app: &App, theme: &Theme, area: Rect, selected: usize) {
    let r = centered(area, 50, app.profiles.len() as u16 + 4);
    f.render_widget(Clear, r);
    let mut lines: Vec<Line> = app
        .profiles
        .iter()
        .enumerate()
        .map(|(i, p)| {
            Line::styled(
                format!("  {}", p.name),
                row_style(theme, i == selected, false),
            )
        })
        .collect();
    lines.push(Line::styled(
        "  (N to create a new profile)",
        theme.dimmed(),
    ));
    f.render_widget(
        Paragraph::new(lines).block(block(theme, "Choose a profile".into())),
        r,
    );
}

fn draw_playlist_picker(f: &mut Frame, app: &App, theme: &Theme, area: Rect, selected: usize) {
    // Only manual playlists can take tracks; the server rejects an add to a
    // smart one, so they are not offered.
    let choices: Vec<&crate::api::models::Playlist> =
        app.playlists.iter().filter(|p| !p.is_smart()).collect();
    let r = centered(area, 50, choices.len().max(1) as u16 + 4);
    f.render_widget(Clear, r);
    let lines: Vec<Line> = if choices.is_empty() {
        vec![Line::styled(
            "  no manual playlists — press Esc, then n",
            theme.dimmed(),
        )]
    } else {
        choices
            .iter()
            .enumerate()
            .map(|(i, p)| {
                Line::styled(
                    format!("  {}", p.name),
                    row_style(theme, i == selected, false),
                )
            })
            .collect()
    };
    f.render_widget(
        Paragraph::new(lines).block(block(theme, "Add to playlist".into())),
        r,
    );
}

fn draw_prompt(f: &mut Frame, theme: &Theme, area: Rect, label: &str, input: &str) {
    let r = centered(area, 60, 3);
    f.render_widget(Clear, r);
    f.render_widget(
        Paragraph::new(Line::from(vec![
            Span::raw(" "),
            Span::raw(input.to_string()),
            Span::styled("▏", Style::default().fg(theme.accent)),
        ]))
        .block(block(theme, label.to_string())),
        r,
    );
}

fn draw_confirm(f: &mut Frame, theme: &Theme, area: Rect, label: &str) {
    let r = centered(area, 60, 4);
    f.render_widget(Clear, r);
    f.render_widget(
        Paragraph::new(vec![
            Line::raw(format!(" {label}")),
            Line::styled("  y to confirm, Esc to cancel", theme.dimmed()),
        ])
        .block(block(theme, "Confirm".into())),
        r,
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pad_fills_short_text_to_the_column_width() {
        assert_eq!(pad("abc", 6), "abc   ");
        assert_eq!(pad("abc", 3), "ab…");
    }

    #[test]
    fn pad_truncates_with_an_ellipsis_rather_than_overflowing() {
        let out = pad("a very long album title indeed", 10);
        assert_eq!(out.chars().count(), 10, "the column must not overflow");
        assert!(out.ends_with('…'));
    }

    #[test]
    fn pad_counts_characters_not_bytes() {
        // A byte-based pad would mangle these and misalign every column.
        assert_eq!(pad("Björk", 5).chars().count(), 5);
        assert_eq!(pad("Dvořák", 8).chars().count(), 8);
        assert_eq!(pad("日本語", 3).chars().count(), 3);
    }

    #[test]
    fn pad_to_zero_width_does_not_panic() {
        assert_eq!(pad("abc", 0).chars().count(), 1, "an ellipsis is the floor");
    }

    #[test]
    fn centered_box_is_centred_and_clamped_to_the_screen() {
        let area = Rect {
            x: 0,
            y: 0,
            width: 100,
            height: 40,
        };
        let r = centered(area, 50, 10);
        assert_eq!((r.x, r.y, r.width, r.height), (25, 15, 50, 10));

        // A modal larger than the terminal must shrink, not overflow.
        let tiny = Rect {
            x: 0,
            y: 0,
            width: 20,
            height: 5,
        };
        let r = centered(tiny, 60, 30);
        assert_eq!((r.width, r.height), (20, 5));
        assert!(r.x + r.width <= tiny.width);
        assert!(r.y + r.height <= tiny.height);
    }

    #[test]
    fn selection_style_wins_over_the_playing_style() {
        let t = Theme::dark();
        assert_eq!(row_style(&t, true, true), t.selected());
        assert_eq!(row_style(&t, false, true), t.playing_row());
        assert_eq!(row_style(&t, false, false), t.base());
    }
}
