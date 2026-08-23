import Foundation
import Testing
@testable import Codeman

/// End-to-end tests against a **real** Codeman server.
///
/// These do not start the server themselves: a unit-test bundle runs in the simulator and cannot
/// spawn a Node process on the host. `Scripts/run-integration-tests.sh` boots
/// `tsx src/index.ts web` on port **3187** with a throwaway `CODEMAN_DATA_DIR` and a known
/// `CODEMAN_PASSWORD`, then runs this suite with the address in the environment.
///
/// Without that environment the whole suite is skipped rather than failing — a green unit run on
/// a machine with no Node checkout is the correct outcome, and a silent pass would be worse.
@Suite("Live server integration", .enabled(if: IntegrationEnvironment.isConfigured))
struct IntegrationTests {
    private var server: ServerConfiguration {
        get throws { try IntegrationEnvironment.serverConfiguration() }
    }

    private func makeClient() throws -> APIClient {
        let configuration = try server
        let credentials = EphemeralCredentialStore(
            credential: IntegrationEnvironment.credential(),
            serverID: configuration.id
        )
        return APIClient(
            server: configuration,
            credentials: credentials,
            session: URLSession(configuration: .ephemeral)
        )
    }

    @Test("the integration environment is actually wired up")
    func environmentIsConfigured() {
        #expect(IntegrationEnvironment.isConfigured, "\(IntegrationEnvironment.describeConfiguration())")
    }

    /// The non-admin-gated probe, and the app's definition of "is this a Codeman?".
    @Test("reads node info and a version")
    func readsNodeInfo() async throws {
        let info = try await makeClient().nodeInfo(scope: .local)
        #expect(!info.version.isEmpty)
        #expect(!info.id.isEmpty)
        #expect(info.capabilities?.contains("api") == true)
    }

    /// Proves the client's Basic header is what the server's timing-safe comparison expects, and
    /// that a wrong password is a clean 401 rather than a decode failure.
    ///
    /// Only meaningful against a server that actually has a password: a Codeman started without
    /// `CODEMAN_PASSWORD` accepts every credential by design, so asserting a 401 there would be
    /// asserting the opposite of the server's configuration.
    @Test("rejects a wrong password with a 401, not a parse error",
          .enabled(if: IntegrationEnvironment.requiresPassword))
    func rejectsWrongPassword() async throws {
        let configuration = try server
        let bad = EphemeralCredentialStore(
            credential: .basic(username: "admin", password: "definitely-not-the-password"),
            serverID: configuration.id
        )
        let client = APIClient(server: configuration, credentials: bad, session: URLSession(configuration: .ephemeral))

        await #expect(throws: APIError.self) {
            _ = try await client.listSessions(scope: .local)
        }
    }

    @Test("lists sessions through the envelope")
    func listsSessions() async throws {
        // A bare array that the preSerialization hook wraps — the shape the client must unwrap.
        let sessions = try await makeClient().listSessions(scope: .local)
        #expect(sessions.allSatisfy { !$0.id.isEmpty })
    }

    @Test("lists cases")
    func listsCases() async throws {
        _ = try await makeClient().listCases(scope: .local)
    }

    /// The full lifecycle the app drives: create a case, start a session, read a snapshot, send a
    /// prompt, delete. Uses its own throwaway case name so it can never touch a real session.
    @Test("creates, drives, and deletes its own session")
    func sessionLifecycle() async throws {
        let client = try makeClient()
        let caseName = "nativeitest\(Int(Date.now.timeIntervalSince1970))"

        let started = try await client.quickStart(
            QuickStartRequest(
                caseName: caseName,
                sessionName: caseName,
                mode: .shell,
                launchCommand: nil,
                modelOverride: nil,
                envOverrides: nil,
                effort: nil,
                parentSessionId: nil
            ),
            scope: .local
        )
        #expect(!started.sessionId.isEmpty)

        // Always clean up, including on a failed assertion below.
        defer {
            Task { try? await client.deleteSession(id: started.sessionId, killMux: true, scope: .local) }
        }

        // Give the pane a moment to produce a prompt.
        try await Task.sleep(for: .seconds(2))

        let snapshot = try await client.terminalSnapshot(id: started.sessionId, full: true, tailBytes: nil, scope: .local)
        // `?full=1` must come back as a full-history capture (or `history` when the pane holds
        // none yet) — never as a visible-frame capture, which would silently be a worse snapshot.
        #expect(snapshot.source != .muxVisible)

        // The `\r` is what makes the server issue `send-keys Enter`; without it the text sits
        // unsubmitted on the composer and this call still returns 200.
        let response = try await client.sendInput(
            SessionInputRequest(input: "echo codeman-native-integration\r", useMux: true,
                                seq: nil, clientId: nil, wait: nil, waitTimeout: nil),
            id: started.sessionId,
            scope: .local
        )
        _ = response

        try await Task.sleep(for: .seconds(2))
        let after = try await client.terminalSnapshot(id: started.sessionId, full: true, tailBytes: nil, scope: .local)
        #expect(after.terminalBuffer.contains("codeman-native-integration"),
                "the prompt did not reach the pane — check the \\r rule")

        try await client.deleteSession(id: started.sessionId, killMux: true, scope: .local)
    }

    /// Reliable delivery: the server applies each `(clientId, seq)` at most once but ACKs a
    /// redelivery anyway, so a retry after a dropped link cannot type the prompt twice.
    @Test("a redelivered input is deduped, not applied twice")
    func dedupesTaggedInput() async throws {
        let client = try makeClient()
        let caseName = "nativededupe\(Int(Date.now.timeIntervalSince1970))"

        let started = try await client.quickStart(
            QuickStartRequest(caseName: caseName, sessionName: caseName, mode: .shell,
                              launchCommand: nil, modelOverride: nil, envOverrides: nil,
                              effort: nil, parentSessionId: nil),
            scope: .local
        )
        defer {
            Task { try? await client.deleteSession(id: started.sessionId, killMux: true, scope: .local) }
        }
        try await Task.sleep(for: .seconds(2))

        let clientID = "native-itest-\(UUID().uuidString.prefix(8))"
        let request = SessionInputRequest(
            input: "echo dedupe-probe\r", useMux: true, seq: 1,
            clientId: clientID, wait: nil, waitTimeout: nil
        )

        _ = try await client.sendInput(request, id: started.sessionId, scope: .local)
        // Same (clientId, seq): a 2xx is the client's ACK, so this must succeed AND skip the write.
        _ = try await client.sendInput(request, id: started.sessionId, scope: .local)

        try await Task.sleep(for: .seconds(2))
        let snapshot = try await client.terminalSnapshot(id: started.sessionId, full: true, tailBytes: nil, scope: .local)
        let occurrences = snapshot.terminalBuffer.components(separatedBy: "dedupe-probe").count - 1
        // The echoed command line plus its output is two; a double-applied input would be four.
        #expect(occurrences <= 3, "input appears \(occurrences) times — dedup did not hold")

        try await client.deleteSession(id: started.sessionId, killMux: true, scope: .local)
    }

    /// `POST /api/sessions/:id/paste-image` has a hand-rolled CSRF check that does **not** share
    /// the global guard's "missing Origin is fine" rule: with no Origin and no Referer it demands
    /// `X-Codeman-CSRF`. This is the one header the client must send, and this test is what proves
    /// `APIClient` actually sends it.
    @Test("image upload passes the paste-image CSRF check")
    func imageUploadCarriesCSRFHeader() async throws {
        let client = try makeClient()
        let caseName = "nativeupload\(Int(Date.now.timeIntervalSince1970))"

        let started = try await client.quickStart(
            QuickStartRequest(caseName: caseName, sessionName: caseName, mode: .shell,
                              launchCommand: nil, modelOverride: nil, envOverrides: nil,
                              effort: nil, parentSessionId: nil),
            scope: .local
        )
        defer {
            Task { try? await client.deleteSession(id: started.sessionId, killMux: true, scope: .local) }
        }
        try await Task.sleep(for: .seconds(1))

        // A real 1×1 PNG: the server sniffs magic bytes and 415s a mismatch, so a fake payload
        // would fail for the wrong reason and hide a genuine CSRF rejection.
        let png = try #require(Data(base64Encoded: IntegrationEnvironment.onePixelPNGBase64))
        let uploaded = try await client.uploadImage(
            png, filename: "probe.png", mimeType: "image/png",
            sessionID: started.sessionId, scope: .local
        )
        #expect(uploaded.filename.hasSuffix(".png"))
        #expect(uploaded.path.contains(".claude-images"))

        try await client.deleteSession(id: started.sessionId, killMux: true, scope: .local)
    }

    /// The SSE contract: the first frame is always `init`, and the keepalive is a *named* event
    /// (an SSE comment would be invisible to the client).
    @Test("the event stream opens with init")
    func eventStreamOpensWithInit() async throws {
        let configuration = try server
        let credentials = EphemeralCredentialStore(
            credential: IntegrationEnvironment.credential(),
            serverID: configuration.id
        )
        let stream = EventStream(
            server: configuration,
            credentials: credentials,
            session: URLSession(configuration: .ephemeral)
        )
        defer { Task { await stream.stop() } }

        let signals = await stream.start(scope: .local)

        // Bounded: a stream that never delivers must fail the test, not hang the suite. The
        // result is returned from the group rather than written to a captured `var` — the closure
        // is `sending`, so a shared mutable capture is exactly the race Swift 6 rejects.
        let sawInit = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await signal in signals {
                    if case let .frame(frame) = signal, frame.name == .known(.initial) { return true }
                    if case let .failed(error) = signal { throw error }
                }
                return false
            }
            group.addTask {
                try await Task.sleep(for: .seconds(15))
                throw IntegrationEnvironment.Timeout()
            }
            let first = try await group.next() ?? false
            group.cancelAll()
            return first
        }

        #expect(sawInit)
    }
}

/// Reads the integration server's address and credentials from the environment.
enum IntegrationEnvironment {
    static let addressKey = "CODEMAN_TEST_URL"
    static let usernameKey = "CODEMAN_TEST_USERNAME"
    static let passwordKey = "CODEMAN_TEST_PASSWORD"

    struct Timeout: Error {}
    struct NotConfigured: Error {}

    /// The scheme always declares the variable, so an unconfigured run gets the *literal*
    /// `$(CODEMAN_TEST_URL)` back rather than nothing — treat an unexpanded placeholder as unset.
    /// Whether the target server actually enforces a password. A Codeman started without
    /// `CODEMAN_PASSWORD` accepts every credential by design, so auth-rejection tests are not
    /// applicable there — and must be skipped rather than failed.
    static var requiresPassword: Bool {
        !(ProcessInfo.processInfo.environment[passwordKey] ?? "").isEmpty
    }

    static var isConfigured: Bool {
        guard let value = ProcessInfo.processInfo.environment[addressKey] else { return false }
        return !value.isEmpty && !value.hasPrefix("$(")
    }

    /// Printed once so a run that skips everything says *why*, instead of reporting eight
    /// instantaneous passes that look like coverage.
    static func describeConfiguration() -> String {
        let environment = ProcessInfo.processInfo.environment
        let codemanKeys = environment.keys.filter { $0.hasPrefix("CODEMAN") }.sorted()
        return "CODEMAN_TEST_URL=\(environment[addressKey] ?? "<unset>") visible CODEMAN keys: \(codemanKeys)"
    }

    static func serverConfiguration() throws -> ServerConfiguration {
        guard isConfigured,
              let raw = ProcessInfo.processInfo.environment[addressKey],
              let normalized = ServerConfiguration.normalize(raw)
        else { throw NotConfigured() }
        return ServerConfiguration(displayName: "integration", baseURLString: normalized)
    }

    static func credential() -> ServerCredential {
        let environment = ProcessInfo.processInfo.environment
        guard let password = environment[passwordKey], !password.isEmpty, !password.hasPrefix("$(") else {
            return .none
        }
        let username = environment[usernameKey].flatMap { $0.hasPrefix("$(") ? nil : $0 } ?? "admin"
        return .basic(username: username, password: password)
    }

    /// A minimal valid PNG — the server checks magic bytes, so this must be real.
    static let onePixelPNGBase64 = """
    iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==
    """
}
