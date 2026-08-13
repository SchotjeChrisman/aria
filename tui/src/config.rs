//! Configuration: a small TOML file, overridable by CLI flags.
//!
//! The file is written back when the user changes something durable from
//! inside the app (server URL, profile, tier, volume), so a first run that is
//! configured interactively does not have to be configured again.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::api::Tier;
use crate::library::{ListKind, Sort, Sorts};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct Config {
    /// Base URL of the Aria server.
    pub server: String,
    /// Profile id used for plays, playlists and listen-later. Empty until the
    /// user picks one, which the app prompts for on first run.
    pub profile_id: String,
    /// Remembered for the header while the profile list loads.
    pub profile_name: String,
    /// "original", "high" or "low".
    pub tier: String,
    /// 0–130, matching mpv's scale where above 100 is soft amplification.
    pub volume: f64,
    /// Binary to spawn for playback. Left configurable because mpv is often
    /// installed under a path rather than on PATH.
    pub mpv_path: String,
    /// Ask the OS for exclusive access to the audio device, so a
    /// high-resolution stream is not resampled by a shared mixer.
    pub exclusive_audio: bool,
    /// Extra arguments appended to mpv's command line, for the things only the
    /// listener knows: `--audio-device=`, `--af=`, a DAC-specific option.
    /// Appended last, so they override the defaults set here.
    pub mpv_args: Vec<String>,
    /// Fraction of a track that must play before it is reported. Aria has no
    /// server-side rule, so the client applies the usual scrobble convention.
    pub scrobble_at: f64,
    /// Colour theme: "dark" or "light".
    pub theme: String,
    /// Row order for the Albums, Artists and Tracks views: a field name, with
    /// a leading `-` for descending — `year`, `-added`. Kept per list because
    /// one order that suited all three would suit none of them.
    pub sort_albums: String,
    pub sort_artists: String,
    pub sort_tracks: String,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            // The bundled container publishes on 3001; a bare `go run` serves
            // 3000. 3000 is the documented app default, so it is ours too.
            server: "http://localhost:3000".into(),
            profile_id: String::new(),
            profile_name: String::new(),
            tier: "original".into(),
            volume: 100.0,
            mpv_path: "mpv".into(),
            exclusive_audio: false,
            mpv_args: Vec::new(),
            scrobble_at: 0.5,
            theme: "dark".into(),
            sort_albums: "artist".into(),
            sort_artists: "artist".into(),
            sort_tracks: "artist".into(),
        }
    }
}

impl Config {
    pub fn tier(&self) -> Tier {
        Tier::parse(&self.tier).unwrap_or_default()
    }

    /// The stored row orders. An unreadable value falls back to the default
    /// rather than refusing to start — a sort is a preference, not data.
    pub fn sorts(&self) -> Sorts {
        let pick = |s: &str, kind| {
            Sort::parse(s)
                .map(|sort| sort.valid_for(kind))
                .unwrap_or_else(|| Sort::new(ListKind::fields(kind)[0]))
        };
        Sorts {
            albums: pick(&self.sort_albums, ListKind::Albums),
            artists: pick(&self.sort_artists, ListKind::Artists),
            tracks: pick(&self.sort_tracks, ListKind::Tracks),
        }
    }

    pub fn set_sorts(&mut self, s: Sorts) {
        self.sort_albums = s.albums.as_str();
        self.sort_artists = s.artists.as_str();
        self.sort_tracks = s.tracks.as_str();
    }

    /// Where the config lives: `$XDG_CONFIG_HOME/aria-tui/config.toml`.
    pub fn default_path() -> PathBuf {
        dirs::config_dir()
            .unwrap_or_else(|| PathBuf::from("."))
            .join("aria-tui")
            .join("config.toml")
    }

    /// Loads the config, falling back to defaults when the file is missing.
    ///
    /// A malformed file is reported rather than silently replaced — losing a
    /// hand-written server URL to a stray typo would be worse than an error.
    pub fn load(path: &Path) -> std::result::Result<Config, String> {
        match std::fs::read_to_string(path) {
            Ok(text) => toml::from_str(&text).map_err(|e| format!("{}: {e}", path.display())),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Config::default()),
            Err(e) => Err(format!("{}: {e}", path.display())),
        }
    }

    pub fn save(&self, path: &Path) -> std::result::Result<(), String> {
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
        }
        let text = toml::to_string_pretty(self).map_err(|e| e.to_string())?;
        std::fs::write(path, text).map_err(|e| format!("{}: {e}", path.display()))
    }

    pub fn normalize(&mut self) {
        self.server = crate::api::normalize_base(&self.server);
        self.volume = self.volume.clamp(0.0, 130.0);
        self.scrobble_at = self.scrobble_at.clamp(0.05, 1.0);
        if Tier::parse(&self.tier).is_none() {
            self.tier = "original".into();
        }
        if self.mpv_path.trim().is_empty() {
            self.mpv_path = "mpv".into();
        }
        // Rewrites an unparseable or misplaced sort to the one actually in
        // use, so the file never claims an order the app is not showing.
        let sorts = self.sorts();
        self.set_sorts(sorts);
    }
}

/// Parsed command line. Flags win over the config file for this run only,
/// unless [`Args::save`] is set or the config file does not exist yet.
#[derive(Debug, Default)]
pub struct Args {
    pub server: Option<String>,
    pub config_path: Option<PathBuf>,
    pub profile: Option<String>,
    pub tier: Option<String>,
    pub no_player: bool,
    pub save: bool,
    pub help: bool,
    pub version: bool,
}

pub const USAGE: &str = "\
aria-tui — terminal client for the Aria music server

USAGE:
    aria-tui [OPTIONS]

OPTIONS:
    -s, --server <URL>     Server base URL (default: from config, else http://localhost:3000)
    -c, --config <PATH>    Config file to use
    -p, --profile <NAME>   Profile to use, by name
    -t, --tier <TIER>      Stream tier: original | high | low
        --save             Store --server and --tier as the new defaults
        --no-player        Browse only; do not start mpv
    -h, --help             Show this help
    -V, --version          Show the version

The server is remembered. On a first run it is written to the config file, so
`aria-tui -s http://box:3001` once is enough and plain `aria-tui` connects
there afterwards. Later, change it with `o` inside the app or with --save.

ENVIRONMENT:
    ARIA_SERVER            Server base URL, when no --server is given
";

/// Hand-rolled because the whole surface is seven flags, and a dependency for
/// that would outweigh it.
pub fn parse_args<I: IntoIterator<Item = String>>(argv: I) -> std::result::Result<Args, String> {
    let mut args = Args::default();
    let mut it = argv.into_iter().peekable();
    while let Some(a) = it.next() {
        let mut take = |flag: &str| -> std::result::Result<String, String> {
            it.next().ok_or_else(|| format!("{flag} needs a value"))
        };
        match a.as_str() {
            "-h" | "--help" => args.help = true,
            "-V" | "--version" => args.version = true,
            "--no-player" => args.no_player = true,
            "--save" => args.save = true,
            "-s" | "--server" => args.server = Some(take("--server")?),
            "-c" | "--config" => args.config_path = Some(PathBuf::from(take("--config")?)),
            "-p" | "--profile" => args.profile = Some(take("--profile")?),
            "-t" | "--tier" => {
                let v = take("--tier")?;
                if Tier::parse(&v).is_none() {
                    return Err(format!(
                        "invalid tier {v:?}: expected original, high or low"
                    ));
                }
                args.tier = Some(v);
            }
            other if other.starts_with('-') => return Err(format!("unknown flag {other}")),
            other => return Err(format!("unexpected argument {other:?}")),
        }
    }
    Ok(args)
}

/// Folds `$ARIA_SERVER` in as a lower-priority `--server`.
///
/// One export in a shell profile, a container `-e`, or an ssh `SendEnv` then
/// declares the server for every invocation. An explicit flag still wins, and
/// a blank value is treated as unset so `ARIA_SERVER= aria-tui` falls back to
/// the config file rather than to an empty URL.
///
/// Takes the lookup as an argument because the process environment is global
/// state, and a test that set it would race every other test in the binary.
pub fn apply_env<F>(args: &mut Args, get: F)
where
    F: Fn(&str) -> Option<String>,
{
    if args.server.is_none() {
        if let Some(v) = get("ARIA_SERVER") {
            if !v.trim().is_empty() {
                args.server = Some(v);
            }
        }
    }
}

/// What this run uses, and what the config file should end up holding.
#[derive(Debug)]
pub struct Resolved {
    /// The config for this run: the file with the flags folded in.
    pub effective: Config,
    /// The config the file should hold. Fields the app changes from the inside
    /// are written on top of this one.
    pub stored: Config,
    /// Whether `stored` still has to be written out.
    pub write_now: bool,
}

/// Decides whether this run's flags are a one-off or the new default.
///
/// A flag is normally for this run only — a one-off `-s` must not silently
/// replace a hand-written server URL. Two cases invert that:
///
///   * there is no config file yet, so there is nothing to protect and the
///     flags are simply how the user is configuring the client for the first
///     time; and
///   * `--save`, which asks for exactly this on a later run.
///
/// Either way the file is written immediately rather than at quit, so a first
/// run that is killed instead of quit still leaves its server behind.
pub fn resolve(on_disk: Config, args: &Args, config_exists: bool) -> Resolved {
    let mut effective = on_disk.clone();
    effective.apply(args);
    if config_exists && !args.save {
        Resolved {
            effective,
            stored: on_disk,
            write_now: false,
        }
    } else {
        Resolved {
            stored: effective.clone(),
            effective,
            write_now: true,
        }
    }
}

impl Config {
    /// Folds CLI overrides in. Only the flags the user actually passed.
    pub fn apply(&mut self, args: &Args) {
        if let Some(s) = &args.server {
            self.server = s.clone();
        }
        if let Some(t) = &args.tier {
            self.tier = t.clone();
        }
        self.normalize();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn argv(items: &[&str]) -> Vec<String> {
        items.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn missing_config_file_yields_defaults_not_an_error() {
        let c = Config::load(Path::new("/nonexistent/aria-tui/config.toml")).unwrap();
        assert_eq!(c.server, "http://localhost:3000");
        assert_eq!(c.tier(), Tier::Original);
    }

    #[test]
    fn malformed_config_is_reported_rather_than_overwritten() {
        let dir = std::env::temp_dir().join(format!("aria-tui-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let p = dir.join("bad.toml");
        std::fs::write(&p, "server = \"unterminated").unwrap();
        assert!(
            Config::load(&p).is_err(),
            "a typo must not silently reset the config"
        );
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn config_round_trips_through_disk() {
        let dir = std::env::temp_dir().join(format!("aria-tui-rt-{}", std::process::id()));
        let p = dir.join("config.toml");
        let c = Config {
            server: "http://box:3001".into(),
            profile_id: "p-1".into(),
            volume: 72.0,
            tier: "high".into(),
            ..Default::default()
        };
        c.save(&p).unwrap();

        let back = Config::load(&p).unwrap();
        assert_eq!(back.server, "http://box:3001");
        assert_eq!(back.profile_id, "p-1");
        assert_eq!(back.volume, 72.0);
        assert_eq!(back.tier(), Tier::High);
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn partial_config_keeps_defaults_for_absent_keys() {
        let dir = std::env::temp_dir().join(format!("aria-tui-part-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let p = dir.join("config.toml");
        std::fs::write(&p, "server = \"http://box:3001\"\n").unwrap();
        let c = Config::load(&p).unwrap();
        assert_eq!(c.server, "http://box:3001");
        assert_eq!(c.volume, 100.0, "absent keys must fall back, not zero out");
        assert_eq!(c.mpv_path, "mpv");
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn normalize_fixes_what_a_user_can_get_wrong() {
        let mut c = Config {
            server: "box:3001/".into(),
            volume: 999.0,
            tier: "lossless".into(),
            mpv_path: "  ".into(),
            scrobble_at: 0.0,
            ..Default::default()
        };
        c.normalize();
        assert_eq!(c.server, "http://box:3001");
        assert_eq!(c.volume, 130.0);
        assert_eq!(
            c.tier, "original",
            "an unknown tier falls back rather than 501-ing"
        );
        assert_eq!(c.mpv_path, "mpv");
        assert_eq!(c.scrobble_at, 0.05);
    }

    #[test]
    fn flags_parse() {
        let a = parse_args(argv(&["--server", "box:3000", "-t", "high", "--no-player"])).unwrap();
        assert_eq!(a.server.as_deref(), Some("box:3000"));
        assert_eq!(a.tier.as_deref(), Some("high"));
        assert!(a.no_player);
    }

    #[test]
    fn an_invalid_tier_is_rejected_at_the_command_line() {
        let err = parse_args(argv(&["--tier", "lossless"])).unwrap_err();
        assert!(err.contains("invalid tier"), "got {err}");
    }

    #[test]
    fn a_flag_without_its_value_is_an_error() {
        assert!(parse_args(argv(&["--server"])).is_err());
    }

    #[test]
    fn unknown_flags_are_rejected() {
        assert!(parse_args(argv(&["--wat"])).is_err());
    }

    #[test]
    fn a_first_run_stores_the_server_it_was_given() {
        // The whole point: `-s` once, then a bare `aria-tui` for ever after.
        let args = parse_args(argv(&["-s", "http://box:3001", "-t", "high"])).unwrap();
        let r = resolve(Config::default(), &args, false);
        assert!(r.write_now, "a first run must write the file");
        assert_eq!(r.stored.server, "http://box:3001");
        assert_eq!(r.stored.tier, "high");
        assert_eq!(r.effective.server, r.stored.server);
    }

    #[test]
    fn a_later_run_keeps_its_flags_out_of_the_file() {
        let on_disk = Config {
            server: "http://nas.local:3000".into(),
            ..Default::default()
        };
        let args = parse_args(argv(&["-s", "http://laptop:3000"])).unwrap();
        let r = resolve(on_disk, &args, true);
        assert!(!r.write_now);
        assert_eq!(r.effective.server, "http://laptop:3000", "for this run");
        assert_eq!(r.stored.server, "http://nas.local:3000", "but not stored");
    }

    #[test]
    fn save_promotes_this_runs_flags_to_the_defaults() {
        let on_disk = Config {
            server: "http://nas.local:3000".into(),
            ..Default::default()
        };
        let args = parse_args(argv(&["-s", "http://laptop:3000", "--save"])).unwrap();
        let r = resolve(on_disk, &args, true);
        assert!(r.write_now);
        assert_eq!(r.stored.server, "http://laptop:3000");
    }

    #[test]
    fn save_without_flags_does_not_wipe_the_stored_config() {
        // `--save` on its own means "keep what I have", not "reset me".
        let on_disk = Config {
            server: "http://nas.local:3000".into(),
            profile_id: "p-1".into(),
            volume: 63.0,
            ..Default::default()
        };
        let args = parse_args(argv(&["--save"])).unwrap();
        let r = resolve(on_disk, &args, true);
        assert_eq!(r.stored.server, "http://nas.local:3000");
        assert_eq!(r.stored.profile_id, "p-1");
        assert_eq!(r.stored.volume, 63.0);
    }

    #[test]
    fn the_env_var_stands_in_for_a_missing_server_flag() {
        let mut args = parse_args(argv(&[])).unwrap();
        apply_env(&mut args, |k| {
            (k == "ARIA_SERVER").then(|| "http://box:3001".to_string())
        });
        assert_eq!(args.server.as_deref(), Some("http://box:3001"));
    }

    #[test]
    fn an_explicit_server_flag_beats_the_env_var() {
        let mut args = parse_args(argv(&["-s", "http://flag:3000"])).unwrap();
        apply_env(&mut args, |_| Some("http://env:3000".to_string()));
        assert_eq!(args.server.as_deref(), Some("http://flag:3000"));
    }

    #[test]
    fn a_blank_env_var_is_treated_as_unset() {
        // `ARIA_SERVER= aria-tui` must fall back to the file, not to "".
        let mut args = parse_args(argv(&[])).unwrap();
        apply_env(&mut args, |_| Some("  ".to_string()));
        assert!(args.server.is_none());
    }

    #[test]
    fn cli_overrides_beat_the_config_file() {
        let mut c = Config {
            server: "http://from-file:3000".into(),
            ..Default::default()
        };
        let a = parse_args(argv(&["-s", "cli-host:9999", "-t", "low"])).unwrap();
        c.apply(&a);
        assert_eq!(c.server, "http://cli-host:9999");
        assert_eq!(c.tier(), Tier::Low);
    }

    #[test]
    fn a_fresh_config_sorts_every_list_by_artist() {
        let s = Config::default().sorts();
        assert_eq!(s.albums, Sort::default());
        assert_eq!(s.artists, Sort::default());
        assert_eq!(s.tracks, Sort::default());
    }

    #[test]
    fn a_stored_sort_comes_back_as_it_was_left() {
        let mut c = Config::default();
        c.set_sorts(Sorts {
            albums: Sort::new(crate::library::SortField::Added),
            ..Default::default()
        });
        assert_eq!(c.sort_albums, "-added", "descending is the leading dash");

        let text = toml::to_string_pretty(&c).unwrap();
        let back: Config = toml::from_str(&text).unwrap();
        assert_eq!(
            back.sorts().albums,
            Sort::new(crate::library::SortField::Added)
        );
    }

    #[test]
    fn a_config_predating_sorting_still_loads() {
        // Every field is `#[serde(default)]`, so a file written by 0.2.0 has
        // no sort keys at all and must not fail to parse.
        let c: Config = toml::from_str("server = \"http://box:3001\"").unwrap();
        assert_eq!(c.server, "http://box:3001");
        assert_eq!(c.sorts().tracks, Sort::default());
    }

    #[test]
    fn every_list_offers_most_played() {
        use crate::library::{ListKind, SortField};
        for kind in [ListKind::Albums, ListKind::Artists, ListKind::Tracks] {
            assert!(
                kind.fields().contains(&SortField::Plays),
                "{kind:?} must offer it, as the Flutter app does"
            );
        }
        let mut c = Config {
            sort_tracks: "-plays".into(),
            ..Default::default()
        };
        c.normalize();
        assert_eq!(c.sorts().tracks.field, SortField::Plays);
        assert!(c.sorts().tracks.desc);
        assert_eq!(c.sort_tracks, "-plays", "and it survives normalising");
    }

    #[test]
    fn a_nonsense_sort_is_rewritten_rather_than_obeyed() {
        let mut c = Config {
            sort_albums: "sideways".into(),
            // A real field, but one the Artists list does not offer.
            sort_artists: "-length".into(),
            ..Default::default()
        };
        c.normalize();
        assert_eq!(c.sort_albums, "artist");
        assert_eq!(
            c.sort_artists, "artist",
            "the file must not claim an order the list is not in"
        );
    }
}
