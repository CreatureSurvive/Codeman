import SwiftUI

/// "✶ Clauding…" — the live turn indicator.
///
/// The text is the CLI's own status line rather than a fixed string, so it carries the verb, the
/// elapsed time and the token count the terminal is already showing. When the pane cannot be read
/// it degrades to a plain "Working…" rather than inventing detail.
struct WorkingIndicatorView: View {
    var status: WorkingStatusReader.Status?

    /// The CLI animates its glyph; matching that keeps the two surfaces recognisably the same
    /// thing rather than one spinning and one pulsing.
    private static let glyphs = ["✶", "✻", "✳", "∗", "✢", "·"]
    @State private var frame = 0

    private let tick = Timer.publish(every: 0.12, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 8) {
            Text(Self.glyphs[frame % Self.glyphs.count])
                .font(.callout)
                .foregroundStyle(.orange)
                // Fixed width: the glyphs have different advances, and without this the label
                // shifts sideways on every frame.
                .frame(width: 16)

            Text(status?.label ?? "Working…")
                .font(.callout)
                .foregroundStyle(.orange)

            if let tokens = status?.tokens {
                Text(tokens)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .onReceive(tick) { _ in frame &+= 1 }
        .accessibilityIdentifier("transcript.working")
        .accessibilityLabel(status?.label ?? "Working")
    }
}
