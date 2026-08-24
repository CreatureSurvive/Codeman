import Foundation

/// Claude Code's own "working" line, read off the pane.
///
/// ⚠️ Parsed rather than invented. The CLI already prints exactly what a progress indicator should
/// say — `✻ Actualizing… (13m 23s · ↓ 47.5k tokens)` — with a randomised gerund, the elapsed time
/// and the token count. Showing a generic spinner instead would discard live information the user
/// can already see in the terminal.
///
/// ⚠️ The glyph is NOT a fixed character: the CLI animates it through `· ✢ ✳ ∗ ✻ ✽`, and the
/// finished line (`✻ Cooked for 2m 49s`) reuses the same glyph — so neither the glyph nor a keyword
/// list identifies "still working". What does is the gerund's trailing ellipsis.
enum WorkingStatusReader {
    struct Status: Equatable, Sendable {
        /// "Actualizing", "Channelling" — whatever the CLI chose this turn.
        var verb: String
        /// "13m 23s", when the line carries it.
        var elapsed: String?
        /// "↓ 47.5k tokens", when the line carries it.
        var tokens: String?

        /// "Actualizing… · 13m 23s"
        var label: String {
            [verb + "…", elapsed].compactMap { $0 }.joined(separator: " · ")
        }
    }

    /// Glyphs the CLI cycles through at the head of the line.
    private static let glyphs: Set<Character> = ["·", "✢", "✳", "∗", "✻", "✽", "✶", "✻"]

    /// `Verb… (13m 23s · ↓ 47.5k tokens · thought for 11s)`
    private static let pattern = try? NSRegularExpression(
        pattern: #"([A-Za-z][A-Za-z'-]*)…\s*(?:\(([^)]*)\))?"#
    )

    /// Find the current working line, or `nil` when the pane shows no turn in progress.
    ///
    /// Scans from the END because the footer is redrawn at the bottom; an older frame higher in the
    /// buffer would report a turn that has since finished.
    static func parse(_ capture: String) -> Status? {
        let plain = PermissionModeReader.stripANSI(capture)
        for line in plain.components(separatedBy: "\n").reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let first = trimmed.first, glyphs.contains(first) else { continue }
            // A finished line reads "Cooked for 2m 49s" — no ellipsis, so it is not a match.
            guard trimmed.contains("…") else { continue }
            guard let pattern else { continue }

            let range = NSRange(trimmed.startIndex..., in: trimmed)
            guard let match = pattern.firstMatch(in: trimmed, range: range),
                  let verbRange = Range(match.range(at: 1), in: trimmed)
            else { continue }

            let verb = String(trimmed[verbRange])
            var elapsed: String?
            var tokens: String?
            if match.numberOfRanges > 2, let detailRange = Range(match.range(at: 2), in: trimmed) {
                for part in trimmed[detailRange].components(separatedBy: "·") {
                    let piece = part.trimmingCharacters(in: .whitespaces)
                    if piece.contains("token") { tokens = piece }
                    // "13m 23s" / "4s" — a duration, not "thought for 11s".
                    else if elapsed == nil, piece.range(of: #"^\d+[hms]"#, options: .regularExpression) != nil {
                        elapsed = piece
                    }
                }
            }
            return Status(verb: verb, elapsed: elapsed, tokens: tokens)
        }
        return nil
    }
}
