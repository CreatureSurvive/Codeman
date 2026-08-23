import Foundation
import GhosttyTerminal
import Observation
import SwiftUI

/// The connection/render state of one terminal pane, as the UI presents it.
enum TerminalPaneState: Sendable, Equatable {
    case idle
    case loadingSnapshot
    case live
    case reconnecting(attempt: Int)
    case ended(reason: String)
    case failed(message: String)

    var isBusy: Bool {
        switch self {
        case .loadingSnapshot, .reconnecting: true
        default: false
        }
    }
}

/// One live terminal: a Ghostty in-memory session, a WebSocket, and the generation logic that
/// keeps their output from ever interleaving with another epoch's.
///
/// Lives on the main actor because it drives a `UIView` and publishes to SwiftUI. All network
/// work is delegated to the `TerminalTransport` actor.
@MainActor
@Observable
final class TerminalSession {
    let sessionID: String
    private(set) var scope: NodeScope
    private(set) var state: TerminalPaneState = .idle
    private(set) var title: String = ""
    private(set) var columns: Int = 80
    private(set) var rows: Int = 24
    /// Set when a link is tapped in the terminal; the pane presents `SFSafariViewController`.
    var pendingLink: URL?

    /// The Ghostty backend. Bytes are handed to `receive(_:)` in arrival order and it takes care
    /// of buffering anything that lands before the Metal surface attaches (1 MiB cap) and of
    /// processing writes on a serial queue.
    let ghosttySession: InMemoryTerminalSession

    private let transport: any TerminalTransporting
    private let api: any APIClientProtocol
    private let viewportClass: @MainActor () -> String

    private var pumpTask: Task<Void, Never>?
    private var snapshotTask: Task<Void, Never>?
    private var resizeTask: Task<Void, Never>?

    /// The generation this pane currently accepts frames from. Bumped by the transport on every
    /// socket epoch and mirrored here; frames tagged with anything else are dropped.
    private var acceptedGeneration: UInt64 = 0
    /// Holds output that arrives while an authoritative snapshot is in flight, and replays it in
    /// order once the snapshot is written. See `SnapshotGate` — the ordering rule lives there so
    /// it can be tested on bytes rather than inferred from this pane's state.
    private var snapshotGate = SnapshotGate()

    private var lastSentColumns = 0
    private var lastSentRows = 0

    /// Whether a Metal surface has ever been attached — see `surfaceDidAttach()`.
    private var hasEverAttachedASurface = false

    /// Whether Ghostty has reported a real grid yet. Until it does, `columns`/`rows` hold the
    /// 80×24 placeholder.
    private var hasMeasuredGrid = false

    /// Whether a snapshot has been written to the grid, so the first real measurement knows
    /// whether there is anything to re-pull.
    private var hasAppliedASnapshot = false

    /// The grid width the capture currently on screen was laid out for.
    private var columnsAtLastSnapshot = 0

    /// Size of the capture currently rendered, so a thinner one cannot wipe it.
    private var renderedCaptureBytes = 0

    /// The confirming re-pull scheduled after an epoch's first snapshot.
    private var confirmTask: Task<Void, Never>?

    /// Long enough for a contended server to have recovered, short enough that a session which
    /// opened thin fills in before the user has finished reading the first screen.
    private static let confirmSnapshotDelay = Duration.milliseconds(700)

    /// The re-pull scheduled when a capture arrived laid out for a width other than this grid's.
    private var widthRetryTask: Task<Void, Never>?

    /// How many times a single resize may wait for the pane to follow before we render anyway.
    /// Bounded because a shared pane held by the server's desktop sizing claim never will.
    private static let maxSnapshotWidthRetries = 3

    /// One server round trip plus tmux's asynchronous `resize-window`, with room to spare.
    private static let widthRetryDelay = Duration.milliseconds(250)

    private var snapshotWidthRetries = 0

    init(
        sessionID: String,
        scope: NodeScope,
        transport: any TerminalTransporting,
        api: any APIClientProtocol,
        viewportClass: @escaping @MainActor () -> String
    ) {
        self.sessionID = sessionID
        self.scope = scope
        self.transport = transport
        self.api = api
        self.viewportClass = viewportClass

        // Placeholders replaced immediately below; the closures need `self`.
        let box = SessionCallbackBox()
        ghosttySession = InMemoryTerminalSession(
            write: { data in box.write(data) },
            resize: { viewport in box.resize(viewport) },
            // The client consumes only columns and rows, and a live iPad divider drag is mostly
            // pixel-only updates — each of which would otherwise ask the agent for a full repaint.
            suppressesPixelOnlyResizes: true
        )

        box.onWrite = { [weak self] data in
            guard let self else { return }
            Task { @MainActor in self.handleTerminalWrite(data) }
        }
        box.onResize = { [weak self] viewport in
            guard let self else { return }
            Task { @MainActor in self.handleGridResize(columns: Int(viewport.columns), rows: Int(viewport.rows)) }
        }
    }

    // No `deinit` teardown: the stored tasks are main-actor state and cannot be touched from a
    // nonisolated deinit. Ownership is explicit instead — `AppModel` calls `stop()` from
    // `closeTerminal`, `teardown`, and `selectNode`, and `stop()` is what cancels the tasks and
    // disconnects the transport. That matches the rule in Architecture §2: whoever starts a task
    // owns cancelling it.

    // MARK: - Lifecycle

    func start() {
        guard pumpTask == nil else { return }
        state = .loadingSnapshot

        pumpTask = Task { [weak self] in
            guard let self else { return }
            let events = await transport.connect(sessionID: sessionID, scope: scope)
            for await event in events {
                await self.handle(event)
            }
        }
    }

    func stop() {
        pumpTask?.cancel()
        pumpTask = nil
        snapshotTask?.cancel()
        snapshotTask = nil
        resizeTask?.cancel()
        resizeTask = nil
        confirmTask?.cancel()
        confirmTask = nil
        widthRetryTask?.cancel()
        widthRetryTask = nil
        let transport = self.transport
        Task { await transport.disconnect() }
        state = .idle
    }

    /// Called when the pane becomes visible again after backgrounding. Pulls an authoritative
    /// snapshot *before* any newer frame is applied.
    func refreshAfterForeground() {
        guard pumpTask != nil else { return }
        // Size first, then capture: the capture is laid out for the pane's current width, so it is
        // worth asking for after the server knows what this pane is.
        reassertSize()
        requestAuthoritativeSnapshot()
    }

    /// A Metal surface attached to this session.
    ///
    /// ⚠️ **The grid lives in the surface, and this session keeps no copy of it.** Anything
    /// written to a previous surface is gone the moment that surface is torn down, so a *second*
    /// surface starts empty — showing only whatever the agent prints next. SwiftUI rebuilds a
    /// representable's `UIView` on any structural change to the pane, so this is not an edge
    /// case: it is what happens when you open a session, switch tabs, or rotate.
    ///
    /// That was the reported bug. A reopened pane showed just the shell prompt, and the only
    /// thing that brought the scrollback back was backgrounding the app — because
    /// `refreshAfterForeground()` pulls a fresh snapshot, which is precisely what a reattached
    /// surface needs too.
    ///
    /// The first attach is deliberately exempt: the package buffers bytes written before a
    /// surface exists and flushes them on attach, so that content is already accounted for and
    /// a snapshot here would be a redundant round trip on every session open.
    func surfaceDidAttach() {
        defer { hasEverAttachedASurface = true }
        guard hasEverAttachedASurface, pumpTask != nil else { return }
        Log.terminal.info("Surface reattached; re-pulling the snapshot")
        requestAuthoritativeSnapshot()
    }

    func changeScope(_ newScope: NodeScope) {
        guard newScope != scope else { return }
        scope = newScope
        // A node change is a new epoch. Restarting the transport bumps the generation, so no
        // in-flight frame from the previous node can land in this pane.
        stop()
        start()
    }

    // MARK: - Transport events

    private func handle(_ event: TerminalTransportEvent) async {
        switch event {
        case let .connected(generation):
            acceptedGeneration = generation
            // A new epoch: whatever was on the grid belongs to the previous connection and must
            // not veto the first capture of this one.
            renderedCaptureBytes = 0
            // …and the server on the other end of this socket has never been told our size.
            lastSentColumns = 0
            lastSentRows = 0
            reassertSize()
            requestAuthoritativeSnapshot()

        case let .frame(frame, generation):
            guard generation == acceptedGeneration else { return } // stale epoch
            apply(frame)

        case let .disconnected(reason, generation):
            guard generation == acceptedGeneration || acceptedGeneration == 0 else { return }
            switch reason {
            case .sessionTerminated, .sessionNotFound:
                state = .ended(reason: reason.userMessage)
            case .forbidden:
                state = .failed(message: reason.userMessage)
            case .tooManyConnections:
                state = .failed(message: reason.userMessage)
            default:
                if case .live = state { state = .reconnecting(attempt: 1) }
            }

        case let .reconnecting(attempt, _):
            state = .reconnecting(attempt: attempt)
        }
    }

    private func apply(_ frame: TerminalServerFrame) {
        switch frame {
        case let .output(text):
            // Bytes are forwarded verbatim and in arrival order — never parsed, trimmed, or
            // reordered. Escape sequences are routinely split across frames.
            let data = Data(text.utf8)
            switch snapshotGate.ingest(data) {
            case .passThrough:
                ghosttySession.receive(data)
            case .held:
                break
            case let .overflowed(flushed):
                // The snapshot is clearly not coming back usefully; take the newest bytes rather
                // than stalling the pane behind a request that has stopped mattering.
                Log.terminal.warning("Held-frame buffer overflowed; releasing hold early")
                for chunk in flushed { ghosttySession.receive(chunk) }
                state = .live
            }

        case .clear:
            resetGrid()

        case .needsRefresh:
            requestAuthoritativeSnapshot()

        case .inputAck:
            // Reliable delivery is handled by the transport's sequence numbering; the ACK is
            // informational here. It is still decoded so an unexpected frame never looks like
            // terminal output.
            break
        }
    }

    // MARK: - Snapshot

    /// Pulls `GET …/terminal?full=1`, resets the grid, writes it, then replays anything held.
    ///
    /// `full=1` rather than `?tail=`: a repaint-mode CLI pane keeps no tmux history, so a tail
    /// would be a strictly worse snapshot, and the full capture is returned *alone* by the server
    /// precisely so it can be written over a cleared grid without duplicating history.
    private func requestAuthoritativeSnapshot() {
        snapshotTask?.cancel()
        snapshotGate.beginSnapshot()
        state = .loadingSnapshot

        let generationAtRequest = acceptedGeneration
        snapshotTask = Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await api.terminalSnapshot(id: sessionID, full: true, tailBytes: nil, scope: scope)
                guard !Task.isCancelled, generationAtRequest == self.acceptedGeneration else {
                    // A newer socket epoch started while this was in flight — its own snapshot
                    // request supersedes this one.
                    return
                }
                self.applySnapshot(snapshot)
            } catch is CancellationError {
                return
            } catch {
                guard generationAtRequest == self.acceptedGeneration else { return }
                // A failed snapshot must not strand the pane: release the hold so live output
                // still renders, and say what happened.
                Log.terminal.warning("Snapshot failed: \(error.localizedDescription, privacy: .public)")
                self.releaseHeldFrames()
                self.state = .live
            }
        }
    }

    private func applySnapshot(_ snapshot: TerminalSnapshot) {
        let incomingBytes = snapshot.terminalBuffer.utf8.count

        // Applying is destructive — the grid is cleared first — so a capture that would shrink
        // what the user is already reading is refused rather than written. See
        // `SnapshotReplacementPolicy`: `full=1` intermittently answers with a fraction of the
        // history, and without this a re-pull is a coin flip on the pane's contents.
        guard SnapshotReplacementPolicy.shouldApply(
            renderedBytes: renderedCaptureBytes,
            incomingBytes: incomingBytes
        ) else {
            Log.terminal.warning(
                "Refused a thin capture: \(incomingBytes, privacy: .public) bytes would replace \(self.renderedCaptureBytes, privacy: .public)"
            )
            releaseHeldFrames()
            state = .live
            return
        }

        // ⚠️ A capture is laid out for the width it was taken at, and it does **not** reflow when
        // written into a grid of another width — the joined logical lines of a `-J` full-history
        // capture simply re-wrap at whatever column this grid ends at, breaking mid-word and
        // spilling the composer's background run onto an orphan row. The width is not recoverable
        // from the bytes (those logical lines are routinely wider than the pane), so the server
        // reports it and we compare.
        //
        // A mismatch here is normal for a moment after a resize: the frame has been sent but the
        // server's fire-and-forget `resize-window` has not landed yet. Wait for it rather than
        // rendering a capture we know is mis-laid — but only for a bounded number of tries,
        // because the pane may legitimately never reach our width (the server's desktop sizing
        // claim pins a shared pane to the desktop's dimensions). Showing the pane at a foreign
        // width beats showing nothing.
        if let paneCols = snapshot.paneCols, paneCols != columns, snapshotWidthRetries < Self.maxSnapshotWidthRetries {
            snapshotWidthRetries += 1
            Log.terminal.info(
                "Capture was laid out for \(paneCols, privacy: .public) cols but the grid is \(self.columns, privacy: .public); re-pulling (\(self.snapshotWidthRetries, privacy: .public)/\(Self.maxSnapshotWidthRetries, privacy: .public))"
            )
            releaseHeldFrames()
            state = .live
            scheduleWidthRetrySnapshot()
            return
        }
        if let paneCols = snapshot.paneCols, paneCols != columns {
            Log.terminal.warning(
                "Rendering a capture laid out for \(paneCols, privacy: .public) cols into a \(self.columns, privacy: .public)-col grid; the pane is not following this client's size"
            )
        }
        snapshotWidthRetries = 0

        let isFirstOfEpoch = !hasAppliedASnapshot
        hasAppliedASnapshot = true
        renderedCaptureBytes = incomingBytes
        columnsAtLastSnapshot = columns
        resetGrid()
        if !snapshot.terminalBuffer.isEmpty {
            ghosttySession.receive(Data(snapshot.terminalBuffer.utf8))
        }
        releaseHeldFrames()
        state = .live
        if isFirstOfEpoch { scheduleConfirmingSnapshot() }
        Log.terminal.info("Snapshot applied: buffer=\(snapshot.terminalBuffer.utf8.count, privacy: .public) grid=\(self.columns, privacy: .public)x\(self.rows, privacy: .public) source=\(snapshot.source?.rawValue ?? "unknown", privacy: .public)")
    }

    /// Fetches the capture once more, shortly after the first one of a socket epoch.
    ///
    /// ⚠️ **This is not a retry-on-error — the first fetch succeeded.** `full=1` intermittently
    /// answers with a fraction of the pane's history (measured: 31 bytes for a 4000-line pane,
    /// labelled `mux-full-history` like any other), and a session that opens on one of those looks
    /// empty until something else forces a re-pull. Backgrounding the app was the only thing that
    /// did, which is why the bug read as "scrollback only loads after backgrounding".
    ///
    /// One extra GET per session open, and it is safe by construction rather than by luck:
    /// `SnapshotReplacementPolicy` refuses a capture thinner than what is already rendered, so the
    /// confirming fetch can only ever improve the pane.
    /// Re-fetches after giving the server's asynchronous `resize-window` time to land.
    ///
    /// Separate from `scheduleConfirmingSnapshot` on purpose: that one improves a capture that was
    /// *valid but thin*, this one replaces one that was laid out for the wrong width. They have
    /// different delays and different exit conditions, and sharing a task handle would let a
    /// confirming fetch cancel a width retry.
    private func scheduleWidthRetrySnapshot() {
        widthRetryTask?.cancel()
        widthRetryTask = Task { [weak self] in
            try? await Task.sleep(for: Self.widthRetryDelay)
            guard let self, !Task.isCancelled, self.pumpTask != nil else { return }
            self.requestAuthoritativeSnapshot()
        }
    }

    private func scheduleConfirmingSnapshot() {
        confirmTask?.cancel()
        confirmTask = Task { [weak self] in
            try? await Task.sleep(for: Self.confirmSnapshotDelay)
            guard let self, !Task.isCancelled, self.pumpTask != nil else { return }
            self.requestAuthoritativeSnapshot()
        }
    }

    /// Ends the hold and replays everything buffered since it began, in order.
    private func releaseHeldFrames() {
        let held = snapshotGate.release()
        if !held.isEmpty {
            Log.terminal.info("Replaying \(held.count, privacy: .public) held frame(s), \(held.reduce(0) { $0 + $1.count }, privacy: .public) bytes")
        }
        for data in held { ghosttySession.receive(data) }
    }

    /// Clears the viewport *and* the scrollback before a snapshot is written, so a full-history
    /// capture is not appended below the history it already contains.
    private func resetGrid() {
        // `\x1b[3J` erases saved lines, `\x1b[H\x1b[2J` homes the cursor and clears the screen.
        ghosttySession.receive(Data("\u{1B}[3J\u{1B}[H\u{1B}[2J".utf8))
    }

    // MARK: - Outbound

    /// Ghostty handing us the bytes the user typed. This is the only place keystrokes enter the
    /// pipeline, so ordering is guaranteed by the transport's single writer.
    private func handleTerminalWrite(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
        let transport = self.transport
        Task { await transport.sendInput(text) }
    }

    private func handleGridResize(columns: Int, rows: Int) {
        guard columns > 0, rows > 0 else { return }
        let wasUnmeasured = !hasMeasuredGrid
        hasMeasuredGrid = true
        self.columns = columns
        self.rows = rows

        // ⚠️ **A capture is laid out for the width it was taken at.** Written into a grid of a
        // different width it does not reflow — the lines keep their original breaks, so after the
        // font size changes the scrollback renders as a narrow column down one side of a wider
        // grid, or runs off the edge of a narrower one. Only a fresh capture at the new width is
        // right, so re-pull whenever the **column** count changes (rows do not affect wrapping).
        //
        // This cannot loop: applying a snapshot never changes the grid, and the shrink guard in
        // `SnapshotReplacementPolicy` keeps a thin re-pull from destroying what is on screen.
        let widthChanged = columns != columnsAtLastSnapshot
        let needsSnapshot = (wasUnmeasured || widthChanged) && hasAppliedASnapshot && pumpTask != nil

        // ⚠️ **Resize first, capture second — the order is the whole fix.** The server's
        // `resizeWindow` is fire-and-forget (`exec`, "the sole caller ignores the result"), so a
        // snapshot requested before our new size has landed comes back laid out for the *old*
        // pane width. Written into the new grid it re-wraps mid-word and the composer's
        // background run spills onto an orphan row. Requesting the snapshot up front — which is
        // what this used to do — guaranteed that race on every rotation and font-size change.
        //
        // Sending the frame still does not prove tmux has resized, so `applySnapshot` checks the
        // capture's reported `paneCols` against this grid rather than trusting the ordering.
        snapshotWidthRetries = 0
        resizeTask?.cancel()
        resizeTask = Task { [weak self] in
            // Coalesce: a rotation or a Stage Manager drag posts sizes faster than the agent can
            // settle, and only the final size may be acted on.
            try? await Task.sleep(for: .milliseconds(100))
            guard let self, !Task.isCancelled else { return }
            await self.flushResize()
            guard needsSnapshot, !Task.isCancelled else { return }
            Log.terminal.info("Grid now \(columns, privacy: .public)x\(rows, privacy: .public); re-pulling the snapshot")
            self.requestAuthoritativeSnapshot()
        }
    }

    private func flushResize(force: Bool = false) async {
        let cols = min(max(columns, 1), 500)
        let rowCount = min(max(rows, 1), 200)
        guard force || cols != lastSentColumns || rowCount != lastSentRows else { return }
        lastSentColumns = cols
        lastSentRows = rowCount

        await transport.send(.resize(cols: cols, rows: rowCount, viewport: viewportClass(), force: force))
        Log.terminal.info("Sent resize \(cols, privacy: .public)x\(rowCount, privacy: .public) force=\(force, privacy: .public)")
    }

    /// Re-states this pane's size to the server, whether or not the client thinks it already has.
    ///
    /// ⚠️ **`lastSentColumns/Rows` records what was *sent*, not what was *applied*.** The server
    /// can decline a resize — `Session.resize()` ignores a mobile or tablet viewport entirely
    /// while a desktop holds a sizing claim — and it drops any resize whose dimensions it believes
    /// are unchanged. So a client that only ever sends deltas can end up permanently out of step
    /// with the pane it is drawing, with no way back: the size it needs is the size it already
    /// "sent". Re-asserting with `force` on every new socket epoch and on foreground is what makes
    /// that recoverable.
    func reassertSize() {
        guard hasMeasuredGrid, pumpTask != nil else { return }
        resizeTask?.cancel()
        resizeTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            await self.flushResize(force: true)
        }
    }

    /// Sends text the user composed outside the terminal (the prompt bar, an approval answer).
    ///
    /// Goes over HTTP rather than the socket because it wants the server's submission semantics:
    /// `sendInput` only issues `send-keys Enter` when the payload contains a carriage return, so
    /// the `\r` is mandatory or the text sits unsubmitted on the composer. Embedded newlines are
    /// stripped first — the server strips them too, joining the lines into one command, which is
    /// never what the user meant.
    func submitComposedPrompt(_ text: String) async throws {
        let single = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        let trimmed = single.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        _ = try await api.sendInput(
            SessionInputRequest(input: trimmed + "\r", useMux: true, seq: nil, clientId: nil, wait: nil, waitTimeout: nil),
            id: sessionID,
            scope: scope
        )
    }

    /// Sends a raw byte sequence straight down the socket (accessory keys, control characters).
    func sendRaw(_ text: String) {
        let transport = self.transport
        Task { await transport.sendInput(text) }
    }

    // MARK: - Delegate feedback

    func updateTitle(_ newTitle: String) {
        title = newTitle
    }

    func openLink(_ urlString: String) {
        // Only http(s) is opened, and only in `SFSafariViewController`. Any other scheme is
        // ignored rather than handed to `UIApplication.open`, which would let terminal output
        // trigger arbitrary app-scheme navigation.
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return }
        pendingLink = url
    }
}

/// Bridges the escaping `@Sendable` closures `InMemoryTerminalSession` requires to a main-actor
/// object that does not exist yet at `init` time.
///
/// The package calls `write` from its own queue, so the box must be safe to call from any thread;
/// it only forwards into a `Task { @MainActor }`, and the handlers are installed once immediately
/// after construction, before the surface can produce anything.
private final class SessionCallbackBox: @unchecked Sendable {
    var onWrite: (@Sendable (Data) -> Void)?
    var onResize: (@Sendable (InMemoryTerminalViewport) -> Void)?

    func write(_ data: Data) { onWrite?(data) }
    func resize(_ viewport: InMemoryTerminalViewport) { onResize?(viewport) }
}
