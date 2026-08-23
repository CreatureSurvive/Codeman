import XCTest

extension XCTestCase {
    /// Labels iOS uses to decline the AutoFill save prompt.
    ///
    /// Deliberately **not** including "Cancel": that label appears on the app's own sheets, and a
    /// global hunt for it closes whatever the test was about to use. (It did exactly that here —
    /// the sweep dismissed the New Session sheet and the failure looked like a broken
    /// `NavigationLink`.) Every label below is specific to the system prompt.
    private var passwordSheetDismissLabels: [String] {
        ["Not Now", "Not now", "Never for This App", "Never for this App"]
    }

    /// Dismisses iOS's AutoFill "Save Password?" prompt if it is on screen.
    ///
    /// Typing into a `SecureField` next to a username field trips iOS's login-form heuristic. The
    /// prompt is legitimate behaviour a real user should keep, so the app does not suppress it —
    /// the tests decline it.
    ///
    /// Two properties shape this implementation:
    ///
    /// - It is presented as a remote view controller **inside the app's own accessibility
    ///   hierarchy**, not as a SpringBoard alert, so `addUIInterruptionMonitor` does not reliably
    ///   fire and querying SpringBoard alone finds nothing.
    /// - It appears on iOS's schedule, a beat after the field loses focus — sometimes after the
    ///   next step has begun — so a single check at the "obvious" moment misses it.
    ///
    /// Returns whether anything was dismissed.
    @MainActor
    @discardableResult
    func dismissPasswordSaveSheetIfPresented(
        in app: XCUIApplication,
        timeout: TimeInterval = 2
    ) -> Bool {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(timeout)

        repeat {
            for source in [app, springboard] {
                for label in passwordSheetDismissLabels {
                    let button = source.buttons[label]
                    if button.exists, button.isHittable {
                        button.tap()
                        return true
                    }
                }
            }
            if Date() >= deadline { break }
            Thread.sleep(forTimeInterval: 0.3)
        } while true

        return false
    }

    /// The New Session control, wherever this size class puts it.
    ///
    /// iPad has a sidebar toolbar button, iPhone a Home toolbar button, and a workspace with
    /// nothing running shows the empty-state button instead. One helper so a layout change is one
    /// edit rather than a sweep through every test.
    @MainActor
    func newSessionButton(in app: XCUIApplication, timeout: TimeInterval = 30) -> XCUIElement {
        let candidates = ["sidebar.newSession", "home.newSession", "home.empty.newSession", "tabs.new"]
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for identifier in candidates {
                let button = app.buttons[identifier]
                if button.exists, button.isHittable { return button }
            }
            Thread.sleep(forTimeInterval: 0.3)
        } while Date() < deadline
        // Return the canonical one so the failure names something recognisable.
        return app.buttons["home.newSession"]
    }

    /// Waits until the app has left onboarding for the workspace.
    @MainActor
    func waitForWorkspace(in app: XCUIApplication, timeout: TimeInterval = 30) -> Bool {
        let home = app.descendants(matching: .any)["home"]
        if home.waitForExistence(timeout: timeout) { return true }
        return app.buttons["sidebar.newSession"].waitForExistence(timeout: 5)
    }

    /// Taps `element` and waits for `expected` to appear, clearing the AutoFill prompt and
    /// retrying if it does not.
    ///
    /// A tap that lands while the prompt is up, or during a presentation animation, is silently
    /// swallowed — the tap "succeeds" and nothing happens. Retrying around an explicit expectation
    /// is what makes these flows deterministic instead of a coin flip.
    @MainActor
    @discardableResult
    func tap(
        _ element: XCUIElement,
        in app: XCUIApplication,
        until expected: XCUIElement,
        attempts: Int = 3,
        timeout: TimeInterval = 12,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        for attempt in 1...attempts {
            dismissPasswordSaveSheetIfPresented(in: app, timeout: attempt == 1 ? 1 : 3)

            if element.exists, element.isHittable {
                element.tap()
            } else if element.waitForExistence(timeout: 5) {
                element.tap()
            }

            if expected.waitForExistence(timeout: timeout) { return true }
        }

        XCTFail(
            "\(element) never produced \(expected) after \(attempts) attempts.",
            file: file,
            line: line
        )
        return false
    }
}
