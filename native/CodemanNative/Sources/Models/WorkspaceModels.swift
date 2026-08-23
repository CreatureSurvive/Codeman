import Foundation

/// A row of `GET /api/cases`.
struct CaseInfo: Decodable, Sendable, Identifiable, Hashable {
    var id: String { name }

    var name: String
    var path: String?
    var description: String?
    var linked: Bool?
    var remote: Bool?
    var docker: Bool?
    var lastUsedAt: Double?
    var sessionCount: Int?
}

struct CreateCaseRequest: Encodable, Sendable {
    var name: String
    var description: String?
}

struct CreateCaseResponse: Decodable, Sendable {
    struct Payload: Decodable, Sendable {
        var name: String
        var path: String
    }

    var `case`: Payload
}

// MARK: - Filesystem path picker

/// `FilesystemBrowseEntry` — `src/types/common.ts:78`.
struct FilesystemEntry: Decodable, Sendable, Identifiable, Hashable {
    enum Kind: String, Decodable, Sendable {
        case file
        case directory
    }

    enum PreviewKind: String, Decodable, Sendable {
        case image
        case text
        case document
    }

    var id: String { path }

    var name: String
    var path: String
    var type: Kind
    var size: Int?
    var symlink: Bool?
    var previewKind: PreviewKind?

    var isDirectory: Bool { type == .directory }
}

/// `FilesystemBrowseRoot` — `src/types/common.ts:85`.
struct FilesystemRoot: Decodable, Sendable, Identifiable, Hashable {
    var id: String { path }
    var label: String
    var path: String
}

/// `FilesystemBrowseData` — `src/types/common.ts:92`.
///
/// `roots` is server-computed and already multi-user-scoped: in multi-user mode a non-admin gets
/// only their own case space, because per-user spaces live inside `homedir()` and a `Home` root
/// would expose every other user's workspace. The client renders what it is given and never
/// synthesises a root.
struct FilesystemListing: Decodable, Sendable {
    var path: String
    var parent: String?
    var root: String
    var roots: [FilesystemRoot]
    var entries: [FilesystemEntry]
    var truncated: Bool
}

// MARK: - Attachments

struct AttachmentRegistrationRequest: Encodable, Sendable {
    var path: String
    /// `false` registers quietly — no `attachment:detected` broadcast. Used when the app is
    /// already showing the file and a card announcing it would be noise.
    var notify: Bool?
}

struct AttachmentDescriptor: Decodable, Sendable, Identifiable, Hashable {
    var id: String { attachmentId ?? path ?? UUID().uuidString }

    var attachmentId: String?
    var path: String?
    var name: String?
    var size: Int?
    var mimeType: String?
    var kind: String?
}

/// Response of `POST /api/sessions/:id/paste-image`.
struct PasteImageResponse: Decodable, Sendable {
    var path: String
    var filename: String
}

// MARK: - Approvals

struct ApprovalItem: Decodable, Sendable, Identifiable, Hashable {
    struct Option: Decodable, Sendable, Hashable {
        var digit: String?
        var label: String?
    }

    var id: String
    var sessionId: String
    var kind: String?
    var title: String?
    var body: String?
    var options: [Option]?
    var createdAt: Double?
    var acknowledgedAt: Double?

    /// Idle items arm the yellow "waiting" alert; permission/question items arm the red
    /// "needs you" alert and only clear on a definitive signal.
    var isIdlePrompt: Bool { kind == "idle" || kind == "idle_prompt" }
}

struct ApprovalAnswerRequest: Encodable, Sendable {
    /// A digit that must match an option parsed from the captured pane frame, or the app is
    /// refused with `409` — the server re-captures the pane before accepting.
    var option: String?
    var text: String?
    var escape: Bool?
}

// MARK: - Subagents

struct SubagentInfo: Decodable, Sendable, Identifiable, Hashable {
    var id: String
    var sessionId: String?
    var name: String?
    var status: String?
    var description: String?
    var startedAt: Double?
    var completedAt: Double?
    var toolName: String?
    var isWorkflowAgent: Bool?
}

// MARK: - Aggregate stats

struct GlobalStats: Decodable, Sendable, Hashable {
    var totalSessions: Int?
    var sessionsCreated: Int?
    var totalInputTokens: Int?
    var totalOutputTokens: Int?
    var totalCost: Double?
}

struct PlanUsage: Decodable, Sendable, Hashable {
    var sessionPercent: Double?
    var weeklyPercent: Double?
    var opusWeeklyPercent: Double?
    var resetsAt: Double?
    var updatedAt: Double?
}

/// The payload of the SSE `init` frame — `WebServer.computeLightState()`.
struct InitialState: Decodable, Sendable {
    var version: String?
    var sessions: [SessionSnapshot]?
    var globalStats: GlobalStats?
    var subagents: [SubagentInfo]?
    var timestamp: Double?
    var planUsage: PlanUsage?
    var sessionOrder: [String]?
}
