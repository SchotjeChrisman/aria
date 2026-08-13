//! Configuration: a small TOML file, overridable by CLI flags.
//!
//! The file is written back when the user changes something durable from
//! inside the app (server URL, profile, tier, volume), so a first run that is
//! configured interactively does not have to be configured again.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::api::Tier;

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
        }
    }
}

impl Config {
    pub fn tier(&self) -> Tier {
        Tier::parse(&self.tier).unwrap_or_default()
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
    }
}

/// Parsed command line. Flags win over the config file for this run only.
#[derive(Debug, Default)]
pub struct Args {
    pub server: Option<String>,
    pub config_path: Option<PathBuf>,
    pub profile: Option<String>,
    pub tier: Option<String>,
    pub no_player: bool,
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
        --no-player        Browse only; do not start mpv
    -h, --help             Show this help
    -V, --version          Show the version
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
}
