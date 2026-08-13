//! Colours.
//!
//! Structural colour comes from the terminal's own 16-colour palette so the
//! client sits inside whatever scheme the user already runs; only the accent
//! and the dimmed text are pinned, and both are chosen to stay legible on a
//! light or a dark background.

use ratatui::style::{Color, Modifier, Style};

#[derive(Debug, Clone, Copy)]
pub struct Theme {
    pub accent: Color,
    pub text: Color,
    pub dim: Color,
    pub border: Color,
    pub border_focus: Color,
    pub selection_bg: Color,
    pub selection_fg: Color,
    pub playing: Color,
    pub favourite: Color,
    pub warning: Color,
    pub error: Color,
}

impl Theme {
    pub fn dark() -> Self {
        Self {
            accent: Color::Cyan,
            text: Color::Reset,
            dim: Color::DarkGray,
            border: Color::DarkGray,
            border_focus: Color::Cyan,
            selection_bg: Color::Indexed(238),
            selection_fg: Color::White,
            playing: Color::Green,
            favourite: Color::Magenta,
            warning: Color::Yellow,
            error: Color::Red,
        }
    }

    pub fn light() -> Self {
        Self {
            accent: Color::Blue,
            text: Color::Reset,
            dim: Color::Gray,
            border: Color::Gray,
            border_focus: Color::Blue,
            selection_bg: Color::Indexed(253),
            selection_fg: Color::Black,
            playing: Color::Green,
            favourite: Color::Magenta,
            warning: Color::Yellow,
            error: Color::Red,
        }
    }

    pub fn from_name(name: &str) -> Self {
        match name {
            "light" => Theme::light(),
            _ => Theme::dark(),
        }
    }

    pub fn base(&self) -> Style {
        Style::default().fg(self.text)
    }

    pub fn dimmed(&self) -> Style {
        Style::default().fg(self.dim)
    }

    pub fn title(&self) -> Style {
        Style::default()
            .fg(self.accent)
            .add_modifier(Modifier::BOLD)
    }

    pub fn selected(&self) -> Style {
        Style::default()
            .bg(self.selection_bg)
            .fg(self.selection_fg)
            .add_modifier(Modifier::BOLD)
    }

    /// The row for the track currently playing, when it is not also selected.
    pub fn playing_row(&self) -> Style {
        Style::default()
            .fg(self.playing)
            .add_modifier(Modifier::BOLD)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn theme_names_resolve_with_a_sane_fallback() {
        assert_eq!(Theme::from_name("light").accent, Color::Blue);
        assert_eq!(Theme::from_name("dark").accent, Color::Cyan);
        assert_eq!(
            Theme::from_name("nonsense").accent,
            Color::Cyan,
            "an unknown theme name must still render"
        );
    }

    #[test]
    fn selection_is_visibly_different_from_the_playing_row() {
        let t = Theme::dark();
        assert_ne!(t.selected(), t.playing_row());
    }
}
