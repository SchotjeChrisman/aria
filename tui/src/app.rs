//! Application state and the actions the key bindings drive.
//!
//! Everything that touches the network runs on a worker thread and reports
//! back as a [`Msg`]; the UI thread never blocks on HTTP. mpv is authoritative
//! for *playback* position once a queue is loaded — the app mirrors its
//! `playlist-pos` back into the queue rather than trying to predict track
//! changes, which is what keeps gapless advances and manual skips consistent.

use std::path::PathBuf;
use std::sync::mpsc::{Receiver, Sender};
use std::sync::Arc;

use crate::api::models::{Playlist, Profile, Status, Tag, Tier, Track};
use crate::api::{ApiError, Client, SseEvent};
use crate::config::Config;
use crate::library::Library;
use crate::player::Player;
use crate::queue::{Queue, Repeat};
use crate::timefmt;

/// Which pane is showing.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum View {
    Albums,
    Artists,
    Tracks,
    Search,
    Queue,
    Playlists,
    Tags,
    Stats,
}

impl View {
    pub const ALL: [View; 8] = [
        View::Albums,
        View::Artists,
        View::Tracks,
        View::Search,
        View::Queue,
        View::Playlists,
        View::Tags,
        View::Stats,
    ];

    pub fn title(self) -> &'static str {
        match self {
            View::Albums => "Albums",
            View::Artists => "Artists",
            View::Tracks => "Tracks",
            View::Search => "Search",
            View::Queue => "Queue",
            View::Playlists => "Playlists",
            View::Tags => "Tags",
            View::Stats => "Stats",
        }
    }
}

/// A modal layered over the current view.
#[derive(Debug, Clone, PartialEq)]
pub enum Modal {
    None,
    Help,
    /// Pick a profile. Mandatory on first run: without one, plays cannot be
    /// reported and playlists cannot be listed.
    ProfilePicker {
        selected: usize,
    },
    /// Add the given track ids to a playlist chosen from the list.
    AddToPlaylist {
        track_ids: Vec<String>,
        selected: usize,
    },
    /// Free-text prompt (new playlist name, server URL).
    Prompt {
        kind: PromptKind,
        label: String,
        input: String,
    },
    /// A blocking confirmation.
    Confirm {
        label: String,
        action: ConfirmAction,
    },
}

#[derive(Debug, Clone, PartialEq)]
pub enum PromptKind {
    NewPlaylist,
    NewProfile,
    ServerUrl,
}

#[derive(Debug, Clone, PartialEq)]
pub enum ConfirmAction {
    DeletePlaylist(String),
    Rescan,
}

/// What the drill-down stack is showing inside a view.
#[derive(Debug, Clone, PartialEq)]
pub enum Detail {
    None,
    Album(String),
    Artist(String),
    Playlist(String),
    Tag(String),
}

/// Messages from background work.
pub enum Msg {
    Library(Result<Vec<Track>, ApiError>),
    Status(Result<Status, ApiError>),
    Profiles(Result<Vec<Profile>, ApiError>),
    Playlists(Result<Vec<Playlist>, ApiError>),
    PlaylistTracks(String, Result<Vec<Track>, ApiError>),
    Tags(Result<Vec<Tag>, ApiError>),
    Stats(Result<serde_json::Value, ApiError>),
    Favourite(String, Result<bool, ApiError>),
    ProfileCreated(Result<Profile, ApiError>),
    PlaylistChanged(Result<Playlist, ApiError>),
    /// A unit action finished; the string is the toast to show on success.
    Done(String, Result<(), ApiError>),
    Sse(SseEvent),
    /// The SSE connection dropped and will be retried.
    SseLost,
    Toast(String),
}

/// A scrollable selection, kept per list so switching views does not lose the
/// user's place.
#[derive(Debug, Default, Clone)]
pub struct ListState {
    pub selected: usize,
    pub offset: usize,
}

impl ListState {
    pub fn clamp(&mut self, len: usize) {
        if len == 0 {
            self.selected = 0;
            self.offset = 0;
        } else if self.selected >= len {
            self.selected = len - 1;
        }
    }

    pub fn move_by(&mut self, delta: isize, len: usize) {
        if len == 0 {
            return;
        }
        let cur = self.selected as isize;
        self.selected = (cur + delta).clamp(0, len as isize - 1) as usize;
    }

    /// Keeps `selected` inside a window of `height` rows.
    pub fn scroll_into_view(&mut self, height: usize) {
        if height == 0 {
            return;
        }
        if self.selected < self.offset {
            self.offset = self.selected;
        } else if self.selected >= self.offset + height {
            self.offset = self.selected + 1 - height;
        }
    }
}

pub struct App {
    /// The config in effect for this run, CLI overrides folded in.
    pub cfg: Config,
    /// The config as it sits on disk. Only an in-app change touches it, which
    /// is what keeps a one-off `--server` flag from permanently replacing a
    /// hand-written URL the next time the file is written.
    saved: Config,
    pub cfg_path: PathBuf,
    pub client: Arc<Client>,
    pub player: Player,
    pub lib: Library,
    pub queue: Queue,

    pub view: View,
    pub detail: Detail,
    pub modal: Modal,

    pub albums_list: ListState,
    pub artists_list: ListState,
    pub tracks_list: ListState,
    pub search_list: ListState,
    pub queue_list: ListState,
    pub playlists_list: ListState,
    pub tags_list: ListState,
    pub detail_list: ListState,

    pub search_input: String,
    pub search_hits: Vec<usize>,
    /// True while the search box has the keyboard.
    pub search_editing: bool,

    pub profiles: Vec<Profile>,
    pub playlists: Vec<Playlist>,
    pub playlist_tracks: Vec<Track>,
    pub tags: Vec<Tag>,
    pub stats: Option<serde_json::Value>,
    pub status: Option<Status>,

    /// Transient message on the status line, with the tick it expires at.
    pub toast: Option<(String, u64)>,
    pub error: Option<String>,
    pub loading: bool,
    /// Scan/enrich progress from the SSE stream, as (label, done, total).
    pub progress: Option<(String, u64, u64)>,

    /// Track id whose play has already been reported, so it is reported once.
    reported: Option<String>,
    /// Count of plays handed to the network. Observable so the reporting rules
    /// can be asserted on.
    pub reports_sent: u64,
    /// The queue entry reporting is currently armed against.
    last_track_id: Option<String>,
    /// Previous `time-pos`, used to tell a repeat-one loop (end -> start) from
    /// a backward seek (middle -> start).
    last_time_pos: f64,
    last_playlist_pos: Option<usize>,
    /// Last mpv error already shown, so one failure is not reported forever.
    last_player_error: Option<String>,
    /// Index we last told mpv to play. While set, mpv's own `playlist-pos`
    /// reports are ignored — a rebuild passes through entry 0 on its way there.
    pending_pos: Option<usize>,

    pub tick: u64,
    pub should_quit: bool,
    tx: Sender<Msg>,
    pub rx: Receiver<Msg>,
}

impl App {
    /// `cfg` is the effective config; `saved` is what was read from disk.
    /// Passing the same value for both (as the tests do) simply means every
    /// change is persisted.
    pub fn new(cfg: Config, cfg_path: PathBuf, player: Player) -> Self {
        Self::with_saved(cfg.clone(), cfg, cfg_path, player)
    }

    pub fn with_saved(cfg: Config, saved: Config, cfg_path: PathBuf, player: Player) -> Self {
        let (tx, rx) = std::sync::mpsc::channel();
        let client = Arc::new(Client::new(&cfg.server));
        Self {
            client,
            cfg,
            saved,
            cfg_path,
            player,
            lib: Library::default(),
            queue: Queue::new(),
            view: View::Albums,
            detail: Detail::None,
            modal: Modal::None,
            albums_list: ListState::default(),
            artists_list: ListState::default(),
            tracks_list: ListState::default(),
            search_list: ListState::default(),
            queue_list: ListState::default(),
            playlists_list: ListState::default(),
            tags_list: ListState::default(),
            detail_list: ListState::default(),
            search_input: String::new(),
            search_hits: Vec::new(),
            search_editing: false,
            profiles: Vec::new(),
            playlists: Vec::new(),
            playlist_tracks: Vec::new(),
            tags: Vec::new(),
            stats: None,
            status: None,
            toast: None,
            error: None,
            loading: false,
            progress: None,
            reported: None,
            reports_sent: 0,
            last_track_id: None,
            last_time_pos: 0.0,
            last_playlist_pos: None,
            pending_pos: None,
            last_player_error: None,
            tick: 0,
            should_quit: false,
            tx,
            rx,
        }
    }

    /// Writes the on-disk config. Whatever was not explicitly carried over
    /// from [`Self::cfg`] keeps the value the file already had.
    pub fn save_config(&mut self) {
        // Volume is a live control rather than a flag, so it always persists.
        self.saved.volume = self.cfg.volume;
        if let Err(e) = self.saved.save(&self.cfg_path) {
            self.error = Some(format!("could not save config: {e}"));
        }
    }

    /// Records an in-app change to a field that a CLI flag can also set. The
    /// user has now chosen it deliberately, so it becomes the stored value.
    pub fn persist_tier(&mut self, tier: String) {
        self.cfg.tier = tier.clone();
        self.saved.tier = tier;
        self.save_config();
    }

    pub fn persist_server(&mut self, server: String) {
        self.cfg.server = server.clone();
        self.cfg.normalize();
        self.saved.server = self.cfg.server.clone();
        self.save_config();
    }

    pub fn sender(&self) -> Sender<Msg> {
        self.tx.clone()
    }

    // ---- background helpers ---------------------------------------------

    fn spawn<F>(&self, f: F)
    where
        F: FnOnce(Arc<Client>, Sender<Msg>) + Send + 'static,
    {
        let client = Arc::clone(&self.client);
        let tx = self.tx.clone();
        std::thread::spawn(move || f(client, tx));
    }

    pub fn load_library(&mut self) {
        self.loading = true;
        self.spawn(|c, tx| {
            let _ = tx.send(Msg::Library(c.tracks()));
        });
    }

    pub fn load_status(&self) {
        self.spawn(|c, tx| {
            let _ = tx.send(Msg::Status(c.status()));
        });
    }

    pub fn load_profiles(&self) {
        self.spawn(|c, tx| {
            let _ = tx.send(Msg::Profiles(c.profiles()));
        });
    }

    pub fn load_playlists(&self) {
        if self.cfg.profile_id.is_empty() {
            return;
        }
        let pid = self.cfg.profile_id.clone();
        self.spawn(move |c, tx| {
            let _ = tx.send(Msg::Playlists(c.playlists(&pid)));
        });
    }

    pub fn load_tags(&self) {
        self.spawn(|c, tx| {
            let _ = tx.send(Msg::Tags(c.tags()));
        });
    }

    pub fn load_stats(&self) {
        if self.cfg.profile_id.is_empty() {
            return;
        }
        let pid = self.cfg.profile_id.clone();
        self.spawn(move |c, tx| {
            let _ = tx.send(Msg::Stats(c.stats(&pid)));
        });
    }

    pub fn toast<S: Into<String>>(&mut self, msg: S) {
        self.toast = Some((msg.into(), self.tick + 12));
    }

    // ---- playback --------------------------------------------------------

    /// Stream URLs for the current queue, at the configured tier.
    ///
    /// The tier falls back to the original when the server reports no ffmpeg:
    /// a transcoded request would answer 501 and mpv would simply fail.
    fn queue_urls(&self) -> Vec<String> {
        let tier = self.effective_tier();
        self.queue
            .items()
            .iter()
            .map(|id| self.client.stream_url(id, tier))
            .collect()
    }

    pub fn effective_tier(&self) -> Tier {
        let want = self.cfg.tier();
        match &self.status {
            Some(s) if !s.transcode && want != Tier::Original => Tier::Original,
            _ => want,
        }
    }

    /// Replaces the queue with `ids` and starts at `start`.
    pub fn play_tracks(&mut self, ids: Vec<String>, start: usize) {
        if ids.is_empty() {
            self.toast("nothing to play");
            return;
        }
        self.queue.set(ids, start);
        let urls = self.queue_urls();
        let pos = self.queue.pos().unwrap_or(0);
        self.pending_pos = Some(pos);
        self.player.set_queue(&urls, pos);
        self.apply_repeat();
        self.reported = None;
        self.last_playlist_pos = Some(pos);
        self.queue_list.selected = pos;
        if !self.player.is_enabled() {
            self.toast("mpv is not available — queued, but not playing");
        }
    }

    pub fn enqueue(&mut self, ids: Vec<String>, next: bool) {
        if ids.is_empty() {
            return;
        }
        let was_empty = self.queue.is_empty();
        let n = ids.len();
        if next {
            self.queue.insert_next(&ids);
        } else {
            self.queue.append(&ids);
        }
        // mpv holds the old list, so it is rebuilt. Playback continues from the
        // same index, which set_queue restores.
        if was_empty {
            let urls = self.queue_urls();
            let pos = self.queue.pos().unwrap_or(0);
            self.pending_pos = Some(pos);
            self.player.set_queue(&urls, pos);
        } else {
            self.rebuild_player_queue_preserving_position();
        }
        self.toast(format!(
            "{n} track{} {}",
            if n == 1 { "" } else { "s" },
            if next {
                "queued next"
            } else {
                "added to queue"
            }
        ));
    }

    /// Rebuilds mpv's playlist without restarting the current track.
    ///
    /// mpv has no "insert into playlist" over IPC that keeps the playing entry,
    /// so the list is reloaded and the elapsed position restored. The seek is
    /// what keeps this from being audible as a restart.
    pub fn rebuild_player_queue_preserving_position(&mut self) {
        if self.queue.is_empty() {
            self.player.stop();
            self.pending_pos = None;
            return;
        }
        let elapsed = self.player.state().time_pos;
        let paused = self.player.state().paused;
        let urls = self.queue_urls();
        let pos = self.queue.pos().unwrap_or(0);
        self.pending_pos = Some(pos);
        self.player.set_queue(&urls, pos);
        if elapsed > 1.0 {
            self.player.seek_absolute(elapsed);
        }
        if paused {
            self.player.set_paused(true);
        }
        self.apply_repeat();
    }

    /// Removes one entry from the queue and brings mpv back in line.
    ///
    /// Three cases, and they differ audibly:
    /// - the queue empties: stop, rather than leave mpv playing an entry that
    ///   is no longer in any queue;
    /// - the *playing* entry goes: whatever slides into its place starts from
    ///   the beginning, not from the removed track's elapsed time;
    /// - anything else: the current track keeps playing, uninterrupted.
    pub fn remove_from_queue(&mut self, index: usize) {
        if index >= self.queue.len() {
            return;
        }
        let was_current = self.queue.pos() == Some(index);
        self.queue.remove(index);
        self.queue_list.clamp(self.queue.len());

        if self.queue.is_empty() {
            self.player.stop();
            self.pending_pos = None;
            return;
        }
        if was_current {
            let urls = self.queue_urls();
            let pos = self.queue.pos().unwrap_or(0);
            self.pending_pos = Some(pos);
            self.player.set_queue(&urls, pos);
            self.apply_repeat();
        } else {
            self.rebuild_player_queue_preserving_position();
        }
    }

    pub fn apply_repeat(&self) {
        let r = self.queue.repeat();
        self.player.set_loop_file(r == Repeat::One);
        self.player.set_loop_playlist(r == Repeat::All);
    }

    pub fn play_next(&mut self) {
        if let Some(i) = self.queue.next_index() {
            self.queue.select(i);
            self.pending_pos = Some(i);
            self.player.play_index(i);
        }
    }

    pub fn play_prev(&mut self) {
        // Restart the track first, the way every player does: only jump back
        // when already near the start.
        if self.player.state().time_pos > 3.0 {
            self.player.seek_absolute(0.0);
            return;
        }
        if let Some(i) = self.queue.prev_index() {
            self.queue.select(i);
            self.pending_pos = Some(i);
            self.player.play_index(i);
        }
    }

    pub fn current_track(&self) -> Option<&Track> {
        self.queue.current().and_then(|id| self.lib.track(id))
    }

    // ---- per-frame work --------------------------------------------------

    pub fn tick(&mut self) {
        self.tick += 1;
        if let Some((_, expires)) = &self.toast {
            if self.tick >= *expires {
                self.toast = None;
            }
        }
        self.sync_playback();
        self.drain_messages();
    }

    /// Follows mpv: it advances the playlist on its own at end-of-file, so the
    /// queue takes its position from mpv rather than guessing.
    fn sync_playback(&mut self) {
        let st = self.player.state();
        self.apply_playback_state(&st);
    }

    /// The state-folding half of [`Self::sync_playback`], split out so the
    /// reporting rules can be tested without an mpv attached.
    fn apply_playback_state(&mut self, st: &crate::player::PlayerState) {
        if let Some(pos) = st.playlist_pos {
            // A rebuild loads entry 0 and only then jumps to the wanted index,
            // so mpv reports an intermediate position that is not where we
            // are. Ignore its reports until it arrives where we sent it.
            match self.pending_pos {
                Some(want) if pos != want => {}
                Some(_) => {
                    self.pending_pos = None;
                    self.last_playlist_pos = Some(pos);
                }
                None => {
                    if Some(pos) != self.last_playlist_pos {
                        self.last_playlist_pos = Some(pos);
                        self.queue.select(pos);
                    }
                }
            }
        }

        // Re-arm reporting when the track being played changes. Keying on the
        // id rather than on mpv's start-file count is what keeps a queue
        // rebuild — which reloads the very same track — from reporting it
        // twice.
        let current_id = self.queue.current().cloned();
        if current_id != self.last_track_id {
            self.last_track_id = current_id.clone();
            self.reported = None;
        } else if current_id.is_some()
            && st.duration > 0.0
            && self.last_time_pos >= st.duration - 2.0
            && st.time_pos < 2.0
        {
            // Same entry, but it ran to the end and started again: repeat-one.
            // That is a second listen and reports again — unlike a backward
            // seek, which lands here from the middle of the track and must not.
            self.reported = None;
        }
        self.last_time_pos = st.time_pos;

        // mpv failures (a dead socket, a rejected command, a stream it could
        // not open) were previously recorded and never shown, which made a
        // silent playback failure look like a bug in the client.
        if let Some(err) = &st.last_error {
            if self.last_player_error.as_deref() != Some(err.as_str()) {
                self.last_player_error = Some(err.clone());
                self.error = Some(err.clone());
            }
        }

        self.maybe_report_play(st);
    }

    /// Reports a play once the usual threshold is crossed: half the track,
    /// capped at 30 seconds. The server enforces nothing here, and it dedups
    /// on (trackId, profileId, at) — but it cannot tell us a report was a
    /// duplicate, so the latch is the client's job.
    fn maybe_report_play(&mut self, st: &crate::player::PlayerState) {
        if self.cfg.profile_id.is_empty() || st.paused {
            return;
        }
        let Some(track) = self.current_track() else {
            return;
        };
        let id = track.id.clone();
        if self.reported.as_deref() == Some(id.as_str()) {
            return;
        }
        // Prefer mpv's duration: it is what is actually being played, and a
        // track can be missing a tagged one.
        let duration = if st.duration > 0.0 {
            Some(st.duration)
        } else {
            track.duration
        };
        let threshold = timefmt::scrobble_threshold(duration, self.cfg.scrobble_at);
        if st.time_pos < threshold {
            return;
        }
        self.reported = Some(id.clone());
        self.reports_sent += 1;
        let pid = self.cfg.profile_id.clone();
        // Stamp the moment the threshold was crossed rather than letting the
        // server stamp its own: identical for a live client, and correct if
        // the request is slow.
        let at = timefmt::iso_now();
        self.spawn(move |c, tx| {
            if let Err(e) = c.report_play(&id, &pid, Some(at)) {
                let _ = tx.send(Msg::Toast(format!("play not recorded: {e}")));
            }
        });
    }

    fn drain_messages(&mut self) {
        while let Ok(msg) = self.rx.try_recv() {
            self.handle(msg);
        }
    }

    fn handle(&mut self, msg: Msg) {
        match msg {
            Msg::Library(Ok(tracks)) => {
                self.loading = false;
                let n = tracks.len();
                self.lib = Library::new(tracks);
                self.albums_list.clamp(self.lib.albums.len());
                self.artists_list.clamp(self.lib.artists.len());
                self.tracks_list.clamp(self.lib.tracks.len());
                self.rerun_search();
                self.error = None;
                self.toast(format!("{n} tracks"));
            }
            Msg::Library(Err(e)) => {
                self.loading = false;
                self.error = Some(format!("library: {e}"));
            }
            Msg::Status(Ok(s)) => self.status = Some(s),
            Msg::Status(Err(e)) => self.error = Some(format!("status: {e}")),
            Msg::Profiles(Ok(ps)) => {
                self.profiles = ps;
                self.ensure_profile();
            }
            Msg::Profiles(Err(e)) => self.error = Some(format!("profiles: {e}")),
            Msg::Playlists(Ok(p)) => {
                self.playlists = p;
                self.playlists_list.clamp(self.playlists.len());
            }
            Msg::Playlists(Err(e)) => self.error = Some(format!("playlists: {e}")),
            Msg::PlaylistTracks(id, Ok(ts)) => {
                if self.detail == Detail::Playlist(id) {
                    self.playlist_tracks = ts;
                    self.detail_list.clamp(self.playlist_tracks.len());
                }
            }
            Msg::PlaylistTracks(_, Err(e)) => self.error = Some(format!("playlist: {e}")),
            Msg::Tags(Ok(t)) => {
                self.tags = t;
                self.tags_list.clamp(self.tags.len());
            }
            Msg::Tags(Err(e)) => self.error = Some(format!("tags: {e}")),
            Msg::Stats(Ok(s)) => self.stats = Some(s),
            Msg::Stats(Err(e)) => self.error = Some(format!("stats: {e}")),
            Msg::Favourite(id, Ok(fav)) => {
                self.lib.set_favourite(&id, fav);
                self.toast(if fav { "favourited" } else { "unfavourited" });
            }
            Msg::Favourite(_, Err(e)) => self.error = Some(format!("favourite: {e}")),
            Msg::ProfileCreated(Ok(p)) => {
                self.toast(format!("profile {} created", p.name));
                self.set_profile(&p.clone());
                self.profiles.push(p);
            }
            Msg::ProfileCreated(Err(e)) => {
                self.error = Some(format!("profile: {e}"));
                // A failed create during first-run setup must hand the picker
                // back, or the session is left with no profile and no way to
                // choose one.
                if self.cfg.profile_id.is_empty() {
                    self.modal = Modal::ProfilePicker { selected: 0 };
                }
            }
            Msg::PlaylistChanged(Ok(_)) => {
                self.load_playlists();
                if let Detail::Playlist(id) = self.detail.clone() {
                    self.open_playlist(&id);
                }
            }
            Msg::PlaylistChanged(Err(e)) => self.error = Some(format!("playlist: {e}")),
            Msg::Done(ok, Ok(())) => {
                if !ok.is_empty() {
                    self.toast(ok);
                }
            }
            Msg::Done(_, Err(e)) => self.error = Some(e.to_string()),
            Msg::Sse(ev) => self.handle_sse(ev),
            Msg::SseLost => self.progress = None,
            Msg::Toast(t) => self.toast(t),
        }
    }

    /// The server publishes four progress streams. Each carries a snapshot,
    /// not a delta, and the `running: false` frame is the cue that the library
    /// changed underneath us.
    fn handle_sse(&mut self, ev: SseEvent) {
        let Some(v) = ev.json() else { return };
        let done = v.get("done").and_then(|x| x.as_u64()).unwrap_or(0);
        let total = v.get("total").and_then(|x| x.as_u64()).unwrap_or(0);
        let running = v.get("running").and_then(|x| x.as_bool());
        let phase = v
            .get("phase")
            .and_then(|x| x.as_str())
            .unwrap_or(ev.name.as_str())
            .to_string();

        match ev.name.as_str() {
            "scan" => {
                if total > 0 && done < total {
                    self.progress = Some(("scan".into(), done, total));
                } else {
                    // A finished scan means new tracks; pick them up.
                    if self.progress.is_some() {
                        self.progress = None;
                        self.load_library();
                        self.load_status();
                    }
                }
            }
            "enrich" | "analyze" | "fingerprint" => match running {
                Some(true) => self.progress = Some((phase, done, total)),
                _ => {
                    if self.progress.is_some() {
                        self.progress = None;
                        // Enrichment rewrites the merged view, so the library
                        // is stale once a pass ends.
                        self.load_library();
                    }
                }
            },
            _ => {}
        }
    }

    // ---- profiles --------------------------------------------------------

    /// Aria seeds at least one profile, so a client that finds none is talking
    /// to something unexpected. With exactly one, use it; with several, ask.
    fn ensure_profile(&mut self) {
        if self.profiles.is_empty() {
            self.error = Some("server has no profiles — create one to record plays".into());
            return;
        }
        if let Some(p) = self
            .profiles
            .iter()
            .find(|p| p.id == self.cfg.profile_id)
            .cloned()
        {
            self.cfg.profile_name = p.name;
            self.after_profile_selected();
            return;
        }
        if self.profiles.len() == 1 {
            let p = self.profiles[0].clone();
            self.set_profile(&p);
        } else {
            self.modal = Modal::ProfilePicker { selected: 0 };
        }
    }

    pub fn set_profile(&mut self, p: &Profile) {
        self.cfg.profile_id = p.id.clone();
        self.cfg.profile_name = p.name.clone();
        self.saved.profile_id = p.id.clone();
        self.saved.profile_name = p.name.clone();
        self.save_config();
        self.after_profile_selected();
    }

    fn after_profile_selected(&mut self) {
        self.load_playlists();
        self.load_stats();
    }

    // ---- navigation helpers ---------------------------------------------

    pub fn rerun_search(&mut self) {
        self.search_hits = self.lib.search(&self.search_input);
        self.search_list.clamp(self.search_hits.len());
    }

    pub fn open_playlist(&mut self, id: &str) {
        self.detail = Detail::Playlist(id.to_string());
        self.detail_list = ListState::default();
        self.playlist_tracks.clear();
        let pid = id.to_string();
        self.spawn(move |c, tx| {
            let r = c.playlist_tracks(&pid);
            let _ = tx.send(Msg::PlaylistTracks(pid, r));
        });
    }

    pub fn toggle_favourite(&mut self, track_id: &str) {
        let Some(t) = self.lib.track(track_id) else {
            return;
        };
        let want = !t.favourite;
        let id = track_id.to_string();
        // Optimistic: the list redraws immediately and the server confirms.
        self.lib.set_favourite(&id, want);
        self.spawn(move |c, tx| {
            let r = c.set_favourite(&id, want);
            let _ = tx.send(Msg::Favourite(id, r));
        });
    }

    /// Track ids currently under the cursor, for play/queue/playlist actions.
    pub fn selection(&self) -> Vec<String> {
        match (&self.detail, self.view) {
            (Detail::Album(id), _) => self
                .lib
                .album(id)
                .map(|a| {
                    a.track_ids
                        .get(self.detail_list.selected)
                        .cloned()
                        .into_iter()
                        .collect()
                })
                .unwrap_or_default(),
            (Detail::Artist(name), _) => self
                .artist_tracks(name)
                .get(self.detail_list.selected)
                .cloned()
                .into_iter()
                .collect(),
            (Detail::Playlist(_), _) => self
                .playlist_tracks
                .get(self.detail_list.selected)
                .map(|t| vec![t.id.clone()])
                .unwrap_or_default(),
            (Detail::Tag(name), _) => self
                .tag_tracks(name)
                .get(self.detail_list.selected)
                .cloned()
                .into_iter()
                .collect(),
            (Detail::None, View::Albums) => self
                .lib
                .albums
                .get(self.albums_list.selected)
                .map(|a| a.track_ids.clone())
                .unwrap_or_default(),
            (Detail::None, View::Artists) => self
                .lib
                .artists
                .get(self.artists_list.selected)
                .map(|a| self.artist_tracks(&a.name))
                .unwrap_or_default(),
            (Detail::None, View::Tracks) => self
                .lib
                .tracks
                .get(self.tracks_list.selected)
                .map(|t| vec![t.id.clone()])
                .unwrap_or_default(),
            (Detail::None, View::Search) => self
                .search_hits
                .get(self.search_list.selected)
                .and_then(|&i| self.lib.tracks.get(i))
                .map(|t| vec![t.id.clone()])
                .unwrap_or_default(),
            (Detail::None, View::Queue) => self
                .queue
                .items()
                .get(self.queue_list.selected)
                .cloned()
                .into_iter()
                .collect(),
            (Detail::None, View::Tags) => self
                .tags
                .get(self.tags_list.selected)
                .map(|t| self.tag_tracks(&t.name))
                .unwrap_or_default(),
            _ => Vec::new(),
        }
    }

    pub fn artist_tracks(&self, name: &str) -> Vec<String> {
        self.lib
            .artists
            .iter()
            .find(|a| a.name == name)
            .map(|a| {
                a.album_ids
                    .iter()
                    .filter_map(|id| self.lib.album(id))
                    .flat_map(|al| al.track_ids.clone())
                    .collect()
            })
            .unwrap_or_default()
    }

    /// Tracks carrying a tag. Tag membership is precomputed by the server and
    /// arrives on each track as a list of names, ancestors included.
    pub fn tag_tracks(&self, tag_name: &str) -> Vec<String> {
        self.lib
            .tracks
            .iter()
            .filter(|t| t.tags.iter().any(|x| x == tag_name))
            .map(|t| t.id.clone())
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn list_state_moves_and_clamps() {
        let mut s = ListState::default();
        s.move_by(5, 3);
        assert_eq!(s.selected, 2, "cannot move past the end");
        s.move_by(-99, 3);
        assert_eq!(s.selected, 0, "cannot move before the start");
    }

    #[test]
    fn list_state_on_an_empty_list_stays_put() {
        let mut s = ListState::default();
        s.move_by(3, 0);
        assert_eq!(s.selected, 0);
    }

    #[test]
    fn clamp_pulls_a_stale_selection_back_in_range() {
        let mut s = ListState {
            selected: 40,
            offset: 30,
        };
        s.clamp(10);
        assert_eq!(s.selected, 9);
        s.clamp(0);
        assert_eq!(s.selected, 0);
        assert_eq!(s.offset, 0);
    }

    #[test]
    fn scrolling_follows_the_selection_down_and_up() {
        let mut s = ListState {
            selected: 25,
            ..Default::default()
        };
        s.scroll_into_view(10);
        assert_eq!(s.offset, 16, "the selection sits on the last visible row");

        s.selected = 3;
        s.scroll_into_view(10);
        assert_eq!(s.offset, 3, "scrolling back up puts it on the first row");
    }

    #[test]
    fn scroll_into_view_with_no_height_is_a_no_op() {
        let mut s = ListState {
            selected: 5,
            offset: 2,
        };
        s.scroll_into_view(0);
        assert_eq!(s.offset, 2);
    }

    #[test]
    fn repeat_cycles_and_labels() {
        assert_eq!(Repeat::Off.next(), Repeat::All);
        assert_eq!(Repeat::All.label(), "all");
    }

    // ---- play reporting -------------------------------------------------

    use crate::api::models::Track;
    use crate::config::Config;
    use crate::player::{Player, PlayerState};

    fn reporting_app() -> App {
        let mut a = App::new(
            Config::default(),
            "/tmp/aria-tui-report-test.toml".into(),
            Player::disabled(),
        );
        a.cfg.profile_id = "p1".into();
        a.lib = crate::library::Library::new(vec![
            Track {
                id: "t1".into(),
                title: "One".into(),
                album_id: "al".into(),
                duration: Some(200.0),
                ..Default::default()
            },
            Track {
                id: "t2".into(),
                title: "Two".into(),
                album_id: "al".into(),
                duration: Some(200.0),
                ..Default::default()
            },
        ]);
        a.queue.set(vec!["t1".into(), "t2".into()], 0);
        a
    }

    fn playing(pos: usize, time: f64) -> PlayerState {
        playing_started(pos, time, 1)
    }

    /// `starts` is mpv's start-file counter, which bumps every time it loads a
    /// file — including when the app rebuilds the playlist under a track that
    /// was already playing.
    fn playing_started(pos: usize, time: f64, starts: u64) -> PlayerState {
        PlayerState {
            time_pos: time,
            duration: 200.0,
            paused: false,
            playlist_pos: Some(pos),
            start_count: starts,
            ..Default::default()
        }
    }

    #[test]
    fn a_play_is_reported_once_at_the_threshold() {
        let mut a = reporting_app();
        a.apply_playback_state(&playing(0, 5.0));
        assert_eq!(a.reports_sent, 0, "too early to count");

        a.apply_playback_state(&playing(0, 31.0));
        assert_eq!(a.reports_sent, 1);

        // Still playing the same track: no second report.
        for t in [40.0, 90.0, 150.0] {
            a.apply_playback_state(&playing(0, t));
        }
        assert_eq!(a.reports_sent, 1);
    }

    #[test]
    fn a_queue_rebuild_does_not_report_the_same_play_twice() {
        // Regression: re-arming on mpv's start-file count meant that queueing
        // a track mid-playback reloaded the playlist and reported the current
        // track again — the server dedups on (track, profile, at), and `at`
        // differs, so it landed as a real second play.
        let mut a = reporting_app();
        a.apply_playback_state(&playing(0, 31.0));
        assert_eq!(a.reports_sent, 1);

        // Enqueue rebuilds mpv's playlist: mpv reloads the file, so its
        // start-file counter bumps and it re-announces the position — while
        // the listener has heard exactly one play.
        a.enqueue(vec!["t2".into()], false);
        a.apply_playback_state(&playing_started(0, 31.5, 2));
        a.apply_playback_state(&playing_started(0, 32.0, 2));
        assert_eq!(a.reports_sent, 1, "the same listen must count once");
    }

    #[test]
    fn each_track_in_the_queue_reports_separately() {
        let mut a = reporting_app();
        a.apply_playback_state(&playing(0, 31.0));
        a.apply_playback_state(&playing(1, 2.0)); // mpv advanced
        a.apply_playback_state(&playing(1, 31.0));
        assert_eq!(a.reports_sent, 2);
    }

    #[test]
    fn a_repeat_one_loop_counts_as_a_second_listen() {
        let mut a = reporting_app();
        a.apply_playback_state(&playing(0, 31.0));
        assert_eq!(a.reports_sent, 1);

        // Ran to the end and started over.
        a.apply_playback_state(&playing(0, 199.5));
        a.apply_playback_state(&playing(0, 0.5));
        a.apply_playback_state(&playing(0, 31.0));
        assert_eq!(a.reports_sent, 2);
    }

    #[test]
    fn seeking_back_within_a_track_does_not_report_it_again() {
        let mut a = reporting_app();
        a.apply_playback_state(&playing(0, 120.0));
        assert_eq!(a.reports_sent, 1);

        // A seek from the middle back to the start is not a new listen.
        a.apply_playback_state(&playing(0, 1.0));
        a.apply_playback_state(&playing(0, 40.0));
        assert_eq!(a.reports_sent, 1);
    }

    #[test]
    fn nothing_is_reported_without_a_profile() {
        let mut a = reporting_app();
        a.cfg.profile_id.clear();
        a.apply_playback_state(&playing(0, 120.0));
        assert_eq!(a.reports_sent, 0, "the server would reject it anyway");
    }

    #[test]
    fn a_paused_track_does_not_cross_the_threshold() {
        let mut a = reporting_app();
        let mut st = playing(0, 120.0);
        st.paused = true;
        a.apply_playback_state(&st);
        assert_eq!(a.reports_sent, 0);
    }

    #[test]
    fn an_intermediate_playlist_pos_during_a_rebuild_is_ignored() {
        // A rebuild loads entry 0 first, so mpv briefly reports position 0 on
        // its way to the index we asked for. Mirroring that back would move the
        // queue to the wrong track.
        let mut a = reporting_app();
        a.play_tracks(vec!["t1".into(), "t2".into()], 1);
        assert_eq!(a.queue.pos(), Some(1));

        a.apply_playback_state(&playing(0, 0.1)); // mpv's transient report
        assert_eq!(a.queue.pos(), Some(1), "the queue must not jump to entry 0");

        a.apply_playback_state(&playing(1, 0.2)); // it arrives where we sent it
        assert_eq!(a.queue.pos(), Some(1));

        // Now mpv is authoritative again: a natural advance is followed.
        a.apply_playback_state(&playing(0, 0.1));
        assert_eq!(a.queue.pos(), Some(0));
    }

    #[test]
    fn a_command_line_override_is_not_written_back_to_the_config_file() {
        // Regression: `apply` merged the flag into the same struct that gets
        // saved, so `aria-tui -s http://laptop:3000` + quit permanently
        // replaced a hand-written server URL in the user's file.
        let dir = std::env::temp_dir().join(format!("aria-tui-flags-{}", std::process::id()));
        let path = dir.join("config.toml");
        let on_disk = Config {
            server: "http://nas.local:3000".into(),
            tier: "original".into(),
            ..Default::default()
        };
        on_disk.save(&path).unwrap();

        let mut effective = on_disk.clone();
        let args = crate::config::parse_args(
            ["-s", "http://laptop:3000", "-t", "low"]
                .iter()
                .map(|s| s.to_string()),
        )
        .unwrap();
        effective.apply(&args);

        let mut app = App::with_saved(effective, on_disk, path.clone(), Player::disabled());
        assert_eq!(
            app.cfg.server, "http://laptop:3000",
            "the flag applies to this run"
        );

        app.save_config(); // what quitting does

        let reloaded = Config::load(&path).unwrap();
        assert_eq!(
            reloaded.server, "http://nas.local:3000",
            "the hand-written URL must survive a one-off flag"
        );
        assert_eq!(reloaded.tier, "original", "and so must the stored tier");
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn an_in_app_change_is_written_back() {
        // The other half of the rule: what the user chooses inside the app is
        // theirs to keep.
        let dir = std::env::temp_dir().join(format!("aria-tui-inapp-{}", std::process::id()));
        let path = dir.join("config.toml");
        let on_disk = Config {
            server: "http://nas.local:3000".into(),
            ..Default::default()
        };
        on_disk.save(&path).unwrap();

        let mut app = App::with_saved(on_disk.clone(), on_disk, path.clone(), Player::disabled());
        app.persist_tier("high".into());
        app.cfg.volume = 42.0;
        app.save_config();

        let reloaded = Config::load(&path).unwrap();
        assert_eq!(reloaded.tier, "high");
        assert_eq!(reloaded.volume, 42.0);
        assert_eq!(
            reloaded.server, "http://nas.local:3000",
            "untouched fields stay"
        );
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn a_failed_profile_create_hands_the_picker_back() {
        let mut a = reporting_app();
        a.cfg.profile_id.clear();
        a.handle(Msg::ProfileCreated(Err(crate::api::ApiError::Transport(
            "boom".into(),
        ))));
        assert!(
            matches!(a.modal, Modal::ProfilePicker { .. }),
            "a first run must not be stranded without a profile"
        );
    }

    #[test]
    fn every_view_has_a_title() {
        for v in View::ALL {
            assert!(!v.title().is_empty());
        }
        assert_eq!(View::ALL.len(), 8);
    }
}
