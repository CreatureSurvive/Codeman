import XCTest

/// The transcript view against a real server.
///
/// Worth driving rather than unit-testing alone: every other transcript test works on decoded
/// values, and none of them can catch the failures this screen actually risks — a `LazyVStack` of
/// mixed block views that fails to lay out, a `DisclosureGroup` that renders nothing, or an empty
/// state showing while blocks exist. Those are only visible when the view is on screen.
final class TranscriptUITests: XCTestCase {
    private var serverURL: String!
    private var password: String!

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard let url = environment["CODEMAN_TEST_URL"], !url.isEmpty, !url.hasPrefix("$(")
        else { throw XCTSkip("No Codeman configured. Run Scripts/fast-ui-test.sh.") }
        serverURL = url
        password = environment["CODEMAN_TEST_PASSWORD"] ?? ""
    }

    /// Opens the session named by `CODEMAN_TEST_TRANSCRIPT_SESSION`, switches the pane to Chat and
    /// asserts real blocks rendered.
    @MainActor
    func testTranscriptRendersBlocks() throws {
        guard let sessionID = ProcessInfo.processInfo.environment["CODEMAN_TEST_TRANSCRIPT_SESSION"],
              !sessionID.isEmpty
        else { throw XCTSkip("Set CODEMAN_TEST_TRANSCRIPT_SESSION to a session with a transcript.") }

        let app = XCUIApplication()
        app.launchArguments += [
            "-ui-testing", "-reset-state",
            "-server-url", serverURL,
            "-server-password", password,
        ]
        app.launch()

        XCTAssertTrue(waitForWorkspace(in: app), "never reached the workspace")

        let card = app.descendants(matching: .any)["home.session.\(sessionID)"]
        XCTAssertTrue(card.waitForExistence(timeout: 30), "the session never appeared on Home")
        card.tap()

        let actions = app.descendants(matching: .any)["terminal.actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 20), "the pane toolbar never appeared")
        actions.tap()

        // The view-mode picker is inline in the actions menu, so "Chat" is a plain menu row.
        let chat = app.buttons["Chat"]
        XCTAssertTrue(chat.waitForExistence(timeout: 10), "no Chat option in the actions menu")
        chat.tap()

        let transcript = app.descendants(matching: .any)["transcript.\(sessionID)"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 20), "the transcript view never appeared")

        // Real content, not the empty state: at least one tool row and one prose block.
        let toolRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "transcript.tool."))
            .firstMatch
        XCTAssertTrue(toolRow.waitForExistence(timeout: 20), "no tool-call rows rendered")

        let assistant = app.descendants(matching: .any)["transcript.assistant"].firstMatch
        XCTAssertTrue(assistant.exists, "no assistant prose rendered")

        // ⚠️ Tap a row that is actually on screen. The view opens scrolled to the newest block, so
        // `firstMatch` is the OLDEST tool call and sits far above the viewport (measured at
        // y = -593); tapping it fails as "not hittable" and reads like a broken accordion.
        let rows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "transcript.tool."))
        let visibleRow = rows.allElementsBoundByIndex.last { $0.isHittable }
        guard let visibleRow else {
            XCTFail("no tool-call row was on screen to expand")
            return
        }
        visibleRow.tap()
        XCTAssertTrue(
            app.buttons["transcript.code.copy"].firstMatch.waitForExistence(timeout: 10),
            "expanding a tool call revealed no output"
        )

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "transcript-view"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
