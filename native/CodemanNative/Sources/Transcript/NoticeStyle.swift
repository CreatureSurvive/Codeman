import SwiftUI

/// Agent prose that is really an error or a warning.
///
/// ⚠️ Detected from the text, because the transcript does not mark it. Claude Code writes a limit
/// notice or a tool failure as an ordinary assistant/text block — there is no `kind: "error"` on
/// the wire — so rendering it as plain prose buries the one message the user most needs to see.
///
/// Deliberately narrow: it matches the shapes these notices actually take, not any sentence
/// containing the word "error". A false positive would paint normal discussion of an error red,
/// which is worse than missing one.
enum NoticeStyle: Equatable, Sendable {
    case error
    case warning

    var tint: Color {
        switch self {
        case .error: return .red
        case .warning: return .orange
        }
    }

    var symbolName: String {
        switch self {
        case .error: return "exclamationmark.triangle.fill"
        case .warning: return "exclamationmark.circle.fill"
        }
    }

    /// Leading markers Claude Code uses for its own notices.
    private static let errorPrefixes = [
        "you've hit your", "you have hit your", "credit balance is too low",
        "api error", "error:", "failed:", "request failed", "rate limit",
    ]

    private static let warningPrefixes = [
        "warning:", "note: ", "caution:", "deprecated:",
    ]

    /// Classify a block of prose, or `nil` when it is ordinary text.
    ///
    /// Only the FIRST line is examined: these notices lead with their marker, whereas a paragraph
    /// that merely mentions an error mentions it mid-sentence.
    static func classify(_ text: String) -> NoticeStyle? {
        guard let first = text
            .components(separatedBy: .newlines)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        else { return nil }

        let line = first.trimmingCharacters(in: .whitespaces).lowercased()
        if errorPrefixes.contains(where: line.hasPrefix) { return .error }
        if warningPrefixes.contains(where: line.hasPrefix) { return .warning }
        // A usage-limit notice can lead with the limit itself rather than "you've hit".
        if line.contains("spend limit") || line.contains("usage limit") { return .error }
        return nil
    }
}

/// A tinted callout for an error or warning message.
struct NoticeBlockView: View {
    let style: NoticeStyle
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: style.symbolName)
                .font(.callout)
                .foregroundStyle(style.tint)

            MarkdownText(text: text)
                .foregroundStyle(style.tint)

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(style.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(style.tint.opacity(0.35), lineWidth: 1)
        }
        .accessibilityIdentifier("transcript.notice")
    }
}
