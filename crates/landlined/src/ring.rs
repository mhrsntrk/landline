use std::collections::VecDeque;

/// A fixed-capacity byte ring buffer.
///
/// Bytes are appended at the back; once the buffer holds more than
/// `capacity` bytes, the oldest bytes are dropped from the front so that
/// only the most recent `capacity` bytes are retained.
pub struct Ring {
    buf: VecDeque<u8>,
    capacity: usize,
}

impl Ring {
    /// Creates a new ring buffer that retains at most `capacity` bytes.
    pub fn new(capacity: usize) -> Self {
        Ring {
            buf: VecDeque::with_capacity(capacity),
            capacity,
        }
    }

    /// Appends `data` to the buffer, keeping only the last `capacity` bytes
    /// overall. If `data` alone is larger than `capacity`, only its tail is
    /// kept.
    pub fn push(&mut self, data: &[u8]) {
        if self.capacity == 0 {
            return;
        }

        // If the incoming slice alone exceeds capacity, only its tail can
        // possibly survive, so drop the rest of the buffer and only copy
        // that tail in.
        let data = if data.len() > self.capacity {
            &data[data.len() - self.capacity..]
        } else {
            data
        };

        self.buf.extend(data.iter().copied());

        while self.buf.len() > self.capacity {
            self.buf.pop_front();
        }
    }

    /// Returns a contiguous copy of the buffered bytes, oldest first.
    pub fn snapshot(&self) -> Vec<u8> {
        self.buf.iter().copied().collect()
    }

    /// Returns the number of bytes currently buffered.
    pub fn len(&self) -> usize {
        self.buf.len()
    }

    /// Returns `true` if no bytes are currently buffered.
    pub fn is_empty(&self) -> bool {
        self.buf.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fill_under_capacity() {
        let mut ring = Ring::new(10);
        ring.push(b"abc");
        assert_eq!(ring.len(), 3);
        assert!(!ring.is_empty());
        assert_eq!(ring.snapshot(), b"abc".to_vec());
    }

    #[test]
    fn overflow_keeps_last_capacity_bytes_in_order() {
        let mut ring = Ring::new(5);
        ring.push(b"abcdefgh"); // 8 bytes pushed in one go, capacity 5
        assert_eq!(ring.len(), 5);
        assert_eq!(ring.snapshot(), b"defgh".to_vec());
    }

    #[test]
    fn overflow_across_multiple_pushes() {
        let mut ring = Ring::new(5);
        ring.push(b"abc");
        ring.push(b"defgh");
        assert_eq!(ring.len(), 5);
        assert_eq!(ring.snapshot(), b"defgh".to_vec());
    }

    #[test]
    fn single_push_larger_than_capacity_keeps_tail() {
        let mut ring = Ring::new(4);
        ring.push(b"0123456789");
        assert_eq!(ring.len(), 4);
        assert_eq!(ring.snapshot(), b"6789".to_vec());
    }

    #[test]
    fn snapshot_after_multiple_wraps_is_contiguous_and_correct() {
        let mut ring = Ring::new(6);
        for chunk in [
            &b"aa"[..],
            &b"bb"[..],
            &b"cc"[..],
            &b"dd"[..],
            &b"ee"[..],
            &b"ff"[..],
        ] {
            ring.push(chunk);
        }
        // Pushed: aa bb cc dd ee ff -> last 6 bytes are "ddeeff"
        assert_eq!(ring.len(), 6);
        assert_eq!(ring.snapshot(), b"ddeeff".to_vec());
    }

    #[test]
    fn capacity_zero_is_always_empty() {
        let mut ring = Ring::new(0);
        assert!(ring.is_empty());
        ring.push(b"anything");
        assert!(ring.is_empty());
        assert_eq!(ring.len(), 0);
        assert_eq!(ring.snapshot(), Vec::<u8>::new());
    }

    #[test]
    fn len_and_is_empty_track_state() {
        let mut ring = Ring::new(3);
        assert!(ring.is_empty());
        assert_eq!(ring.len(), 0);

        ring.push(b"a");
        assert!(!ring.is_empty());
        assert_eq!(ring.len(), 1);

        ring.push(b"bc");
        assert_eq!(ring.len(), 3);

        ring.push(b"d");
        assert_eq!(ring.len(), 3);
        assert_eq!(ring.snapshot(), b"bcd".to_vec());
    }
}
