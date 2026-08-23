import Foundation

/// `SessionMode` — `src/types/session.ts:50`.
enum SessionMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case claude
    case shell
    case opencode
    case codex
    case gemini
    case antigravity
    case pi

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .shell: "Shell"
        case .opencode: "OpenCode"
        case .codex: "Codex"
        case .gemini: "Gemini"
        case .antigravity: "Antigravity"
        case .pi: "Pi"
        }
    }

    var symbolName: String {
        switch self {
        case .claude: "sparkles"
        case .shell: "terminal"
        case .opencode: "chevron.left.forwardslash.chevron.right"
        case .codex: "curlybraces"
        case .gemini: "diamond"
        case .antigravity: "arrow.up.forward.circle"
        case .pi: "function"
        }
    }

    /// Modes whose CLI renders its own TUI. `isExternalCliMode()` in `session.ts` gates
    /// Claude-specific behaviour (Ralph, token parsing, `❯` readiness) off for these.
    var isExternalCLI: Bool {
        switch self {
        case .claude, .shell: false
        case .opencode, .codex, .gemini, .antigravity, .pi: true
        }
    }
}

/// `SessionStatus` — `src/types/session.ts:35`.
enum SessionStatus: String, Codable, Sendable {
    case idle
    case busy
    case stopped
    case error
}

/// `SessionBackend` — `src/types/session.ts:49`. Non-secret badge metadata only.
struct SessionBackend: Codable, Sendable, Hashable {
    enum Kind: String, Codable, Sendable {
        case anthropic
        case openai
        case gemini
        case googleVertex = "google-vertex"
        case opencode
        case codex
        case antigravity
        case custom
    }

    var label: String
    var type: Kind
    var source: String?
    var model: String?
}

struct SessionRemoteInfo: Codable, Sendable, Hashable {
    var host: String?
    var username: String?
    var owned: Bool?
    var remoteSessionName: String?
}

struct SessionDockerInfo: Codable, Sendable, Hashable {
    var containerName: String?
    var image: String?
}

/// The light `SessionState` the server broadcasts and returns from `GET /api/sessions`.
///
/// Deliberately tolerant: every field beyond `id` is optional, because the server ships light
/// state from several call sites with slightly different fills and a strict model would make the
/// whole list undecodable over one missing key.
struct SessionSnapshot: Codable, Sendable, Identifiable, Hashable {
    var id: String
    var pid: Int?
    var status: SessionStatus?
    var workingDir: String?
    var name: String?
    var mode: SessionMode?
    var owner: String?
    var parentSessionId: String?
    var createdAt: Double?
    var lastActivityAt: Double?
    var lastSubmitAt: Double?
    var pinned: Bool?
    var pinnedAt: Double?

    var totalCost: Double?
    var inputTokens: Int?
    var outputTokens: Int?

    var respawnEnabled: Bool?
    var respawnBlocked: Bool?
    var ralphEnabled: Bool?
    var ralphCompletionPhrase: String?

    var cliVersion: String?
    var cliModel: String?
    var cliAccountType: String?
    var cliLatestVersion: String?
    var backend: SessionBackend?

    var autoResumeEnabled: Bool?
    var autoResumeAt: Double?

    var remote: SessionRemoteInfo?
    var docker: SessionDockerInfo?

    var effort: String?
    var currentTaskId: String?

    // MARK: - Derived

    var displayName: String {
        if let name, !name.isEmpty { return name }
        if let workingDir, let last = workingDir.split(separator: "/").last { return String(last) }
        return String(id.prefix(8))
    }

    var effectiveStatus: SessionStatus { status ?? .idle }

    var isRunning: Bool { pid != nil && effectiveStatus != .stopped }

    var createdDate: Date? { createdAt.map { Date(timeIntervalSince1970: $0 / 1000) } }
    var lastActivityDate: Date? { lastActivityAt.map { Date(timeIntervalSince1970: $0 / 1000) } }
    var lastSubmitDate: Date? { lastSubmitAt.map { Date(timeIntervalSince1970: $0 / 1000) } }

    /// Badge text for the model in use. Prefers the authoritative CLI-reported model, then the
    /// backend hint. Never guesses.
    var modelBadge: String? {
        if let cliModel, !cliModel.isEmpty { return cliModel }
        if let model = backend?.model, !model.isEmpty { return model }
        return nil
    }

    var backendBadge: String? {
        if let label = backend?.label, !label.isEmpty { return label }
        if let account = cliAccountType, !account.isEmpty { return account }
        return nil
    }

    var locationBadge: String? {
        if let remote, let host = remote.host { return remote.username.map { "\($0)@\(host)" } ?? host }
        if let docker, let container = docker.containerName { return container }
        return nil
    }
}

// MARK: - Ordering

/// The home-screen ordering rule from `CodemanSessionOrder` (`constants.js`), reproduced so the
/// native sidebar answers "which of these wants me next?" the same way the web home screens do.
///
/// Rank: needs → error → waiting → working → idle → done. The tiebreak **flips direction**
/// halfway down: states a session is still *in* sort oldest-first (blocked longest = most
/// urgent); states it has *stopped* in sort newest-first (the one that just went quiet is the one
/// you came back for). A `0`/absent stamp means "unknown" and sorts last within its state.
enum SessionOverviewRank: Int, Sendable, Comparable {
    case needs = 0
    case error = 1
    case waiting = 2
    case working = 3
    case idle = 4
    case done = 5

    /// True for states the session is still *in*, which sort oldest-first.
    var isOngoing: Bool {
        switch self {
        case .needs, .error, .waiting, .working: true
        case .idle, .done: false
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

enum SessionOrdering {
    static func rank(for session: SessionSnapshot, needsAttention: Bool, waitingForInput: Bool) -> SessionOverviewRank {
        if needsAttention { return .needs }
        if session.effectiveStatus == .error { return .error }
        if waitingForInput { return .waiting }
        if session.effectiveStatus == .busy { return .working }
        if session.effectiveStatus == .stopped || session.pid == nil { return .done }
        return .idle
    }

    /// The stamp the tiebreak keys off. A *working* pane repaints about once a second, so its
    /// `lastActivityAt` is always "now" — the running group must key off `lastSubmitAt` (the
    /// pane's last Enter) or every running turn looks freshly started.
    static func tiebreakStamp(for session: SessionSnapshot, rank: SessionOverviewRank) -> Double {
        if rank == .working {
            if let submit = session.lastSubmitAt, submit > 0 { return submit }
            // No submit stamp: fall back to last activity, which lands it at the SHORT end of the
            // group rather than falsely leading it.
            return session.lastActivityAt ?? 0
        }
        return session.lastActivityAt ?? session.createdAt ?? 0
    }

    /// Sorts a list into home-screen order. `orderIndex` is the user's tab order and is the final
    /// tiebreak, so the list is deterministic and cannot shuffle between renders.
    static func sorted(
        _ sessions: [SessionSnapshot],
        needsAttention: Set<String>,
        waitingForInput: Set<String>,
        orderIndex: [String: Int]
    ) -> [SessionSnapshot] {
        sessions
            .map { session -> (SessionSnapshot, SessionOverviewRank, Double, Int) in
                let r = rank(
                    for: session,
                    needsAttention: needsAttention.contains(session.id),
                    waitingForInput: waitingForInput.contains(session.id)
                )
                return (session, r, tiebreakStamp(for: session, rank: r), orderIndex[session.id] ?? Int.max)
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }

                let (l, r) = (lhs.2, rhs.2)
                // 0 means unknown, not "the epoch" — it sorts last in either direction.
                if l == 0 || r == 0 {
                    if l != r { return r == 0 }
                } else if l != r {
                    return lhs.1.isOngoing ? l < r : l > r
                }

                if lhs.3 != rhs.3 { return lhs.3 < rhs.3 }
                return lhs.0.id < rhs.0.id
            }
            .map(\.0)
    }
}

// MARK: - Requests

/// `CreateSessionSchema` — `src/web/schemas.ts:325`.
struct CreateSessionRequest: Encodable, Sendable {
    var workingDir: String?
    var mode: SessionMode?
    var name: String?
    var parentSessionId: String?
    var envOverrides: [String: String]?
    var effort: String?
    var modelOverride: String?
    var statusLineTelemetry: Bool?
    var resumeSessionId: String?
}

/// `QuickStartSchema` — `src/web/schemas.ts:740`. The preferred launch path: it creates the case
/// if missing, resolves remote-SSH and Docker cases, and *starts* the session.
struct QuickStartRequest: Encodable, Sendable {
    var caseName: String?
    var sessionName: String?
    var mode: SessionMode?
    var launchCommand: String?
    var modelOverride: String?
    var envOverrides: [String: String]?
    var effort: String?
    var parentSessionId: String?
}

struct QuickStartResponse: Decodable, Sendable {
    var sessionId: String
    var casePath: String?
    var caseName: String?
}

struct CreateSessionResponse: Decodable, Sendable {
    var session: SessionSnapshot
}

/// `SessionInputWithLimitSchema` — `src/web/schemas.ts:1133`.
struct SessionInputRequest: Encodable, Sendable {
    var input: String
    var useMux: Bool?
    var seq: Int?
    var clientId: String?
    var wait: Bool?
    var waitTimeout: Int?
}

struct SessionInputResponse: Decodable, Sendable {
    struct WaitResult: Decodable, Sendable {
        var timedOut: Bool?
        var signal: String?
        var aborted: Bool?
        var ended: Bool?
        var timeoutMs: Int?
    }

    var delivered: Bool?
    var duplicate: Bool?
    var status: SessionStatus?
    var limitPaused: Bool?
    var wait: WaitResult?
}

/// `ResizeSchema` — `src/web/schemas.ts:379`.
struct ResizeRequest: Encodable, Sendable {
    var cols: Int
    var rows: Int
    var viewportType: String?
    var force: Bool?
}

struct RenameSessionRequest: Encodable, Sendable {
    var name: String
}

/// Response of `GET /api/sessions/:id/terminal` — the authoritative reconnect snapshot.
struct TerminalSnapshot: Decodable, Sendable {
    enum Source: String, Decodable, Sendable {
        case history
        case muxVisible = "mux-visible"
        case muxFullHistory = "mux-full-history"
    }

    var terminalBuffer: String
    var status: SessionStatus?
    var fullSize: Int?
    var truncated: Bool?
    /// `'capped'` means the byte ceiling was hit and the oldest output is genuinely out of reach.
    /// `'tail'` means an intentional partial replay that a `full=1` pull can still recover.
    var truncationReason: String?
    var retainedBytes: Int?
    var source: Source?
    /// Width, in cells, of the pane this capture was laid out at.
    ///
    /// ⚠️ Not recoverable from the bytes: a full-history capture is `capture-pane -J`, whose
    /// *logical* lines are routinely wider than the pane. Rendering a capture into a grid of a
    /// different width is what produces mid-word breaks and prompt-highlight overhang, so the
    /// client compares this against its own grid instead of assuming they agree.
    /// `nil` when the body came from byte history, which has no single layout width.
    var paneCols: Int?
    var paneRows: Int?
}

/// A row from `GET /api/history/sessions` / `GET /api/sessions/unified`.
struct HistorySession: Decodable, Sendable, Identifiable, Hashable {
    var id: String { sessionId ?? claudeSessionId ?? path ?? UUID().uuidString }

    var sessionId: String?
    var claudeSessionId: String?
    var name: String?
    var path: String?
    var firstPrompt: String?
    var lastActivityAt: Double?
    var mode: SessionMode?
    var messageCount: Int?

    /// The label the row renders — and therefore the key an A–Z sort must use. Most rows are
    /// transcript-backed and have no `name`, so sorting on `name` alone silently does nothing.
    var rowLabel: String {
        if let name, !name.isEmpty { return name }
        if let firstPrompt, !firstPrompt.isEmpty { return firstPrompt }
        return path ?? id
    }
}
