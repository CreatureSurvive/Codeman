import Foundation

/// Whether a freshly fetched capture may replace what is already on the grid.
///
/// Applying a snapshot is destructive: the pane is cleared (`\u{1B}[3J\u{1B}[H\u{1B}[2J`) before the
/// capture is written, because a full-history capture appended below the history it already
/// contains would duplicate everything. So a capture that comes back *thinner* than what is on
/// screen does not merely fail to help — it deletes the scrollback the user was reading.
///
/// ⚠️ **`GET …/terminal?full=1` is not guaranteed to return the full history.** Measured against a
/// live server: the same pane, seconds apart, answered once with the whole 4000-line scrollback and
/// once with a 31-byte capture — both labelled `source: "mux-full-history"`. The server falls back
/// when its `capture-pane` cannot be served, and under contention that happens often enough to be
/// the difference between a session opening full and opening empty.
///
/// The web client has the same rule for the same reason (`_replayWouldShrinkBuffer()` in app.js),
/// where a repaint-mode CLI keeps no tmux history and its capture is a single frame. Porting the
/// rule here is what makes a re-pull safe to do freely — on reattach, on foreground, on a grid
/// measurement — instead of a gamble each time.
enum SnapshotReplacementPolicy {
    /// A capture must retain at least this fraction of what is on screen to replace it. Well below
    /// 1 so that ordinary churn — a cleared screen, a TUI redrawing smaller — still applies, while
    /// a collapse to a fraction of the content does not.
    static let minimumRetainedFraction = 0.5

    /// - Parameters:
    ///   - renderedBytes: size of the capture currently on the grid, `0` if none.
    ///   - incomingBytes: size of the capture just fetched.
    static func shouldApply(renderedBytes: Int, incomingBytes: Int) -> Bool {
        // Nothing on screen: anything is an improvement, including nothing.
        guard renderedBytes > 0 else { return true }
        // Growth or parity is always fine.
        guard incomingBytes < renderedBytes else { return true }
        return Double(incomingBytes) >= Double(renderedBytes) * minimumRetainedFraction
    }
}
