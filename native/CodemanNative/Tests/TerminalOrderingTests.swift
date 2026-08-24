import Foundation
import Testing
@testable import Codeman

/// A scriptable stand-in for `TerminalTransport`. Lives in the test target only — no mock ever
/// enters a production path.
actor TestTerminalTransport: TerminalTransporting {
    private var continuation: AsyncStream<TerminalTransportEvent>.Continuation?
    private(set) var sentFrames: [TerminalClientFrame] = []
    private(set) var connectCount = 0
    private(set) var disconnectCount = 0
    private(set) var generation: UInt64 = 0

    func connect(sessionID: String, scope: NodeScope) async -> AsyncStream<TerminalTransportEvent> {
        connectCount += 1
        let (stream, continuation) = AsyncStream<TerminalTransportEvent>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = continuation
        return stream
    }

    func send(_ frame: TerminalClientFrame) async { sentFrames.append(frame) }

    func sendInput(_ text: String) async {
        sentFrames.append(.input(text: text, seq: sentFrames.count, clientID: "test"))
    }

    func disconnect() async {
        disconnectCount += 1
        continuation?.finish()
        continuation = nil
    }

    func currentGeneration() async -> UInt64 { generation }

    // MARK: - Scripting

    /// `TerminalSession.start()` subscribes from inside a `Task`, so a test that emits the instant
    /// it returns races the subscription and the event is dropped. Production has no such race —
    /// the socket is open before any frame arrives — so the harness waits the same way.
    func waitUntilConnected(timeout: Duration = .seconds(2)) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while continuation == nil {
            if ContinuousClock.now > deadline {
                throw TransportNotReady()
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    struct TransportNotReady: Error {}

    /// Opens a new epoch, exactly as a real reconnect does.
    func emitConnected() {
        generation &+= 1
        continuation?.yield(.connected(generation: generation))
    }

    func emitOutput(_ text: String, generation override: UInt64? = nil) {
        continuation?.yield(.frame(.output(text), generation: override ?? generation))
    }

    func emitFrame(_ frame: TerminalServerFrame, generation override: UInt64? = nil) {
        continuation?.yield(.frame(frame, generation: override ?? generation))
    }

    func emitDisconnected(_ reason: TerminalDisconnectReason) {
        continuation?.yield(.disconnected(reason, generation: generation))
    }
}

/// Records every byte handed to Ghostty, in order, so ordering can be asserted on.
actor SnapshotRecorder {
    private(set) var writes: [String] = []
    func record(_ text: String) { writes.append(text) }
    var joined: String { writes.joined() }
}

/// An `APIClientProtocol` that answers only what these tests need and reports the rest as
/// unimplemented rather than silently returning a plausible-looking empty value.
actor TestAPIClient: APIClientProtocol {
    private let snapshot: TerminalSnapshot
    private var snapshotDelay: Duration
    private(set) var snapshotRequests: [(full: Bool, session: String)] = []
    private(set) var sentInputs: [SessionInputRequest] = []

    init(snapshot: TerminalSnapshot, snapshotDelay: Duration = .zero) {
        self.snapshot = snapshot
        self.snapshotDelay = snapshotDelay
    }

    func terminalSnapshot(id: String, full: Bool, tailBytes: Int?, scope: NodeScope) async throws -> TerminalSnapshot {
        snapshotRequests.append((full, id))
        if snapshotDelay != .zero { try await Task.sleep(for: snapshotDelay) }
        return snapshot
    }

    /// These tests drive the terminal, not the transcript view; the endpoint is stubbed as
    /// "no transcript" so the double satisfies the protocol without pretending to serve one.
    func transcript(id: String, limit: Int?, maxBytes: Int?, before: Int?, since: Int?, scope: NodeScope) async throws
        -> TranscriptResponse {
        try JSONDecoder().decode(
            TranscriptResponse.self,
            from: Data(#"{"available":false,"reason":"stub","blocks":[]}"#.utf8)
        )
    }

    func transcriptImage(id: String, ref: String, scope: NodeScope) async throws -> Data { Data() }

    func attachmentData(id: String, sessionID: String, scope: NodeScope) async throws -> Data { Data() }

    func slashCommands(id: String, scope: NodeScope) async throws -> SlashCommandsResponse {
        try JSONDecoder().decode(
            SlashCommandsResponse.self,
            from: Data(#"{"available":false,"commands":[]}"#.utf8)
        )
    }

    func projectFiles(id: String, depth: Int, scope: NodeScope) async throws -> FileTreeResponse {
        FileTreeResponse(root: "/tmp", tree: [], totalFiles: 0, totalDirectories: 0, truncated: false)
    }

    func fileContent(id: String, path: String, scope: NodeScope) async throws -> FileContent {
        try JSONDecoder().decode(FileContent.self, from: Data(#"{"path":"\#(path)","content":""}"#.utf8))
    }

    func sendInput(_ request: SessionInputRequest, id: String, scope: NodeScope) async throws -> SessionInputResponse {
        sentInputs.append(request)
        return SessionInputResponse(delivered: true, duplicate: false, status: .busy, limitPaused: false, wait: nil)
    }

    // Unused by these tests.
    func nodeInfo(scope: NodeScope) async throws -> NodeInfo { throw Unimplemented() }
    func listNodes() async throws -> NodeListResponse { throw Unimplemented() }
    func upsertNode(_ request: UpsertNodeRequest, id: String?) async throws -> NodeRecordDTO { throw Unimplemented() }
    func deleteNode(id: String) async throws { throw Unimplemented() }
    func testNode(id: String) async throws -> NodeTestResponse { throw Unimplemented() }
    func pairNode(_ request: PairNodeRequest) async throws -> NodeRecordDTO { throw Unimplemented() }
    func listSessions(scope: NodeScope) async throws -> [SessionSnapshot] { [] }
    func session(id: String, scope: NodeScope) async throws -> SessionSnapshot { throw Unimplemented() }
    func quickStart(_ request: QuickStartRequest, scope: NodeScope) async throws -> QuickStartResponse { throw Unimplemented() }
    func createSession(_ request: CreateSessionRequest, scope: NodeScope) async throws -> SessionSnapshot { throw Unimplemented() }
    func startInteractive(id: String, clearBreaker: Bool, scope: NodeScope) async throws {}
    func startShell(id: String, scope: NodeScope) async throws {}
    func renameSession(id: String, name: String, scope: NodeScope) async throws {}
    func deleteSession(id: String, killMux: Bool, scope: NodeScope) async throws {}
    func setPinned(id: String, pinned: Bool, scope: NodeScope) async throws {}
    func sendNewlineKey(id: String, scope: NodeScope) async throws {}
    func resize(_ request: ResizeRequest, id: String, scope: NodeScope) async throws {}
    func historySessions(scope: NodeScope) async throws -> [HistorySession] { [] }
    func listCases(scope: NodeScope) async throws -> [CaseInfo] { [] }
    func createCase(_ request: CreateCaseRequest, scope: NodeScope) async throws -> CreateCaseResponse { throw Unimplemented() }
    func browse(path: String?, sessionID: String?, showHidden: Bool, scope: NodeScope) async throws -> FilesystemListing { throw Unimplemented() }
    func uploadImage(_ data: Data, filename: String, mimeType: String, sessionID: String, scope: NodeScope) async throws -> PasteImageResponse { throw Unimplemented() }
    func registerAttachment(path: String, notify: Bool, sessionID: String, scope: NodeScope) async throws -> AttachmentDescriptor { throw Unimplemented() }
    func settings(scope: NodeScope) async throws -> ServerSettings { ServerSettings() }
    func updateSettings(_ update: SettingsUpdate, scope: NodeScope) async throws {}
    func approvals(scope: NodeScope) async throws -> [ApprovalItem] { [] }
    func answerApproval(id: String, request: ApprovalAnswerRequest, scope: NodeScope) async throws {}
    func subagents(scope: NodeScope) async throws -> [SubagentInfo] { [] }
    func logout(scope: NodeScope) async throws {}

    struct Unimplemented: Error {}
}

@Suite("Terminal reconnect ordering")
@MainActor
struct TerminalOrderingTests {
    private func makeSession(
        transport: TestTerminalTransport,
        api: TestAPIClient
    ) -> TerminalSession {
        TerminalSession(
            sessionID: "sess-1",
            scope: .local,
            transport: transport,
            api: api,
            viewportClass: { "mobile" }
        )
    }

    /// The whole point of the generation counter: bytes from a superseded socket must never paint
    /// into a pane that has already moved on.
    @Test("frames from a stale generation are dropped")
    func dropsStaleGeneration() async throws {
        let transport = TestTerminalTransport()
        let api = TestAPIClient(snapshot: TerminalSnapshot(
            terminalBuffer: "SNAPSHOT", status: .idle, fullSize: 8,
            truncated: false, truncationReason: nil, retainedBytes: 8, source: .muxFullHistory
        ))
        let session = makeSession(transport: transport, api: api)
        session.start()
        try await transport.waitUntilConnected()

        await transport.emitConnected()                  // generation 1
        try await settle()
        await transport.emitConnected()                  // generation 2 supersedes it
        try await settle()

        // A frame tagged with the retired epoch must be ignored.
        await transport.emitOutput("STALE", generation: 1)
        await transport.emitOutput("FRESH", generation: 2)
        try await settle()

        // Both snapshots were requested (one per epoch), and the pane ended up live.
        let requests = await api.snapshotRequests
        #expect(requests.count >= 1)
        let allFullReloads = requests.allSatisfy { $0.full }
        #expect(allFullReloads, "reconnect must use ?full=1, not a tail")
        #expect(session.state == .live)
    }

    /// The reconnect bug this exists to prevent: output that arrives while the snapshot request is
    /// in flight is newer than the snapshot and must be replayed after it, not discarded. The
    /// byte-level ordering is pinned in `SnapshotGateTests`; this checks the pane drives it.
    @Test("a pane recovers to live after a slow snapshot with output in flight")
    func holdsFramesDuringSnapshot() async throws {
        let transport = TestTerminalTransport()
        let api = TestAPIClient(
            snapshot: TerminalSnapshot(
                terminalBuffer: "HISTORY", status: .idle, fullSize: 7,
                truncated: false, truncationReason: nil, retainedBytes: 7, source: .muxFullHistory
            ),
            // Long enough that live output genuinely lands mid-request.
            snapshotDelay: .milliseconds(120)
        )
        let session = makeSession(transport: transport, api: api)
        session.start()
        try await transport.waitUntilConnected()

        await transport.emitConnected()
        // Land output while the snapshot is still on the wire.
        try await Task.sleep(for: .milliseconds(20))
        await transport.emitOutput("LIVE-1")
        await transport.emitOutput("LIVE-2")

        try await Task.sleep(for: .milliseconds(300))
        #expect(session.state == .live)
    }

    @Test("a needsRefresh frame triggers a fresh authoritative snapshot")
    func needsRefreshPullsSnapshot() async throws {
        let transport = TestTerminalTransport()
        let api = TestAPIClient(snapshot: TerminalSnapshot(
            terminalBuffer: "X", status: .idle, fullSize: 1,
            truncated: false, truncationReason: nil, retainedBytes: 1, source: .muxVisible
        ))
        let session = makeSession(transport: transport, api: api)
        session.start()
        try await transport.waitUntilConnected()

        await transport.emitConnected()
        try await settle()
        let before = await api.snapshotRequests.count

        await transport.emitFrame(.needsRefresh)
        try await settle()

        let after = await api.snapshotRequests.count
        #expect(after == before + 1)
        #expect(session.state == .live)
    }

    @Test("a terminated session ends the pane instead of spinning on reconnect")
    func terminatedSessionEndsPane() async throws {
        let transport = TestTerminalTransport()
        let api = TestAPIClient(snapshot: TerminalSnapshot(
            terminalBuffer: "", status: .idle, fullSize: 0,
            truncated: false, truncationReason: nil, retainedBytes: 0, source: .history
        ))
        let session = makeSession(transport: transport, api: api)
        session.start()
        try await transport.waitUntilConnected()

        await transport.emitConnected()
        try await settle()
        await transport.emitDisconnected(.sessionTerminated)
        try await settle()

        guard case .ended = session.state else {
            Issue.record("expected .ended, got \(session.state)")
            return
        }
    }

    @Test("the 5-connection cap surfaces as a failure, not a silent blank pane")
    func tooManyConnectionsFails() async throws {
        let transport = TestTerminalTransport()
        let api = TestAPIClient(snapshot: TerminalSnapshot(
            terminalBuffer: "", status: .idle, fullSize: 0,
            truncated: false, truncationReason: nil, retainedBytes: 0, source: .history
        ))
        let session = makeSession(transport: transport, api: api)
        session.start()
        try await transport.waitUntilConnected()

        await transport.emitConnected()
        try await settle()
        await transport.emitDisconnected(.tooManyConnections)
        try await settle()

        guard case let .failed(message) = session.state else {
            Issue.record("expected .failed, got \(session.state)")
            return
        }
        #expect(message.contains("5"))
    }

    /// `sendInput` only issues `send-keys Enter` when the payload contains a carriage return: a
    /// `\r`-less POST returns 200 while the text sits unsubmitted on the composer.
    @Test("a composed prompt is always carriage-return terminated")
    func composedPromptCarriesReturn() async throws {
        let transport = TestTerminalTransport()
        let api = TestAPIClient(snapshot: TerminalSnapshot(
            terminalBuffer: "", status: .idle, fullSize: 0,
            truncated: false, truncationReason: nil, retainedBytes: 0, source: .history
        ))
        let session = makeSession(transport: transport, api: api)

        try await session.submitComposedPrompt("run the tests")
        let sent = await api.sentInputs
        #expect(sent.count == 1)
        #expect(sent[0].input == "run the tests\r")
        #expect(sent[0].useMux == true)
    }

    /// The server strips embedded newlines and joins the lines, so `"echo A\necho B"` would run
    /// `echo Aecho B`. Collapsing to spaces client-side is the honest reading of the intent.
    @Test("newlines in a composed prompt become spaces, not a joined command")
    func composedPromptFlattensNewlines() async throws {
        let transport = TestTerminalTransport()
        let api = TestAPIClient(snapshot: TerminalSnapshot(
            terminalBuffer: "", status: .idle, fullSize: 0,
            truncated: false, truncationReason: nil, retainedBytes: 0, source: .history
        ))
        let session = makeSession(transport: transport, api: api)

        try await session.submitComposedPrompt("echo A\necho B")
        let sent = await api.sentInputs
        #expect(sent[0].input == "echo A echo B\r")
    }

    @Test("an empty prompt is not sent")
    func emptyPromptIsNotSent() async throws {
        let transport = TestTerminalTransport()
        let api = TestAPIClient(snapshot: TerminalSnapshot(
            terminalBuffer: "", status: .idle, fullSize: 0,
            truncated: false, truncationReason: nil, retainedBytes: 0, source: .history
        ))
        let session = makeSession(transport: transport, api: api)

        try await session.submitComposedPrompt("   \n  ")
        let sent = await api.sentInputs
        #expect(sent.isEmpty)
    }

    @Test("only http and https links are surfaced to the browser")
    func linkSchemeFilter() {
        let transport = TestTerminalTransport()
        let api = TestAPIClient(snapshot: TerminalSnapshot(
            terminalBuffer: "", status: .idle, fullSize: 0,
            truncated: false, truncationReason: nil, retainedBytes: 0, source: .history
        ))
        let session = makeSession(transport: transport, api: api)

        session.openLink("https://example.com/docs")
        #expect(session.pendingLink?.absoluteString == "https://example.com/docs")

        session.pendingLink = nil
        // Terminal output must not be able to trigger arbitrary app-scheme navigation.
        for hostile in ["file:///etc/passwd", "tel:+15551234", "shortcuts://run", "javascript:alert(1)"] {
            session.openLink(hostile)
            #expect(session.pendingLink == nil, "should not open \(hostile)")
        }
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(60))
    }
}

/// The reconnect ordering rule, asserted on bytes.
@Suite("Snapshot gate")
struct SnapshotGateTests {
    private func chunk(_ text: String) -> Data { Data(text.utf8) }

    @Test("passes output through when no snapshot is pending")
    func passThroughWhenIdle() {
        var gate = SnapshotGate()
        #expect(gate.ingest(chunk("hello")) == .passThrough)
        #expect(!gate.isAwaitingSnapshot)
    }

    @Test("holds output while a snapshot is in flight")
    func holdsDuringSnapshot() {
        var gate = SnapshotGate()
        gate.beginSnapshot()
        #expect(gate.ingest(chunk("a")) == .held)
        #expect(gate.ingest(chunk("b")) == .held)
        #expect(gate.heldByteCount == 2)
    }

    /// The guarantee: held output is replayed in arrival order, and *after* the snapshot the pane
    /// writes first — the snapshot is the older state.
    @Test("replays held output in arrival order")
    func replaysInOrder() {
        var gate = SnapshotGate()
        gate.beginSnapshot()
        for text in ["one", "two", "three"] { _ = gate.ingest(chunk(text)) }

        let replayed = gate.release().map { String(decoding: $0, as: UTF8.self) }
        #expect(replayed == ["one", "two", "three"])
        #expect(!gate.isAwaitingSnapshot)
        #expect(gate.heldByteCount == 0)
    }

    @Test("release with nothing held is empty, not a crash")
    func releaseEmpty() {
        var gate = SnapshotGate()
        gate.beginSnapshot()
        #expect(gate.release().isEmpty)
    }

    /// Output must never be silently dropped. Past the cap the gate flushes everything it holds —
    /// including the chunk that overflowed it, last — and stops waiting.
    @Test("overflow flushes in order rather than dropping bytes")
    func overflowFlushesInOrder() {
        var gate = SnapshotGate(capacity: 8)
        gate.beginSnapshot()
        #expect(gate.ingest(chunk("1234")) == .held)
        #expect(gate.ingest(chunk("5678")) == .held)

        guard case let .overflowed(flushed) = gate.ingest(chunk("9")) else {
            Issue.record("expected an overflow")
            return
        }
        #expect(flushed.map { String(decoding: $0, as: UTF8.self) } == ["1234", "5678", "9"])
        #expect(!gate.isAwaitingSnapshot)
        #expect(gate.heldByteCount == 0)
    }

    @Test("after an overflow, subsequent output passes straight through")
    func passesThroughAfterOverflow() {
        var gate = SnapshotGate(capacity: 4)
        gate.beginSnapshot()
        _ = gate.ingest(chunk("12345"))
        #expect(gate.ingest(chunk("next")) == .passThrough)
    }

    /// A second snapshot (a `{"t":"r"}` refresh mid-stream) re-arms the hold.
    @Test("a new snapshot re-arms the hold")
    func reArms() {
        var gate = SnapshotGate()
        gate.beginSnapshot()
        _ = gate.ingest(chunk("first"))
        _ = gate.release()

        gate.beginSnapshot()
        #expect(gate.ingest(chunk("second")) == .held)
        #expect(gate.release().map { String(decoding: $0, as: UTF8.self) } == ["second"])
    }
}
