import XCTest

/// Opening a session that **already has scrollback** must show that scrollback immediately.
///
/// This is the one terminal behaviour a screenshot of a freshly launched agent cannot check: a new
/// session's output arrives live over the socket, so the snapshot path — `GET …/terminal?full=1`,
/// written into the Ghostty grid before the Metal surface exists — is never exercised. The
/// reported symptom was a blank pane on first open that filled in only after backgrounding the
/// app, which is precisely the difference between the pre-attach buffer and a live surface.
///
/// Reading the grid is possible because `AccessibleTerminalView` publishes the viewport as its
/// accessibility value.
final class ScrollbackUITests: XCTestCase {
    private var server: TestServer!
    private var sessionID: String?

    /// Server access as a `Sendable` value rather than methods on the test case: the test method
    /// is `@MainActor` and a nonisolated `async` method on the case would be sending `self`.
    private struct TestServer: Sendable {
        let url: String
        let password: String

        @discardableResult
        func request(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
            var urlRequest = URLRequest(url: URL(string: url + path)!)
            urlRequest.httpMethod = method
            let credential = Data("admin:\(password)".utf8).base64EncodedString()
            urlRequest.setValue("Basic \(credential)", forHTTPHeaderField: "Authorization")
            if let body {
                urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
            }
            let (data, _) = try await URLSession.shared.data(for: urlRequest)
            return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        }

        /// Creates a shell session that has already printed `marker`, so the app finds real
        /// history waiting for it rather than producing the output itself.
        func makeSessionWithScrollback(marker: String) async throws -> String {
            // quick-start creates the case if it is missing and *starts* the session, which is
            // what gives it a PTY to print into.
            let caseName = "scrollcase\(Int(Date().timeIntervalSince1970) % 1_000_000)"
            let created = try await request("POST", "/api/quick-start", body: [
                "caseName": caseName,
                "mode": "shell",
            ])
            let payload = created["data"] as? [String: Any] ?? created
            guard let id = payload["sessionId"] as? String else {
                throw XCTSkip("could not create a session: \(created)")
            }

            // `\r` is mandatory: the server only issues `send-keys Enter` when the payload carries
            // a carriage return, so without it the command sits unsubmitted on the composer.
            try await request("POST", "/api/sessions/\(id)/input", body: ["input": "echo \(marker)\r"])

            // Do not launch until the server can actually replay the marker, or the test would be
            // racing the shell rather than testing the client.
            for _ in 0..<40 {
                let snapshot = try await request("GET", "/api/sessions/\(id)/terminal?full=1")
                let data = snapshot["data"] as? [String: Any] ?? snapshot
                if let buffer = data["terminalBuffer"] as? String, buffer.contains(marker) { return id }
                try await Task.sleep(for: .milliseconds(500))
            }
            throw XCTSkip("the server never produced the marker in its own capture")
        }
    }

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard let url = environment["CODEMAN_TEST_URL"], !url.isEmpty,
              let password = environment["CODEMAN_TEST_PASSWORD"]
        else { throw XCTSkip("No Codeman configured. Run Scripts/run-integration-tests.sh.") }
        server = TestServer(url: url, password: password)
    }

    override func tearDown() async throws {
        if let sessionID, let server {
            _ = try? await server.request("DELETE", "/api/sessions/\(sessionID)?killMux=true")
        }
        try await super.tearDown()
    }

    // MARK: - Test

    @MainActor
    func testOpeningASessionShowsItsExistingScrollback() async throws {
        let marker = "SCROLLBACK-\(Int(Date().timeIntervalSince1970) % 1_000_000)"
        let connection = server!
        let id = try await connection.makeSessionWithScrollback(marker: marker)
        sessionID = id

        let app = XCUIApplication()
        app.launchArguments += ["-ui-testing", "-reset-state"]
        app.launch()

        app.buttons["onboarding.addServer"].tap()
        let address = app.textFields["addServer.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        address.tap()
        address.typeText(connection.url)
        let passwordField = app.secureTextFields["addServer.password"]
        passwordField.tap()
        passwordField.typeText(connection.password)
        app.buttons["addServer.save"].tap()
        dismissPasswordSaveSheetIfPresented(in: app, timeout: 2)

        XCTAssertTrue(waitForWorkspace(in: app), "never reached the workspace")

        // Open the session that already has history. A Home card on iPhone, a sidebar row on iPad.
        let card = app.descendants(matching: .any)["home.session.\(id)"]
        let opener = card.waitForExistence(timeout: 30)
            ? card
            : app.descendants(matching: .any)["session.\(id)"]
        XCTAssertTrue(opener.waitForExistence(timeout: 15), "the session never appeared in the UI")

        // The SwiftUI `.accessibilityIdentifier` on the representable wins over the UIView's own
        // "terminal.surface", so the pane identifier is what actually resolves. The element is the
        // same one either way, which is what makes its `value` the live viewport.
        let surface = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "terminal.pane."))
            .firstMatch
        // Retrying around the surface appearing: a card can be momentarily unhittable while the
        // grid settles after a refresh, and a tap that lands then is silently dropped.
        XCTAssertTrue(tap(opener, in: app, until: surface, timeout: 30), "no terminal surface appeared")

        XCTAssertTrue(
            waitForViewport(surface, toContain: marker, timeout: 45),
            """
            The pane never showed the scrollback that existed before it opened. \
            Viewport was: \(surface.value as? String ?? "<nil>")
            """
        )
    }

    /// Polls the surface's accessibility value, which reports the live Ghostty viewport.
    @MainActor
    private func waitForViewport(
        _ surface: XCUIElement,
        toContain marker: String,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let text = surface.value as? String, text.contains(marker) { return true }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < deadline
        return false
    }
}
