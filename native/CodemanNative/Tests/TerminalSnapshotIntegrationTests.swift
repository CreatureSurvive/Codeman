import GhosttyTerminal
import UIKit
import XCTest
@testable import Codeman

/// The real snapshot path — a live server, a real socket, a real Metal surface — with no UI.
///
/// This is the fast equivalent of `ScrollbackUITests`: same production code from `start()` through
/// `.connected` → `GET …/terminal?full=1` → the Ghostty grid, but driven directly instead of
/// through onboarding and a tap. Seconds per run rather than minutes, and it can read the viewport
/// in-process rather than through XCUITest's accessibility snapshot.
///
/// Needs `CODEMAN_TEST_URL`. It creates its own throwaway case and session and deletes them, so it
/// never touches a session someone is using.
@MainActor
final class TerminalSnapshotIntegrationTests: XCTestCase {
    private var connection: LiveServer!
    private var sessionID: String?
    /// Cases this test created, deleted in teardown so runs do not litter the host's workspace.
    private var caseNames: [String] = []
    private var window: UIWindow!
    private var view: AccessibleTerminalView!
    private var terminal: TerminalSession?
    private var coordinator: GhosttyTerminalView.Coordinator?

    struct LiveServer: Sendable {
        let url: String
        let username: String
        let password: String

        var credential: ServerCredential {
            password.isEmpty ? .none : .basic(username: username, password: password)
        }

        @discardableResult
        func request(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
            var request = URLRequest(url: URL(string: url + path)!)
            request.httpMethod = method
            if let header = credential.authorizationHeader {
                request.setValue(header, forHTTPHeaderField: "Authorization")
            }
            if let body {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
            }
            let (data, _) = try await URLSession.shared.data(for: request)
            return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        }

        func unwrap(_ response: [String: Any]) -> [String: Any] {
            response["data"] as? [String: Any] ?? response
        }
    }

    /// A credential store with no Keychain and no persistence — this test is about the terminal.
    private actor StaticCredentials: CredentialStoring {
        private let value: ServerCredential
        init(_ value: ServerCredential) { self.value = value }
        func credential(for serverID: UUID) async -> ServerCredential { value }
        func store(_ credential: ServerCredential, for serverID: UUID) async throws {}
        func remove(for serverID: UUID) async throws {}
    }

    override func setUp() async throws {
        try await super.setUp()
        let environment = ProcessInfo.processInfo.environment
        guard let url = environment["CODEMAN_TEST_URL"], !url.isEmpty, !url.hasPrefix("$(")
        else { throw XCTSkip("No Codeman configured. Run Scripts/fast-ui-test.sh.") }
        connection = LiveServer(
            url: url,
            username: environment["CODEMAN_TEST_USERNAME"] ?? "admin",
            password: environment["CODEMAN_TEST_PASSWORD"] ?? ""
        )
    }

    override func tearDown() async throws {
        terminal?.stop()
        terminal = nil
        view?.removeFromSuperview()
        window?.rootViewController = nil
        window?.isHidden = true
        view = nil
        window = nil
        coordinator = nil
        if let sessionID, let connection {
            _ = try? await connection.request("DELETE", "/api/sessions/\(sessionID)?killMux=true")
        }
        for name in caseNames {
            _ = try? await connection?.request("DELETE", "/api/cases/\(name)")
        }
        caseNames = []
        // These tests share one live Codeman and one tmux server. A session that just printed
        // thousands of lines is still being torn down while the next test attaches, and that
        // contention — not the client — is what made them flaky in a suite while each passed
        // alone. A short settle is cheaper than serialising them by hand.
        try? await Task.sleep(for: .milliseconds(750))
        try await super.tearDown()
    }

    /// Starts a shell session that has already printed `marker`, and waits until the server's own
    /// `full=1` capture contains it — so a failure below is the client's, not a race with the shell.
    private func makeSessionWithScrollback(marker: String) async throws -> String {
        let caseName = "scrollcase\(Int(Date().timeIntervalSince1970) % 1_000_000)"
        caseNames.append(caseName)
        let created = try await connection.request("POST", "/api/quick-start", body: [
            "caseName": caseName,
            "mode": "shell",
        ])
        guard let id = connection.unwrap(created)["sessionId"] as? String else {
            throw XCTSkip("could not create a session: \(created)")
        }
        sessionID = id

        // The `\r` is mandatory — without it the server never issues `send-keys Enter`.
        try await connection.request("POST", "/api/sessions/\(id)/input", body: ["input": "echo \(marker)\r"])

        for _ in 0..<40 {
            let snapshot = try await connection.request("GET", "/api/sessions/\(id)/terminal?full=1")
            if let buffer = connection.unwrap(snapshot)["terminalBuffer"] as? String, buffer.contains(marker) {
                return id
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw XCTSkip("the server never produced the marker in its own capture")
    }

    private func attachSurface(to session: TerminalSession) {
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        view = AccessibleTerminalView(frame: window.bounds)
        view.terminalSession = session.ghosttySession
        // The production coordinator, not a stand-in: it is what carries the surface-attach
        // callback the pane depends on, so a test without it would not exercise the real wiring.
        coordinator = GhosttyTerminalView.Coordinator(
            session: session,
            isFocused: .constant(false),
            proxy: TerminalSurfaceProxy()
        )
        view.delegate = coordinator
        view.controller = TerminalController(theme: CodemanTerminalTheme.tokyoNight.resolved())
        view.configuration = TerminalSurfaceOptions(
            backend: .inMemory(session.ghosttySession),
            fontSize: 13,
            resizeThrottleMilliseconds: 0
        )
        // A hosting controller and `isHidden = false`, not `makeKeyAndVisible()`: the surface only
        // needs a window to build, and leaving a key window behind leaks into the next test in the
        // same process — which is why these passed alone and failed in a suite.
        let host = UIViewController()
        host.view.addSubview(view)
        window.rootViewController = host
        window.isHidden = false
        view.frame = window.bounds
        view.layoutIfNeeded()
        view.fitToSize()
    }

    /// Yields with `Task.sleep` rather than spinning a nested `RunLoop`: the pane's snapshot
    /// completes on the main actor, and a synchronous run-loop spin inside an async test starves
    /// exactly the continuation being waited on.
    private func waitForViewport(
        _ session: TerminalSession,
        contains marker: String,
        timeout: TimeInterval = 12
    ) async -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var latest = ""
        repeat {
            try? await Task.sleep(for: .milliseconds(100))
            latest = session.ghosttySession.readViewportText() ?? ""
            if latest.contains(marker) { return latest }
        } while Date() < deadline
        return latest
    }

    private func makeTerminal(for id: String) -> TerminalSession {
        let server = ServerConfiguration(
            displayName: "test",
            baseURLString: connection.url,
            username: connection.username,
            usesBearerToken: false,
            pinnedCertificateSHA256: nil
        )
        let credentials = StaticCredentials(connection.credential)
        let urlSession = URLSession(configuration: .ephemeral)
        let api = APIClient(server: server, credentials: credentials, session: urlSession)
        let transport = TerminalTransport(
            server: server,
            credentials: credentials,
            session: urlSession,
            clientID: "snapshottest" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24)
        )

        let session = TerminalSession(
            sessionID: id,
            scope: .local,
            transport: transport,
            api: api,
            viewportClass: { "mobile" }
        )
        terminal = session
        return session
    }

    /// The surface exists before the socket opens — an already-visible pane reconnecting.
    func testOpeningASessionRendersItsExistingScrollback() async throws {
        let marker = "SCROLLBACK-\(Int(Date().timeIntervalSince1970) % 1_000_000)"
        let id = try await makeSessionWithScrollback(marker: marker)

        let session = makeTerminal(for: id)
        attachSurface(to: session)
        session.start()

        let text = await waitForViewport(session, contains: marker)
        XCTAssertTrue(
            text.contains(marker),
            """
            the pane never showed scrollback that existed before it opened.
            pane state: \(session.state)
            surface attached: \(session.ghosttySession.readViewportText() != nil)
            grid: \(session.columns)x\(session.rows)
            viewport: \(text.debugDescription)
            """
        )
    }
}

extension TerminalSnapshotIntegrationTests {
    /// The ordering the app actually uses when you open a session: `AppModel` starts the terminal
    /// the moment the selection changes, and SwiftUI builds the pane — and therefore the Metal
    /// surface — afterwards. The snapshot is written to a session with no surface yet, and only
    /// the package's pre-attach buffer carries it across.
    func testScrollbackSurvivesASurfaceThatAttachesAfterTheSnapshot() async throws {
        let marker = "LATE-ATTACH-\(Int(Date().timeIntervalSince1970) % 1_000_000)"
        let id = try await makeSessionWithScrollback(marker: marker)

        let session = makeTerminal(for: id)
        session.start()

        // Wait for the snapshot to land while there is deliberately no surface.
        let deadline = Date().addingTimeInterval(15)
        while session.state != .live, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(session.state, .live, "the snapshot never completed")

        attachSurface(to: session)
        let text = await waitForViewport(session, contains: marker)
        XCTAssertTrue(
            text.contains(marker),
            """
            scrollback written before the surface attached was lost.
            pane state: \(session.state)
            viewport: \(text.debugDescription)
            """
        )
    }
}

extension TerminalSnapshotIntegrationTests {
    /// A real agent session has far more history than a two-line shell. The pre-attach buffer is
    /// capped at 1 MiB with the oldest bytes dropped, so a large capture is the case where a
    /// correct-looking implementation can still lose the top of the scrollback — or, if something
    /// else is wrong, all of it.
    func testALargeScrollbackStillRenders() async throws {
        let marker = "BIGTAIL-\(Int(Date().timeIntervalSince1970) % 1_000_000)"
        let caseName = "bigcase\(Int(Date().timeIntervalSince1970) % 1_000_000)"
        caseNames.append(caseName)
        let created = try await connection.request("POST", "/api/quick-start", body: [
            "caseName": caseName,
            "mode": "shell",
        ])
        guard let id = connection.unwrap(created)["sessionId"] as? String else {
            throw XCTSkip("could not create a session: \(created)")
        }
        sessionID = id

        try await connection.request("POST", "/api/sessions/\(id)/input",
                                     body: ["input": "seq 1 4000; echo \(marker)\r"])

        var captureBytes = 0
        for _ in 0..<60 {
            let snapshot = try await connection.request("GET", "/api/sessions/\(id)/terminal?full=1")
            if let buffer = connection.unwrap(snapshot)["terminalBuffer"] as? String, buffer.contains(marker) {
                captureBytes = buffer.utf8.count
                break
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        try XCTSkipIf(captureBytes == 0, "the server never produced the marker in its own capture")

        let session = makeTerminal(for: id)
        session.start()
        attachSurface(to: session)

        let text = await waitForViewport(session, contains: marker)
        XCTAssertTrue(
            text.contains(marker),
            """
            a \(captureBytes)-byte capture did not reach the grid.
            pane state: \(session.state)
            viewport: \(text.debugDescription)
            """
        )
    }

    /// An alt-screen CLI (claude, vim) keeps no tmux history, so its capture is a single frame.
    /// That is a different snapshot shape from a scrolling shell, and it is what the user
    /// actually runs.
    func testAnAltScreenCliSessionRendersItsFrame() async throws {
        // Opt-in: this spawns a real Claude CLI on the machine under test, which costs the
        // owner's quota and competes with whatever else is running. Enable deliberately with
        // CODEMAN_TEST_SPAWN_AGENTS=1.
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["CODEMAN_TEST_SPAWN_AGENTS"] == "1",
            "set CODEMAN_TEST_SPAWN_AGENTS=1 to exercise a real agent CLI"
        )
        let caseName = "altcase\(Int(Date().timeIntervalSince1970) % 1_000_000)"
        caseNames.append(caseName)
        let created = try await connection.request("POST", "/api/quick-start", body: [
            "caseName": caseName,
            "mode": "claude",
        ])
        guard let id = connection.unwrap(created)["sessionId"] as? String else {
            throw XCTSkip("claude mode unavailable here: \(created)")
        }
        sessionID = id

        // Wait for the CLI to paint something. Nothing is ever typed into this session.
        var captured = ""
        for _ in 0..<60 {
            let snapshot = try await connection.request("GET", "/api/sessions/\(id)/terminal?full=1")
            if let buffer = connection.unwrap(snapshot)["terminalBuffer"] as? String,
               buffer.trimmingCharacters(in: .whitespacesAndNewlines).count > 40 {
                captured = buffer
                break
            }
            try await Task.sleep(for: .milliseconds(1000))
        }
        try XCTSkipIf(captured.isEmpty, "the CLI never painted a frame the server could capture")

        let session = makeTerminal(for: id)
        session.start()
        attachSurface(to: session)

        let deadline = Date().addingTimeInterval(12)
        var text = ""
        repeat {
            try? await Task.sleep(for: .milliseconds(200))
            text = session.ghosttySession.readViewportText() ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).count > 20 { break }
        } while Date() < deadline

        XCTAssertGreaterThan(
            text.trimmingCharacters(in: .whitespacesAndNewlines).count, 20,
            """
            an alt-screen pane opened blank although the server captured \(captured.utf8.count) bytes.
            pane state: \(session.state)
            viewport: \(text.debugDescription)
            """
        )
    }
}

extension TerminalSnapshotIntegrationTests {
    /// A **second** surface for the same session must show the scrollback too.
    ///
    /// This is what a SwiftUI pane does on any structural rebuild: the old `UITerminalView` is
    /// dismantled and a new one is built, which tears down the Ghostty surface and creates an
    /// empty one. The grid lives in the surface and `InMemoryTerminalSession` keeps no copy, so
    /// unless something re-sends the content the pane comes back blank — and stays blank until
    /// backgrounding the app forces `refreshAfterForeground()` to pull a new snapshot. That is
    /// exactly the reported bug.
    func testASecondSurfaceForTheSameSessionShowsTheScrollback() async throws {
        let marker = "REATTACH-\(Int(Date().timeIntervalSince1970) % 1_000_000)"
        let id = try await makeSessionWithScrollback(marker: marker)

        let session = makeTerminal(for: id)
        attachSurface(to: session)
        session.start()

        let first = await waitForViewport(session, contains: marker)
        try XCTSkipUnless(first.contains(marker), "the first surface never rendered; a different bug")

        // Rebuild the pane exactly as SwiftUI does.
        view.removeFromSuperview()
        window.isHidden = true
        attachSurface(to: session)

        let second = await waitForViewport(session, contains: marker)
        XCTAssertTrue(
            second.contains(marker),
            """
            a rebuilt pane came back blank.
            pane state: \(session.state)
            viewport: \(second.debugDescription)
            """
        )
    }
}
