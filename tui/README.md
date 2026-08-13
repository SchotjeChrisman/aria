# aria-tui

A terminal client for the [Aria](../README.md) music server. Browses the
library, drives playback through **mpv** (gapless, bit-perfect by default),
edits playlists, and records plays back to the server.

```sh
cd tui
cargo build --release
./target/release/aria-tui --server http://localhost:3001
```

The binary is self-contained apart from mpv, which it launches as a child
process and drives over a JSON IPC socket. Without mpv the client still runs —
it just browses instead of playing, and says so.

### Installing a release build

Every release carries `aria-tui-linux-x64.tar.gz` and `aria-tui-macos.zip`.
The macOS build is universal, so one download covers Intel and Apple silicon.

```sh
tar -xzf aria-tui-linux-x64.tar.gz
install -m755 aria-tui ~/.local/bin/
```

Then install mpv from your package manager (`apt install mpv`,
`brew install mpv`, `dnf install mpv`). There is no Windows build: playback
drives mpv over a unix socket.

Unlike the Flutter app, the macOS binary is not signed or notarized. A download
through a browser is quarantined; `curl` or `gh release download` is not. To
clear it:

```sh
xattr -dr com.apple.quarantine aria-tui
```

## First run

Point it at the server and pick a profile:

```sh
aria-tui -s http://your-box:3001
```

Aria seeds one profile, so with a single-user server there is nothing to
choose; with several the client asks. The choice is saved, along with the
server URL, volume and stream tier, to
`$XDG_CONFIG_HOME/aria-tui/config.toml`.

The profile is not cosmetic: Aria scopes playlists, listen-later, stats and
play history to it, and `POST /api/plays` refuses a report without one.

## Options

```
-s, --server <URL>     Server base URL (default: http://localhost:3000)
-c, --config <PATH>    Config file to use
-p, --profile <NAME>   Profile to use, by name
-t, --tier <TIER>      Stream tier: original | high | low
    --no-player        Browse only; do not start mpv
-h, --help             Show this help
-V, --version          Show the version
```

## Keys

| Key | Action |
| --- | --- |
| `1`–`8`, `Tab` | Switch view |
| `j` / `k`, `↓` / `↑` | Move |
| `g` / `G` | Top / bottom |
| `Ctrl-d` / `Ctrl-u` | Half page down / up |
| `Enter` | Open a collection, or play from the cursor |
| `Esc` | Back, or close a modal |
| `Space` | Play / pause |
| `n` / `p` | Next / previous track |
| `←` / `→` | Seek 5s (`Shift` for 30s) |
| `-` / `=` | Volume |
| `s` | Shuffle |
| `r` | Repeat: off → all → one |
| `x` | Stop and clear the queue |
| `a` / `A` | Add to queue / play next |
| `f` | Favourite |
| `P` | Add to a playlist |
| `d` | Remove from the queue or a playlist |
| `/` | Search |
| `t` | Cycle the stream tier |
| `R` | Reload the library |
| `S` | Rescan the server's library |
| `?` | Help |
| `q` | Quit |

`n` creates a new playlist while the Playlists view is open; everywhere else it
skips to the next track.

## Views

**Albums**, **Artists**, **Tracks** are the library, folded client-side —
Aria serves the whole merged track view from `/api/tracks` and has no album,
artist or search endpoint, so grouping, sorting and searching all happen here.
Albums group by `albumId` (Aria derives album identity from the directory), and
sorting ignores case, accents and a leading article.

**Search** filters as you type, across title, artist, album, composer and
genre, ignoring accents — "bjork" finds Björk. Every term must match, so extra
words narrow the result.

**Queue** is what is playing. `Enter` jumps to a row, `d` removes one.

**Playlists** browses and edits manual playlists. Smart playlists are shown but
not editable — they are defined by their rules, and the server rejects a track
added to one.

**Tags** and **Stats** read the server's tag tree and your listening history.

## Playback

mpv owns the playlist, so transitions are gapless and skipping is instant. The
client streams the **original file** by default — bit-perfect, byte for byte —
and only asks for the Opus tiers if you press `t`. If the server was built
without ffmpeg it reports `transcode: false` and the client stays on the
original rather than sending a request that would 501.

Set `exclusive_audio = true` in the config to ask the OS for exclusive access
to the audio device, which stops a shared mixer resampling a high-resolution
stream.

A play is reported once it has been listened to for half the track, capped at
30 seconds — the usual convention, applied client-side because Aria enforces
none.

## Configuration

`$XDG_CONFIG_HOME/aria-tui/config.toml`:

```toml
server = "http://localhost:3001"
profile_id = "default"
profile_name = "Listener"
tier = "original"          # original | high | low
volume = 100.0             # 0–130, mpv's scale
mpv_path = "mpv"
exclusive_audio = false
mpv_args = []              # extra mpv flags, appended last
scrobble_at = 0.5          # fraction of a track before a play is reported
theme = "dark"             # dark | light
```

`mpv_args` is for the things only you know about your setup — pick a specific
output device, add a filter, work around a DAC:

```toml
mpv_args = ["--audio-device=alsa/hw:2,0", "--audio-channels=stereo"]
```

They are appended after the client's own flags, so they win.

A malformed config is reported rather than silently replaced, so a typo cannot
lose your server URL.

## Development

```sh
cargo test              # unit and rendering tests, no server needed
cargo clippy --all-targets
```

The rendering tests draw real frames through ratatui's `TestBackend`, so views,
modals and column truncation are covered without a terminal.

Against a live server:

```sh
ARIA_TEST_SERVER=http://localhost:3999 cargo test --test live
```

These exercise the parts that only the real server can confirm — response
shapes, the playlist round-trip, the play-timestamp layout, and the 501 on a
transcoded tier. They are skipped when the variable is unset.
