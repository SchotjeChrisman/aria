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
use crate::library::{Library, ListKind, Sort, SortField};
use crate::player::Player;
use crate::queue::{Queue, Repeat};
use crate::timefmt;

/// The three lists whose order the user chooses.
const SORTABLE: [ListKind; 3] = [ListKind::Albums, ListKind::Artists, ListKind::Tracks];

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

    /// The library list this view shows, if it is one that can be re-sorted.
    /// The queue is a hand-built order and a playlist is the order it was
    /// saved in, so neither is sortable; search results are ranked by how well
    /// they match, which is the only useful order for them.
    pub fn list_kind(self) -> Option<ListKind> {
        match self {
            View::Albums => Some(ListKind::Albums),
            View::Artists => Some(ListKind::Artists),
            View::Tracks => Some(ListKind::Tracks),
            _ => None,
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
    PlayCounts(Result<std::collections::HashMap<String, u32>, ApiError>),
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
    /// Per-track play counts for the active profile, `None` until a list is
    /// sorted by them. Held here as well as in the library because a rescan
    /// rebuilds the library, and re-fetching on every rescan would undo the
    /// laziness this is fetched with.
    pub play_counts: Option<std::collections::HashMap<String, u32>>,
    counts_in_flight: bool,

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
            play_counts: None,
            counts_in_flight: false,
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

    /// Hands the stored row orders to a freshly loaded library. Sorting lives
    /// in the library because that is where the rows are, but the choice is
    /// the user's and outlives any one load.
    fn apply_sorts(&mut self) {
        let sorts = self.cfg.sorts();
        self.lib.set_sorts(sorts);
        if let Some(counts) = self.play_counts.clone() {
            self.lib.set_play_counts(counts);
        }
    }

    /// The library items each list's cursor is on, so a re-order can put the
    /// cursors back on them rather than leaving them pointing at a row number.
    fn held_rows(&self) -> [Option<usize>; 3] {
        SORTABLE.map(|k| self.lib.row(k, self.list_state(k).selected))
    }

    fn restore_rows(&mut self, held: [Option<usize>; 3]) {
        for (kind, item) in SORTABLE.into_iter().zip(held) {
            if let Some(row) = item.and_then(|i| self.lib.row_of(kind, i)) {
                self.list_state_mut(kind).selected = row;
            }
        }
    }

    fn list_state_mut(&mut self, kind: ListKind) -> &mut ListState {
        match kind {
            ListKind::Albums => &mut self.albums_list,
            ListKind::Artists => &mut self.artists_list,
            ListKind::Tracks => &mut self.tracks_list,
        }
    }

    pub fn list_state(&self, kind: ListKind) -> &ListState {
        match kind {
            ListKind::Albums => &self.albums_list,
            ListKind::Artists => &self.artists_list,
            ListKind::Tracks => &self.tracks_list,
        }
    }

    /// The list the sort keys act on: only a top-level library view, since a
    /// drill-down shows an album in disc order and a playlist in the order it
    /// was saved.
    pub fn sortable(&self) -> Option<ListKind> {
        if self.detail == Detail::None {
            self.view.list_kind()
        } else {
            None
        }
    }

    pub fn cycle_sort(&mut self) {
        let Some(kind) = self.sortable() else {
            self.toast("this view has a fixed order");
            return;
        };
        let next = self.lib.sort(kind).next(kind);
        self.set_sort(kind, next);
    }

    pub fn reverse_sort(&mut self) {
        let Some(kind) = self.sortable() else {
            self.toast("this view has a fixed order");
            return;
        };
        let next = self.lib.sort(kind).reversed();
        self.set_sort(kind, next);
    }

    fn set_sort(&mut self, kind: ListKind, sort: Sort) {
        // The row under the cursor is remembered across the re-sort. Losing
        // your place in a list long enough to need sorting is the very thing
        // sorting is being reached for, and `g` is one key away when the top
        // is what was wanted.
        let held = self.held_rows();

        let mut sorts = self.lib.sorts();
        sorts.set(kind, sort);
        self.lib.set_sorts(sorts);
        self.cfg.set_sorts(sorts);
        self.saved.set_sorts(sorts);
        self.save_config();
        self.restore_rows(held);

        // Play counts are not part of the library document, so asking for
        // this order is what goes and gets them.
        if sort.field == SortField::Plays && self.play_counts.is_none() {
            if self.cfg.profile_id.is_empty() {
                // Plays are recorded against a profile, so without one there
                // is nothing to rank by — say that rather than counting to 0.
                self.toast("sorted by plays — but no profile is chosen");
                return;
            }
            self.ensure_play_counts();
            self.toast("sorted by plays — counting…");
            return;
        }
        self.toast(format!("sorted by {}", sort.label()));
    }

    /// Records an in-app change to a field that a CLI flag can also set. The
    /// user has now chosen it deliberately, so it becomes the stored value.
    pub fn persist_tier(&mut self, tier: String) {
        self.cfg.tier = tier.clone();
        self.saved.tier = tier;
        self.save_config();
    }

    /// Points the client at a different server and stores the choice, so it is
    /// the one used from the next run onwards.
    ///
    /// Everything on screen belongs to the old server — track ids, playlist
    /// ids, profile ids, stream URLs — so the state is dropped rather than
    /// blended. Replacing the message channel is what retires the requests
    /// already in flight: their threads find the receiver gone, so a slow
    /// answer from the old server cannot land on top of the new library.
    pub fn switch_server(&mut self, server: String) {
        // Checked before normalising, not after: `normalize_base` answers the
        // default URL for empty input, so an emptied prompt would otherwise
        // read as "switch me to localhost:3000" and drop the session.
        let typed = server.trim();
        if typed.is_empty() {
            self.toast("no server URL given");
            return;
        }
        let next = crate::api::normalize_base(typed);
        if next == self.cfg.server {
            self.toast("already connected to that server");
            return;
        }

        self.cfg.server = next.clone();
        self.saved.server = next.clone();
        // The profile belongs to the server that issued it, so it cannot carry
        // over; `ensure_profile` picks or asks again once the new list lands.
        self.cfg.profile_id.clear();
        self.cfg.profile_name.clear();
        self.saved.profile_id.clear();
        self.saved.profile_name.clear();
        self.save_config();

        let (tx, rx) = std::sync::mpsc::channel();
        self.tx = tx;
        self.rx = rx;
        self.client = Arc::new(Client::new(&next));

        // The queue holds URLs on the old host, so it is stopped rather than
        // left playing something the visible library no longer describes.
        self.player.stop();
        self.queue.clear();
        self.lib = Library::default();
        self.playlists.clear();
        self.playlist_tracks.clear();
        self.tags.clear();
        self.profiles.clear();
        self.stats = None;
        self.status = None;
        self.play_counts = None;
        self.counts_in_flight = false;
        self.progress = None;
        self.detail = Detail::None;
        self.reported = None;
        self.last_track_id = None;
        self.pending_pos = None;
        self.error = None;
        self.rerun_search();

        self.spawn_event_stream();
        self.load_library();
        self.load_status();
        self.load_profiles();
        self.load_tags();
        self.toast(format!("connected to {next}"));
    }

    /// Subscribes to the server's progress stream, reconnecting for as long as
    /// the channel lives. Scan and enrichment passes rewrite the merged track
    /// view, so this is how the client learns its library went stale.
    ///
    /// Respawned on a server switch; the previous thread retires itself when
    /// its send fails against the replaced channel.
    pub fn spawn_event_stream(&self) {
        use std::time::{Duration, Instant};

        let tx = self.sender();
        let base = self.client.base_url().to_string();
        std::thread::spawn(move || {
            let client = Client::new(&base);
            let base_delay = Duration::from_secs(1);
            let mut backoff = base_delay;
            loop {
                let started = Instant::now();
                let tx2 = tx.clone();
                let result = client.events(move |ev| {
                    let _ = tx2.send(Msg::Sse(ev));
                });
                if tx.send(Msg::SseLost).is_err() {
                    return; // the app is gone, or this server is no longer ours
                }
                let _ = result;
                // A stream that stayed up was healthy, so the next drop starts
                // from a short delay again — otherwise one bad patch would
                // leave the client on a minute-long reconnect for the rest of
                // the run.
                if started.elapsed() >= Duration::from_secs(30) {
                    backoff = base_delay;
                }
                // A drop is normal (server restart, proxy timeout); back off up
                // to a minute rather than hammering.
                std::thread::sleep(backoff);
                backoff = (backoff * 2).min(Duration::from_secs(60));
            }
        });
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
        self.refresh_play_counts();
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
                self.apply_sorts();
                // Also here, not only when the profile is settled: the two
                // arrive in whichever order the server answers, and until the
                // library exists there is no sort to notice plays in.
                self.ensure_play_counts();
                self.albums_list.clamp(self.lib.albums.len());
                self.artists_list.clamp(self.lib.artists.len());
                self.tracks_list.clamp(self.lib.tracks.len());
                self.rerun_search();
                self.error = None;
                self.toast(format!("{n} track{}", if n == 1 { "" } else { "s" }));
            }
            Msg::Library(Err(e)) => {
                self.loading = false;
                self.error = Some(format!("library: {e}"));
            }
            Msg::PlayCounts(Ok(counts)) => {
                self.counts_in_flight = false;
                // Preserved across the re-order for the same reason an
                // explicit sort change is: the row being looked at should not
                // move out from under the cursor.
                let held = self.held_rows();
                self.play_counts = Some(counts.clone());
                self.lib.set_play_counts(counts);
                self.restore_rows(held);
            }
            Msg::PlayCounts(Err(e)) => {
                self.counts_in_flight = false;
                self.error = Some(format!("play counts: {e}"));
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
        // Plays belong to the profile that made them, so the counts on hand
        // are now the wrong listener's. Drop them, and fetch again only if a
        // list is actually ranked by them.
        self.play_counts = None;
        self.lib.clear_play_counts();
        self.ensure_play_counts();
    }

    /// Fetches the per-track play counts, but only when a list is sorted by
    /// them and they are not already loaded. The map is one row per played
    /// track, and a listener who never sorts by plays should never pay for it
    /// — the same laziness the Flutter app applies.
    pub fn ensure_play_counts(&mut self) {
        if self.play_counts.is_some() || !self.sorting_by_plays() {
            return;
        }
        self.fetch_play_counts();
    }

    fn fetch_play_counts(&mut self) {
        if self.counts_in_flight || self.cfg.profile_id.is_empty() {
            return;
        }
        self.counts_in_flight = true;
        let pid = self.cfg.profile_id.clone();
        self.spawn(move |c, tx| {
            let _ = tx.send(Msg::PlayCounts(c.play_counts(&pid)));
        });
    }

    pub fn sorting_by_plays(&self) -> bool {
        [ListKind::Albums, ListKind::Artists, ListKind::Tracks]
            .iter()
            .any(|&k| self.lib.sort(k).field == SortField::Plays)
    }

    /// Re-fetches the counts after a play is recorded, so a list ranked by
    /// plays reflects what was just listened to. Only when they are already
    /// loaded, which by the laziness above means only when they are on screen.
    /// The old counts stay in place until the new ones land, so the list is
    /// re-ordered once rather than collapsing to all-zeros in between.
    fn refresh_play_counts(&mut self) {
        if self.play_counts.is_some() && self.sorting_by_plays() {
            self.fetch_play_counts();
        }
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
            // Through the display order, not straight into the library: the
            // cursor counts rows on screen, and the rows are sorted.
            (Detail::None, View::Albums) => self
                .album_at(self.albums_list.selected)
                .map(|a| a.track_ids.clone())
                .unwrap_or_default(),
            (Detail::None, View::Artists) => self
                .artist_at(self.artists_list.selected)
                .map(|a| a.name.clone())
                .map(|name| self.artist_tracks(&name))
                .unwrap_or_default(),
            (Detail::None, View::Tracks) => self
                .track_at(self.tracks_list.selected)
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

    /// The item shown on a display row. Rows are what the cursor and the
    /// renderer count; the library vectors keep their own load order.
    pub fn album_at(&self, row: usize) -> Option<&crate::api::models::Album> {
        self.lib
            .row(ListKind::Albums, row)
            .and_then(|i| self.lib.albums.get(i))
    }

    pub fn artist_at(&self, row: usize) -> Option<&crate::library::Artist> {
        self.lib
            .row(ListKind::Artists, row)
            .and_then(|i| self.lib.artists.get(i))
    }

    pub fn track_at(&self, row: usize) -> Option<&Track> {
        self.lib
            .row(ListKind::Tracks, row)
            .and_then(|i| self.lib.tracks.get(i))
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
    fn switching_servers_in_the_app_stores_the_new_url() {
        let dir = std::env::temp_dir().join(format!("aria-tui-switch-{}", std::process::id()));
        let path = dir.join("config.toml");
        let on_disk = Config {
            server: "http://nas.local:3000".into(),
            profile_id: "p-1".into(),
            profile_name: "Alex".into(),
            ..Default::default()
        };
        on_disk.save(&path).unwrap();

        let mut app = App::with_saved(on_disk.clone(), on_disk, path.clone(), Player::disabled());
        app.lib = Library::new(vec![Track {
            id: "t1".into(),
            album_id: "al1".into(),
            ..Default::default()
        }]);
        app.play_tracks(vec!["t1".into()], 0);

        // Typed without a scheme, the way a user would.
        app.switch_server("box:3001".into());

        assert_eq!(app.cfg.server, "http://box:3001");
        assert_eq!(app.client.base_url(), "http://box:3001");
        assert!(
            app.lib.tracks.is_empty() && app.queue.is_empty(),
            "the old server's library and queue must not survive the switch"
        );
        assert!(
            app.cfg.profile_id.is_empty(),
            "a profile id is scoped to the server that issued it"
        );

        let reloaded = Config::load(&path).unwrap();
        assert_eq!(reloaded.server, "http://box:3001");
        assert!(reloaded.profile_id.is_empty());
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn a_switch_to_the_same_server_is_a_no_op() {
        // Opening the prompt and pressing Enter must not clear the library and
        // drop the profile for nothing.
        let dir = std::env::temp_dir().join(format!("aria-tui-noswitch-{}", std::process::id()));
        let cfg = Config {
            server: "http://nas.local:3000".into(),
            profile_id: "p-1".into(),
            ..Default::default()
        };
        let mut app = App::new(cfg, dir.join("config.toml"), Player::disabled());
        app.lib = Library::new(vec![Track {
            id: "t1".into(),
            album_id: "al1".into(),
            ..Default::default()
        }]);

        // Same URL, spelled with the trailing slash `normalize_base` strips.
        app.switch_server("http://nas.local:3000/".into());

        assert_eq!(app.lib.tracks.len(), 1, "nothing should have been dropped");
        assert_eq!(app.cfg.profile_id, "p-1");
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn an_emptied_server_prompt_changes_nothing() {
        // Ctrl-U then Enter. `normalize_base("")` answers the default URL, so
        // taking it at face value would have switched the user to
        // localhost:3000 and thrown away their library and profile.
        let dir = std::env::temp_dir().join(format!("aria-tui-blank-{}", std::process::id()));
        let cfg = Config {
            server: "http://nas.local:3000".into(),
            profile_id: "p-1".into(),
            ..Default::default()
        };
        let mut app = App::new(cfg, dir.join("config.toml"), Player::disabled());
        app.lib = Library::new(vec![Track {
            id: "t1".into(),
            album_id: "al1".into(),
            ..Default::default()
        }]);

        app.switch_server("   ".into());

        assert_eq!(app.cfg.server, "http://nas.local:3000");
        assert_eq!(app.cfg.profile_id, "p-1");
        assert_eq!(app.lib.tracks.len(), 1);
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn a_reply_from_the_old_server_cannot_land_on_the_new_one() {
        // A slow /api/tracks against the previous host must not repopulate the
        // library after the switch. The retired channel is what stops it.
        let dir = std::env::temp_dir().join(format!("aria-tui-stale-{}", std::process::id()));
        let cfg = Config {
            server: "http://nas.local:3000".into(),
            ..Default::default()
        };
        let mut app = App::new(cfg, dir.join("config.toml"), Player::disabled());
        let old_tx = app.sender();

        app.switch_server("http://box:3001".into());

        let sent = old_tx.send(Msg::Library(Ok(vec![Track {
            id: "ghost".into(),
            album_id: "al1".into(),
            ..Default::default()
        }])));
        assert!(sent.is_err(), "the old channel must be closed");
        app.tick();
        assert!(
            app.lib.track("ghost").is_none(),
            "a stale reply must not reach the new session"
        );
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

    // ---- sorting --------------------------------------------------------

    use crate::library::SortField;
    use std::collections::HashMap;

    fn sort_track(id: &str, artist: &str, album: &str, album_id: &str, year: i64) -> Track {
        Track {
            id: id.into(),
            title: format!("Track {id}"),
            artist: artist.into(),
            album_artist: artist.into(),
            album: album.into(),
            album_id: album_id.into(),
            year: Some(year),
            track_no: Some(1),
            duration: Some(180.0),
            ..Default::default()
        }
    }

    fn sorting_app(name: &str) -> (App, PathBuf) {
        let path = std::env::temp_dir()
            .join(format!("aria-tui-sort-{}-{name}", std::process::id()))
            .join("config.toml");
        let mut a = App::new(Config::default(), path.clone(), Player::disabled());
        a.handle(Msg::Library(Ok(vec![
            sort_track("a", "Zebra", "Later", "al1", 1999),
            sort_track("b", "Mango", "Middle", "al2", 1970),
            sort_track("c", "Apple", "Early", "al3", 1955),
        ])));
        (a, path)
    }

    fn album_titles(a: &App) -> Vec<String> {
        (0..a.lib.albums.len())
            .filter_map(|row| a.album_at(row))
            .map(|al| al.title.clone())
            .collect()
    }

    #[test]
    fn the_sort_key_cycles_the_current_view_only() {
        let (mut a, _) = sorting_app("cycle");
        a.view = View::Albums;
        assert_eq!(a.lib.sort(ListKind::Albums).field, SortField::Artist);

        a.cycle_sort();
        assert_eq!(a.lib.sort(ListKind::Albums).field, SortField::Title);
        assert_eq!(
            a.lib.sort(ListKind::Tracks).field,
            SortField::Artist,
            "the other lists keep their own order"
        );
        assert_eq!(album_titles(&a), vec!["Early", "Later", "Middle"]);
    }

    #[test]
    fn the_reverse_key_flips_the_direction_without_changing_the_field() {
        let (mut a, _) = sorting_app("reverse");
        a.view = View::Albums;
        a.reverse_sort();
        let s = a.lib.sort(ListKind::Albums);
        assert_eq!(s.field, SortField::Artist);
        assert!(s.desc);
        assert_eq!(album_titles(&a), vec!["Later", "Middle", "Early"]);
    }

    #[test]
    fn a_re_sort_keeps_the_cursor_on_the_row_it_was_on() {
        let (mut a, _) = sorting_app("cursor");
        a.view = View::Albums;
        a.albums_list.selected = 2; // by artist: Apple, Mango, Zebra -> "Later"
        assert_eq!(a.album_at(2).unwrap().title, "Later");

        a.reverse_sort();
        assert_eq!(
            a.album_at(a.albums_list.selected).unwrap().title,
            "Later",
            "the album under the cursor must not change identity"
        );
        assert_eq!(a.albums_list.selected, 0, "and it moved to the top");
    }

    #[test]
    fn the_selection_reads_the_sorted_row_not_the_library_row() {
        let (mut a, _) = sorting_app("selection");
        a.view = View::Albums;
        a.albums_list.selected = 0;
        assert_eq!(a.selection(), vec!["c".to_string()], "Apple sorts first");

        a.reverse_sort();
        assert_eq!(
            a.selection(),
            vec!["c".to_string()],
            "the cursor followed its album down the list"
        );

        a.albums_list.selected = 0;
        assert_eq!(
            a.selection(),
            vec!["a".to_string()],
            "and row 0 is now Zebra's album, not the library's first"
        );
    }

    #[test]
    fn a_chosen_sort_survives_a_library_reload() {
        let (mut a, _) = sorting_app("reload");
        a.view = View::Tracks;
        a.cycle_sort(); // artist -> title
        a.reverse_sort();

        a.handle(Msg::Library(Ok(vec![
            sort_track("a", "Zebra", "Later", "al1", 1999),
            sort_track("b", "Mango", "Middle", "al2", 1970),
        ])));

        let s = a.lib.sort(ListKind::Tracks);
        assert_eq!(s.field, SortField::Title);
        assert!(s.desc, "a rescan must not quietly reset the order");
        assert_eq!(a.track_at(0).unwrap().id, "b");
    }

    #[test]
    fn a_sort_is_written_to_the_config() {
        let (mut a, path) = sorting_app("persist");
        a.view = View::Tracks;
        a.cycle_sort(); // artist -> title

        let reloaded = Config::load(&path).unwrap();
        assert_eq!(reloaded.sort_tracks, "title");
        assert_eq!(
            reloaded.sorts().tracks.field,
            SortField::Title,
            "and it reads back as the same order next run"
        );
        std::fs::remove_dir_all(path.parent().unwrap()).ok();
    }

    #[test]
    fn play_counts_are_not_fetched_until_a_list_is_ranked_by_them() {
        let (mut a, _) = sorting_app("lazy");
        a.cfg.profile_id = "p1".into();
        a.view = View::Albums;

        // Every other order is answered from the library document alone.
        for _ in 0..4 {
            a.cycle_sort();
            assert!(!a.counts_in_flight, "{:?}", a.lib.sort(ListKind::Albums));
        }
        assert_eq!(a.lib.sort(ListKind::Albums).field, SortField::Tracks);

        a.cycle_sort(); // -> plays
        assert_eq!(a.lib.sort(ListKind::Albums).field, SortField::Plays);
        assert!(a.counts_in_flight, "asking for plays is what fetches them");
    }

    #[test]
    fn a_stored_plays_sort_fetches_the_counts_on_startup() {
        // The library and the profile list arrive in whichever order the
        // server answers, so either one landing last must set this off.
        for library_first in [true, false] {
            let path = std::env::temp_dir()
                .join(format!("aria-tui-sort-{}-boot", std::process::id()))
                .join("config.toml");
            let cfg = Config {
                sort_tracks: "-plays".into(),
                profile_id: "p1".into(),
                ..Default::default()
            };
            let mut a = App::new(cfg, path, Player::disabled());
            let tracks = vec![sort_track("a", "Zebra", "Later", "al1", 1999)];
            let profiles = vec![Profile {
                id: "p1".into(),
                name: "Listener".into(),
                ..Default::default()
            }];
            if library_first {
                a.handle(Msg::Library(Ok(tracks)));
                a.handle(Msg::Profiles(Ok(profiles)));
            } else {
                a.handle(Msg::Profiles(Ok(profiles)));
                a.handle(Msg::Library(Ok(tracks)));
            }
            assert!(a.counts_in_flight, "library_first = {library_first}");
        }
    }

    #[test]
    fn arriving_counts_rank_the_list_and_keep_the_cursor() {
        let (mut a, _) = sorting_app("counts");
        a.cfg.profile_id = "p1".into();
        a.view = View::Albums;
        let mut s = a.lib.sorts();
        s.set(ListKind::Albums, Sort::new(SortField::Plays));
        a.lib.set_sorts(s);
        a.albums_list.selected = 0; // by artist: Apple's "Early"
        assert_eq!(a.album_at(0).unwrap().title, "Early");

        a.handle(Msg::PlayCounts(Ok(HashMap::from([("a".into(), 12)]))));

        assert_eq!(
            a.album_at(0).unwrap().title,
            "Later",
            "the played album leads"
        );
        assert_eq!(
            a.album_at(a.albums_list.selected).unwrap().title,
            "Early",
            "and the cursor stayed on the album it was on"
        );
        assert!(!a.counts_in_flight);
        assert_eq!(a.play_counts.as_ref().unwrap()["a"], 12);
    }

    #[test]
    fn a_rescan_does_not_re_fetch_the_counts_it_already_has() {
        let (mut a, _) = sorting_app("rescan");
        a.cfg.profile_id = "p1".into();
        a.handle(Msg::PlayCounts(Ok(HashMap::from([("a".into(), 3)]))));

        a.handle(Msg::Library(Ok(vec![
            sort_track("a", "Zebra", "Later", "al1", 1999),
            sort_track("b", "Mango", "Middle", "al2", 1970),
        ])));

        assert!(!a.counts_in_flight, "the counts survive the reload");
        assert_eq!(
            a.lib.plays("a"),
            3,
            "and are re-folded onto the rebuilt library"
        );
    }

    #[test]
    fn a_profile_change_drops_the_previous_listeners_counts() {
        let (mut a, _) = sorting_app("profile");
        a.cfg.profile_id = "p1".into();
        a.handle(Msg::PlayCounts(Ok(HashMap::from([("a".into(), 99)]))));
        assert_eq!(a.lib.plays("a"), 99);

        a.set_profile(&Profile {
            id: "p2".into(),
            name: "Someone else".into(),
            ..Default::default()
        });

        assert!(a.play_counts.is_none(), "plays belong to a profile");
        assert_eq!(a.lib.plays("a"), 0);
        assert!(
            !a.counts_in_flight,
            "and nothing is fetched while no list is ranked by them"
        );
    }

    #[test]
    fn a_profile_change_refetches_while_a_list_is_ranked_by_plays() {
        let (mut a, _) = sorting_app("profile-plays");
        a.cfg.profile_id = "p1".into();
        let mut s = a.lib.sorts();
        s.set(ListKind::Tracks, Sort::new(SortField::Plays));
        a.lib.set_sorts(s);
        a.handle(Msg::PlayCounts(Ok(HashMap::from([("a".into(), 99)]))));

        a.set_profile(&Profile {
            id: "p2".into(),
            name: "Someone else".into(),
            ..Default::default()
        });
        assert!(a.counts_in_flight, "the new listener's counts are wanted");
    }

    #[test]
    fn sorting_by_plays_without_a_profile_says_so_instead_of_counting_to_zero() {
        let (mut a, _) = sorting_app("noprofile");
        a.cfg.profile_id.clear();
        a.view = View::Tracks;
        let mut s = a.lib.sorts();
        s.set(ListKind::Tracks, Sort::new(SortField::Length));
        a.lib.set_sorts(s);

        a.cycle_sort(); // length -> plays
        assert_eq!(a.lib.sort(ListKind::Tracks).field, SortField::Plays);
        assert!(!a.counts_in_flight);
        assert!(a.toast.unwrap().0.contains("no profile"));
    }

    #[test]
    fn a_recorded_play_refreshes_the_counts_it_just_changed() {
        let mut a = reporting_app();
        let mut s = a.lib.sorts();
        s.set(ListKind::Tracks, Sort::new(SortField::Plays));
        a.lib.set_sorts(s);
        a.handle(Msg::PlayCounts(Ok(HashMap::from([("t1".into(), 1)]))));
        assert!(!a.counts_in_flight);

        a.apply_playback_state(&playing(0, 31.0));
        assert_eq!(a.reports_sent, 1);
        assert!(
            a.counts_in_flight,
            "a most-played list must not stay one play behind"
        );
    }

    #[test]
    fn a_recorded_play_costs_nothing_when_nothing_is_ranked_by_plays() {
        let mut a = reporting_app();
        a.apply_playback_state(&playing(0, 31.0));
        assert_eq!(a.reports_sent, 1);
        assert!(
            !a.counts_in_flight,
            "the counts were never wanted, so they are never fetched"
        );
    }

    #[test]
    fn views_with_an_order_of_their_own_refuse_to_be_sorted() {
        let (mut a, _) = sorting_app("fixed");
        for view in [View::Queue, View::Search, View::Playlists, View::Stats] {
            a.view = view;
            assert_eq!(a.sortable(), None, "{}", view.title());
        }

        // Nor inside a drill-down, where the order belongs to the collection.
        a.view = View::Albums;
        a.detail = Detail::Album("al1".into());
        assert_eq!(a.sortable(), None);

        let before = a.lib.sorts();
        a.cycle_sort();
        assert_eq!(a.lib.sorts(), before, "and the keys change nothing");
        assert!(a.toast.is_some(), "but they do say why");
    }
}
