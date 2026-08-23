import XCTest

/// Drives the app against a real Codeman and captures screenshots at each stage.
///
/// This is the verification that the terminal actually *renders* — a build that compiles and a
/// test suite that passes still cannot tell you whether Metal drew anything. The captures are
/// attached to the `.xcresult` and extracted by `Scripts/capture-screenshots.sh`.
///
/// Skips itself when no server is configured, rather than capturing a blank onboarding screen and
/// calling it proof.
final class ScreenshotUITests: XCTestCase {
    private var serverURL: String?
    private var password: String?

    override func setUp() async throws {
        try await super.setUp()
        // Capture as much as possible even if one step misbehaves — a partial set of
        // screenshots is diagnostic, an aborted run is not.
        continueAfterFailure = true
        let environment = ProcessInfo.processInfo.environment
        serverURL = environment["CODEMAN_TEST_URL"].flatMap { $0.hasPrefix("$(") ? nil : $0 }
        password = environment["CODEMAN_TEST_PASSWORD"].flatMap { $0.hasPrefix("$(") ? nil : $0 }
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testCaptureFullFlow() throws {
        guard let serverURL else {
            throw XCTSkip("No Codeman configured. Run Scripts/capture-screenshots.sh.")
        }
        // An unauthenticated Codeman is a valid target; an empty password is not a reason to skip.
        let password = self.password ?? ""

        // Connect through launch arguments: typing an address and password through the on-screen
        // keyboard was most of this capture's runtime, and none of what it proves.
        let app = XCUIApplication()
        app.launchArguments += [
            "-ui-testing", "-reset-state",
            "-server-url", serverURL,
            "-server-password", password,
        ]
        app.launch()

        XCTAssertTrue(waitForWorkspace(in: app), "app did not reach the workspace")
        capture(app, "01-home")

        let newSession = newSessionButton(in: app)
        XCTAssertTrue(newSession.waitForExistence(timeout: 20), "no way to start a session")
        capture(app, "02-home-detail")

        guard tap(newSession, in: app, until: app.descendants(matching: .any)["launch.newCase"]) else {
            capture(app, "05-launch-sheet-UNEXPECTED")
            return
        }
        capture(app, "05-launch-sheet")

        // A shell session needs no CLI installed, so the capture works on any machine.
        let caseName = app.textFields["newCase.name"]
        guard tap(app.descendants(matching: .any)["launch.newCase"], in: app, until: caseName) else {
            capture(app, "05b-newcase-MISSING")
            XCTFail("new-case screen never appeared. Hierarchy:\n\(app.debugDescription)")
            return
        }
        caseName.tap()
        caseName.typeText("shotcase\(Int(Date().timeIntervalSince1970) % 100000)")
        app.buttons["newCase.create"].tap()

        // Pick Shell, then start. A `StaticText` inside a picker row is not itself hittable, so
        // the tap goes to its coordinate rather than the element.
        let shell = app.staticTexts.matching(identifier: "Shell").firstMatch
        if shell.waitForExistence(timeout: 10) {
            if shell.isHittable {
                shell.tap()
            } else {
                shell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
        }
        capture(app, "06-launch-configured")

        let terminalQuery = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "terminal.pane."))
            .firstMatch
        guard tap(app.buttons["launch.start"], in: app, until: terminalQuery, timeout: 45) else {
            capture(app, "07-terminal-MISSING")
            return
        }

        // Wait for a terminal surface, then give Ghostty time to attach and draw the shell prompt.
        // The snapshot pull plus the first PTY output; 6s is generous but this is a capture run.
        Thread.sleep(forTimeInterval: 6)
        capture(app, "07-terminal")

        // Type into the terminal so the capture shows real, agent-produced output rather than an
        // empty grid that a broken renderer would also produce.
        let composer = app.textFields["composer.field"]
        if composer.waitForExistence(timeout: 10) {
            composer.tap()
            composer.typeText("echo CODEMAN NATIVE TERMINAL OK && ls")
            app.buttons["composer.send"].tap()
            Thread.sleep(forTimeInterval: 5)
            capture(app, "08-terminal-with-output")
        }

        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 3)
        capture(app, "09-terminal-landscape")
        XCUIDevice.shared.orientation = .portrait
        Thread.sleep(forTimeInterval: 2)

        // Settings and the custom-action editor, the other two screens worth eyeballing.
        if app.buttons["toolbar.settings"].exists {
            app.buttons["toolbar.settings"].tap()
        } else if app.buttons["Settings"].firstMatch.exists {
            app.buttons["Settings"].firstMatch.tap()
        }
        if app.buttons["settings.customActions"].waitForExistence(timeout: 10) {
            capture(app, "10-settings")
            app.buttons["settings.customActions"].tap()
            Thread.sleep(forTimeInterval: 1)
            capture(app, "11-custom-actions")
        }
    }
}
