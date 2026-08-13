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

use aria_tui::app::{App, Modal};
use aria_tui::config::{apply_env, parse_args, resolve, Config, Resolved, USAGE};
use aria_tui::keys::handle_key;
use aria_tui::player::{Player, PlayerError};
use aria_tui::ui;

const VERSION: &str = env!("CARGO_PKG_VERSION");

fn main() -> io::Result<()> {
    let mut args = match parse_args(std::env::args().skip(1)) {
        Ok(a) => a,
        Err(e) => {
            eprintln!("aria-tui: {e}\n\n{USAGE}");
            std::process::exit(2);
        }
    };
    apply_env(&mut args, |k| std::env::var(k).ok());
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
    let cfg = match Config::load(&cfg_path) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("aria-tui: {e}");
            std::process::exit(1);
        }
    };
    let resolved = resolve(cfg, &args, cfg_path.exists());
    let mut config_note = None;
    if resolved.write_now {
        match resolved.stored.save(&cfg_path) {
            // A first run says nothing: storing the server is the expected
            // behaviour, not an event. An explicit --save confirms, because it
            // was asked for.
            Ok(()) if args.save => {
                config_note = Some(format!("saved to {}", cfg_path.display()));
            }
            Ok(()) => {}
            Err(e) => config_note = Some(format!("could not save config: {e}")),
        }
    }
    let Resolved {
        effective: cfg,
        stored: saved_cfg,
        ..
    } = resolved;

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
    // The player note is the more urgent of the two, so it wins the one line.
    if let Some(note) = player_note.or_else(|| config_note.take()) {
        app.toast(note);
    }

    // The library, status and profile list all load in the background; the UI
    // is interactive immediately.
    app.load_library();
    app.load_status();
    app.load_profiles();
    app.load_tags();
    app.spawn_event_stream();

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
