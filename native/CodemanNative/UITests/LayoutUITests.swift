import XCTest

/// Layout and adaptivity checks that need no reachable server.
///
/// Everything server-dependent lives in `SessionFlowUITests`, which skips itself when no Codeman
/// is configured — a UI suite that silently passes because it could not reach anything would be
/// worse than one that says so.
final class LayoutUITests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    private func launchClean() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-ui-testing", "-reset-state"]
        app.launch()
        return app
    }

    @MainActor
    func testSurvivesRotationWithoutLosingState() {
        let app = launchClean()
        app.buttons["onboarding.addServer"].tap()

        let address = app.textFields["addServer.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        address.tap()
        address.typeText("192.168.4.4:3000")

        XCUIDevice.shared.orientation = .landscapeLeft
        // A typed address must survive the size-class change — losing it would mean the form is
        // being rebuilt rather than re-laid-out.
        XCTAssertTrue(app.textFields["addServer.address"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["addServer.address"].value as? String, "192.168.4.4:3000")

        XCUIDevice.shared.orientation = .portrait
        XCTAssertEqual(app.textFields["addServer.address"].value as? String, "192.168.4.4:3000")
    }

    @MainActor
    func testQRScanEntryPointExists() {
        let app = launchClean()
        app.buttons["onboarding.addServer"].tap()
        XCTAssertTrue(app.buttons["addServer.scan"].waitForExistence(timeout: 5))
    }

    /// Every interactive control must carry a label for VoiceOver.
    @MainActor
    func testPrimaryControlsAreAccessible() {
        let app = launchClean()
        let addServer = app.buttons["onboarding.addServer"]
        XCTAssertTrue(addServer.waitForExistence(timeout: 10))
        XCTAssertFalse(addServer.label.isEmpty)

        addServer.tap()
        XCTAssertTrue(app.buttons["addServer.test"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["addServer.test"].label.isEmpty)
        XCTAssertFalse(app.buttons["addServer.save"].label.isEmpty)
    }

    /// The test button must stay disabled until there is something to test — a spinner against a
    /// nil URL is the "loading state that never resolves" this app is meant not to have.
    @MainActor
    func testConnectionTestIsGatedOnAValidAddress() {
        let app = launchClean()
        app.buttons["onboarding.addServer"].tap()

        let test = app.buttons["addServer.test"]
        XCTAssertTrue(test.waitForExistence(timeout: 5))
        XCTAssertFalse(test.isEnabled)

        let address = app.textFields["addServer.address"]
        address.tap()
        address.typeText("codeman.example.com")
        XCTAssertTrue(test.isEnabled)
    }

    /// An unreachable address must produce a stated failure, not an endless spinner.
    @MainActor
    func testUnreachableServerReportsAFailure() {
        let app = launchClean()
        app.buttons["onboarding.addServer"].tap()

        let address = app.textFields["addServer.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        address.tap()
        // Reserved for documentation/examples, and port 1 is never listening.
        address.typeText("192.0.2.1:1")

        app.buttons["addServer.test"].tap()

        // The result is an error line under the button; the exact text comes from URLSession, so
        // assert that the failure surfaced at all rather than pinning a system string.
        let failed = NSPredicate(format: "exists == true")
        let indicator = app.images["xmark.circle.fill"]
        expectation(for: failed, evaluatedWith: indicator, handler: nil)
        waitForExpectations(timeout: 45)
    }
}
