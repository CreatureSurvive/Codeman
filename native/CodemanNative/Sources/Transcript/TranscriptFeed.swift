import Foundation
import Observation

/// Keeps one session's transcript current for the view.
///
/// **Why polling and not a stream.** Codeman's transcript SSE events (`transcript:tool_start`,
/// `tool_end`, `complete`) are *signals* — they carry a tool name and an error flag, never block
/// content. There is no server-side stream of transcript blocks to subscribe to, so those events
/// are used for what they can honestly do: tell us the file changed, and trigger a fetch. Between
/// signals a slow heartbeat covers the parts of a turn that raise no event at all (prose arriving
/// mid-turn). Making up a delta protocol on top of signal events would be guessing at content.
@MainActor
@Observable
final class TranscriptFeed {
    private(set) var blocks: [TranscriptBlock] = []
    private(set) var availability: TranscriptParser.Availability = .unknown
    private(set) var truncated = false
    private(set) var totalBlocks = 0
    private(set) var isLoading = false
    /// True while a page above the current window is being fetched.
    private(set) var isLoadingOlder = false
    /// False once paging has reached the beginning of the transcript.
    private(set) var canLoadOlder = false
    /// Set when a fetch fails. The last good blocks stay on screen underneath it.
    private(set) var loadError: String?

    /// Id of the newest block, for `ScrollViewReader`.
    var lastBlockID: String? { blocks.last?.id }

    /// A message sent from the composer that has not yet appeared in the transcript.
    ///
    /// ⚠️ The transcript is Claude Code's own log, so a sent prompt only appears once the CLI
    /// writes it — and if the agent is mid-turn the CLI QUEUES it, which can be a long time. With
    /// no local echo the message simply looked lost. Echoing it keeps the send visible and, while
    /// it stays pending, honestly says it has not been picked up yet.
    struct PendingSend: Identifiable, Sendable, Equatable {
        let id: String
        let text: String
        let sentAt: Date

        init(text: String) {
            // Prefixed so it can never collide with a server block id.
            id = "pending:\(UUID().uuidString)"
            self.text = text
            sentAt = Date()
        }
    }

    /// Re-run echo reconciliation against what is already held.
    ///
    /// ⚠️ Needed because reconciliation used to happen ONLY inside a successful ingest. A dropped
    /// poll, or a refresh coalesced away while another was in flight, left an echo on screen whose
    /// real entry had already arrived — which is the "stays pinned even after processing starts"
    /// symptom. Cheap and idempotent, so it can run on every tick.
    func reconcilePending() {
        guard !pendingSends.isEmpty else { return }
        rebuildBlocks()
    }

    /// Echo a just-sent message and chase it with a short burst of refreshes.
    func noteSent(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pendingSends.append(PendingSend(text: trimmed))
        rebuildBlocks()
        lastChangeAt = Date()

        // ⚠️ One immediate refresh is not enough: the CLI has to receive the keystrokes and write
        // the entry, which takes longer than the round trip. Chase it instead of waiting for the
        // next poll.
        burstTask?.cancel()
        burstTask = Task { [weak self] in
            for delay in [Duration.milliseconds(400), .milliseconds(1200), .seconds(3)] {
                try? await Task.sleep(for: delay)
                guard let self, !Task.isCancelled else { return }
                self.refresh()
            }
        }
    }

    /// Blocks the server knows about, plus any local echo still waiting.
    private var serverBlocks: [TranscriptBlock] = []

    private func rebuildBlocks() {
        let merged = TranscriptEcho.merge(server: serverBlocks, pending: pendingSends)
        pendingSends = merged.stillPending
        blocks = merged.blocks
    }

    /// True while a message is echoed but not yet in the transcript.
    var hasPendingSend: Bool { !pendingSends.isEmpty }

    /// Forget a local echo without touching the CLI. Used when the user dismisses a card.
    func dropPending(id: String) {
        pendingSends.removeAll { $0.id == id }
        rebuildBlocks()
    }

    private let sessionID: String
    private let scope: NodeScope
    private let api: any APIClientProtocol
    private let parser = TranscriptParser()

    private var refreshTask: Task<Void, Never>?
    private var olderTask: Task<Void, Never>?
    private var refreshAgainWhenDone = false
    private var burstTask: Task<Void, Never>?
    /// Locally-echoed sends awaiting their real transcript entry.
    private var pendingSends: [PendingSend] = []
    /// When the transcript last actually changed, for choosing the poll cadence.
    private var lastChangeAt = Date.distantPast
    /// Byte offset of the oldest page held; the cursor for reading the page above it.
    private var oldestWindowStart: Int?
    /// Byte offset the last poll's window ended at — where the next one resumes reading FORWARD.
    /// nil until the first load establishes it.
    private var tailCursor: Int?
    private var pollTask: Task<Void, Never>?
    /// Coalesces the burst of SSE signals a single turn produces into one fetch.
    private var pendingRefresh = false

    /// A turn fires tool_start/tool_end in quick succession; refetching on each would be several
    /// hundred KB per tool call.
    private static let coalesceDelay = Duration.milliseconds(400)
    /// Cadence while the conversation is moving. Prose written mid-turn raises no SSE event, so
    /// this is the only thing that surfaces it — 5s made a live turn feel frozen.
    private static let activeInterval = Duration.milliseconds(1500)

    /// Cadence once nothing has changed for a while. A quiet session does not need a fetch every
    /// second and a half on a phone.
    private static let idleInterval = Duration.seconds(5)

    /// How long after the last change the fast cadence persists.
    private static let activeWindow: TimeInterval = 45

    /// ⚠️ The FIRST load reads a much larger slice than a poll does, and the asymmetry is
    /// deliberate. A single user message carrying screenshots is hundreds of KB to megabytes of
    /// base64 in the transcript (measured: 241KB–1.7MB per entry), so a 1MB window can be consumed
    /// by one image and hide every block before it. Opening a conversation should show history;
    /// polling only needs the newest turn, and re-reading megabytes every 5 seconds would be
    /// wasteful on a phone.
    private static let initialWindowBytes = 6 * 1024 * 1024

    /// Block cap for the first load, sized to the 6MB window rather than the server's default 200.
    private static let initialBlockLimit = 1000

    /// One page of history per scroll-to-top. Smaller than the initial window: this is fetched
    /// while the user is actively scrolling, so it has to arrive quickly.
    private static let olderPageBytes = 2 * 1024 * 1024

    /// How many pages one gap back-fill may fetch before giving up.
    ///
    /// ⚠️ A bound, not a target. A phone left asleep overnight can wake to a transcript that grew
    /// by hundreds of megabytes; chasing all of it would stall the view for as long as it took,
    /// and the user is looking at the newest turn anyway. Four pages of 2 MB recovers the recent
    /// past — where a missed prompt actually is — and leaves the rest to ordinary scroll paging.
    private static let maxBackfillPages = 4
    private var hasLoadedOnce = false

    init(sessionID: String, scope: NodeScope, api: any APIClientProtocol) {
        self.sessionID = sessionID
        self.scope = scope
        self.api = api
    }

    func start() {
        guard pollTask == nil else { return }
        refresh()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = await MainActor.run { self?.pollInterval ?? Self.idleInterval }
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled else { return }
                self.reconcilePending()
                self.refresh()
            }
        }
    }

    /// Fast while a turn is live or a send is outstanding, slow once things settle.
    private var pollInterval: Duration {
        if hasPendingSend { return Self.activeInterval }
        return Date().timeIntervalSince(lastChangeAt) < Self.activeWindow ? Self.activeInterval : Self.idleInterval
    }

    func stop() {
        burstTask?.cancel()
        burstTask = nil
        pollTask?.cancel()
        pollTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        olderTask?.cancel()
        olderTask = nil
    }

    /// Fetch the page above the oldest one held, so scrolling up reaches the start of the chat.
    ///
    /// - Returns: the id of the block that was first BEFORE the prepend, so the caller can pin the
    ///   scroll position to it — otherwise inserting rows above the viewport jumps the reader.
    @discardableResult
    func loadOlder() async -> String? {
        guard canLoadOlder, !isLoadingOlder, let cursor = oldestWindowStart, cursor > 0 else { return nil }
        isLoadingOlder = true
        defer { isLoadingOlder = false }

        let anchor = blocks.first?.id
        do {
            let response = try await api.transcript(
                id: sessionID,
                limit: nil,
                maxBytes: Self.olderPageBytes,
                before: cursor,
                since: nil,
                scope: scope
            )
            let snapshot = await parser.ingest(response, olderPage: true)
            serverBlocks = snapshot.blocks
            rebuildBlocks()
            oldestWindowStart = response.windowStart
            canLoadOlder = response.hasMore && (response.windowStart ?? 0) < cursor
            return anchor
        } catch {
            loadError = error.localizedDescription
            return nil
        }
    }

    /// Fill a hole between two windows by paging backwards from its upper edge.
    ///
    /// Reuses the ordinary `before` paging rather than inventing a second read path: the hole is
    /// just the range `[from, to)`, and each page walks its `windowStart` down until it reaches
    /// `from`. Blocks land in place because the parser merges by id and keeps server order.
    ///
    /// ⚠️ Bounded by `maxBackfillPages`. A phone left in a pocket overnight can return to a
    /// transcript that grew by hundreds of megabytes, and chasing all of it would stall the view
    /// for as long as it took. Falling short leaves a smaller hole than the one we started with,
    /// which is strictly better than either extreme.
    private func backfill(from: Int, to: Int) async {
        var cursor = to
        for _ in 0..<Self.maxBackfillPages {
            guard cursor > from else { return }
            do {
                let page = try await api.transcript(
                    id: sessionID,
                    limit: nil,
                    maxBytes: Self.olderPageBytes,
                    before: cursor,
                    since: nil,
                    scope: scope
                )
                let snapshot = await parser.ingest(page, olderPage: true)
                guard !Task.isCancelled else { return }
                serverBlocks = snapshot.blocks
                rebuildBlocks()
                guard let start = page.windowStart, start < cursor else { return }
                cursor = start
            } catch {
                // A failed back-fill is not worth surfacing: the live tail is already on screen
                // and the next gap report will try again.
                return
            }
        }
    }

    /// Called from the SSE handler for this session's transcript signals.
    func signalChanged() {
        guard !pendingRefresh else { return }
        pendingRefresh = true
        Task { [weak self] in
            try? await Task.sleep(for: Self.coalesceDelay)
            guard let self else { return }
            self.pendingRefresh = false
            self.refresh()
        }
    }

    /// Discards the accumulated thread. `/clear` starts a new conversation whose blocks are
    /// unrelated to the old ids, so merging across it would show two threads spliced together.
    func resetConversation() {
        Task { [parser] in await parser.reset() }
        blocks = []
        serverBlocks = []
        pendingSends.removeAll()
        availability = .unknown
        totalBlocks = 0
        truncated = false
        oldestWindowStart = nil
        tailCursor = nil
        canLoadOlder = false
        hasLoadedOnce = false
    }

    func refresh() {
        // ⚠️ Coalesce, never DROP. This used to `return` when a fetch was already in flight, so a
        // refresh requested right after sending was silently swallowed whenever it collided with
        // the 5s poll — the message then did not appear until some later tick.
        guard refreshTask == nil else {
            refreshAgainWhenDone = true
            return
        }
        isLoading = blocks.isEmpty
        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.refreshTask = nil
                self.isLoading = false
                if self.refreshAgainWhenDone {
                    self.refreshAgainWhenDone = false
                    self.refresh()
                }
            }
            do {
                // ⚠️ `limit` must MATCH the window. The first load reads 6MB, which routinely
                // parses to more than the server's default cap of 200 blocks — and the cap keeps
                // the NEWEST, dropping the oldest. That silently removed the earlier half of the
                // conversation, prompts included, from a window that had actually returned it.
                let firstLoad = !hasLoadedOnce
                let previousCursor = self.tailCursor
                // ⚠️ Poll FORWARD from where the last window ended, never as a fresh tail read.
                // A tail poll answers "what is at the end of the file", which is not the same
                // question as "what happened since I last looked" — and on a real transcript the
                // difference is whole prompts. Measured: the 1 MB tail of a 37 MB session parses
                // to 130 blocks and ZERO user prompts, because tool results dominate the bytes. So
                // any pause in polling (backgrounded on iOS, most obviously) let the file advance
                // past a whole window, and the prompts sent in that stretch appeared in no window
                // this client ever saw. Backwards paging could not reach them either: it walks up
                // from the FIRST window, never into a hole that opened at the tail.
                let response = try await api.transcript(
                    id: sessionID,
                    limit: firstLoad ? Self.initialBlockLimit : nil,
                    maxBytes: firstLoad ? Self.initialWindowBytes : nil,
                    before: nil,
                    since: firstLoad ? nil : tailCursor,
                    scope: scope
                )
                self.hasLoadedOnce = true
                let snapshot = await parser.ingest(response)
                guard !Task.isCancelled else { return }
                if snapshot.blocks.count != self.serverBlocks.count { self.lastChangeAt = Date() }
                self.serverBlocks = snapshot.blocks
                self.rebuildBlocks()
                self.availability = snapshot.availability
                self.truncated = snapshot.truncated
                self.totalBlocks = snapshot.totalBlocks
                self.loadError = nil
                // Only the first page establishes the paging cursor. A later poll reads the live
                // tail, whose window start is BELOW everything already paged in — adopting it
                // would rewind the cursor and re-fetch pages already on screen.
                if self.oldestWindowStart == nil {
                    self.oldestWindowStart = response.windowStart
                    self.canLoadOlder = response.hasMore
                }
                // Advance the poll cursor. Guarded against going backwards: a window that
                // returned nothing new reports its own start as the end, and rewinding would
                // re-fetch and re-merge the same bytes on every tick.
                if let end = response.windowEnd, end > (self.tailCursor ?? 0) { self.tailCursor = end }
                // The agent outran us. Back-fill the named hole rather than leaving a silent
                // discontinuity in the middle of the conversation.
                if response.gap, let from = previousCursor, let to = response.windowStart, to > from {
                    await self.backfill(from: from, to: to)
                }
            } catch is CancellationError {
                return
            } catch let error as APIError where error.isMissingEndpoint {
                // The server predates the transcript endpoint. Say so once and stop polling — a
                // route that does not exist will not start existing, and retrying every 5s only
                // burns battery to keep re-learning the same thing.
                await parser.markUnsupported()
                self.availability = .unsupported
                self.loadError = nil
                self.stop()
            } catch {
                // Keep whatever is already rendered: a dropped poll on a working connection is
                // routine, and blanking a conversation the user is reading is worse than stale.
                self.loadError = error.localizedDescription
            }
        }
    }
}
