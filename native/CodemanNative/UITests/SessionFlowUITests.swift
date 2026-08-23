import XCTest

/// Flows that need a reachable Codeman.
///
/// `Scripts/run-integration-tests.sh` exports `CODEMAN_TEST_URL` / `CODEMAN_TEST_PASSWORD` for a
/// throwaway server; without them every test here skips explicitly rather than passing vacuously.
final class SessionFlowUITests: XCTestCase {
    private var serverURL: String?
    private var password: String?

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        serverURL = environment["CODEMAN_TEST_URL"]
        password = environment["CODEMAN_TEST_PASSWORD"]
    }

    private func requireServer() throws -> (url: String, password: String) {
        guard let serverURL, !serverURL.isEmpty, let password else {
            throw XCTSkip("No Codeman configured. Run Scripts/run-integration-tests.sh.")
        }
        return (serverURL, password)
    }

    @MainActor
    private func launchConnected() throws -> XCUIApplication {
        let server = try requireServer()
        let app = XCUIApplication()
        app.launchArguments += ["-ui-testing", "-reset-state"]
        app.launch()

        app.buttons["onboarding.addServer"].tap()
        let address = app.textFields["addServer.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        address.tap()
        address.typeText(server.url)

        let passwordField = app.secureTextFields["addServer.password"]
        passwordField.tap()
        passwordField.typeText(server.password)

        app.buttons["addServer.test"].tap()
        // A green check means the app reached the server and parsed `/api/node/info`.
        XCTAssertTrue(app.images["checkmark.circle.fill"].waitForExistence(timeout: 30),
                      "connection test did not succeed")

        app.buttons["addServer.save"].tap()
        // `Scripts/prepare-simulator.sh` turns AutoFill passwords off, so the "Save Password?"
        // sheet should never appear. This sweep is the belt to that braces, for a device the
        // script did not prepare — a short poll that finds nothing and moves on.
        dismissPasswordSaveSheetIfPresented(in: app, timeout: 2)
        return app
    }

    @MainActor
    func testOnboardingConnectsToARealServer() throws {
        let app = try launchConnected()
        // Once connected the app leaves onboarding for the workspace.
        XCTAssertTrue(waitForWorkspace(in: app), "app did not reach the workspace after connecting")
    }

    @MainActor
    func testLaunchSheetListsBackendsAndCases() throws {
        let app = try launchConnected()

        let newSession = newSessionButton(in: app)
        XCTAssertTrue(newSession.waitForExistence(timeout: 30))
        tap(newSession, in: app, until: app.descendants(matching: .any)["launch.newCase"])
        XCTAssertTrue(app.staticTexts["Shell"].waitForExistence(timeout: 10),
                      "the backend picker did not appear")
        XCTAssertTrue(app.descendants(matching: .any)["launch.browse"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["launch.newCase"].exists)
    }

    @MainActor
    func testDirectoryBrowserListsServerSuppliedRoots() throws {
        let app = try launchConnected()

        let newSession = newSessionButton(in: app)
        XCTAssertTrue(newSession.waitForExistence(timeout: 30))
        tap(newSession, in: app, until: app.descendants(matching: .any)["launch.browse"])
        app.descendants(matching: .any)["launch.browse"].tap()

        // The roots come from the server and are already ownership-scoped, so the assertion is
        // that *something* was rendered rather than that a specific root exists.
        XCTAssertTrue(app.buttons["browser.use"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.navigationBars["Choose Directory"].exists)
    }

    /// A launched session must produce a terminal surface with a real, non-zero grid — the one
    /// thing a compiling build and a green unit suite cannot tell you.
    @MainActor
    func testLaunchedSessionRendersATerminalGrid() throws {
        let app = try launchConnected()

        let newSession = newSessionButton(in: app)
        XCTAssertTrue(newSession.waitForExistence(timeout: 30))
        tap(newSession, in: app, until: app.descendants(matching: .any)["launch.newCase"])
        let caseName = app.textFields["newCase.name"]
        tap(app.descendants(matching: .any)["launch.newCase"], in: app, until: caseName)
        caseName.tap()
        caseName.typeText("gridcase\(Int(Date().timeIntervalSince1970) % 100000)")
        app.buttons["newCase.create"].tap()

        let shell = app.staticTexts.matching(identifier: "Shell").firstMatch
        if shell.waitForExistence(timeout: 10) {
            if shell.isHittable {
                shell.tap()
            } else {
                shell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
        }

        let terminal = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "terminal.pane."))
            .firstMatch
        XCTAssertTrue(tap(app.buttons["launch.start"], in: app, until: terminal, timeout: 45),
                      "no terminal surface appeared")

        // The header reports the live grid. A zero-by-zero grid means Ghostty never measured the
        // surface, which is the failure a screenshot alone would not distinguish from a dark theme.
        let grid = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "columns by")
        ).firstMatch
        XCTAssertTrue(grid.waitForExistence(timeout: 30), "the pane never reported a grid size")
        XCTAssertFalse(grid.label.hasPrefix("0 columns"), "grid never measured: \(grid.label)")
    }

    @MainActor
    func testCustomActionEditorRoundTrips() throws {
        let app = try launchConnected()

        // Settings is reachable from the sidebar toolbar on iPad and the nav bar on iPhone.
        let settings = app.buttons["toolbar.settings"].waitForExistence(timeout: 20)
            ? app.buttons["toolbar.settings"]
            : app.buttons["Settings"].firstMatch
        tap(settings, in: app, until: app.buttons["settings.customActions"])
        tap(app.buttons["settings.customActions"], in: app, until: app.buttons["actions.add"])
        tap(app.buttons["actions.add"], in: app, until: app.textFields["actionEditor.label"])

        let label = app.textFields["actionEditor.label"]
        label.tap()
        label.typeText("UI test action")

        let command = app.textViews["actionEditor.command"].exists
            ? app.textViews["actionEditor.command"]
            : app.textFields["actionEditor.command"]
        command.tap()
        command.typeText("echo hello")

        // Save is gated on validation; a well-formed action must enable it.
        let save = app.buttons["actionEditor.save"]
        XCTAssertTrue(save.isEnabled, "a valid action should be saveable")
        save.tap()

        XCTAssertTrue(app.staticTexts["UI test action"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testEnvironmentEditorWarnsAboutAnUnlaunchableKey() throws {
        let app = try launchConnected()

        let settings = app.buttons["toolbar.settings"].waitForExistence(timeout: 20)
            ? app.buttons["toolbar.settings"]
            : app.buttons["Settings"].firstMatch
        tap(settings, in: app, until: app.buttons["settings.customActions"])
        tap(app.buttons["settings.customActions"], in: app, until: app.buttons["actions.add"])
        tap(app.buttons["actions.add"], in: app, until: app.textFields["actionEditor.label"])

        let label = app.textFields["actionEditor.label"]
        label.tap(); label.typeText("Env probe")

        let command = app.textViews["actionEditor.command"].exists
            ? app.textViews["actionEditor.command"]
            : app.textFields["actionEditor.command"]
        command.tap(); command.typeText("true")

        app.buttons["actionEditor.addEnv"].tap()
        let key = app.textFields["env.key"].firstMatch
        XCTAssertTrue(key.waitForExistence(timeout: 5))
        key.tap()
        // Outside the server's launch-time prefix allowlist, so the editor must say so *now*
        // rather than letting the user discover it at launch.
        key.typeText("MY_VAR")

        XCTAssertTrue(app.staticTexts["Warnings"].waitForExistence(timeout: 5)
                      || app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'refuse'")).firstMatch.exists,
                      "no warning shown for a key outside the allowlist")
        // A warning must not block saving.
        XCTAssertTrue(app.buttons["actionEditor.save"].isEnabled)
    }
}
