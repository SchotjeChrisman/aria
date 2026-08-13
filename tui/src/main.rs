//! `aria-tui` — a terminal client for the Aria music server.

use std::io::{self, Stdout};
use std::time::{Duration, Instant};

use crossterm::event::{self, Event, KeyEventKind};
use crossterm::execute;
use crossterm::terminal::{
    disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen,
};
use ratatui::backend::CrosstermBackend;
use ratatui::Terminal;

use aria_tui::api::Client;
use aria_tui::app::{App, Modal, Msg};
use aria_tui::config::{parse_args, Config, USAGE};
use aria_tui::keys::handle_key;
use aria_tui::player::{Player, PlayerError};
use aria_tui::ui;

const VERSION: &str = env!("CARGO_PKG_VERSION");

fn main() -> io::Result<()> {
    let args = match parse_args(std::env::args().skip(1)) {
        Ok(a) => a,
        Err(e) => {
            eprintln!("aria-tui: {e}\n\n{USAGE}");
            std::process::exit(2);
        }
    };
    if args.help {
        println!("{USAGE}");
        return Ok(());
    }
    if args.version {
        println!("aria-tui {VERSION}");
        return Ok(());
    }

    let cfg_path = args
        .config_path
        .clone()
        .unwrap_or_else(Config::default_path);
    let mut cfg = match Config::load(&cfg_path) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("aria-tui: {e}");
            std::process::exit(1);
        }
    };
    // Kept before the CLI overrides are folded in: flags apply to this run,
    // not to the user's file.
    let saved_cfg = cfg.clone();
    cfg.apply(&args);

    // Start mpv before taking over the terminal, so a failure prints plainly.
    let (player, player_note) = if args.no_player {
        (
            Player::disabled_at_volume(cfg.volume),
            Some("playback disabled (--no-player)".to_string()),
        )
    } else {
        match Player::start(
            &cfg.mpv_path,
            cfg.exclusive_audio,
            cfg.volume,
            &cfg.mpv_args,
        ) {
            Ok(p) => (p, None),
            Err(PlayerError::NotFound(bin)) => (
                Player::disabled_at_volume(cfg.volume),
                Some(format!(
                    "{bin} not found — browsing only, install mpv to play audio"
                )),
            ),
            Err(e) => (
                Player::disabled_at_volume(cfg.volume),
                Some(format!("{e} — browsing only")),
            ),
        }
    };

    let mut app = App::with_saved(cfg, saved_cfg, cfg_path, player);
    if let Some(note) = player_note {
        app.toast(note);
    }

    // The library, status and profile list all load in the background; the UI
    // is interactive immediately.
    app.load_library();
    app.load_status();
    app.load_profiles();
    app.load_tags();
    spawn_event_stream(&app);

    // A profile named on the command line is resolved once the list arrives.
    let wanted_profile = args.profile.clone();

    let mut terminal = setup_terminal()?;
    let res = run(&mut terminal, &mut app, wanted_profile);
    restore_terminal(&mut terminal)?;

    // mpv is shut down explicitly so it never outlives the terminal restore.
    app.player.quit();

    if let Err(e) = res {
        eprintln!("aria-tui: {e}");
        std::process::exit(1);
    }
    Ok(())
}

fn setup_terminal() -> io::Result<Terminal<CrosstermBackend<Stdout>>> {
    enable_raw_mode()?;
    let mut stdout = io::stdout();
    execute!(stdout, EnterAlternateScreen)?;
    // Leaving the terminal in raw mode on a panic makes the shell unusable, so
    // the hook restores it before the message is printed.
    let default_hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        let _ = disable_raw_mode();
        let _ = execute!(io::stdout(), LeaveAlternateScreen);
        default_hook(info);
    }));
    Terminal::new(CrosstermBackend::new(stdout))
}

fn restore_terminal(terminal: &mut Terminal<CrosstermBackend<Stdout>>) -> io::Result<()> {
    disable_raw_mode()?;
    execute!(terminal.backend_mut(), LeaveAlternateScreen)?;
    terminal.show_cursor()
}

/// Subscribes to the server's progress stream, reconnecting for as long as the
/// app runs. Scan and enrichment passes rewrite the merged track view, so this
/// is how the client knows its library went stale.
fn spawn_event_stream(app: &App) {
    let tx = app.sender();
    let base = app.client.base_url().to_string();
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
                return; // the app is gone
            }
            let _ = result;
            // A stream that stayed up was healthy, so the next drop starts
            // from a short delay again — otherwise one bad patch would leave
            // the client on a minute-long reconnect for the rest of the run.
            if started.elapsed() >= Duration::from_secs(30) {
                backoff = base_delay;
            }
            // A drop is normal (server restart, proxy timeout); back off up to
            // a minute rather than hammering.
            std::thread::sleep(backoff);
            backoff = (backoff * 2).min(Duration::from_secs(60));
        }
    });
}

fn run(
    terminal: &mut Terminal<CrosstermBackend<Stdout>>,
    app: &mut App,
    wanted_profile: Option<String>,
) -> io::Result<()> {
    let frame = Duration::from_millis(200);
    let mut last = Instant::now();
    let mut profile_pending = wanted_profile;

    loop {
        terminal.draw(|f| ui::draw(f, app))?;

        // Wait for input, but never longer than a frame — the progress bar and
        // the elapsed time have to advance without a keypress.
        let timeout = frame.saturating_sub(last.elapsed());
        if event::poll(timeout)? {
            match event::read()? {
                // Windows terminals send key-release events too; acting on both
                // would double every keystroke.
                Event::Key(key) if key.kind == KeyEventKind::Press => handle_key(app, key),
                Event::Resize(_, _) => {}
                _ => {}
            }
        }

        if last.elapsed() >= frame {
            app.tick();
            last = Instant::now();

            // Resolve a --profile name once the profile list has arrived.
            if let Some(name) = profile_pending.clone() {
                if !app.profiles.is_empty() {
                    match app.profiles.iter().find(|p| p.name == name).cloned() {
                        Some(p) => {
                            app.set_profile(&p);
                            app.modal = Modal::None;
                        }
                        None => app.toast(format!("no profile named {name:?}")),
                    }
                    profile_pending = None;
                }
            }
        }

        if app.should_quit {
            // Remember the volume for next time. Anything a --flag set for this
            // run only is deliberately not written back.
            app.save_config();
            return Ok(());
        }
    }
}
