import Foundation

/// Control keys sent to a running CLI, as the bytes a hardware keyboard produces.
///
/// ⚠️ These go through `POST /api/sessions/:id/input`, the same path Codeman's own auto-resume
/// uses (`session-auto-ops.ts` writes `\u{1B}` to dismiss a limit dialog). Sending the real control
/// byte means the CLI cannot tell the difference between this and a keypress.
enum SessionControl {
    /// Interrupt the current turn. Claude Code's own footer says "esc to interrupt".
    ///
    /// ⚠️ Esc does NOT clear typed text — measured on a live pane, text in the composer survived
    /// it. It aborts work in progress, which is what makes it both "stop" and "steer": stopping the
    /// current turn is precisely what lets a queued prompt start.
    static let interrupt = "\u{1B}"

    /// Up arrow. Claude Code binds it to "press up to edit queued messages", so this recalls the
    /// most recent queued prompt into its composer.
    static let recallPrevious = "\u{1B}[A"
}
