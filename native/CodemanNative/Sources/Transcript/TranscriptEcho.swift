import Foundation

/// Reconciles locally-echoed sends against what the server reports.
///
/// Pure and separate because the rule is not obvious: a pending send is resolved by MATCHING TEXT,
/// not by elapsed time. The transcript is Claude Code's own log, so a prompt appears only when the
/// CLI writes it — and when the agent is mid-turn the CLI queues the prompt, which can be minutes.
/// Expiring a pending echo on a timer would make a queued message vanish while it is still waiting
/// to be picked up.
enum TranscriptEcho {
    struct Result: Equatable {
        var blocks: [TranscriptBlock]
        var stillPending: [TranscriptFeed.PendingSend]
    }

    static func merge(server: [TranscriptBlock], pending: [TranscriptFeed.PendingSend]) -> Result {
        let realUserText = Set(
            server.compactMap { block -> String? in
                guard case .user(let user) = block else { return nil }
                let trimmed = user.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
        )

        // ⚠️ Only the FIRST unmatched echo of a given text resolves. Sending the same message twice
        // is legitimate, and clearing both against one real entry would drop a message the user
        // can still see nothing of.
        var unresolved: [TranscriptFeed.PendingSend] = []
        var consumed: Set<String> = []
        for send in pending {
            if realUserText.contains(send.text), !consumed.contains(send.text) {
                consumed.insert(send.text)
                continue
            }
            unresolved.append(send)
        }

        let echoed: [TranscriptBlock] = unresolved.map { send in
            .user(.init(id: send.id, timestamp: send.sentAt, text: send.text, truncated: false, images: []))
        }
        return Result(blocks: server + echoed, stillPending: unresolved)
    }
}
