import Foundation
import GhosttyTerminal
import Observation
import SwiftUI

/// The single view-facing state tree.
///
/// Owns the active server's clients, the node registry, the session list, and one
/// `TerminalSession` per open pane. Everything it touches below the UI layer is an actor, so this
/// type stays on the main actor and never blocks.
@MainActor
@Observable
final class AppModel {
    // MARK: - Server

    private(set) var servers: [ServerConfiguration] = []
    private(set) var activeServer: ServerConfiguration?
    private(set) var connectionState: ConnectionState = .disconnected

    enum ConnectionState: Sendable, Equatable {
        case disconnected
        case connecting
        case connected(serverVersion: String?)
        case reconnecting(attempt: Int, reason: String)
        case unauthorized
        case failed(String)

        var isLive: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    // MARK: - Nodes

    private(set) var nodes: [NodeState] = []
    private(set) var selectedNodeID: String = "local"
    /// False when the server answered `403` to `GET /api/nodes` — a non-admin in multi-user mode.
    /// The node UI is hidden entirely rather than shown broken.
    private(set) var nodeManagementAvailable = true

    var selectedNode: NodeState? { nodes.first { $0.id == selectedNodeID } }
    var scope: NodeScope { selectedNode?.scope ?? .local }

    // MARK: - Sessions

    private(set) var sessions: [SessionSnapshot] = []
    private(set) var sessionOrder: [String] = []
    private(set) var historySessions: [HistorySession] = []
    private(set) var cases: [CaseInfo] = []
    private(set) var approvals: [ApprovalItem] = []
    private(set) var subagents: [SubagentInfo] = []
    private(set) var globalStats: GlobalStats?
    private(set) var planUsage: PlanUsage?
    private(set) var serverVersion: String?

    /// Sessions with a red "needs you" prompt (permission / question hooks).
    private(set) var needsAttention: Set<String> = []
    /// Sessions with a yellow "waiting for input" prompt (idle hooks).
    private(set) var waitingForInput: Set<String> = []

    /// The sessions the user has open as tabs, in the order they were opened.
    ///
    /// Distinct from `sessions` (everything the server is running) and from `terminals` (the
    /// panes that happen to hold a socket). This is the *workspace*: what the tab strip shows and
    /// what survives navigating back to Home. A session the user never opened is not a tab, and
    /// closing a tab does not close the session on the server.
    private(set) var openSessionIDs: [String] = []

    /// `nil` means the workspace is showing Home rather than a terminal.
    var selectedSessionID: String? {
        didSet {
            guard oldValue != selectedSessionID else { return }
            if let id = selectedSessionID {
                if !openSessionIDs.contains(id) { openSessionIDs.append(id) }
                ensureTerminal(for: id)
                acknowledgeIdleAlert(for: id)
            }
        }
    }

    /// The open tabs that still correspond to a live session, in tab order.
    var openSessions: [SessionSnapshot] {
        openSessionIDs.compactMap { id in sessions.first { $0.id == id } }
    }

    /// Leaves the terminal for Home **without** closing the tab or the session.
    func leaveSession() {
        selectedSessionID = nil
    }

    /// Closes one tab. The session keeps running on the server — this is closing a window, not
    /// stopping an agent, which is `deleteSession`.
    func closeTab(_ id: String) {
        guard let index = openSessionIDs.firstIndex(of: id) else { return }
        openSessionIDs.remove(at: index)
        if secondarySessionID == id { secondarySessionID = nil }
        if selectedSessionID == id {
            // Prefer the tab that took its place, else the one before it, else Home.
            selectedSessionID = openSessionIDs.indices.contains(index)
                ? openSessionIDs[index]
                : openSessionIDs.last
        }
        closeTerminal(for: id)
        closeTranscriptFeed(for: id)
        setComposerDraft("", for: id)
    }

    /// Second pane on iPad. `nil` means single-pane.
    var secondarySessionID: String? {
        didSet {
            guard oldValue != secondarySessionID else { return }
            if let id = secondarySessionID { ensureTerminal(for: id) }
            if let old = oldValue, old != selectedSessionID, old != secondarySessionID {
                closeTerminal(for: old)
            }
        }
    }

    private(set) var terminals: [String: TerminalSession] = [:]

    /// One transcript feed per session that has been shown as a transcript. Created lazily so a
    /// user who never leaves the terminal never polls the endpoint.
    private(set) var transcriptFeeds: [String: TranscriptFeed] = [:]

    /// Per-session pane presentation. Absent means "use the preference".
    private var sessionViewModes: [String: SessionViewMode] = [:]

    /// Unsent composer text, per session.
    ///
    /// ⚠️ Held here, not in the composer's `@State`. The composer is destroyed whenever the pane
    /// switches to the terminal or the session is left, so a half-typed message died with it —
    /// losing work the user had not sent yet. Persisted as well, so it also survives a relaunch.
    private var composerDrafts: [String: String] = UserDefaults.standard
        .dictionary(forKey: AppModel.draftsKey) as? [String: String] ?? [:]

    private static let draftsKey = "codeman.native.composerDrafts"

    /// Files staged in the composer but not yet sent, per session.
    ///
    /// ⚠️ Held as a LIST, not spliced into the draft text. Codeman ultimately delivers a path,
    /// because it types into a terminal — but pasting that path into the field the moment you pick
    /// a photo makes the composer look like a shell prompt. Staging the picks lets the composer
    /// show thumbnails and only append the paths at send time.
    private var pendingAttachments: [String: [PendingAttachment]] = [:]

    struct PendingAttachment: Identifiable, Sendable, Equatable {
        let id = UUID()
        /// Server-side path the agent will open.
        var path: String
        var fileName: String
        /// Local preview, so the chip shows the picture without a round trip.
        var preview: UIImage?

        static func == (lhs: PendingAttachment, rhs: PendingAttachment) -> Bool { lhs.id == rhs.id }
    }

    func attachments(for sessionID: String) -> [PendingAttachment] { pendingAttachments[sessionID] ?? [] }

    func addAttachment(_ attachment: PendingAttachment, for sessionID: String) {
        pendingAttachments[sessionID, default: []].append(attachment)
    }

    func removeAttachment(_ id: UUID, for sessionID: String) {
        pendingAttachments[sessionID]?.removeAll { $0.id == id }
    }

    func clearAttachments(for sessionID: String) {
        pendingAttachments.removeValue(forKey: sessionID)
    }

    func composerDraft(for sessionID: String) -> String { composerDrafts[sessionID] ?? "" }

    func setComposerDraft(_ text: String, for sessionID: String) {
        if text.isEmpty {
            composerDrafts.removeValue(forKey: sessionID)
        } else {
            composerDrafts[sessionID] = text
        }
        UserDefaults.standard.set(composerDrafts, forKey: AppModel.draftsKey)
    }

    /// Sessions ordered the way both web home screens order them.
    var orderedSessions: [SessionSnapshot] {
        var index: [String: Int] = [:]
        for (position, id) in sessionOrder.enumerated() { index[id] = position }
        return SessionOrdering.sorted(
            sessions,
            needsAttention: needsAttention,
            waitingForInput: waitingForInput,
            orderIndex: index
        )
    }

    func session(id: String) -> SessionSnapshot? { sessions.first { $0.id == id } }

    // MARK: - Settings

    private(set) var customActions: [CustomRunAction] = []
    var preferences = UserPreferences()
    private(set) var terminalController: TerminalController

    // MARK: - Errors surfaced to the UI

    var alert: AppAlert?
    /// Set by the `codeman://connect` deep-link handler; presents the add-server sheet prefilled.
    var pendingQuickConnect: QuickConnectRequest?

    struct AppAlert: Identifiable, Sendable {
        let id = UUID()
        var title: String
        var message: String
    }

    // MARK: - Collaborators

    private let persistence: any ServerPersisting
    private let credentials: any CredentialStoring
    private let trust = ServerTrustEvaluator()

    /// Internal rather than private so `AppModel+Actions` can reach it; views go through
    /// `apiClient`, never through a client of their own.
    private(set) var currentAPI: (any APIClientProtocol)?
    var trustEvaluator: ServerTrustEvaluator { trust }
    /// A separate session for pre-save connection probes, so a failed probe cannot poison the
    /// live REST session's connection reuse.
    @ObservationIgnored private(set) lazy var probeSession: URLSession = CodemanURLSession.make(delegate: trust)

    private var events: EventStream?
    private var eventTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var nodeProbeTask: Task<Void, Never>?

    @ObservationIgnored private lazy var restSession: URLSession = CodemanURLSession.make(delegate: trust)
    @ObservationIgnored private lazy var streamSession: URLSession = CodemanURLSession.makeStreaming(delegate: trust)

    private let decoder = JSONDecoder()

    init(persistence: any ServerPersisting, credentials: any CredentialStoring) {
        self.persistence = persistence
        self.credentials = credentials
        // Read into a local first: `preferences` has a default value, so reading it back before
        // every stored property is initialised is not allowed, and the controller needs the
        // user's saved theme rather than the default one.
        let loaded = UserPreferences.load()
        preferences = loaded
        terminalController = TerminalController(theme: loaded.terminalTheme.resolved())
    }

    // MARK: - Bootstrap

    /// Set from a UI-testing launch argument; connects before the saved-server path runs.
    var pendingPreconnect: LaunchConfiguration.Preconnect?

    func bootstrap() async {
        if let preconnect = pendingPreconnect {
            pendingPreconnect = nil
            if let normalized = ServerConfiguration.normalize(preconnect.url) {
                let host = URL(string: normalized)?.host() ?? normalized
                let configuration = ServerConfiguration(
                    displayName: host,
                    baseURLString: normalized,
                    username: preconnect.username,
                    usesBearerToken: false,
                    pinnedCertificateSHA256: nil
                )
                try? await addServer(
                    configuration,
                    credential: preconnect.password.isEmpty
                        ? .none
                        : .basic(username: preconnect.username, password: preconnect.password)
                )
                return
            }
        }

        servers = (try? await persistence.loadServers()) ?? []
        for server in servers where server.pinnedCertificateSHA256 != nil {
            if let host = server.host {
                trust.setPin(server.pinnedCertificateSHA256, forHost: host)
            }
        }
        if let last = servers.max(by: { ($0.lastUsedAt ?? .distantPast) < ($1.lastUsedAt ?? .distantPast) }) {
            await activate(server: last)
        }
    }

    // MARK: - Server lifecycle

    func activate(server: ServerConfiguration) async {
        await teardown()

        activeServer = server
        connectionState = .connecting
        if let host = server.host { trust.setPin(server.pinnedCertificateSHA256, forHost: host) }

        let client = APIClient(server: server, credentials: credentials, session: restSession)
        currentAPI = client
        events = EventStream(server: server, credentials: credentials, session: streamSession)

        var stamped = server
        stamped.lastUsedAt = .now
        try? await persistence.upsert(stamped)
        if let index = servers.firstIndex(where: { $0.id == server.id }) { servers[index] = stamped }
        activeServer = stamped

        await refreshEverything()
        startEventStream()
    }

    func addServer(_ server: ServerConfiguration, credential: ServerCredential) async throws {
        try await credentials.store(credential, for: server.id)
        try await persistence.upsert(server)
        servers = (try? await persistence.loadServers()) ?? servers
        await activate(server: server)
    }

    func removeServer(_ server: ServerConfiguration) async {
        if activeServer?.id == server.id { await teardown(); activeServer = nil }
        try? await credentials.remove(for: server.id)
        try? await persistence.delete(id: server.id)
        servers.removeAll { $0.id == server.id }
    }

    func signOut() async {
        if let api = currentAPI { try? await api.logout(scope: .local) }
        if let server = activeServer { try? await credentials.remove(for: server.id) }
        await teardown()
        activeServer = nil
        connectionState = .disconnected
    }

    private func teardown() async {
        eventTask?.cancel(); eventTask = nil
        pollTask?.cancel(); pollTask = nil
        nodeProbeTask?.cancel(); nodeProbeTask = nil
        await events?.stop()
        events = nil

        for terminal in terminals.values { terminal.stop() }
        terminals.removeAll()

        sessions = []
        historySessions = []
        cases = []
        approvals = []
        subagents = []
        nodes = []
        selectedNodeID = "local"
        selectedSessionID = nil
        secondarySessionID = nil
        openSessionIDs.removeAll()
        currentAPI = nil
    }

    // MARK: - Refresh

    func refreshEverything() async {
        guard let api = currentAPI else { return }

        await refreshNodes()

        do {
            async let sessionList = api.listSessions(scope: scope)
            async let caseList = api.listCases(scope: scope)
            async let settings = api.settings(scope: scope)

            sessions = try await sessionList
            cases = (try? await caseList) ?? cases
            if let loaded = try? await settings {
                customActions = loaded.customRunActions ?? customActions
            }
            connectionState = .connected(serverVersion: serverVersion)
        } catch let error as APIError {
            handle(error)
            return
        } catch {
            connectionState = .failed(error.localizedDescription)
            return
        }

        // Best-effort extras: none of these should turn a working connection into a failure.
        approvals = (try? await api.approvals(scope: scope)) ?? []
        subagents = (try? await api.subagents(scope: scope)) ?? []
        historySessions = (try? await api.historySessions(scope: scope)) ?? []
        rebuildAlertSets()
    }

    func refreshSessions() async {
        guard let api = currentAPI else { return }
        if let list = try? await api.listSessions(scope: scope) { sessions = list }
    }

    func refreshNodes() async {
        guard let api = currentAPI else { return }

        // The reachability probe is the one node route that is not admin-gated, so it works for
        // every user and doubles as the server-version read.
        if let info = try? await api.nodeInfo(scope: .local) {
            serverVersion = info.version
        }

        do {
            let response = try await api.listNodes()
            nodeManagementAvailable = true
            var list = [NodeState(dto: response.local, isLocal: true)]
            list.append(contentsOf: response.nodes.map { NodeState(dto: $0, isLocal: false) })
            nodes = list
            if !nodes.contains(where: { $0.id == selectedNodeID }) { selectedNodeID = "local" }
            probeRemoteNodes()
        } catch let error as APIError where error.isForbidden {
            // Multi-user non-admin: federation is not theirs to see. Present the single local
            // node and hide the management UI rather than showing a broken panel.
            nodeManagementAvailable = false
            nodes = [NodeState(id: "local", name: activeServer?.displayName ?? "Codeman",
                               baseURLString: activeServer?.baseURLString ?? "", isLocal: true,
                               reachability: .online(version: serverVersion))]
            selectedNodeID = "local"
        } catch {
            nodeManagementAvailable = false
            if nodes.isEmpty {
                nodes = [NodeState(id: "local", name: activeServer?.displayName ?? "Codeman",
                                   baseURLString: activeServer?.baseURLString ?? "", isLocal: true,
                                   reachability: .online(version: serverVersion))]
            }
        }
    }

    /// Probes every enabled remote node and records what came back.
    ///
    /// ⚠️ **Concurrent, and each result applies as it lands.** The sweep used to await each node
    /// in turn and `guard !Task.isCancelled` *after* receiving a result, so any refresh during the
    /// sweep — an SSE reconnect, a pull-to-refresh — cancelled it and threw away answers already
    /// paid for, leaving nodes stuck on whatever they read before. A node behind a slow link also
    /// delayed every node after it.
    private func probeRemoteNodes() {
        nodeProbeTask?.cancel()
        guard let api = currentAPI, nodeManagementAvailable else { return }
        let remoteIDs = nodes.filter { !$0.isLocal && $0.enabled }.map(\.id)
        guard !remoteIDs.isEmpty else { return }

        nodeProbeTask = Task { [weak self] in
            await withTaskGroup(of: (String, NodeTestResponse?).self) { group in
                for id in remoteIDs {
                    group.addTask { (id, try? await api.testNode(id: id)) }
                }
                for await (id, result) in group {
                    guard let self else { return }
                    // Applied even if this task was cancelled meanwhile: the answer is true
                    // regardless of who asked, and dropping it is what left nodes unresolved.
                    self.applyProbe(result, to: id)
                }
            }
        }
    }

    private func applyProbe(_ result: NodeTestResponse?, to id: String) {
        guard let index = nodes.firstIndex(where: { $0.id == id }) else { return }
        if let result, result.ok {
            nodes[index].reachability = .online(version: result.info?.version)
        } else if let message = result?.message, !message.isEmpty {
            nodes[index].reachability = .offline(reason: message)
        } else if result != nil {
            nodes[index].reachability = .offline(reason: "The node answered, but not as a Codeman server.")
        } else {
            // The probe itself failed (no route, TLS, timeout). Say that, rather than putting
            // words in the node's mouth about a response it never sent.
            nodes[index].reachability = .offline(reason: "Could not reach this node from the server.")
        }
    }

    func selectNode(_ id: String) async {
        guard id != selectedNodeID else { return }
        // A node switch is a new epoch for every pane: tear the terminals down so no in-flight
        // frame from the old node can land in a pane now showing the new one.
        for terminal in terminals.values { terminal.stop() }
        terminals.removeAll()
        selectedSessionID = nil
        secondarySessionID = nil
        // Tabs are per node: the ids belong to the node that issued them.
        openSessionIDs.removeAll()

        selectedNodeID = id
        await refreshEverything()
        restartEventStream()
    }

    // MARK: - Events

    private func startEventStream() {
        guard let events else { return }
        let scope = self.scope
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            let stream = await events.start(scope: scope)
            for await signal in stream {
                guard let self else { return }
                await self.handle(signal)
            }
        }
        startPollFallback()
    }

    private func restartEventStream() {
        eventTask?.cancel()
        Task { [weak self] in
            await self?.events?.stop()
            self?.startEventStream()
        }
    }

    /// A low-frequency safety net. The SSE stream is the live path; this exists so a stream that
    /// silently stops delivering (a proxy that idle-closed it) cannot leave the list frozen
    /// indefinitely. It is deliberately slow — the stream, not the poll, is what makes the UI feel
    /// live.
    private func startPollFallback() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(45))
                guard let self, !Task.isCancelled else { return }
                await self.refreshSessions()
            }
        }
    }

    private func handle(_ signal: EventStreamSignal) async {
        switch signal {
        case .connected:
            if case .reconnecting = connectionState { await refreshEverything() }
            connectionState = .connected(serverVersion: serverVersion)

        case let .reconnecting(attempt, _, reason):
            connectionState = .reconnecting(attempt: attempt, reason: reason)

        case let .failed(error):
            handle(error)

        case let .frame(frame):
            apply(frame)
        }
    }

    private func apply(_ frame: SSEFrame) {
        guard let known = frame.name.known else { return }

        switch known {
        case .initial:
            if let state = frame.decode(InitialState.self, using: decoder) {
                if let list = state.sessions { sessions = list }
                sessionOrder = state.sessionOrder ?? sessionOrder
                globalStats = state.globalStats ?? globalStats
                planUsage = state.planUsage ?? planUsage
                subagents = state.subagents ?? subagents
                serverVersion = state.version ?? serverVersion
            }

        case .heartbeat:
            break // liveness only

        case .sessionCreated:
            if let payload = frame.decode(SessionUpdatedPayload.self, using: decoder) {
                upsert(payload.session)
            } else if let snapshot = frame.decode(SessionSnapshot.self, using: decoder) {
                upsert(snapshot)
            }

        case .sessionUpdated:
            if let payload = frame.decode(SessionUpdatedPayload.self, using: decoder) {
                upsert(payload.session)
            }

        case .sessionDeleted:
            if let id = frame.decode(SessionScopedPayload.self, using: decoder)?.resolvedID {
                remove(sessionID: id)
            }

        case .sessionIdle, .sessionExit, .sessionWorking, .sessionInteractive, .sessionRunning,
             .sessionCliInfo, .sessionPinned, .sessionStatusTelemetry, .sessionRespawnBreakerTripped:
            // These carry partial payloads; the session list is the source of truth, so refresh
            // rather than patching a half-shaped object into it.
            Task { [weak self] in await self?.refreshSessions() }

        case .hookPermissionPrompt, .hookElicitationDialog:
            if let id = frame.decode(HookEventPayload.self, using: decoder)?.resolvedID {
                needsAttention.insert(id)
                waitingForInput.remove(id)
                NotificationPresenter.shared.notifyNeedsAttention(sessionName: displayName(for: id))
            }

        case .hookIdlePrompt:
            if let id = frame.decode(HookEventPayload.self, using: decoder)?.resolvedID,
               !needsAttention.contains(id) {
                waitingForInput.insert(id)
                NotificationPresenter.shared.notifyIdle(sessionName: displayName(for: id))
            }

        case .hookStop, .hookElicitationComplete, .hookElicitationResponse:
            if let id = frame.decode(HookEventPayload.self, using: decoder)?.resolvedID {
                needsAttention.remove(id)
                waitingForInput.remove(id)
            }

        case .transcriptToolStart, .transcriptToolEnd, .transcriptComplete:
            // ⚠️ These are SIGNALS, not content — they carry a tool name and an error flag, never
            // conversation blocks. They can only say "the transcript moved"; the feed coalesces
            // the burst a turn produces and refetches once.
            //
            // ⚠️ They also carry no session id, so every open feed is nudged. That is correct
            // rather than lazy: only the visible session has a running feed, and a refetch it did
            // not need is one bounded GET.
            for feed in transcriptFeeds.values { feed.signalChanged() }

        case .approvalPending, .approvalUpdated, .approvalResolved:
            Task { [weak self] in await self?.refreshApprovals() }

        case .subagentDiscovered, .subagentUpdated, .subagentCompleted:
            Task { [weak self] in await self?.refreshSubagents() }

        case .sessionOrderChanged:
            struct OrderPayload: Decodable, Sendable { var order: [String]? }
            if let order = frame.decode(OrderPayload.self, using: decoder)?.order { sessionOrder = order }

        case .caseCreated, .caseLinked, .caseDeleted:
            Task { [weak self] in await self?.refreshCases() }

        default:
            break
        }
    }

    private func upsert(_ snapshot: SessionSnapshot) {
        if let index = sessions.firstIndex(where: { $0.id == snapshot.id }) {
            sessions[index] = snapshot
        } else {
            sessions.append(snapshot)
        }
    }

    private func remove(sessionID: String) {
        sessions.removeAll { $0.id == sessionID }
        needsAttention.remove(sessionID)
        waitingForInput.remove(sessionID)
        // The feed polls on a timer; leaving it behind would keep fetching a transcript for a
        // session that no longer exists.
        closeTranscriptFeed(for: sessionID)
        // A session that ended server-side stops being a tab: the pane it backed cannot come
        // back, and leaving the tab would offer a dead terminal.
        if openSessionIDs.contains(sessionID) {
            closeTab(sessionID)
        } else {
            closeTerminal(for: sessionID)
        }
        if secondarySessionID == sessionID { secondarySessionID = nil }
    }

    private func rebuildAlertSets() {
        // Seed the tab-alert state machine from the approvals inbox on every full refresh. The
        // web client does this unconditionally, and for the same reason: without it a relaunch
        // shows a calm list while a permission dialog is blocking a session.
        needsAttention.removeAll()
        waitingForInput.removeAll()
        for item in approvals {
            if item.isIdlePrompt {
                if item.acknowledgedAt == nil { waitingForInput.insert(item.sessionId) }
            } else {
                needsAttention.insert(item.sessionId)
            }
        }
    }

    private func displayName(for id: String) -> String {
        session(id: id)?.displayName ?? String(id.prefix(8))
    }

    // MARK: - Alert acknowledgement

    /// Viewing a session **acknowledges** its idle alert; it does not resolve the item, which
    /// stays answerable. Looking at a permission dialog answers nothing, so the red alert is
    /// deliberately untouched here.
    private func acknowledgeIdleAlert(for id: String) {
        guard waitingForInput.contains(id) else { return }
        waitingForInput.remove(id)
    }

    func refreshApprovals() async {
        guard let api = currentAPI else { return }
        approvals = (try? await api.approvals(scope: scope)) ?? approvals
        rebuildAlertSets()
    }

    func refreshSubagents() async {
        guard let api = currentAPI else { return }
        subagents = (try? await api.subagents(scope: scope)) ?? subagents
    }

    func refreshCases() async {
        guard let api = currentAPI else { return }
        cases = (try? await api.listCases(scope: scope)) ?? cases
    }

    // MARK: - Transcript

    /// How one session's pane is presented. Per-session and in-memory: switching a pane to the
    /// transcript is a way of looking at *that* conversation right now, not a durable property of
    /// it. The starting point comes from `preferences.defaultSessionViewMode`.
    func viewMode(for sessionID: String) -> SessionViewMode {
        sessionViewModes[sessionID] ?? preferences.defaultSessionViewMode
    }

    func setViewMode(_ mode: SessionViewMode, for sessionID: String) {
        sessionViewModes[sessionID] = mode
        // The terminal keeps streaming while the transcript is showing — its socket is the input
        // path, and tearing it down would make switching back a full reconnect plus snapshot.
        if mode == .transcript {
            ensureTranscriptFeed(for: sessionID)?.start()
        } else {
            transcriptFeeds[sessionID]?.stop()
        }
    }

    @discardableResult
    func ensureTranscriptFeed(for sessionID: String) -> TranscriptFeed? {
        if let existing = transcriptFeeds[sessionID] { return existing }
        guard let api = currentAPI else { return nil }
        let feed = TranscriptFeed(sessionID: sessionID, scope: scope, api: api)
        transcriptFeeds[sessionID] = feed
        return feed
    }

    private func closeTranscriptFeed(for sessionID: String) {
        transcriptFeeds.removeValue(forKey: sessionID)?.stop()
        sessionViewModes.removeValue(forKey: sessionID)
    }

    // MARK: - Terminals

    @discardableResult
    func ensureTerminal(for sessionID: String) -> TerminalSession? {
        if let existing = terminals[sessionID] { return existing }
        guard let api = currentAPI, let server = activeServer else { return nil }

        let transport = TerminalTransport(
            server: server,
            credentials: credentials,
            session: streamSession,
            clientID: ClientIdentity.terminalClientID(server: server.id, session: sessionID)
        )
        let terminal = TerminalSession(
            sessionID: sessionID,
            scope: scope,
            transport: transport,
            api: api,
            viewportClass: { [weak self] in self?.preferences.viewportClass ?? "mobile" }
        )
        terminals[sessionID] = terminal
        terminal.start()
        return terminal
    }

    func closeTerminal(for sessionID: String) {
        guard sessionID != selectedSessionID, sessionID != secondarySessionID else { return }
        terminals.removeValue(forKey: sessionID)?.stop()
    }

    func terminal(for sessionID: String) -> TerminalSession? { terminals[sessionID] }

    // MARK: - Scene phase

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .background:
            // Sockets are left alone: iOS gives a grace period and a quick app switch should not
            // lose the pane. The event stream is stopped so it cannot accumulate a backlog.
            Task { [weak self] in await self?.events?.stop() }
        case .active:
            startEventStream()
            for terminal in terminals.values { terminal.refreshAfterForeground() }
            Task { [weak self] in await self?.refreshSessions() }
        default:
            break
        }
    }

    // MARK: - Error handling

    private func handle(_ error: APIError) {
        if error.isUnauthorized {
            // Never auto-retry: the failure bucket is per-IP and shared with the login path.
            connectionState = .unauthorized
            return
        }
        if case let .rateLimited(retryAfter) = error {
            connectionState = .failed(APIError.rateLimited(retryAfter: retryAfter).localizedDescription)
            return
        }
        connectionState = .failed(error.localizedDescription)
    }

    func report(_ error: any Error, title: String) {
        let message = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
        alert = AppAlert(title: title, message: message)
        Log.ui.error("\(title, privacy: .public): \(message, privacy: .private)")
    }

    /// Replaces the in-memory action list after a successful server write.
    func applyCustomActions(_ actions: [CustomRunAction]) {
        customActions = actions
    }

    // MARK: - Preferences

    func updatePreferences(_ mutate: (inout UserPreferences) -> Void) {
        mutate(&preferences)
        preferences.save()
        _ = terminalController.setTheme(preferences.terminalTheme.resolved())
    }
}

/// Stable per-install identifiers.
enum ClientIdentity {
    private static let installKey = "codeman.native.installID"

    static var installID: String {
        if let existing = UserDefaults.standard.string(forKey: installKey) { return existing }
        let fresh = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        UserDefaults.standard.set(fresh, forKey: installKey)
        return fresh
    }

    /// One stable `cid` per (install, server, session).
    ///
    /// `WsConnectionRegistry` supersedes only the *same* `cid`, so a stable value means a
    /// reconnect reclaims its own slot. A fresh id per attempt would burn through the
    /// five-connections-per-session cap on a flaky link and start getting `4008`.
    static func terminalClientID(server: UUID, session: String) -> String {
        let raw = "\(installID)-\(server.uuidString.prefix(8))-\(session.prefix(8))"
        // Must match /^[A-Za-z0-9_-]{8,64}$/-style expectations; keep it conservative.
        let filtered = raw.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return String(filtered.prefix(64))
    }
}
