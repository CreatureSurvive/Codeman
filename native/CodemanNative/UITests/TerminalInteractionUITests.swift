import XCTest

/// The terminal as an input surface in its own right.
///
/// `UITerminalView` owns tap, drag and long-press recognizers — tap to focus, drag to select,
/// long-press for Copy, tap a URL to open it. A SwiftUI `.onTapGesture` on the container used to
/// win over all of them, so the composer was the only way to send anything and selection, copy and
/// links were all dead. One gesture conflict, four broken behaviours; this pins the one that is
/// cheap to drive from a UI test.
final class TerminalInteractionUITests: XCTestCase {
    private var connection: LiveServer!

    /// Server access as a `Sendable` value: a nonisolated `async` method on the test case would be
    /// sending `self` from the `@MainActor` test.
    private struct LiveServer: Sendable {
        let url: String
        let password: String

        private func authorized(_ request: inout URLRequest) {
            guard !password.isEmpty else { return }
            let credential = Data("admin:\(password)".utf8).base64EncodedString()
            request.setValue("Basic \(credential)", forHTTPHeaderField: "Authorization")
        }

        func makeShellSession() async throws -> String {
            let caseName = "typecase\(Int(Date().timeIntervalSince1970) % 1_000_000)"
            var request = URLRequest(url: URL(string: url + "/api/quick-start")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            authorized(&request)
            request.httpBody = try JSONSerialization.data(
                withJSONObject: ["caseName": caseName, "mode": "shell"]
            )
            let (data, _) = try await URLSession.shared.data(for: request)
            let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            let payload = json["data"] as? [String: Any] ?? json
            guard let id = payload["sessionId"] as? String else {
                throw XCTSkip("could not create a session: \(json)")
            }
            return id
        }

        func delete(sessionID: String) async {
            var request = URLRequest(url: URL(string: url + "/api/sessions/\(sessionID)?killMux=true")!)
            request.httpMethod = "DELETE"
            authorized(&request)
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard let url = environment["CODEMAN_TEST_URL"], !url.isEmpty, !url.hasPrefix("$(")
        else { throw XCTSkip("No Codeman configured. Run Scripts/fast-ui-test.sh.") }
        connection = LiveServer(url: url, password: environment["CODEMAN_TEST_PASSWORD"] ?? "")
    }

    @MainActor
    func testTypingGoesStraightIntoTheTerminal() async throws {
        let server = connection!
        let sessionID = try await server.makeShellSession()

        let app = XCUIApplication()
        app.launchArguments += [
            "-ui-testing", "-reset-state",
            "-server-url", server.url,
            "-server-password", server.password,
        ]
        app.launch()

        XCTAssertTrue(waitForWorkspace(in: app), "never reached the workspace")

        let card = app.descendants(matching: .any)["home.session.\(sessionID)"]
        let opener = card.waitForExistence(timeout: 30)
            ? card
            : app.descendants(matching: .any)["session.\(sessionID)"]
        XCTAssertTrue(opener.waitForExistence(timeout: 15), "the session never appeared")

        let surface = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "terminal.pane."))
            .firstMatch
        guard tap(opener, in: app, until: surface, timeout: 30) else { return }

        // Tap the grid itself to focus it — the gesture that used to be swallowed.
        surface.tap()

        let marker = "DIRECTTYPE\(Int(Date().timeIntervalSince1970) % 100_000)"
        app.typeText("echo \(marker)\n")

        XCTAssertTrue(
            waitForViewport(surface, toContain: marker, timeout: 25),
            """
            Typing did not reach the terminal — the composer should not be required. \
            Viewport was: \(surface.value as? String ?? "<nil>")
            """
        )

        await server.delete(sessionID: sessionID)
    }

    /// Long-pressing the grid must produce something you can actually select from.
    ///
    /// The package reports the gesture and expects the host to present the text — without the
    /// selection delegate the long press silently did nothing, which is why copy, the edit menu
    /// and therefore paste were all unreachable.
    @MainActor
    func testLongPressOpensSelectableText() async throws {
        let server = connection!
        let sessionID = try await server.makeShellSession()

        let app = XCUIApplication()
        app.launchArguments += [
            "-ui-testing", "-reset-state",
            "-server-url", server.url,
            "-server-password", server.password,
        ]
        app.launch()
        XCTAssertTrue(waitForWorkspace(in: app), "never reached the workspace")

        let card = app.descendants(matching: .any)["home.session.\(sessionID)"]
        let opener = card.waitForExistence(timeout: 30)
            ? card
            : app.descendants(matching: .any)["session.\(sessionID)"]
        XCTAssertTrue(opener.waitForExistence(timeout: 15), "the session never appeared")

        let surface = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "terminal.pane."))
            .firstMatch
        guard tap(opener, in: app, until: surface, timeout: 30) else { return }

        surface.tap()
        app.typeText("echo SELECTME\n")
        _ = waitForViewport(surface, toContain: "SELECTME", timeout: 20)

        surface.press(forDuration: 0.9)

        let selectionText = app.textViews["selection.text"]
        XCTAssertTrue(
            selectionText.waitForExistence(timeout: 10),
            "long-press produced no selectable text"
        )
        XCTAssertTrue(app.buttons["selection.copyAll"].exists, "no way to copy the selection")

        await server.delete(sessionID: sessionID)
    }

    /// Tapping a URL in the grid opens it.
    ///
    /// This is the behaviour our fork of libghostty-spm adds (`opensLinksOnTap`). Upstream cannot
    /// do it: ghostty raises its open-URL action from a mouse click over a *hovered* link, and a
    /// finger produces neither a hover nor a click.
    @MainActor
    func testTappingAUrlOpensIt() async throws {
        let server = connection!
        let sessionID = try await server.makeShellSession()

        let app = XCUIApplication()
        app.launchArguments += [
            "-ui-testing", "-reset-state",
            "-server-url", server.url,
            "-server-password", server.password,
        ]
        app.launch()
        XCTAssertTrue(waitForWorkspace(in: app), "never reached the workspace")

        let card = app.descendants(matching: .any)["home.session.\(sessionID)"]
        let opener = card.waitForExistence(timeout: 30)
            ? card
            : app.descendants(matching: .any)["session.\(sessionID)"]
        XCTAssertTrue(opener.waitForExistence(timeout: 15))

        let surface = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "terminal.pane."))
            .firstMatch
        guard tap(opener, in: app, until: surface, timeout: 30) else { return }

        // Clear first so the URL lands on a predictable row near the top.
        surface.tap()
        app.typeText("clear && echo https://example.com/codeman\n")
        guard waitForViewport(surface, toContain: "example.com", timeout: 20) else {
            XCTFail("the URL never appeared in the grid")
            await server.delete(sessionID: sessionID)
            return
        }

        // The keyboard is up and the grid has scrolled; walk the left edge of the first rows
        // looking for the link rather than assuming an exact cell.
        let safariDone = app.buttons["Done"]
        var opened = false
        for row in stride(from: 0.02, through: 0.30, by: 0.02) {
            surface.coordinate(withNormalizedOffset: CGVector(dx: 0.28, dy: row)).tap()
            if safariDone.waitForExistence(timeout: 2) { opened = true; break }
        }

        XCTAssertTrue(opened, "tapping the URL did not open it")
        if opened { safariDone.tap() }

        await server.delete(sessionID: sessionID)
    }

    @MainActor
    private func waitForViewport(
        _ surface: XCUIElement,
        toContain marker: String,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let text = surface.value as? String, text.contains(marker) { return true }
            Thread.sleep(forTimeInterval: 0.4)
        } while Date() < deadline
        return false
    }
}
