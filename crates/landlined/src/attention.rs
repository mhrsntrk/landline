//! Spotting a program asking for its user, in the PTY output stream.
//!
//! Two signals count, both of them things a terminal program sends on purpose
//! to get a person's attention:
//!
//! - a bare BEL (0x07) outside any escape sequence, the terminal bell;
//! - a desktop notification escape: OSC 9 (`ESC ] 9 ; text BEL`, iTerm2 and
//!   others), OSC 777 (`ESC ] 777 ; notify ; title ; body BEL`, urxvt and
//!   others) or OSC 99 (kitty).
//!
//! The trap is that BEL is also the most common *terminator* of an OSC, and
//! shells and tmux send OSC 0/2 window-title updates at every prompt. Counting
//! every 0x07 would light the badge on every `ls`. So this is a small state
//! machine that knows when it is inside an OSC, and it keeps that state across
//! chunk boundaries, because the pump's chunks are cut wherever the PTY read
//! happened to return.
//!
//! OSC 9 has one squatter: `9;4;...` is ConEmu's progress report, which is not
//! a request for anything, so it is ignored.
//!
//! What an agent actually sends depends on its own settings. Claude Code
//! 2.1.326 at its defaults sent neither signal in a plain xterm-256color PTY,
//! so a badge only appears for programs configured to ring the bell (for
//! Claude Code, `"preferredNotifChannel": "terminal_bell"` in its
//! `settings.json`). Inside tmux only the BEL arrives: tmux forwards a pane's
//! bell to its client but swallows OSC notifications.

/// The most of an OSC payload kept. Longer ones are skipped, not truncated:
/// a notification body that size is not one line on a phone anyway, and the
/// cap is what bounds memory for a stream that never terminates its OSC.
const MAX_OSC: usize = 512;
/// The most characters of notification text kept for display.
const MAX_TEXT: usize = 140;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Signal {
    Bell,
    Notify(String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum State {
    Ground,
    Esc,
    Osc,
    /// Saw ESC inside an OSC: either the start of the ST terminator
    /// (`ESC \`), or the OSC was abandoned for a new sequence.
    OscEsc,
}

pub struct Scanner {
    state: State,
    osc: Vec<u8>,
    overflow: bool,
}

impl Default for Scanner {
    fn default() -> Self {
        Self::new()
    }
}

impl Scanner {
    pub fn new() -> Self {
        Scanner {
            state: State::Ground,
            osc: Vec::new(),
            overflow: false,
        }
    }

    /// Scans one chunk. Returns the strongest signal in it: a notification
    /// with text wins over a bare bell, and a later one wins over an earlier
    /// one of the same kind.
    pub fn feed(&mut self, bytes: &[u8]) -> Option<Signal> {
        let mut found = None;
        for &byte in bytes {
            if let Some(signal) = self.step(byte) {
                found = match (found, signal) {
                    (Some(Signal::Notify(text)), Signal::Bell) => Some(Signal::Notify(text)),
                    (_, signal) => Some(signal),
                };
            }
        }
        found
    }

    fn step(&mut self, byte: u8) -> Option<Signal> {
        match self.state {
            State::Ground => match byte {
                0x07 => return Some(Signal::Bell),
                0x1b => self.state = State::Esc,
                _ => {}
            },
            State::Esc => match byte {
                b']' => {
                    self.osc.clear();
                    self.overflow = false;
                    self.state = State::Osc;
                }
                0x1b => {}
                _ => self.state = State::Ground,
            },
            State::Osc => match byte {
                0x07 => {
                    self.state = State::Ground;
                    return self.finish();
                }
                0x1b => self.state = State::OscEsc,
                // CAN and SUB abort any sequence.
                0x18 | 0x1a => self.state = State::Ground,
                _ => {
                    if self.osc.len() < MAX_OSC {
                        self.osc.push(byte);
                    } else {
                        self.overflow = true;
                    }
                }
            },
            State::OscEsc => {
                if byte == b'\\' {
                    self.state = State::Ground;
                    return self.finish();
                }
                // Not ST: the OSC was abandoned and this ESC starts something
                // else, so read this byte as the one after an ESC.
                self.state = State::Esc;
                return self.step(byte);
            }
        }
        None
    }

    fn finish(&mut self) -> Option<Signal> {
        if self.overflow {
            return None;
        }
        let payload = String::from_utf8_lossy(&self.osc).into_owned();
        let text = if let Some(rest) = payload.strip_prefix("9;") {
            if rest.starts_with("4;") {
                return None;
            }
            rest.to_string()
        } else if let Some(rest) = payload.strip_prefix("777;notify;") {
            match rest.split_once(';') {
                Some((title, body)) if !title.is_empty() && !body.is_empty() => {
                    format!("{title}: {body}")
                }
                Some((title, body)) => format!("{title}{body}"),
                None => rest.to_string(),
            }
        } else {
            // kitty: `99;metadata;body`. Anything else is not a notification.
            let rest = payload.strip_prefix("99;")?;
            rest.split_once(';')
                .map(|(_, body)| body)
                .unwrap_or("")
                .to_string()
        };
        Some(Signal::Notify(clean(&text)))
    }
}

/// One printable line, at most `MAX_TEXT` characters: whatever a program put
/// in its notification ends up in a phone's row, so control characters go.
pub fn clean(text: &str) -> String {
    let flat: String = text
        .chars()
        .map(|c| if c.is_control() { ' ' } else { c })
        .collect();
    let squashed = flat.split_whitespace().collect::<Vec<_>>().join(" ");
    squashed.chars().take(MAX_TEXT).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scan(chunks: &[&[u8]]) -> Vec<Signal> {
        let mut scanner = Scanner::new();
        chunks.iter().filter_map(|c| scanner.feed(c)).collect()
    }

    #[test]
    fn bare_bell_counts() {
        assert_eq!(scan(&[b"done\x07\r\n"]), vec![Signal::Bell]);
    }

    #[test]
    fn title_updates_terminated_by_bel_do_not() {
        assert!(scan(&[b"\x1b]0;user@host: ~\x07$ ", b"\x1b]2;vim\x07"]).is_empty());
    }

    #[test]
    fn title_split_across_chunks_does_not() {
        assert!(scan(&[b"\x1b]0;long ti", b"tle here", b"\x07prompt"]).is_empty());
    }

    #[test]
    fn st_terminated_title_does_not() {
        assert!(scan(&[b"\x1b]0;title\x1b\\ok"]).is_empty());
    }

    #[test]
    fn osc9_notification_with_text() {
        assert_eq!(
            scan(&[b"\x1b]9;Claude needs your permission\x07"]),
            vec![Signal::Notify("Claude needs your permission".into())]
        );
    }

    #[test]
    fn osc9_split_and_st_terminated() {
        assert_eq!(
            scan(&[b"\x1b]9;Build ", b"finished\x1b", b"\\"]),
            vec![Signal::Notify("Build finished".into())]
        );
    }

    #[test]
    fn osc9_progress_is_not_a_notification() {
        assert!(scan(&[b"\x1b]9;4;1;50\x07"]).is_empty());
    }

    #[test]
    fn osc777_title_and_body() {
        assert_eq!(
            scan(&[b"\x1b]777;notify;Codex;Approve command?\x07"]),
            vec![Signal::Notify("Codex: Approve command?".into())]
        );
    }

    #[test]
    fn notify_beats_bell_in_one_chunk() {
        assert_eq!(
            scan(&[b"\x07\x1b]9;waiting\x07"]),
            vec![Signal::Notify("waiting".into())]
        );
    }

    #[test]
    fn bell_after_a_csi_sequence_counts() {
        assert_eq!(scan(&[b"\x1b[1;31mred\x1b[0m\x07"]), vec![Signal::Bell]);
    }

    #[test]
    fn oversized_osc_is_skipped_and_scanning_recovers() {
        let mut big = b"\x1b]9;".to_vec();
        big.extend(std::iter::repeat_n(b'x', MAX_OSC + 10));
        big.push(0x07);
        assert!(scan(&[&big]).is_empty());
        let mut scanner = Scanner::new();
        scanner.feed(&big);
        assert_eq!(scanner.feed(b"\x07"), Some(Signal::Bell));
    }

    #[test]
    fn abandoned_osc_then_new_sequence() {
        assert_eq!(
            scan(&[b"\x1b]0;half\x1b]9;real\x07"]),
            vec![Signal::Notify("real".into())]
        );
    }

    #[test]
    fn text_is_cleaned_and_capped() {
        assert_eq!(clean("a\tb\r\n  c"), "a b c");
        assert_eq!(clean(&"y".repeat(500)).chars().count(), MAX_TEXT);
    }
}
