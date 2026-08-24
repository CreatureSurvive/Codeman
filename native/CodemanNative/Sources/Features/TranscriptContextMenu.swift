import SwiftUI
import UIKit

/// Long-press actions on a message, matched to what that message can actually still do.
///
/// The three states are genuinely different: a queued prompt has not run and can be recalled,
/// steered past or abandoned; a turn in flight can only be stopped; and finished text can only be
/// copied. Offering "stop" on a finished message, or "steer" on one that already ran, would be
/// offering the user a control that does nothing.
struct TranscriptMessageMenu: ViewModifier {
    enum State {
        /// Delivered to the CLI and waiting behind the current turn.
        case queued
        /// The agent is working on this now.
        case processing
        /// Already in the transcript; nothing left to control.
        case settled
    }

    let state: State
    let text: String
    let sessionID: String
    /// Forget the local echo. Only meaningful while queued.
    var onDismiss: (() -> Void)?

    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.contextMenu {
            if !text.isEmpty {
                Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = text }
            }

            switch state {
            case .queued:
                Divider()
                // Claude Code binds Up to "press up to edit queued messages", so this pulls the
                // prompt out of the queue and back into its composer.
                Button("Edit", systemImage: "pencil") { send(SessionControl.recallPrevious) }

                // Steering IS interrupting: ending the current turn is what lets the queued prompt
                // start, which is the whole point of queueing something mid-turn.
                Button("Steer", systemImage: "arrow.turn.up.right") { send(SessionControl.interrupt) }

                Divider()
                // ⚠️ Honest wording. This drops the local echo; it cannot reach into Claude Code's
                // queue and delete an entry, and there is no key sequence that does so reliably.
                // "Edit" is the way to take a prompt back out of the queue.
                Button("Dismiss card", systemImage: "eye.slash", role: .destructive) { onDismiss?() }

            case .processing:
                Divider()
                Button("Stop", systemImage: "stop.fill", role: .destructive) {
                    send(SessionControl.interrupt)
                }

            case .settled:
                EmptyView()
            }
        }
    }

    private func send(_ sequence: String) {
        guard let api = model.apiClient else { return }
        Task {
            _ = try? await api.sendInput(
                SessionInputRequest(input: sequence),
                id: sessionID,
                scope: model.scope
            )
            model.transcriptFeeds[sessionID]?.refresh()
        }
    }
}

extension View {
    /// Attach the long-press menu appropriate to a message's state.
    func transcriptMessageMenu(
        state: TranscriptMessageMenu.State,
        text: String,
        sessionID: String,
        onDismiss: (() -> Void)? = nil
    ) -> some View {
        modifier(TranscriptMessageMenu(state: state, text: text, sessionID: sessionID, onDismiss: onDismiss))
    }
}
