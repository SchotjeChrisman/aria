//! Playback: an mpv child process driven over its JSON IPC socket.
//!
//! mpv owns the playlist. The app mirrors its queue into mpv once and then
//! moves around with `playlist-play-index`, which is what makes skipping
//! instant and transitions gapless — mpv pre-loads the next entry itself.
//!
//! When mpv is not installed the whole module degrades to [`Player::disabled`]:
//! every command is a no-op and the UI stays browsable.

pub mod ipc;

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::process::{Child, Command as ProcCommand, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use serde_json::{json, Value};

use ipc::{prop, Command, Incoming};

/// Everything the reader thread learns from mpv. Polled by the UI each tick.
#[derive(Debug, Clone, Default)]
pub struct PlayerState {
    pub time_pos: f64,
    pub duration: f64,
    pub paused: bool,
    /// Index into the queue mpv is playing, or `None` while idle.
    pub playlist_pos: Option<usize>,
    pub volume: f64,
    pub idle: bool,
    /// Bumped on every natural end-of-file. The app compares it against the
    /// value it last saw to detect "a track finished on its own".
    pub eof_count: u64,
    /// Bumped whenever mpv starts a new file, natural or not.
    pub start_count: u64,
    pub last_error: Option<String>,
}

#[derive(Debug)]
pub enum PlayerError {
    /// mpv is not on PATH. The caller should fall back to [`Player::disabled`].
    NotFound(String),
    Spawn(String),
    /// mpv started but never created its IPC socket.
    SocketTimeout(String),
}

impl std::fmt::Display for PlayerError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PlayerError::NotFound(s) => write!(f, "mpv not found: {s}"),
            PlayerError::Spawn(s) => write!(f, "could not start mpv: {s}"),
            PlayerError::SocketTimeout(s) => write!(f, "mpv IPC socket never appeared: {s}"),
        }
    }
}

pub struct Player {
    child: Option<Child>,
    sock_path: Option<PathBuf>,
    write_half: Option<Mutex<UnixStream>>,
    state: Arc<Mutex<PlayerState>>,
    next_id: AtomicU64,
    /// Queue length last pushed to mpv, so `next`/`prev` can clamp.
    queue_len: Mutex<usize>,
    enabled: bool,
}

impl Player {
    /// A player with no mpv behind it. Commands are accepted and dropped.
    pub fn disabled() -> Self {
        Self::disabled_at_volume(100.0)
    }

    /// A disabled player that still reports a volume, so the transport shows
    /// the configured level rather than a misleading 0%.
    pub fn disabled_at_volume(volume: f64) -> Self {
        Self {
            child: None,
            sock_path: None,
            write_half: None,
            state: Arc::new(Mutex::new(PlayerState {
                volume,
                idle: true,
                ..Default::default()
            })),
            next_id: AtomicU64::new(1),
            queue_len: Mutex::new(0),
            enabled: false,
        }
    }

    pub fn is_enabled(&self) -> bool {
        self.enabled
    }

    /// Spawns mpv and connects to its IPC socket.
    ///
    /// `exclusive` asks the OS for exclusive access to the audio device, which
    /// is what keeps a high-resolution stream from being resampled by a shared
    /// mixer. It fails softly inside mpv when the device will not grant it.
    pub fn start(
        mpv_bin: &str,
        exclusive: bool,
        initial_volume: f64,
        extra_args: &[String],
    ) -> Result<Self, PlayerError> {
        let sock_path = socket_path();
        // A stale socket from a crashed run would make mpv refuse to bind.
        let _ = std::fs::remove_file(&sock_path);

        let mut cmd = ProcCommand::new(mpv_bin);
        cmd.arg("--idle=yes")
            .arg("--no-video")
            .arg("--no-terminal")
            .arg("--no-config")
            .arg("--audio-display=no")
            // "yes" is the strict form: mpv keeps the audio device open across
            // playlist entries instead of tearing it down between tracks.
            .arg("--gapless-audio=yes")
            .arg("--keep-open=no")
            // The server answers Range requests, so a modest cache is enough to
            // ride out network jitter without delaying seeks.
            .arg("--cache=yes")
            .arg("--demuxer-max-bytes=32MiB")
            .arg(format!("--volume={}", initial_volume.clamp(0.0, 130.0)))
            .arg(format!("--input-ipc-server={}", sock_path.display()))
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        if exclusive {
            cmd.arg("--audio-exclusive=yes");
        }
        // Last, so a user's own flag wins over the defaults above.
        cmd.args(extra_args);

        let child = cmd.spawn().map_err(|e| {
            if e.kind() == std::io::ErrorKind::NotFound {
                PlayerError::NotFound(mpv_bin.to_string())
            } else {
                PlayerError::Spawn(e.to_string())
            }
        })?;

        // From here on mpv is running, so every failure has to take it down
        // with it — returning Err while leaving the child alive would leak a
        // silent mpv holding the audio device for the rest of the session.
        let mut child = child;
        let stream = match connect_with_retry(&sock_path, Duration::from_secs(5)) {
            Ok(s) => s,
            Err(e) => {
                let _ = child.kill();
                let _ = child.wait();
                let _ = std::fs::remove_file(&sock_path);
                return Err(PlayerError::SocketTimeout(format!(
                    "{}: {e}",
                    sock_path.display()
                )));
            }
        };
        let read_half = match stream.try_clone() {
            Ok(h) => h,
            Err(e) => {
                let _ = child.kill();
                let _ = child.wait();
                let _ = std::fs::remove_file(&sock_path);
                return Err(PlayerError::Spawn(e.to_string()));
            }
        };

        let state = Arc::new(Mutex::new(PlayerState {
            volume: initial_volume,
            idle: true,
            ..Default::default()
        }));
        spawn_reader(read_half, Arc::clone(&state));

        let player = Self {
            child: Some(child),
            sock_path: Some(sock_path),
            write_half: Some(Mutex::new(stream)),
            state,
            next_id: AtomicU64::new(1),
            queue_len: Mutex::new(0),
            enabled: true,
        };
        player.observe_all();
        Ok(player)
    }

    fn observe_all(&self) {
        for (id, name) in [
            (prop::TIME_POS, "time-pos"),
            (prop::DURATION, "duration"),
            (prop::PAUSE, "pause"),
            (prop::PLAYLIST_POS, "playlist-pos"),
            (prop::VOLUME, "volume"),
            (prop::IDLE_ACTIVE, "idle-active"),
            (prop::CORE_IDLE, "core-idle"),
            (prop::EOF_REACHED, "eof-reached"),
        ] {
            self.send(ipc::observe_property(id, name));
        }
    }

    /// Snapshot of what mpv last reported.
    pub fn state(&self) -> PlayerState {
        self.state.lock().map(|s| s.clone()).unwrap_or_default()
    }

    fn send(&self, args: Vec<Value>) {
        let Some(sock) = &self.write_half else { return };
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let line = Command::new(args, id).to_line();
        if let Ok(mut s) = sock.lock() {
            // A dead mpv shows up as a write error; record it rather than
            // panicking, so the UI can say so and keep running.
            if let Err(e) = s.write_all(line.as_bytes()).and_then(|_| s.flush()) {
                if let Ok(mut st) = self.state.lock() {
                    st.last_error = Some(format!("mpv write failed: {e}"));
                }
            }
        }
    }

    /// Replaces mpv's playlist with `urls` and starts playing at `start`.
    ///
    /// mpv is paused across the rebuild so the first entry does not audibly
    /// start before we jump to the requested index.
    pub fn set_queue(&self, urls: &[String], start: usize) {
        if urls.is_empty() {
            self.stop();
            return;
        }
        if let Ok(mut n) = self.queue_len.lock() {
            *n = urls.len();
        }
        self.send(ipc::set_property("pause", json!(true)));
        self.send(ipc::loadfile(&urls[0], "replace"));
        for url in &urls[1..] {
            self.send(ipc::loadfile(url, "append"));
        }
        if start > 0 {
            self.send(ipc::playlist_play_index(start.min(urls.len() - 1)));
        }
        self.send(ipc::set_property("pause", json!(false)));
    }

    /// Jumps within the already-loaded playlist.
    pub fn play_index(&self, index: usize) {
        self.send(ipc::playlist_play_index(index));
        self.send(ipc::set_property("pause", json!(false)));
    }

    pub fn toggle_pause(&self) {
        let paused = self.state().paused;
        self.send(ipc::set_property("pause", json!(!paused)));
    }

    pub fn set_paused(&self, paused: bool) {
        self.send(ipc::set_property("pause", json!(paused)));
    }

    pub fn seek_absolute(&self, seconds: f64) {
        self.send(ipc::seek_absolute(seconds.max(0.0)));
    }

    pub fn seek_relative(&self, seconds: f64) {
        self.send(ipc::seek_relative(seconds));
    }

    pub fn set_volume(&self, volume: f64) {
        let v = volume.clamp(0.0, 130.0);
        self.send(ipc::set_property("volume", json!(v)));
        // Reflect it immediately: the observed property will confirm, but the
        // UI should not lag a tick behind the keypress.
        if let Ok(mut s) = self.state.lock() {
            s.volume = v;
        }
    }

    /// `loop-file` repeats the current track for ever; `loop-playlist` wraps
    /// the queue. They are independent in mpv, so the caller sets both.
    pub fn set_loop_file(&self, on: bool) {
        self.send(ipc::set_property(
            "loop-file",
            if on { json!("inf") } else { json!("no") },
        ));
    }

    pub fn set_loop_playlist(&self, on: bool) {
        self.send(ipc::set_property(
            "loop-playlist",
            if on { json!("inf") } else { json!("no") },
        ));
    }

    pub fn stop(&self) {
        self.send(ipc::stop());
        self.send(ipc::playlist_clear());
        if let Ok(mut n) = self.queue_len.lock() {
            *n = 0;
        }
        if let Ok(mut s) = self.state.lock() {
            s.playlist_pos = None;
            s.time_pos = 0.0;
            s.duration = 0.0;
            s.idle = true;
        }
    }

    /// Shuts mpv down. Called on quit; also runs from `Drop`.
    pub fn quit(&mut self) {
        if self.write_half.is_some() {
            self.send(vec![json!("quit")]);
        }
        self.write_half = None;
        if let Some(mut child) = self.child.take() {
            // mpv exits promptly on `quit`; only escalate if it does not.
            let deadline = Instant::now() + Duration::from_millis(700);
            loop {
                match child.try_wait() {
                    Ok(Some(_)) => break,
                    Ok(None) if Instant::now() < deadline => {
                        thread::sleep(Duration::from_millis(20));
                    }
                    _ => {
                        let _ = child.kill();
                        let _ = child.wait();
                        break;
                    }
                }
            }
        }
        if let Some(p) = self.sock_path.take() {
            let _ = std::fs::remove_file(p);
        }
    }
}

impl Drop for Player {
    fn drop(&mut self) {
        self.quit();
    }
}

/// Reads mpv's event stream until the socket closes, folding each line into
/// the shared state.
fn spawn_reader(stream: UnixStream, state: Arc<Mutex<PlayerState>>) {
    thread::spawn(move || {
        let reader = BufReader::new(stream);
        for line in reader.lines() {
            let Ok(line) = line else { break };
            let Some(msg) = ipc::parse_line(&line) else {
                continue;
            };
            let Ok(mut s) = state.lock() else { break };
            apply(&mut s, msg);
        }
    });
}

/// Folds one decoded message into the state. Split out so it can be tested
/// without a socket.
pub fn apply(s: &mut PlayerState, msg: Incoming) {
    match msg {
        Incoming::PropertyChange { id, value, .. } => match id {
            prop::TIME_POS => s.time_pos = value.and_then(|v| v.as_f64()).unwrap_or(0.0),
            prop::DURATION => s.duration = value.and_then(|v| v.as_f64()).unwrap_or(0.0),
            prop::PAUSE => s.paused = value.and_then(|v| v.as_bool()).unwrap_or(false),
            prop::PLAYLIST_POS => {
                // mpv reports -1 for "no entry selected", which is not a
                // usable index.
                s.playlist_pos = value
                    .and_then(|v| v.as_i64())
                    .filter(|&n| n >= 0)
                    .map(|n| n as usize);
            }
            prop::VOLUME => {
                if let Some(v) = value.and_then(|v| v.as_f64()) {
                    s.volume = v;
                }
            }
            prop::IDLE_ACTIVE => s.idle = value.and_then(|v| v.as_bool()).unwrap_or(false),
            _ => {}
        },
        Incoming::EndFile { reason } => {
            // Only a natural end means "the track finished". A skip or a stop
            // must not be counted, or the app would advance twice.
            if reason == "eof" {
                s.eof_count = s.eof_count.wrapping_add(1);
            }
        }
        Incoming::StartFile => {
            s.start_count = s.start_count.wrapping_add(1);
            s.idle = false;
        }
        Incoming::IdleEvent => {
            s.idle = true;
            s.playlist_pos = None;
            s.time_pos = 0.0;
        }
        Incoming::Reply { error, .. } => {
            if error != "success" {
                s.last_error = Some(format!("mpv: {error}"));
            }
        }
        Incoming::FileLoaded | Incoming::Other(_) => {}
    }
}

/// Per-process socket path, preferring the user's runtime dir so it lands on
/// tmpfs and is cleaned up by the session.
fn socket_path() -> PathBuf {
    let base = std::env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(std::env::temp_dir);
    base.join(format!("aria-tui-mpv-{}.sock", std::process::id()))
}

fn connect_with_retry(path: &PathBuf, timeout: Duration) -> std::io::Result<UnixStream> {
    let deadline = Instant::now() + timeout;
    let mut last = None;
    while Instant::now() < deadline {
        match UnixStream::connect(path) {
            Ok(s) => return Ok(s),
            Err(e) => {
                last = Some(e);
                thread::sleep(Duration::from_millis(25));
            }
        }
    }
    Err(last.unwrap_or_else(|| std::io::Error::other("timed out")))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn st() -> PlayerState {
        PlayerState::default()
    }

    #[test]
    fn disabled_player_accepts_commands_without_mpv() {
        let p = Player::disabled();
        assert!(!p.is_enabled());
        p.set_queue(&["http://h/1".into(), "http://h/2".into()], 1);
        p.toggle_pause();
        p.seek_relative(10.0);
        p.set_volume(50.0);
        // Volume is mirrored locally even with no mpv attached.
        assert_eq!(p.state().volume, 50.0);
    }

    #[test]
    fn time_and_duration_fold_into_state() {
        let mut s = st();
        apply(
            &mut s,
            Incoming::PropertyChange {
                id: prop::TIME_POS,
                name: "time-pos".into(),
                value: Some(json!(41.25)),
            },
        );
        apply(
            &mut s,
            Incoming::PropertyChange {
                id: prop::DURATION,
                name: "duration".into(),
                value: Some(json!(300.0)),
            },
        );
        assert_eq!(s.time_pos, 41.25);
        assert_eq!(s.duration, 300.0);
    }

    #[test]
    fn unavailable_time_pos_resets_rather_than_sticking() {
        let mut s = st();
        s.time_pos = 99.0;
        apply(
            &mut s,
            Incoming::PropertyChange {
                id: prop::TIME_POS,
                name: "time-pos".into(),
                value: None,
            },
        );
        assert_eq!(s.time_pos, 0.0);
    }

    #[test]
    fn negative_playlist_pos_is_not_an_index() {
        let mut s = st();
        apply(
            &mut s,
            Incoming::PropertyChange {
                id: prop::PLAYLIST_POS,
                name: "playlist-pos".into(),
                value: Some(json!(-1)),
            },
        );
        assert_eq!(s.playlist_pos, None);

        apply(
            &mut s,
            Incoming::PropertyChange {
                id: prop::PLAYLIST_POS,
                name: "playlist-pos".into(),
                value: Some(json!(3)),
            },
        );
        assert_eq!(s.playlist_pos, Some(3));
    }

    #[test]
    fn only_natural_eof_counts_as_a_finished_track() {
        let mut s = st();
        apply(
            &mut s,
            Incoming::EndFile {
                reason: "stop".into(),
            },
        );
        apply(
            &mut s,
            Incoming::EndFile {
                reason: "quit".into(),
            },
        );
        assert_eq!(s.eof_count, 0, "a skip or stop must not read as finished");

        apply(
            &mut s,
            Incoming::EndFile {
                reason: "eof".into(),
            },
        );
        assert_eq!(s.eof_count, 1);
    }

    #[test]
    fn idle_event_clears_position() {
        let mut s = st();
        s.playlist_pos = Some(2);
        s.time_pos = 30.0;
        apply(&mut s, Incoming::IdleEvent);
        assert!(s.idle);
        assert_eq!(s.playlist_pos, None);
        assert_eq!(s.time_pos, 0.0);
    }

    #[test]
    fn failed_command_reply_is_surfaced() {
        let mut s = st();
        apply(
            &mut s,
            Incoming::Reply {
                request_id: 3,
                error: "property not found".into(),
                data: None,
            },
        );
        assert_eq!(s.last_error.as_deref(), Some("mpv: property not found"));
    }

    #[test]
    fn successful_reply_leaves_no_error() {
        let mut s = st();
        apply(
            &mut s,
            Incoming::Reply {
                request_id: 1,
                error: "success".into(),
                data: None,
            },
        );
        assert_eq!(s.last_error, None);
    }
}
