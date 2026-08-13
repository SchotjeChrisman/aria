//! Blocking HTTP client for the Aria server.
//!
//! Aria has no authentication and no per-request user header. Identity is
//! carried explicitly: playlists and listen-later entries are filtered by a
//! `profileId` query parameter, and `POST /api/plays` refuses a body without
//! one. The client therefore takes the active profile id from the caller on
//! every call that needs it rather than holding hidden state.

pub mod models;

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read};
use std::time::Duration;

use serde::de::DeserializeOwned;
use serde_json::json;

pub use models::{
    Album, ListenLaterItem, PlayReport, Playlist, Profile, Status, Tag, TagItem, Tier, Track,
};

#[derive(Debug)]
pub enum ApiError {
    /// Could not reach the server at all.
    Transport(String),
    /// The server answered, but not with success.
    Status { code: u16, body: String },
    /// The server answered with something we could not decode.
    Decode(String),
}

impl std::fmt::Display for ApiError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ApiError::Transport(e) => write!(f, "cannot reach server: {e}"),
            ApiError::Status { code, body } => {
                let msg = extract_error_message(body);
                write!(f, "server returned {code}: {msg}")
            }
            ApiError::Decode(e) => write!(f, "unexpected response: {e}"),
        }
    }
}

impl std::error::Error for ApiError {}

/// Aria's error bodies are `{"error":"..."}`. Fall back to the raw body, and
/// keep it short — this ends up on a single status line.
fn extract_error_message(body: &str) -> String {
    let msg = serde_json::from_str::<serde_json::Value>(body)
        .ok()
        .and_then(|v| v.get("error").and_then(|e| e.as_str()).map(str::to_string))
        .unwrap_or_else(|| body.trim().to_string());
    if msg.chars().count() > 200 {
        msg.chars().take(200).collect::<String>() + "…"
    } else {
        msg
    }
}

pub type Result<T> = std::result::Result<T, ApiError>;

/// `/api/tracks` is the whole library in one document. At six figures of
/// tracks the merged view runs to tens of megabytes, so the default read cap
/// has to go — a truncated body would surface as a confusing parse error
/// rather than as "your library is too big".
const MAX_BODY: u64 = 1024 * 1024 * 1024;

#[derive(Clone)]
pub struct Client {
    base: String,
    agent: ureq::Agent,
    /// No global timeout, for the two requests that are legitimately
    /// long-lived: the SSE stream and a synchronous rescan.
    streaming_agent: ureq::Agent,
}

impl Client {
    /// `base_url` may be given with or without a scheme or trailing slash;
    /// a bare `host:port` is assumed to be plain HTTP, which is how a
    /// self-hosted Aria is normally reached.
    pub fn new(base_url: &str) -> Self {
        let config = ureq::Agent::config_builder()
            // Long enough for a cold `/api/tracks` on a large library, where
            // the server may be building and gzipping the merged view.
            .timeout_global(Some(Duration::from_secs(120)))
            // Report the server's own error body instead of turning a 4xx into
            // a bare status code with nothing to show the user.
            .http_status_as_error(false)
            .build();
        let streaming = ureq::Agent::config_builder()
            .timeout_global(None)
            .http_status_as_error(false)
            .build();
        Self {
            base: normalize_base(base_url),
            agent: config.into(),
            streaming_agent: streaming.into(),
        }
    }

    pub fn base_url(&self) -> &str {
        &self.base
    }

    fn url(&self, path: &str) -> String {
        format!("{}{}", self.base, path)
    }

    /// Reads a response fully, turning a non-2xx into an [`ApiError::Status`]
    /// that carries the server's own message.
    fn finish(mut resp: ureq::http::Response<ureq::Body>, path: &str) -> Result<String> {
        let code = resp.status().as_u16();
        let text = resp
            .body_mut()
            .with_config()
            .limit(MAX_BODY)
            .read_to_string()
            .map_err(|e| ApiError::Transport(format!("{e} (from {path})")))?;
        if !(200..300).contains(&code) {
            return Err(ApiError::Status { code, body: text });
        }
        Ok(text)
    }

    fn get_json<T: DeserializeOwned>(&self, path: &str) -> Result<T> {
        let url = self.url(path);
        let resp = self.agent.get(&url).call().map_err(classify)?;
        let body = Self::finish(resp, path)?;
        serde_json::from_str(&body).map_err(|e| ApiError::Decode(format!("{e} (from {path})")))
    }

    fn send_json<T: DeserializeOwned>(
        &self,
        method: &str,
        path: &str,
        body: serde_json::Value,
    ) -> Result<T> {
        let url = self.url(path);
        let req = match method {
            "POST" => self.agent.post(&url),
            "PUT" => self.agent.put(&url),
            "PATCH" => self.agent.patch(&url),
            // DELETE carries no body in this API, and ureq types it as such.
            "DELETE" => return self.delete(path),
            other => return Err(ApiError::Transport(format!("unsupported method {other}"))),
        };
        let resp = req.send_json(&body).map_err(classify)?;
        let text = Self::finish(resp, path)?;
        // Some mutations answer an empty body; `null` decodes into anything
        // optional and into `()`.
        let text = if text.trim().is_empty() {
            "null"
        } else {
            &text
        };
        serde_json::from_str(text).map_err(|e| ApiError::Decode(format!("{e} (from {path})")))
    }

    fn delete<T: DeserializeOwned>(&self, path: &str) -> Result<T> {
        let url = self.url(path);
        let resp = self.agent.delete(&url).call().map_err(classify)?;
        let text = Self::finish(resp, path)?;
        let text = if text.trim().is_empty() {
            "null"
        } else {
            &text
        };
        serde_json::from_str(text).map_err(|e| ApiError::Decode(format!("{e} (from {path})")))
    }

    // ---- status ----------------------------------------------------------

    pub fn status(&self) -> Result<Status> {
        self.get_json("/api/status")
    }

    // ---- library ---------------------------------------------------------

    /// The entire library in one document.
    ///
    /// There is no server-side search or album endpoint: Aria serves the whole
    /// merged track view (gzipped, and cached server-side per generation) and
    /// every client indexes it locally. On a large library this is the one
    /// genuinely heavy request the client makes, so it is fetched once at
    /// startup and refreshed only on demand or when a scan finishes.
    pub fn tracks(&self) -> Result<Vec<Track>> {
        self.get_json("/api/tracks")
    }

    /// Toggles the independent favourite flag. Returns the new state.
    pub fn set_favourite(&self, track_id: &str, favourite: bool) -> Result<bool> {
        let v: serde_json::Value = self.send_json(
            "PUT",
            &format!("/api/tracks/{}/favourite", urlencode(track_id)),
            json!({ "favourite": favourite }),
        )?;
        Ok(v.get("favourite")
            .and_then(|f| f.as_bool())
            .unwrap_or(favourite))
    }

    /// Raw enrichment blob for an album: label, release date, blurb.
    pub fn album_info(&self, album_id: &str) -> Result<serde_json::Value> {
        self.get_json(&format!("/api/album/{}/info", urlencode(album_id)))
    }

    /// Raw enrichment blob for an artist: biography, discography, images.
    pub fn artist(&self, name: &str) -> Result<serde_json::Value> {
        self.get_json(&format!("/api/artist/{}", urlencode(name)))
    }

    /// `{"synced": "...", "plain": "..."}`, or JSON null when nothing matched.
    pub fn lyrics(&self, track_id: &str) -> Result<serde_json::Value> {
        self.get_json(&format!("/api/lyrics/{}", urlencode(track_id)))
    }

    /// Listening statistics. Scoped to a profile — omitting the id silently
    /// aggregates every profile, which is never what the header means by
    /// "your" top artists. Top-N lists are capped at 50 server-side.
    pub fn stats(&self, profile_id: &str) -> Result<serde_json::Value> {
        self.get_json(&format!("/api/stats?profileId={}", urlencode(profile_id)))
    }

    /// Generated mixes for a profile.
    pub fn mixes(&self, profile_id: &str) -> Result<serde_json::Value> {
        self.get_json(&format!("/api/mixes?profileId={}", urlencode(profile_id)))
    }

    /// Kicks off a rescan. The server runs it synchronously and publishes
    /// progress on the SSE stream, so this call blocks until the scan ends.
    pub fn scan(&self) -> Result<serde_json::Value> {
        let url = self.url("/api/scan");
        let resp = self
            .streaming_agent
            .post(&url)
            .send_json(json!({}))
            .map_err(classify)?;
        let text = Self::finish(resp, "/api/scan")?;
        let text = if text.trim().is_empty() {
            "null"
        } else {
            &text
        };
        serde_json::from_str(text).map_err(|e| ApiError::Decode(e.to_string()))
    }

    // ---- profiles --------------------------------------------------------

    pub fn profiles(&self) -> Result<Vec<Profile>> {
        self.get_json("/api/profiles")
    }

    /// `color` must be a `#rrggbb` string; the server rejects anything else.
    pub fn create_profile(&self, name: &str, color: &str) -> Result<Profile> {
        self.send_json(
            "POST",
            "/api/profiles",
            json!({ "name": name, "color": color }),
        )
    }

    // ---- plays -----------------------------------------------------------

    /// Reports a finished play. `at` must use the millisecond-precision
    /// `%Y-%m-%dT%H:%M:%S.000Z` layout when supplied; passing `None` lets the
    /// server stamp it, which is what a live client wants.
    pub fn report_play(&self, track_id: &str, profile_id: &str, at: Option<String>) -> Result<()> {
        let body = serde_json::to_value(PlayReport {
            track_id: track_id.to_string(),
            profile_id: profile_id.to_string(),
            at,
        })
        .map_err(|e| ApiError::Decode(e.to_string()))?;
        let _: serde_json::Value = self.send_json("POST", "/api/plays", body)?;
        Ok(())
    }

    /// All-time play counts for a profile, as `{trackId: plays}`.
    ///
    /// One row per *played* track, so a track nobody has reached is absent
    /// rather than zero, and the map stays small next to the library. Omitting
    /// `period` asks for all time, which is what "most played" means here.
    pub fn play_counts(&self, profile_id: &str) -> Result<HashMap<String, u32>> {
        let v: serde_json::Value = self.get_json(&format!(
            "/api/plays/counts?profileId={}",
            urlencode(profile_id)
        ))?;
        Ok(v.get("counts")
            .and_then(|c| c.as_object())
            .map(|m| {
                m.iter()
                    .filter_map(|(id, n)| Some((id.clone(), n.as_u64()? as u32)))
                    .collect()
            })
            .unwrap_or_default())
    }

    // ---- playlists -------------------------------------------------------

    pub fn playlists(&self, profile_id: &str) -> Result<Vec<Playlist>> {
        self.get_json(&format!(
            "/api/playlists?profileId={}",
            urlencode(profile_id)
        ))
    }

    pub fn create_playlist(&self, name: &str, profile_id: &str) -> Result<Playlist> {
        self.send_json(
            "POST",
            "/api/playlists",
            json!({ "name": name, "profileId": profile_id, "type": "manual" }),
        )
    }

    pub fn rename_playlist(&self, id: &str, name: &str) -> Result<Playlist> {
        self.send_json(
            "PATCH",
            &format!("/api/playlists/{}", urlencode(id)),
            json!({ "name": name }),
        )
    }

    pub fn delete_playlist(&self, id: &str) -> Result<()> {
        let _: serde_json::Value = self.send_json(
            "DELETE",
            &format!("/api/playlists/{}", urlencode(id)),
            json!({}),
        )?;
        Ok(())
    }

    /// Appends a track. Duplicates are allowed by the server, deliberately.
    pub fn playlist_add_track(&self, playlist_id: &str, track_id: &str) -> Result<Playlist> {
        self.send_json(
            "POST",
            &format!("/api/playlists/{}/tracks", urlencode(playlist_id)),
            json!({ "trackId": track_id }),
        )
    }

    /// Removes *every* occurrence of the track; an unknown id is a no-op.
    pub fn playlist_remove_track(&self, playlist_id: &str, track_id: &str) -> Result<Playlist> {
        self.send_json(
            "DELETE",
            &format!(
                "/api/playlists/{}/tracks/{}",
                urlencode(playlist_id),
                urlencode(track_id)
            ),
            json!({}),
        )
    }

    /// Resolved tracks, in playlist order for a manual playlist and in rule
    /// order for a smart one.
    pub fn playlist_tracks(&self, playlist_id: &str) -> Result<Vec<Track>> {
        self.get_json(&format!("/api/playlists/{}/tracks", urlencode(playlist_id)))
    }

    // ---- tags ------------------------------------------------------------

    pub fn tags(&self) -> Result<Vec<Tag>> {
        self.get_json("/api/tags")
    }

    // ---- listen later ----------------------------------------------------

    pub fn listen_later(&self, profile_id: &str) -> Result<Vec<ListenLaterItem>> {
        self.get_json(&format!(
            "/api/listenlater?profileId={}",
            urlencode(profile_id)
        ))
    }

    /// Removes an entry. The profile id is a query parameter here, and
    /// omitting it makes the delete a silent no-op that still answers `ok` —
    /// so it is always sent.
    pub fn listen_later_remove(&self, id: &str, profile_id: &str) -> Result<()> {
        let _: serde_json::Value = self.delete(&format!(
            "/api/listenlater/{}?profileId={}",
            urlencode(id),
            urlencode(profile_id)
        ))?;
        Ok(())
    }

    // ---- media URLs ------------------------------------------------------

    /// The URL handed to mpv. The original tier takes no query parameter — the
    /// server treats an absent or unrecognised `tier` as bit-perfect
    /// passthrough, but asking for exactly what we want keeps the request
    /// honest and the server logs readable.
    pub fn stream_url(&self, track_id: &str, tier: Tier) -> String {
        match tier.query_value() {
            Some(t) => self.url(&format!("/api/stream/{}?tier={}", urlencode(track_id), t)),
            None => self.url(&format!("/api/stream/{}", urlencode(track_id))),
        }
    }

    pub fn art_url(&self, album_id: &str) -> String {
        self.url(&format!("/api/art/{}", urlencode(album_id)))
    }

    // ---- events ----------------------------------------------------------

    /// Opens the SSE stream and calls `on_event` for every named event until
    /// the connection drops. Blocking: run it on its own thread.
    ///
    /// The server emits `scan` and `enrich` progress events, plus comment-only
    /// keepalive lines every 25 seconds that carry no event and must be
    /// skipped rather than parsed.
    pub fn events<F>(&self, mut on_event: F) -> Result<()>
    where
        F: FnMut(SseEvent),
    {
        let url = self.url("/api/events");
        let resp = self
            .streaming_agent
            .get(&url)
            .header("Accept", "text/event-stream")
            .call()
            .map_err(classify)?;
        let reader = BufReader::new(resp.into_body().into_reader());
        let mut name = String::new();
        let mut data = String::new();
        for line in reader.lines() {
            let line = line.map_err(|e| ApiError::Transport(e.to_string()))?;
            if let Some(rest) = line.strip_prefix("event:") {
                name = rest.trim().to_string();
            } else if let Some(rest) = line.strip_prefix("data:") {
                if !data.is_empty() {
                    data.push('\n');
                }
                data.push_str(rest.trim());
            } else if line.trim().is_empty() {
                // Blank line ends a frame. A keepalive (": ping") never sets
                // either field, so nothing is dispatched for it.
                if !name.is_empty() || !data.is_empty() {
                    on_event(SseEvent {
                        name: std::mem::take(&mut name),
                        data: std::mem::take(&mut data),
                    });
                }
            }
            // Anything else (": connected", ": ping", "id:", "retry:") is
            // deliberately ignored.
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct SseEvent {
    pub name: String,
    pub data: String,
}

impl SseEvent {
    pub fn json(&self) -> Option<serde_json::Value> {
        serde_json::from_str(&self.data).ok()
    }
}

fn classify(e: ureq::Error) -> ApiError {
    match e {
        ureq::Error::StatusCode(code) => ApiError::Status {
            code,
            body: String::new(),
        },
        other => ApiError::Transport(other.to_string()),
    }
}

/// Trims a user-typed base URL into something joinable: adds the scheme when
/// missing and drops any trailing slash.
pub fn normalize_base(input: &str) -> String {
    let s = input.trim().trim_end_matches('/');
    if s.is_empty() {
        return "http://localhost:3000".to_string();
    }
    if s.starts_with("http://") || s.starts_with("https://") {
        s.to_string()
    } else {
        format!("http://{s}")
    }
}

/// Percent-encodes a path or query segment.
///
/// Artist names are used verbatim as path segments (`/api/artist/{name}`) and
/// routinely contain spaces, slashes and non-ASCII, so this cannot be skipped.
pub fn urlencode(s: &str) -> String {
    const UNRESERVED: &[u8] = b"-_.~";
    let mut out = String::with_capacity(s.len());
    for b in s.as_bytes() {
        if b.is_ascii_alphanumeric() || UNRESERVED.contains(b) {
            out.push(*b as char);
        } else {
            out.push('%');
            out.push_str(&format!("{b:02X}"));
        }
    }
    out
}

/// Reads an SSE body from any reader. Split out from [`Client::events`] so the
/// frame parsing can be tested without a server.
pub fn parse_sse<R: Read, F: FnMut(SseEvent)>(reader: R, mut on_event: F) {
    let reader = BufReader::new(reader);
    let mut name = String::new();
    let mut data = String::new();
    for line in reader.lines().map_while(std::result::Result::ok) {
        if let Some(rest) = line.strip_prefix("event:") {
            name = rest.trim().to_string();
        } else if let Some(rest) = line.strip_prefix("data:") {
            if !data.is_empty() {
                data.push('\n');
            }
            data.push_str(rest.trim());
        } else if line.trim().is_empty() && (!name.is_empty() || !data.is_empty()) {
            on_event(SseEvent {
                name: std::mem::take(&mut name),
                data: std::mem::take(&mut data),
            });
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base_url_accepts_what_a_user_would_type() {
        assert_eq!(normalize_base("localhost:3001"), "http://localhost:3001");
        assert_eq!(normalize_base("http://box:3000/"), "http://box:3000");
        assert_eq!(
            normalize_base("https://aria.example.com//"),
            "https://aria.example.com"
        );
        assert_eq!(normalize_base("  10.0.0.5:3000  "), "http://10.0.0.5:3000");
        assert_eq!(normalize_base(""), "http://localhost:3000");
    }

    #[test]
    fn stream_url_omits_the_tier_for_bit_perfect() {
        let c = Client::new("http://box:3000");
        assert_eq!(
            c.stream_url("t1", Tier::Original),
            "http://box:3000/api/stream/t1"
        );
        assert_eq!(
            c.stream_url("t1", Tier::High),
            "http://box:3000/api/stream/t1?tier=high"
        );
        assert_eq!(
            c.stream_url("t1", Tier::Low),
            "http://box:3000/api/stream/t1?tier=low"
        );
    }

    #[test]
    fn path_segments_are_encoded() {
        // An artist name goes in the path verbatim, so spaces and slashes must
        // not be able to reshape the request.
        assert_eq!(urlencode("Simon & Garfunkel"), "Simon%20%26%20Garfunkel");
        assert_eq!(urlencode("AC/DC"), "AC%2FDC");
        assert_eq!(urlencode("Björk"), "Bj%C3%B6rk");
        assert_eq!(urlencode("plain-name_1.0~"), "plain-name_1.0~");
    }

    #[test]
    fn art_url_is_built_from_the_album_id() {
        let c = Client::new("localhost:3001");
        assert_eq!(c.art_url("al1"), "http://localhost:3001/api/art/al1");
    }

    #[test]
    fn error_message_prefers_the_servers_own_wording() {
        assert_eq!(
            extract_error_message(r#"{"error":"trackId and profileId required"}"#),
            "trackId and profileId required"
        );
        assert_eq!(
            extract_error_message("plain text failure"),
            "plain text failure"
        );
    }

    #[test]
    fn long_error_bodies_are_truncated_for_the_status_line() {
        let long = "x".repeat(500);
        let msg = extract_error_message(&long);
        assert!(
            msg.chars().count() <= 201,
            "got {} chars",
            msg.chars().count()
        );
        assert!(msg.ends_with('…'));
    }

    #[test]
    fn sse_frames_are_dispatched_on_the_blank_line() {
        let body = "event: scan\ndata: {\"done\":3,\"total\":10}\n\nevent: enrich\ndata: {\"ok\":true}\n\n";
        let mut got = Vec::new();
        parse_sse(body.as_bytes(), |e| got.push(e));
        assert_eq!(
            got,
            vec![
                SseEvent {
                    name: "scan".into(),
                    data: r#"{"done":3,"total":10}"#.into()
                },
                SseEvent {
                    name: "enrich".into(),
                    data: r#"{"ok":true}"#.into()
                },
            ]
        );
    }

    #[test]
    fn keepalive_comments_dispatch_nothing() {
        // The server opens with ": connected" and pings every 25s. Treating a
        // ping as a frame would spam the UI with empty events.
        let body = ": connected\n\n: ping\n\nevent: scan\ndata: {\"done\":1}\n\n";
        let mut got = Vec::new();
        parse_sse(body.as_bytes(), |e| got.push(e));
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].name, "scan");
    }

    #[test]
    fn multiline_data_is_joined_with_newlines() {
        let body = "event: log\ndata: line one\ndata: line two\n\n";
        let mut got = Vec::new();
        parse_sse(body.as_bytes(), |e| got.push(e));
        assert_eq!(got[0].data, "line one\nline two");
    }

    #[test]
    fn sse_event_data_decodes_as_json() {
        let e = SseEvent {
            name: "scan".into(),
            data: r#"{"done":3}"#.into(),
        };
        assert_eq!(e.json().unwrap()["done"], 3);
        let bad = SseEvent {
            name: "scan".into(),
            data: "not json".into(),
        };
        assert_eq!(bad.json(), None);
    }
}
