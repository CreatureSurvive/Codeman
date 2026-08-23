import Foundation
import Testing
@testable import Codeman

@Suite("Custom launch actions")
struct CustomActionTests {
    @Test("flattens env entries into the envOverrides object")
    func flattensEnv() {
        let action = CustomRunAction(
            id: "a1", label: "Dev", command: "npm run dev",
            env: [
                CustomActionEnvVar(key: "CLAUDE_CODE_MAX_OUTPUT_TOKENS", value: "8000"),
                CustomActionEnvVar(key: "ANTHROPIC_BASE_URL", value: "https://proxy.example"),
            ]
        )
        #expect(action.envOverrides == [
            "CLAUDE_CODE_MAX_OUTPUT_TOKENS": "8000",
            "ANTHROPIC_BASE_URL": "https://proxy.example",
        ])
    }

    /// `runCustomAction` drops entries whose key fails the server's own name rule rather than
    /// sending them and eating a validation error.
    @Test("drops entries with an invalid key name")
    func dropsInvalidKeys() {
        let action = CustomRunAction(
            id: "a1", label: "Dev", command: "run",
            env: [
                CustomActionEnvVar(key: "9BAD", value: "x"),
                CustomActionEnvVar(key: "has-dash", value: "x"),
                CustomActionEnvVar(key: "", value: "x"),
                CustomActionEnvVar(key: "GOOD_NAME", value: "y"),
            ]
        )
        #expect(action.envOverrides == ["GOOD_NAME": "y"])
    }

    @Test("validates the server's own key grammar", arguments: [
        ("PATH", true), ("_x", true), ("A1", true), ("a_b_1", true),
        ("1A", false), ("A-B", false), ("A B", false), ("", false), ("A.B", false),
    ])
    func keyGrammar(key: String, expected: Bool) {
        #expect(CustomActionEnvVar.isValidKey(key) == expected)
    }

    @Test("recognises credential-shaped key names", arguments: [
        "ANTHROPIC_API_KEY", "OPENAI_API_KEY", "MY_TOKEN", "app_secret",
        "DB_PASSWORD", "ANTHROPIC_AUTH_TOKEN",
    ])
    func detectsSensitive(key: String) {
        #expect(CustomActionEnvVar(key: key).isSensitive)
    }

    @Test("does not flag names with no credential fragment")
    func doesNotOverflagSensitive() {
        for key in ["GOOGLE_CLOUD_PROJECT", "PI_MODEL", "API_TIMEOUT_MS", "OPENCODE_MODEL", "CODEX_MODEL"] {
            #expect(!CustomActionEnvVar(key: key).isSensitive, "\(key) should not be treated as a secret")
        }
    }

    /// The rule is a plain substring match, matching the web client's
    /// `/(?:TOKEN|KEY|SECRET|PASSWORD|AUTH)/i` exactly — so a name that merely *contains* one of
    /// those words is flagged even when its value is a number. Over-matching is the correct trade
    /// for a predicate that gates writing the environment onto a command line, and narrowing it
    /// would silently diverge from the web client's refusal.
    @Test("over-matches by design rather than risking a leak")
    func overMatchesDeliberately() {
        #expect(CustomActionEnvVar(key: "CLAUDE_CODE_MAX_OUTPUT_TOKENS").isSensitive)
    }

    /// The env allowlist read from `schemas.ts:125`/`:144`. This fork's list is wider than
    /// `CLAUDE.md` documents; the code is authoritative.
    @Test("launch allowlist matches the server's prefixes and exact keys", arguments: [
        ("ANTHROPIC_API_KEY", true),
        ("CLAUDE_CODE_MAX_OUTPUT_TOKENS", true),
        ("CODEX_MODEL", true),
        ("GEMINI_API_KEY", true),
        ("GOOGLE_CLOUD_PROJECT", true),
        ("OPENAI_API_KEY", true),
        ("OPENCODE_MODEL", true),
        ("OPENCLAW_THING", true),
        ("ANTIGRAVITY_MODEL", true),
        ("PI_MODEL", true),
        ("CLAUDE_CONFIG_DIR", true),
        ("API_TIMEOUT_MS", true),
        ("PATH", false),
        ("HOME", false),
        ("CLAUDE_CONFIG_DIR_EXTRA", false),
        ("MY_VAR", false),
    ])
    func launchAllowlist(key: String, allowed: Bool) {
        #expect(EnvironmentAllowlist.isLaunchable(key) == allowed)
    }

    @Test("a storable-but-unlaunchable key is a warning, not a save blocker")
    func unlaunchableKeyIsWarning() {
        let action = CustomRunAction(
            id: "a1", label: "Dev", command: "run",
            env: [CustomActionEnvVar(key: "MY_VAR", value: "1")]
        )
        let issues = action.validate()
        #expect(issues.contains { if case .envKeyNotLaunchable = $0 { true } else { false } })
        let onlyWarnings = issues.allSatisfy { $0.isWarning }
        #expect(onlyWarnings, "nothing here should block saving")
    }

    @Test("blocking validation catches the server's hard limits")
    func blockingValidation() {
        let action = CustomRunAction(
            id: "a1",
            label: "",
            command: "line one\nline two",
            env: [CustomActionEnvVar(key: "9BAD", value: "x")]
        )
        let issues = action.validate()
        #expect(issues.contains { if case .emptyLabel = $0 { true } else { false } })
        #expect(issues.contains { if case .commandHasNewline = $0 { true } else { false } })
        #expect(issues.contains { if case .invalidEnvKey = $0 { true } else { false } })
    }

    @Test("a well-formed action validates clean")
    func validAction() {
        let action = CustomRunAction(
            id: "a1", label: "Dev server", command: "npm run dev",
            env: [CustomActionEnvVar(key: "CLAUDE_CODE_MAX_OUTPUT_TOKENS", value: "8000")]
        )
        #expect(action.validate().isEmpty)
    }

    // MARK: - The remote-node fallback and its refusal

    @Test("detects a node's envOverrides rejection message", arguments: [
        "envOverrides, effort, and per-CLI config are not supported for remote cases",
        "Disallowed environment variable",
        "not supported",
    ])
    func detectsEnvRejection(message: String) {
        #expect(CustomActionLauncher.mentionsEnvRejection(message))
    }

    @Test("does not mistake an unrelated error for an env rejection")
    func ignoresUnrelatedError() {
        #expect(!CustomActionLauncher.mentionsEnvRejection("Codex CLI not found. Install with: npm install -g @openai/codex"))
        #expect(!CustomActionLauncher.mentionsEnvRejection("Session is busy"))
    }

    /// The fallback folds the environment into the command line. That is fine for a model name
    /// and unacceptable for a token, which is why the refusal exists.
    @Test("carriesSensitiveEnv gates the command-line fallback")
    func sensitiveEnvGatesFallback() {
        let safe = CustomRunAction(
            id: "a", label: "Safe", command: "run",
            env: [CustomActionEnvVar(key: "OPENCODE_MODEL", value: "big")]
        )
        #expect(!safe.carriesSensitiveEnv)

        let unsafe = CustomRunAction(
            id: "b", label: "Unsafe", command: "run",
            env: [CustomActionEnvVar(key: "ANTHROPIC_API_KEY", value: "sk-secret")]
        )
        #expect(unsafe.carriesSensitiveEnv)
    }

    @Test("the inline fallback quotes values and stays a single line")
    func inlineFallbackQuoting() {
        let action = CustomRunAction(
            id: "a", label: "Dev", command: "npm run dev",
            env: [
                CustomActionEnvVar(key: "OPENCODE_MODEL", value: "big model"),
                CustomActionEnvVar(key: "CODEX_MODEL", value: "it's fine"),
            ]
        )
        let command = CustomActionLauncher.inlineEnvCommand(action)
        #expect(command.hasSuffix("npm run dev"))
        #expect(command.contains("OPENCODE_MODEL='big model'"))
        #expect(command.contains(#"CODEX_MODEL='it'\''s fine'"#))
        #expect(!command.contains("\n"), "launchCommand must be a single line")
    }

    @Test("shell quoting is literal and closes an embedded quote correctly")
    func shellQuoting() {
        #expect(CustomActionLauncher.shellQuote("plain") == "'plain'")
        #expect(CustomActionLauncher.shellQuote("a b") == "'a b'")
        #expect(CustomActionLauncher.shellQuote("$(rm -rf /)") == "'$(rm -rf /)'")
        #expect(CustomActionLauncher.shellQuote("it's") == #"'it'\''s'"#)
        #expect(CustomActionLauncher.shellQuote("`whoami`") == "'`whoami`'")
    }
}

@Suite("Session ordering")
struct SessionOrderingTests {
    private func session(
        _ id: String,
        status: SessionStatus = .idle,
        pid: Int? = 100,
        lastActivity: Double? = nil,
        lastSubmit: Double? = nil
    ) -> SessionSnapshot {
        var snapshot = SessionSnapshot(id: id)
        snapshot.status = status
        snapshot.pid = pid
        snapshot.lastActivityAt = lastActivity
        snapshot.lastSubmitAt = lastSubmit
        return snapshot
    }

    @Test("ranks needs-you above everything else")
    func ranksNeedsFirst() {
        let sessions = [
            session("idle"),
            session("working", status: .busy, lastSubmit: 1000),
            session("needs"),
        ]
        let sorted = SessionOrdering.sorted(
            sessions,
            needsAttention: ["needs"],
            waitingForInput: [],
            orderIndex: [:]
        )
        #expect(sorted.first?.id == "needs")
    }

    /// States a session is still *in* sort oldest-first: blocked longest is most urgent.
    @Test("ongoing states sort oldest-first")
    func ongoingOldestFirst() {
        let sessions = [
            session("recent", status: .busy, lastSubmit: 9000),
            session("longRunning", status: .busy, lastSubmit: 1000),
        ]
        let sorted = SessionOrdering.sorted(sessions, needsAttention: [], waitingForInput: [], orderIndex: [:])
        #expect(sorted.map(\.id) == ["longRunning", "recent"])
    }

    /// States a session has *stopped* in sort newest-first: the one that just went quiet is the
    /// one you came back for.
    @Test("finished states sort newest-first")
    func finishedNewestFirst() {
        let sessions = [
            session("old", status: .stopped, pid: nil, lastActivity: 1000),
            session("justFinished", status: .stopped, pid: nil, lastActivity: 9000),
        ]
        let sorted = SessionOrdering.sorted(sessions, needsAttention: [], waitingForInput: [], orderIndex: [:])
        #expect(sorted.map(\.id) == ["justFinished", "old"])
    }

    /// A working pane repaints roughly once a second, so `lastActivityAt` is always "now" and
    /// would rank every running turn as freshly started.
    @Test("the working group keys off lastSubmitAt, not lastActivityAt")
    func workingUsesSubmitStamp() {
        let sessions = [
            // Started its turn long ago but repainted a moment ago.
            session("longTurn", status: .busy, lastActivity: 9999, lastSubmit: 100),
            // Started its turn recently.
            session("shortTurn", status: .busy, lastActivity: 9999, lastSubmit: 5000),
        ]
        let sorted = SessionOrdering.sorted(sessions, needsAttention: [], waitingForInput: [], orderIndex: [:])
        #expect(sorted.map(\.id) == ["longTurn", "shortTurn"])
    }

    /// A `0`/absent stamp means "unknown", not "the epoch" — otherwise a brand-new session would
    /// head every oldest-first group.
    @Test("an unknown stamp sorts last within its state")
    func unknownStampSortsLast() {
        let sessions = [
            session("unknown", status: .busy, lastActivity: nil, lastSubmit: nil),
            session("known", status: .busy, lastSubmit: 5000),
        ]
        let sorted = SessionOrdering.sorted(sessions, needsAttention: [], waitingForInput: [], orderIndex: [:])
        #expect(sorted.map(\.id) == ["known", "unknown"])
    }

    @Test("the user's tab order is the final tiebreak, so renders are deterministic")
    func tabOrderTiebreak() {
        let sessions = [session("b", lastActivity: 500), session("a", lastActivity: 500)]
        let sorted = SessionOrdering.sorted(
            sessions,
            needsAttention: [],
            waitingForInput: [],
            orderIndex: ["a": 1, "b": 0]
        )
        #expect(sorted.map(\.id) == ["b", "a"])
    }

    @Test("full rank order is needs → error → waiting → working → idle → done")
    func fullRankOrder() {
        let sessions = [
            session("done", status: .stopped, pid: nil),
            session("idle"),
            session("working", status: .busy, lastSubmit: 1),
            session("waiting"),
            session("error", status: .error),
            session("needs"),
        ]
        let sorted = SessionOrdering.sorted(
            sessions,
            needsAttention: ["needs"],
            waitingForInput: ["waiting"],
            orderIndex: [:]
        )
        #expect(sorted.map(\.id) == ["needs", "error", "waiting", "working", "idle", "done"])
    }
}

@Suite("Session model decoding")
struct SessionDecodingTests {
    private let decoder = JSONDecoder()

    /// Light state ships from several call sites with different fills; a strict model would make
    /// the whole list undecodable over one missing key.
    @Test("decodes a minimal session")
    func decodesMinimal() throws {
        let json = Data(#"{"id":"abc"}"#.utf8)
        let session = try decoder.decode(SessionSnapshot.self, from: json)
        #expect(session.id == "abc")
        #expect(session.effectiveStatus == .idle)
        #expect(session.displayName == "abc")
    }

    @Test("decodes the full badge metadata")
    func decodesBadges() throws {
        let json = Data("""
        {"id":"s1","name":"w1-demo","mode":"claude","status":"busy","pid":42,
         "cliModel":"Opus 4.5","cliVersion":"2.1.27","cliAccountType":"Claude Max",
         "backend":{"label":"GLM","type":"custom","source":"open.bigmodel.cn","model":"glm-4.6"},
         "inputTokens":1200,"outputTokens":800,"totalCost":0.42}
        """.utf8)
        let session = try decoder.decode(SessionSnapshot.self, from: json)
        #expect(session.displayName == "w1-demo")
        #expect(session.modelBadge == "Opus 4.5")
        #expect(session.backendBadge == "GLM")
        #expect(session.backend?.type == .custom)
        #expect(session.effectiveStatus == .busy)
        #expect(session.isRunning)
    }

    @Test("falls back to the backend model when the CLI has not reported one")
    func modelBadgeFallback() throws {
        let json = Data(#"{"id":"s1","backend":{"label":"OpenAI","type":"openai","model":"gpt-5"}}"#.utf8)
        let session = try decoder.decode(SessionSnapshot.self, from: json)
        #expect(session.modelBadge == "gpt-5")
    }

    @Test("names a remote and a docker session by its location")
    func locationBadge() throws {
        let remote = try decoder.decode(SessionSnapshot.self, from: Data(
            #"{"id":"s1","remote":{"host":"build.local","username":"ci","owned":true}}"#.utf8))
        #expect(remote.locationBadge == "ci@build.local")

        let docker = try decoder.decode(SessionSnapshot.self, from: Data(
            #"{"id":"s2","docker":{"containerName":"codeman-demo","image":"codeman/agent:base"}}"#.utf8))
        #expect(docker.locationBadge == "codeman-demo")
    }

    @Test("derives a display name from the working directory when unnamed")
    func nameFromWorkingDir() throws {
        let json = Data(#"{"id":"abcdef123456","workingDir":"/Users/me/Projects/thing"}"#.utf8)
        let session = try decoder.decode(SessionSnapshot.self, from: json)
        #expect(session.displayName == "thing")
    }

    @Test("all seven session modes decode")
    func decodesAllModes() throws {
        for mode in SessionMode.allCases {
            let json = Data(#"{"id":"s","mode":"\#(mode.rawValue)"}"#.utf8)
            let session = try decoder.decode(SessionSnapshot.self, from: json)
            #expect(session.mode == mode)
        }
    }

    @Test("external CLI modes are classified the way session.ts classifies them")
    func externalCliClassification() {
        #expect(!SessionMode.claude.isExternalCLI)
        #expect(!SessionMode.shell.isExternalCLI)
        for mode in [SessionMode.opencode, .codex, .gemini, .antigravity, .pi] {
            #expect(mode.isExternalCLI)
        }
    }

    /// `HistorySession` rows are mostly transcript-backed with no `name`, so an A–Z sort on
    /// `name` alone silently does nothing — the row label is the sort key.
    @Test("history rows label from name, then first prompt, then path")
    func historyRowLabel() throws {
        let named = try decoder.decode(HistorySession.self, from: Data(#"{"name":"Fix login","path":"/a/b"}"#.utf8))
        #expect(named.rowLabel == "Fix login")

        let prompted = try decoder.decode(HistorySession.self, from: Data(#"{"firstPrompt":"why is CI red","path":"/a/b"}"#.utf8))
        #expect(prompted.rowLabel == "why is CI red")

        let bare = try decoder.decode(HistorySession.self, from: Data(#"{"path":"/a/b"}"#.utf8))
        #expect(bare.rowLabel == "/a/b")
    }
}
