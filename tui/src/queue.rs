//! The play queue.
//!
//! The queue is the client's source of truth for *what* plays and in which
//! order; mpv is told the resulting list and then owns *when*. Shuffle is
//! applied here rather than with mpv's own `--shuffle` so the user can see the
//! shuffled order in the queue view and so unshuffling restores the original
//! order exactly.

use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Repeat {
    #[default]
    Off,
    /// Wrap around at the end of the queue.
    All,
    /// Repeat the current track for ever.
    One,
}

impl Repeat {
    pub fn next(self) -> Repeat {
        match self {
            Repeat::Off => Repeat::All,
            Repeat::All => Repeat::One,
            Repeat::One => Repeat::Off,
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Repeat::Off => "off",
            Repeat::All => "all",
            Repeat::One => "one",
        }
    }
}

#[derive(Debug, Default)]
pub struct Queue {
    /// Track ids in the order they will play.
    items: Vec<String>,
    /// The pre-shuffle order, kept so unshuffling is exact rather than a
    /// re-sort that would lose a hand-built order.
    unshuffled: Vec<String>,
    pos: Option<usize>,
    shuffle: bool,
    repeat: Repeat,
    rng: Rng,
}

impl Queue {
    pub fn new() -> Self {
        Self {
            rng: Rng::from_clock(),
            ..Default::default()
        }
    }

    pub fn items(&self) -> &[String] {
        &self.items
    }

    pub fn len(&self) -> usize {
        self.items.len()
    }

    pub fn is_empty(&self) -> bool {
        self.items.is_empty()
    }

    pub fn pos(&self) -> Option<usize> {
        self.pos
    }

    pub fn current(&self) -> Option<&String> {
        self.pos.and_then(|i| self.items.get(i))
    }

    pub fn shuffle(&self) -> bool {
        self.shuffle
    }

    pub fn repeat(&self) -> Repeat {
        self.repeat
    }

    pub fn set_repeat(&mut self, r: Repeat) {
        self.repeat = r;
    }

    pub fn cycle_repeat(&mut self) -> Repeat {
        self.repeat = self.repeat.next();
        self.repeat
    }

    /// Replaces the queue and selects `start`.
    ///
    /// With shuffle on, the chosen track still plays first — picking a track
    /// and having a different one start would be a bug, not a shuffle.
    pub fn set(&mut self, ids: Vec<String>, start: usize) {
        self.unshuffled = ids.clone();
        self.items = ids;
        if self.items.is_empty() {
            self.pos = None;
            return;
        }
        let start = start.min(self.items.len() - 1);
        if self.shuffle {
            self.items.swap(0, start);
            let rest = &mut self.items[1..];
            self.rng.shuffle(rest);
            self.pos = Some(0);
        } else {
            self.pos = Some(start);
        }
    }

    /// Appends to the end of the queue, leaving playback untouched.
    pub fn append(&mut self, ids: &[String]) {
        self.items.extend_from_slice(ids);
        self.unshuffled.extend_from_slice(ids);
        if self.pos.is_none() && !self.items.is_empty() {
            self.pos = Some(0);
        }
    }

    /// Inserts directly after the current track — "play next".
    pub fn insert_next(&mut self, ids: &[String]) {
        let at = match self.pos {
            Some(p) => (p + 1).min(self.items.len()),
            None => 0,
        };
        for (n, id) in ids.iter().enumerate() {
            self.items.insert(at + n, id.clone());
        }
        // The unshuffled order is what unshuffling restores, so the new entries
        // are inserted into it too — but positionally, after the current track
        // as found *there*. Copying the shuffled order over it instead would
        // quietly make shuffle a one-way door.
        let at_unshuffled = self
            .current()
            .and_then(|cur| self.unshuffled.iter().position(|x| x == cur))
            .map(|i| i + 1)
            .unwrap_or(self.unshuffled.len());
        for (n, id) in ids.iter().enumerate() {
            self.unshuffled.insert(at_unshuffled + n, id.clone());
        }
        if self.pos.is_none() && !self.items.is_empty() {
            self.pos = Some(0);
        }
    }

    /// Removes one entry, keeping `pos` pointing at the same *track* where it
    /// can. Removing the current track leaves `pos` on whatever slid into its
    /// place, which is what a listener expects: the queue moves up.
    pub fn remove(&mut self, index: usize) {
        if index >= self.items.len() {
            return;
        }
        let removed = self.items.remove(index);
        if let Some(i) = self.unshuffled.iter().position(|x| *x == removed) {
            self.unshuffled.remove(i);
        }
        match self.pos {
            Some(p) if self.items.is_empty() => {
                let _ = p;
                self.pos = None;
            }
            Some(p) if index < p => self.pos = Some(p - 1),
            Some(p) if p >= self.items.len() => self.pos = Some(self.items.len() - 1),
            _ => {}
        }
    }

    pub fn clear(&mut self) {
        self.items.clear();
        self.unshuffled.clear();
        self.pos = None;
    }

    pub fn select(&mut self, index: usize) -> Option<usize> {
        if index < self.items.len() {
            self.pos = Some(index);
            self.pos
        } else {
            None
        }
    }

    /// The index that follows the current one, honouring repeat.
    ///
    /// `Repeat::One` is deliberately *not* handled here: mpv loops the file
    /// itself, and an explicit skip should still move on rather than replay.
    pub fn next_index(&self) -> Option<usize> {
        let p = self.pos?;
        if p + 1 < self.items.len() {
            Some(p + 1)
        } else if self.repeat == Repeat::All && !self.items.is_empty() {
            Some(0)
        } else {
            None
        }
    }

    pub fn prev_index(&self) -> Option<usize> {
        let p = self.pos?;
        if p > 0 {
            Some(p - 1)
        } else if self.repeat == Repeat::All && !self.items.is_empty() {
            Some(self.items.len() - 1)
        } else {
            None
        }
    }

    /// Turns shuffle on or off, keeping the current track playing and its
    /// position consistent.
    pub fn set_shuffle(&mut self, on: bool) {
        if on == self.shuffle {
            return;
        }
        self.shuffle = on;
        if on {
            match self.pos {
                // Move the playing entry to the front by *index* and shuffle
                // the rest in place. Filtering by track id instead would delete
                // every other copy of it — a queue may legitimately hold the
                // same track more than once.
                Some(p) if p < self.items.len() => {
                    self.items.swap(0, p);
                    self.rng.shuffle(&mut self.items[1..]);
                    self.pos = Some(0);
                }
                _ => {
                    self.rng.shuffle(&mut self.items);
                    self.pos = if self.items.is_empty() { None } else { Some(0) };
                }
            }
        } else {
            let current = self.current().cloned();
            self.items = self.unshuffled.clone();
            // With duplicates this lands on the first copy, which plays the
            // same audio — the alternative is tracking identity per slot for
            // no audible gain.
            self.pos = current.and_then(|c| self.items.iter().position(|x| *x == c));
        }
    }

    pub fn toggle_shuffle(&mut self) -> bool {
        self.set_shuffle(!self.shuffle);
        self.shuffle
    }
}

/// xorshift64*. The queue needs an unpredictable-enough order, not a
/// cryptographic one, and this keeps the client dependency-free.
#[derive(Debug)]
struct Rng(u64);

impl Default for Rng {
    fn default() -> Self {
        Rng(0x2545F4914F6CDD1D)
    }
}

impl Rng {
    fn from_clock() -> Self {
        let n = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos() as u64)
            .unwrap_or(0x9E3779B97F4A7C15);
        // A zero state is a fixed point for xorshift, so it must be avoided.
        Rng(n | 1)
    }

    fn next_u64(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.0 = x;
        x.wrapping_mul(0x2545F4914F6CDD1D)
    }

    /// Fisher–Yates.
    fn shuffle<T>(&mut self, items: &mut [T]) {
        if items.len() < 2 {
            return;
        }
        for i in (1..items.len()).rev() {
            let j = (self.next_u64() % (i as u64 + 1)) as usize;
            items.swap(i, j);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ids(n: usize) -> Vec<String> {
        (0..n).map(|i| format!("t{i}")).collect()
    }

    #[test]
    fn set_selects_the_requested_track() {
        let mut q = Queue::new();
        q.set(ids(5), 2);
        assert_eq!(q.pos(), Some(2));
        assert_eq!(q.current().unwrap(), "t2");
    }

    #[test]
    fn set_clamps_an_out_of_range_start() {
        let mut q = Queue::new();
        q.set(ids(3), 99);
        assert_eq!(q.pos(), Some(2));
    }

    #[test]
    fn setting_an_empty_queue_clears_the_position() {
        let mut q = Queue::new();
        q.set(ids(3), 0);
        q.set(vec![], 0);
        assert_eq!(q.pos(), None);
        assert!(q.is_empty());
    }

    #[test]
    fn shuffled_set_still_starts_on_the_chosen_track() {
        let mut q = Queue::new();
        q.set_shuffle(true);
        q.set(ids(50), 7);
        assert_eq!(
            q.current().unwrap(),
            "t7",
            "picking a track must play that track"
        );
        assert_eq!(q.len(), 50, "shuffle must not drop or duplicate entries");
    }

    #[test]
    fn unshuffling_restores_the_original_order() {
        let mut q = Queue::new();
        q.set(ids(20), 0);
        let before = q.items().to_vec();
        q.set_shuffle(true);
        q.set_shuffle(false);
        assert_eq!(q.items(), before.as_slice());
    }

    #[test]
    fn toggling_shuffle_keeps_the_current_track_current() {
        let mut q = Queue::new();
        q.set(ids(30), 11);
        assert_eq!(q.current().unwrap(), "t11");
        q.toggle_shuffle();
        assert_eq!(q.current().unwrap(), "t11");
        q.toggle_shuffle();
        assert_eq!(q.current().unwrap(), "t11");
    }

    #[test]
    fn shuffling_keeps_duplicate_entries() {
        // Regression: filtering the current track out by id deleted every
        // other copy of it. A queue may hold the same track several times.
        let mut q = Queue::new();
        q.set(
            vec![
                "a".into(),
                "dup".into(),
                "b".into(),
                "dup".into(),
                "dup".into(),
            ],
            1,
        );
        assert_eq!(q.current().unwrap(), "dup");
        q.set_shuffle(true);

        assert_eq!(q.len(), 5, "no entry may be dropped");
        assert_eq!(
            q.items().iter().filter(|x| *x == "dup").count(),
            3,
            "all three copies must survive"
        );
        assert_eq!(q.current().unwrap(), "dup");
    }

    #[test]
    fn shuffle_keeps_every_entry_exactly_once() {
        let mut q = Queue::new();
        q.set(ids(100), 0);
        q.set_shuffle(true);
        let mut got = q.items().to_vec();
        got.sort();
        let mut want = ids(100);
        want.sort();
        assert_eq!(got, want);
    }

    #[test]
    fn next_stops_at_the_end_when_repeat_is_off() {
        let mut q = Queue::new();
        q.set(ids(3), 2);
        assert_eq!(q.next_index(), None);
    }

    #[test]
    fn repeat_all_wraps_in_both_directions() {
        let mut q = Queue::new();
        q.set(ids(3), 2);
        q.set_repeat(Repeat::All);
        assert_eq!(q.next_index(), Some(0));
        q.select(0);
        assert_eq!(q.prev_index(), Some(2));
    }

    #[test]
    fn an_explicit_skip_moves_on_even_under_repeat_one() {
        // mpv loops the file for Repeat::One; pressing next must still advance,
        // or the user would be stuck on the track.
        let mut q = Queue::new();
        q.set(ids(3), 0);
        q.set_repeat(Repeat::One);
        assert_eq!(q.next_index(), Some(1));
    }

    #[test]
    fn repeat_cycles_through_all_three_modes() {
        let mut q = Queue::new();
        assert_eq!(q.cycle_repeat(), Repeat::All);
        assert_eq!(q.cycle_repeat(), Repeat::One);
        assert_eq!(q.cycle_repeat(), Repeat::Off);
    }

    #[test]
    fn insert_next_lands_directly_after_the_current_track() {
        let mut q = Queue::new();
        q.set(ids(4), 1);
        q.insert_next(&["x".to_string()]);
        assert_eq!(q.items()[2], "x");
        assert_eq!(q.current().unwrap(), "t1", "playback must not jump");
    }

    #[test]
    fn play_next_while_shuffled_does_not_destroy_the_original_order() {
        // Regression: copying the shuffled list over `unshuffled` made turning
        // shuffle off restore the shuffled order instead of the real one.
        let mut q = Queue::new();
        q.set(ids(10), 0);
        let original = q.items().to_vec();
        q.set_shuffle(true);
        q.insert_next(&["x".to_string()]);
        q.set_shuffle(false);

        let restored = q.items().to_vec();
        let without_x: Vec<String> = restored.iter().filter(|s| *s != "x").cloned().collect();
        assert_eq!(without_x, original, "the original order must come back");
        assert!(
            restored.contains(&"x".to_string()),
            "the inserted track is kept"
        );
    }

    #[test]
    fn insert_next_on_an_empty_queue_starts_it() {
        let mut q = Queue::new();
        q.insert_next(&["x".to_string()]);
        assert_eq!(q.pos(), Some(0));
        assert_eq!(q.current().unwrap(), "x");
    }

    #[test]
    fn append_leaves_the_current_track_alone() {
        let mut q = Queue::new();
        q.set(ids(3), 1);
        q.append(&["z".to_string()]);
        assert_eq!(q.len(), 4);
        assert_eq!(q.current().unwrap(), "t1");
    }

    #[test]
    fn removing_an_earlier_entry_keeps_the_same_track_current() {
        let mut q = Queue::new();
        q.set(ids(5), 3);
        q.remove(1);
        assert_eq!(
            q.current().unwrap(),
            "t3",
            "the current track must not change"
        );
        assert_eq!(q.pos(), Some(2));
    }

    #[test]
    fn removing_the_current_entry_moves_the_queue_up() {
        let mut q = Queue::new();
        q.set(ids(5), 2);
        q.remove(2);
        assert_eq!(q.current().unwrap(), "t3");
    }

    #[test]
    fn removing_the_last_entry_clamps_the_position() {
        let mut q = Queue::new();
        q.set(ids(3), 2);
        q.remove(2);
        assert_eq!(q.pos(), Some(1));
        assert_eq!(q.current().unwrap(), "t1");
    }

    #[test]
    fn removing_everything_clears_the_position() {
        let mut q = Queue::new();
        q.set(ids(1), 0);
        q.remove(0);
        assert_eq!(q.pos(), None);
        assert!(q.is_empty());
    }

    #[test]
    fn removing_out_of_range_is_a_no_op() {
        let mut q = Queue::new();
        q.set(ids(2), 0);
        q.remove(99);
        assert_eq!(q.len(), 2);
    }

    #[test]
    fn rng_shuffle_is_a_permutation() {
        let mut rng = Rng(12345);
        let mut v: Vec<u32> = (0..64).collect();
        rng.shuffle(&mut v);
        let mut sorted = v.clone();
        sorted.sort();
        assert_eq!(sorted, (0..64).collect::<Vec<u32>>());
    }

    #[test]
    fn rng_does_not_get_stuck_on_one_order() {
        let mut a: Vec<u32> = (0..32).collect();
        let mut b = a.clone();
        Rng(1).shuffle(&mut a);
        Rng(999_983).shuffle(&mut b);
        assert_ne!(a, b, "different seeds must give different orders");
    }
}
