import GhosttyTerminal
import Observation
import SwiftUI
import UIKit

/// Text the user long-pressed, handed over for selection in a real text view.
///
/// A Ghostty grid is drawn with Metal, so it cannot host UIKit's selection handles, magnifier or
/// edit menu. The package's design is to report the gesture instead: the host gets a snapshot of
/// the viewport and a suggested range, and presents somewhere the user can actually select.
struct TerminalSelectionPayload: Identifiable, Equatable {
    let id = UUID()
    /// Viewport text, lines separated by `\n`.
    let text: String
    /// Suggested pre-selection in UTF-16 units, or `nil` to select everything.
    let anchorRange: NSRange?
}

/// A handle to the live `UITerminalView` for the few things that are genuinely imperative.
///
/// SwiftUI has no way to ask a representable's view to do something on demand, and the alternative
/// — encoding "paste now" as a piece of state — makes a one-shot action into something the view
/// must remember it has already done. A proxy the representable fills in is smaller and honest
/// about being a reference to a UIKit object.
@MainActor
@Observable
final class TerminalSurfaceProxy {
    @ObservationIgnored weak var view: AccessibleTerminalView?

    /// Set when the user long-presses the grid; the pane presents it and clears it.
    var pendingSelection: TerminalSelectionPayload?

    var canPaste: Bool { UIPasteboard.general.hasStrings }

    /// Pastes through the terminal's own action rather than by injecting keystrokes.
    ///
    /// ⚠️ `UITerminalView.paste(_:)` routes clipboard text to `sendText`, which wraps it for
    /// bracketed-paste mode (2004). Sending the same text as key input — which is what the generic
    /// `insertText` path does — strips those markers, and a pasted multi-line command then runs
    /// line by line instead of landing in the shell's edit buffer.
    func paste() {
        guard let view else { return }
        if !view.isFirstResponder { _ = view.acquireProgrammaticFocus() }
        view.paste(nil)
    }

    /// The whole visible grid, for "Select Text" invoked from a menu rather than by long-press.
    func viewportText() -> String? {
        view?.terminalSession?.readViewportText()
    }
}
