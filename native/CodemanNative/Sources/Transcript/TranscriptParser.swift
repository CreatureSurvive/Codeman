import Foundation

/// Accumulates a session's transcript blocks off the main actor.
///
/// The server sends the tail of the conversation on every fetch, not a delta, so the same blocks
/// arrive again and again. This owns the merge: dedupe by the server's stable block id, keep
/// server order, and let a later copy of a block *replace* an earlier one — that is how a tool
/// call stops saying "running" once its result row is written.
///
/// An `actor` because a transcript is large (measured: ~180 KB of JSON per fetch, hundreds of
/// blocks) and decoding plus merging it on the main actor would drop frames while the user is
/// scrolling. Views read an immutable snapshot.
actor TranscriptParser {
    /// Insertion-ordered blocks, oldest first.
    private var order: [String] = []
    private var byID: [String: TranscriptBlock] = [:]

    /// The last thing the server said about availability, so the view can explain an empty state
    /// ("shell sessions write no Claude transcript") instead of just showing nothing.
    private(set) var availability: Availability = .unknown

    private(set) var truncated = false
    private(set) var totalBlocks = 0

    enum Availability: Equatable, Sendable {
        case unknown
        case available
        /// The session type or state has no transcript; carries the server's reason.
        case unavailable(String)
        /// The server has no transcript endpoint at all — it predates this feature.
        ///
        /// ⚠️ Distinct from `unavailable` on purpose. Both end in an empty list, but one means
        /// "this session has nothing to show" and the other means "this Codeman cannot answer".
        /// Collapsing them is what made an old server report a long conversation as empty.
        case unsupported
    }

    struct Snapshot: Sendable, Equatable {
        var blocks: [TranscriptBlock]
        var availability: Availability
        /// True when older blocks exist on the server but were not sent.
        var truncated: Bool
        var totalBlocks: Int
    }

    /// Merge a fetched payload.
    ///
    /// ⚠️ Blocks are **replaced in place**, never appended blindly. A tool call is emitted the
    /// moment the agent invokes it and re-emitted with its result once that lands, under the same
    /// id; appending would show the same command twice, once permanently stuck at "running".
    ///
    /// - Returns: the merged snapshot, so the caller does not need a second hop to read it.
    /// - Parameter olderPage: true when this is a page read from ABOVE what is already held, so
    ///   its blocks belong at the front. A page fetched while scrolling up would otherwise be
    ///   appended and the conversation would read out of order.
    @discardableResult
    func ingest(_ response: TranscriptResponse, olderPage: Bool = false) -> Snapshot {
        // An older page says nothing about live availability, and letting it overwrite the flags
        // would report the tail as truncated based on a historical window.
        if !olderPage {
            availability = response.available ? .available : .unavailable(response.reason ?? "No transcript available")
            truncated = response.truncated
            totalBlocks = response.totalBlocks ?? response.blocks.count
        }

        if olderPage {
            // Preserve the page's own order while placing all of it before what is already held.
            let fresh = response.blocks.filter { byID[$0.id] == nil }
            for block in response.blocks { byID[block.id] = block }
            order.insert(contentsOf: fresh.map(\.id), at: 0)
        } else {
            // ⚠️ Accumulate; NEVER take the response as the whole conversation. A poll reads a
            // fixed-size window of the END of the transcript, and that window slides forward as
            // the file grows — so a block present in one poll can be absent from the next without
            // having been deleted. Replacing the list with each response is what made user prompts
            // vanish from the middle of a live conversation.
            for block in response.blocks {
                if byID.updateValue(block, forKey: block.id) == nil {
                    order.append(block.id)
                }
            }
        }
        return snapshot()
    }

    /// Records that the server does not implement the endpoint, without touching held blocks.
    func markUnsupported() {
        availability = .unsupported
    }

    /// Drop everything. Used when the session is switched or `/clear` starts a new conversation —
    /// the ids of the old thread are not wrong, they simply belong to a conversation that is gone.
    func reset() {
        order.removeAll()
        byID.removeAll()
        availability = .unknown
        truncated = false
        totalBlocks = 0
    }

    func snapshot() -> Snapshot {
        Snapshot(
            blocks: order.compactMap { byID[$0] },
            availability: availability,
            truncated: truncated,
            totalBlocks: totalBlocks
        )
    }

    /// Id of the newest block, for scroll-to-bottom without re-reading the whole array.
    var lastBlockID: String? { order.last }
}
