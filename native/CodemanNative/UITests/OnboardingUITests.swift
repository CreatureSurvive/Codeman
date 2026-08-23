import XCTest

/// Onboarding is the one flow that works with no server reachable, so it is the UI suite's
/// foundation: everything else is gated behind a live Codeman.
final class OnboardingUITests: XCTestCase {
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
    func testShowsConnectPromptOnFirstRun() {
        let app = launchClean()
        XCTAssertTrue(app.buttons["onboarding.addServer"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testAddServerFormValidatesAddress() {
        let app = launchClean()
        app.buttons["onboarding.addServer"].tap()

        let address = app.textFields["addServer.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))

        // Save stays disabled until the address parses.
        let save = app.buttons["addServer.save"]
        XCTAssertFalse(save.isEnabled)

        address.tap()
        address.typeText("192.168.1.50:3000")
        XCTAssertTrue(save.isEnabled)

        // A LAN address must default to http — the footer says which URL will be used.
        XCTAssertTrue(app.staticTexts["Will connect to http://192.168.1.50:3000"].exists)
    }

    /// Save must persist the server and leave onboarding even when the address is unreachable —
    /// connecting is `activate`'s job and it reports failure through the banner, not by refusing
    /// to save.
    ///
    /// This is the regression test for a Save button that did nothing: storing the credential
    /// threw `errSecNoSuchAttr` from the Keychain, and the resulting alert was bound to the root
    /// view, which cannot present while this sheet is up. Both halves were invisible, so the
    /// button simply looked dead.
    @MainActor
    func testSavingAnUnreachableServerLeavesOnboarding() {
        let app = launchClean()
        app.buttons["onboarding.addServer"].tap()

        let address = app.textFields["addServer.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        address.tap()
        // Port 1 refuses immediately, so the save completes without waiting out a network timeout.
        address.typeText("127.0.0.1:1")

        app.buttons["addServer.save"].tap()
        dismissPasswordSaveSheetIfPresented(in: app)

        // The sheet is gone…
        XCTAssertTrue(
            app.textFields["addServer.address"].waitForNonExistence(timeout: 20),
            "the Add Server sheet stayed up, so the save never completed"
        )
        // …and so is onboarding: a saved server is now active.
        XCTAssertFalse(app.buttons["onboarding.addServer"].exists)
        // The refused connection is reported, not swallowed. Queried across element types because
        // `.accessibilityElement(children: .combine)` decides the banner's type, not the test.
        let banner = app.descendants(matching: .any).matching(identifier: "banner.connection").firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 20), "the failed connection was never surfaced")
    }

    @MainActor
    func testAuthModeSwitchesCredentialFields() {
        let app = launchClean()
        app.buttons["onboarding.addServer"].tap()
        XCTAssertTrue(app.textFields["addServer.address"].waitForExistence(timeout: 5))

        XCTAssertTrue(app.secureTextFields["addServer.password"].exists)

        app.buttons["Token"].tap()
        XCTAssertTrue(app.secureTextFields["addServer.token"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.secureTextFields["addServer.password"].exists)
    }

    @MainActor
    func testRotationKeepsOnboardingUsable() {
        let app = launchClean()
        XCTAssertTrue(app.buttons["onboarding.addServer"].waitForExistence(timeout: 10))

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["onboarding.addServer"].waitForExistence(timeout: 5))

        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.buttons["onboarding.addServer"].waitForExistence(timeout: 5))
    }
}
