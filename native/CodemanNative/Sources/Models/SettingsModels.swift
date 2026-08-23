import Foundation

/// One `env` entry of a custom run action — `schemas.ts:1070`.
struct CustomActionEnvVar: Codable, Sendable, Hashable, Identifiable {
    var id = UUID()
    var key: String
    var value: String

    private enum CodingKeys: String, CodingKey { case key, value }

    init(key: String = "", value: String = "") {
        self.key = key
        self.value = value
    }

    /// The server's own key rule for a stored action: `/^[A-Za-z_][A-Za-z0-9_]*$/`.
    ///
    /// Note this is *looser* than the launch-time `safeEnvOverridesSchema` prefix allowlist — an
    /// action can be saved with a key that the launch call will reject, which is why the editor
    /// warns at edit time (API-Audit §9).
    ///
    /// Hand-checked rather than regex-matched so the rule is obvious and allocation-free; it runs
    /// on every keystroke in the editor.
    static func isValidKey(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first else { return false }
        let isLeading = CharacterSet.letters.contains(first) && first.isASCII || first == "_"
        guard isLeading else { return false }
        return key.unicodeScalars.dropFirst().allSatisfy { scalar in
            scalar == "_" || (scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar)))
        }
    }

    var hasValidKey: Bool { Self.isValidKey(key) }

    /// Key-name fragments that mark a value as a credential: `TOKEN|KEY|SECRET|PASSWORD|AUTH`,
    /// case-insensitive. Byte-for-byte the set `runCustomAction` uses, and deliberately a plain
    /// **substring** match like the web client's regex.
    ///
    /// This over-matches — `CLAUDE_CODE_MAX_OUTPUT_TOKENS` contains "TOKEN" and is flagged even
    /// though it holds a number. That is the correct trade: this predicate gates the remote-node
    /// fallback that folds the environment into a command line, where a false positive costs one
    /// masked field and a false negative writes a live credential into a process argument list.
    /// Narrowing it here would also silently diverge from the web client's refusal.
    static let sensitiveKeyFragments = ["TOKEN", "KEY", "SECRET", "PASSWORD", "AUTH"]

    var isSensitive: Bool {
        let upper = key.uppercased()
        return Self.sensitiveKeyFragments.contains { upper.contains($0) }
    }
}

/// A saved custom launch action. Stored server-side under the `customRunActions` settings key,
/// so edits made here appear in the web client and vice versa.
struct CustomRunAction: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var label: String
    var command: String
    var env: [CustomActionEnvVar]?

    init(id: String = UUID().uuidString.lowercased(), label: String = "", command: String = "", env: [CustomActionEnvVar]? = nil) {
        self.id = id
        self.label = label
        self.command = command
        self.env = env
    }

    // Server-side limits, mirrored so the editor can validate before a round trip.
    static let maxActions = 20
    static let maxLabelLength = 40
    static let maxCommandLength = 2000
    static let maxEnvEntries = 50
    static let maxEnvValueLength = 2000
    static let maxEnvKeyLength = 128

    enum ValidationIssue: Sendable, Hashable {
        case emptyLabel
        case labelTooLong
        case emptyCommand
        case commandTooLong
        case commandHasNewline
        case tooManyEnvEntries
        case invalidEnvKey(String)
        case envKeyTooLong(String)
        case envValueTooLong(String)
        case envValueHasNewline(String)
        /// Key is storable but will be rejected at launch by the env prefix allowlist.
        case envKeyNotLaunchable(String)

        var message: String {
            switch self {
            case .emptyLabel: "Give the action a name."
            case .labelTooLong: "Name must be \(CustomRunAction.maxLabelLength) characters or fewer."
            case .emptyCommand: "Enter a launch command."
            case .commandTooLong: "Command must be \(CustomRunAction.maxCommandLength) characters or fewer."
            case .commandHasNewline: "Command must be a single line."
            case .tooManyEnvEntries: "At most \(CustomRunAction.maxEnvEntries) environment variables."
            case let .invalidEnvKey(k): "“\(k)” is not a valid variable name."
            case let .envKeyTooLong(k): "“\(k)” is longer than \(CustomRunAction.maxEnvKeyLength) characters."
            case let .envValueTooLong(k): "The value for \(k) is too long."
            case let .envValueHasNewline(k): "The value for \(k) must be a single line."
            case let .envKeyNotLaunchable(k):
                "\(k) can be saved but the server will refuse it at launch — it is outside the allowed prefixes."
            }
        }

        /// Warnings do not block saving.
        var isWarning: Bool {
            if case .envKeyNotLaunchable = self { return true }
            return false
        }
    }

    func validate() -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        let trimmedLabel = label.trimmingCharacters(in: .whitespaces)
        if trimmedLabel.isEmpty { issues.append(.emptyLabel) }
        if label.count > Self.maxLabelLength { issues.append(.labelTooLong) }

        let trimmedCommand = command.trimmingCharacters(in: .whitespaces)
        if trimmedCommand.isEmpty { issues.append(.emptyCommand) }
        if command.count > Self.maxCommandLength { issues.append(.commandTooLong) }
        if command.contains(where: \.isNewline) { issues.append(.commandHasNewline) }

        let entries = env ?? []
        if entries.count > Self.maxEnvEntries { issues.append(.tooManyEnvEntries) }
        for entry in entries where !entry.key.isEmpty {
            if !entry.hasValidKey { issues.append(.invalidEnvKey(entry.key)); continue }
            if entry.key.count > Self.maxEnvKeyLength { issues.append(.envKeyTooLong(entry.key)) }
            if entry.value.count > Self.maxEnvValueLength { issues.append(.envValueTooLong(entry.key)) }
            if entry.value.contains(where: \.isNewline) { issues.append(.envValueHasNewline(entry.key)) }
            if !EnvironmentAllowlist.isLaunchable(entry.key) { issues.append(.envKeyNotLaunchable(entry.key)) }
        }
        return issues
    }

    /// Flattens `env` into the `envOverrides` object the launch endpoints take, dropping entries
    /// whose key fails the server's own name rule — exactly what `runCustomAction` does.
    var envOverrides: [String: String] {
        var result: [String: String] = [:]
        for entry in env ?? [] where entry.hasValidKey {
            result[entry.key] = entry.value
        }
        return result
    }

    /// True when any variable name looks like a credential. A remote node that rejects
    /// `envOverrides` must **not** be retried with the env folded into the command line in that
    /// case — that would put a secret in a process argument list.
    var carriesSensitiveEnv: Bool {
        (env ?? []).contains { $0.hasValidKey && $0.isSensitive }
    }
}

/// The env-var allowlist enforced by `safeEnvOverridesSchema` at launch time.
///
/// Read from `src/web/schemas.ts:125` (`ALLOWED_ENV_PREFIXES`) and `:144` (`ALLOWED_ENV_KEYS`).
/// **This fork's list is wider than `CLAUDE.md` documents** — it also admits `ANTHROPIC_`,
/// `OPENAI_`, `OPENCLAW_`, and the exact key `API_TIMEOUT_MS`. The code is authoritative.
///
/// The client uses this only to *warn* early. The server remains the enforcement point, and a
/// rejection message from the server is always shown verbatim rather than second-guessed —
/// notably, a `BLOCKED_ENV_KEYS` set also exists server-side and is not duplicated here.
enum EnvironmentAllowlist {
    static let prefixes: [String] = [
        "ANTHROPIC_",
        "CLAUDE_CODE_",
        "CODEX_",
        "GEMINI_",
        "GOOGLE_",
        "OPENAI_",
        "OPENCODE_",
        "OPENCLAW_",
        "ANTIGRAVITY_",
        "PI_",
    ]

    static let exactKeys: Set<String> = ["API_TIMEOUT_MS", "CLAUDE_CONFIG_DIR"]

    static func isLaunchable(_ key: String) -> Bool {
        if exactKeys.contains(key) { return true }
        return prefixes.contains { key.hasPrefix($0) }
    }
}

/// Ready-made variables for the action editor, grouped the way the allowlist groups them.
struct EnvironmentPreset: Sendable, Hashable, Identifiable {
    var id: String { key }
    var key: String
    var summary: String
    var group: String
    var isSensitive: Bool { CustomActionEnvVar(key: key).isSensitive }
}

enum EnvironmentPresets {
    static let all: [EnvironmentPreset] = [
        .init(key: "ANTHROPIC_BASE_URL", summary: "Point Claude at an alternative API endpoint.", group: "Anthropic"),
        .init(key: "ANTHROPIC_AUTH_TOKEN", summary: "Bearer token for a proxied Anthropic endpoint.", group: "Anthropic"),
        .init(key: "ANTHROPIC_API_KEY", summary: "API key instead of the CLI's own login.", group: "Anthropic"),
        .init(key: "ANTHROPIC_MODEL", summary: "Override the model the CLI requests.", group: "Anthropic"),
        .init(key: "CLAUDE_CODE_MAX_OUTPUT_TOKENS", summary: "Cap the CLI's output budget.", group: "Claude Code"),
        .init(key: "CLAUDE_CONFIG_DIR", summary: "Run this session against a separate Claude account/config dir.", group: "Claude Code"),
        .init(key: "OPENAI_API_KEY", summary: "API key for Codex and OpenAI-backed CLIs.", group: "OpenAI"),
        .init(key: "OPENAI_BASE_URL", summary: "Alternative OpenAI-compatible endpoint.", group: "OpenAI"),
        .init(key: "CODEX_MODEL", summary: "Model for a Codex session.", group: "OpenAI"),
        .init(key: "GEMINI_API_KEY", summary: "API key for the Gemini CLI.", group: "Google"),
        .init(key: "GOOGLE_CLOUD_PROJECT", summary: "Vertex AI project id.", group: "Google"),
        .init(key: "GOOGLE_APPLICATION_CREDENTIALS", summary: "Path to a Vertex AI service-account file.", group: "Google"),
        .init(key: "GOOGLE_GENAI_USE_VERTEXAI", summary: "Route Gemini through Vertex AI.", group: "Google"),
        .init(key: "OPENCODE_MODEL", summary: "Model for an OpenCode session.", group: "OpenCode"),
        .init(key: "ANTIGRAVITY_MODEL", summary: "Model for an Antigravity session.", group: "Antigravity"),
        .init(key: "PI_MODEL", summary: "Model for a Pi session.", group: "Pi"),
        .init(key: "API_TIMEOUT_MS", summary: "Request timeout applied to the CLI's API calls.", group: "General"),
    ]

    static var groups: [String] {
        var seen = Set<String>()
        return all.compactMap { seen.insert($0.group).inserted ? $0.group : nil }
    }
}

/// The subset of `GET/PUT /api/settings` this client reads and writes.
///
/// `SettingsUpdateSchema` is `.strict()`, so **only keys declared there may be sent**. A partial
/// PUT is safe (the server merges), but an undeclared key is an `INVALID_INPUT` for the whole
/// request — which is why this struct encodes `nil` fields as absent rather than as JSON null.
struct ServerSettings: Codable, Sendable {
    var customRunActions: [CustomRunAction]?
    var runMode: String?
    var showResponseViewer: Bool?
    var showPlanUsageLimits: Bool?
    var language: String?
    var tmuxHistoryLimit: Int?
    var workspaceHooksEnabled: Bool?
    var agentSkillEnabled: Bool?
    var approvalsInboxEnabled: Bool?
}

/// A PUT body carrying only the keys being changed.
struct SettingsUpdate: Encodable, Sendable {
    var customRunActions: [CustomRunAction]?
    var runMode: String?

    var isEmpty: Bool { customRunActions == nil && runMode == nil }
}
