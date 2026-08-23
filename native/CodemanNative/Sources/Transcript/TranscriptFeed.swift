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
    /// Set when a fetch fails. The last good blocks stay on screen underneath it.
    private(set) var loadError: String?

    /// Id of the newest block, for `ScrollViewReader`.
    var lastBlockID: String? { blocks.last?.id }

    private let sessionID: String
    private let scope: NodeScope
    private let api: any APIClientProtocol
    private let parser = TranscriptParser()

    private var refreshTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    /// Coalesces the burst of SSE signals a single turn produces into one fetch.
    private var pendingRefresh = false

    /// A turn fires tool_start/tool_end in quick succession; refetching on each would be several
    /// hundred KB per tool call.
    private static let coalesceDelay = Duration.milliseconds(400)
    /// Covers what raises no event: prose written mid-turn.
    private static let pollInterval = Duration.seconds(5)

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
                try? await Task.sleep(for: Self.pollInterval)
                guard let self, !Task.isCancelled else { return }
                self.refresh()
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        refreshTask?.cancel()
        refreshTask = nil
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
        availability = .unknown
        totalBlocks = 0
        truncated = false
    }

    func refresh() {
        guard refreshTask == nil else { return }
        isLoading = blocks.isEmpty
        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.refreshTask = nil
                self.isLoading = false
            }
            do {
                let response = try await api.transcript(id: sessionID, limit: nil, scope: scope)
                let snapshot = await parser.ingest(response)
                guard !Task.isCancelled else { return }
                self.blocks = snapshot.blocks
                self.availability = snapshot.availability
                self.truncated = snapshot.truncated
                self.totalBlocks = snapshot.totalBlocks
                self.loadError = nil
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
