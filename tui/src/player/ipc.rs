//! The mpv JSON IPC wire protocol, kept free of any socket or process code so
//! it can be exercised without mpv installed.
//!
//! mpv speaks newline-delimited JSON both ways. Commands carry a `request_id`
//! that comes back on the matching reply; everything else arriving on the
//! socket is an asynchronous event.

use serde::Deserialize;
use serde_json::{json, Value};

/// A command to mpv, already shaped as the `{"command": [...]}` envelope.
#[derive(Debug, Clone, PartialEq)]
pub struct Command {
    pub args: Vec<Value>,
    pub request_id: u64,
}

impl Command {
    pub fn new(args: Vec<Value>, request_id: u64) -> Self {
        Self { args, request_id }
    }

    /// Serialises to the exact newline-terminated line mpv expects.
    pub fn to_line(&self) -> String {
        let mut s = serde_json::to_string(&json!({
            "command": self.args,
            "request_id": self.request_id,
        }))
        .expect("command args are always serialisable");
        s.push('\n');
        s
    }
}

/// Property ids used with `observe_property`. mpv echoes the id back on every
/// change, which is cheaper to match on than the property name.
pub mod prop {
    pub const TIME_POS: u64 = 1;
    pub const DURATION: u64 = 2;
    pub const PAUSE: u64 = 3;
    pub const PLAYLIST_POS: u64 = 4;
    pub const VOLUME: u64 = 5;
    pub const IDLE_ACTIVE: u64 = 6;
    pub const CORE_IDLE: u64 = 7;
    pub const EOF_REACHED: u64 = 8;
}

/// Builds the `loadfile` command. `mode` is mpv's third argument: "replace"
/// starts a fresh playlist, "append" adds without disturbing playback.
pub fn loadfile(url: &str, mode: &str) -> Vec<Value> {
    vec![json!("loadfile"), json!(url), json!(mode)]
}

pub fn set_property(name: &str, value: Value) -> Vec<Value> {
    vec![json!("set_property"), json!(name), value]
}

pub fn observe_property(id: u64, name: &str) -> Vec<Value> {
    vec![json!("observe_property"), json!(id), json!(name)]
}

/// Absolute seek in seconds. mpv clamps past the end itself.
pub fn seek_absolute(seconds: f64) -> Vec<Value> {
    vec![json!("seek"), json!(seconds), json!("absolute")]
}

pub fn seek_relative(seconds: f64) -> Vec<Value> {
    vec![json!("seek"), json!(seconds), json!("relative")]
}

/// `playlist-play-index` jumps within the loaded playlist without reloading it,
/// which is what keeps next/prev instant on a long queue.
pub fn playlist_play_index(index: usize) -> Vec<Value> {
    vec![json!("playlist-play-index"), json!(index as i64)]
}

pub fn playlist_clear() -> Vec<Value> {
    vec![json!("playlist-clear")]
}

pub fn stop() -> Vec<Value> {
    vec![json!("stop")]
}

/// Anything mpv sends us, once classified.
#[derive(Debug, Clone, PartialEq)]
pub enum Incoming {
    /// A property we asked to observe changed. `value` is `None` when mpv
    /// reports the property as unavailable (e.g. `time-pos` while idle).
    PropertyChange {
        id: u64,
        name: String,
        value: Option<Value>,
    },
    /// The current file ended. `reason` distinguishes a natural end ("eof")
    /// from a user-driven stop/skip.
    EndFile {
        reason: String,
    },
    StartFile,
    FileLoaded,
    /// mpv ran out of playlist and went idle.
    IdleEvent,
    /// A reply to one of our commands.
    Reply {
        request_id: u64,
        error: String,
        data: Option<Value>,
    },
    /// An event we do not model. Kept so the reader can log rather than fail.
    Other(String),
}

#[derive(Deserialize)]
struct RawLine {
    #[serde(default)]
    event: Option<String>,
    #[serde(default)]
    id: Option<u64>,
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    data: Option<Value>,
    #[serde(default)]
    reason: Option<String>,
    #[serde(default)]
    request_id: Option<u64>,
    #[serde(default)]
    error: Option<String>,
}

/// Classifies one line from the socket. Returns `None` for blank lines and for
/// anything that is not valid JSON — mpv occasionally emits neither, and a
/// malformed line must never take the reader thread down.
pub fn parse_line(line: &str) -> Option<Incoming> {
    let line = line.trim();
    if line.is_empty() {
        return None;
    }
    let raw: RawLine = serde_json::from_str(line).ok()?;

    match raw.event.as_deref() {
        Some("property-change") => Some(Incoming::PropertyChange {
            id: raw.id?,
            name: raw.name.unwrap_or_default(),
            // mpv omits `data` entirely for an unavailable property, and sends
            // an explicit null for a null-valued one. Both mean "no value".
            value: match raw.data {
                None | Some(Value::Null) => None,
                Some(v) => Some(v),
            },
        }),
        Some("end-file") => Some(Incoming::EndFile {
            reason: raw.reason.unwrap_or_else(|| "unknown".into()),
        }),
        Some("start-file") => Some(Incoming::StartFile),
        Some("file-loaded") => Some(Incoming::FileLoaded),
        Some("idle") => Some(Incoming::IdleEvent),
        Some(other) => Some(Incoming::Other(other.to_string())),
        None => {
            // No `event` key: this is a command reply.
            let request_id = raw.request_id?;
            Some(Incoming::Reply {
                request_id,
                error: raw.error.unwrap_or_else(|| "success".into()),
                data: raw.data,
            })
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn command_line_is_newline_terminated_json() {
        let c = Command::new(loadfile("http://h/api/stream/t1", "replace"), 7);
        let line = c.to_line();
        assert!(line.ends_with('\n'));
        let v: Value = serde_json::from_str(line.trim()).unwrap();
        assert_eq!(v["request_id"], 7);
        assert_eq!(v["command"][0], "loadfile");
        assert_eq!(v["command"][1], "http://h/api/stream/t1");
        assert_eq!(v["command"][2], "replace");
    }

    #[test]
    fn parses_property_change_with_value() {
        let got = parse_line(r#"{"event":"property-change","id":1,"name":"time-pos","data":12.5}"#);
        assert_eq!(
            got,
            Some(Incoming::PropertyChange {
                id: 1,
                name: "time-pos".into(),
                value: Some(json!(12.5)),
            })
        );
    }

    #[test]
    fn missing_and_null_data_both_read_as_no_value() {
        for line in [
            r#"{"event":"property-change","id":1,"name":"time-pos"}"#,
            r#"{"event":"property-change","id":1,"name":"time-pos","data":null}"#,
        ] {
            match parse_line(line).unwrap() {
                Incoming::PropertyChange { value, .. } => assert_eq!(value, None),
                other => panic!("expected property change, got {other:?}"),
            }
        }
    }

    #[test]
    fn parses_end_file_reason() {
        assert_eq!(
            parse_line(r#"{"event":"end-file","reason":"eof"}"#),
            Some(Incoming::EndFile {
                reason: "eof".into()
            })
        );
    }

    #[test]
    fn reply_without_event_key_is_a_reply() {
        assert_eq!(
            parse_line(r#"{"error":"success","data":null,"request_id":4}"#),
            Some(Incoming::Reply {
                request_id: 4,
                error: "success".into(),
                data: None,
            })
        );
    }

    #[test]
    fn junk_and_blank_lines_are_ignored_not_fatal() {
        assert_eq!(parse_line(""), None);
        assert_eq!(parse_line("   "), None);
        assert_eq!(parse_line("not json at all"), None);
        assert_eq!(parse_line("{unterminated"), None);
    }

    #[test]
    fn unknown_events_are_preserved_as_other() {
        assert_eq!(
            parse_line(r#"{"event":"audio-reconfig"}"#),
            Some(Incoming::Other("audio-reconfig".into()))
        );
    }

    #[test]
    fn seek_helpers_shape_correctly() {
        assert_eq!(
            seek_absolute(30.0),
            vec![json!("seek"), json!(30.0), json!("absolute")]
        );
        assert_eq!(
            seek_relative(-5.0),
            vec![json!("seek"), json!(-5.0), json!("relative")]
        );
    }
}
