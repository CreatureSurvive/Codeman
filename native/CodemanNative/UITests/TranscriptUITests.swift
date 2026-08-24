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

        // Real content, not the empty state: prose plus at least one collapsed run of steps.
        let stepRows = app.descendants(matching: .any)["transcript.steps"]
        XCTAssertTrue(stepRows.firstMatch.waitForExistence(timeout: 20), "no step rows rendered")

        let assistant = app.descendants(matching: .any)["transcript.assistant"].firstMatch
        XCTAssertTrue(assistant.exists, "no assistant prose rendered")

        let transcriptShot = XCTAttachment(screenshot: app.screenshot())
        transcriptShot.name = "transcript-timeline"
        transcriptShot.lifetime = .keepAlways
        add(transcriptShot)

        // ⚠️ Tap a row that is on screen. The view opens scrolled to the newest block, so
        // `firstMatch` is the OLDEST row and sits far above the viewport (measured at y = -593);
        // tapping it fails as "not hittable" and reads like a broken control.
        guard let visibleRow = app.descendants(matching: .any)
            .matching(identifier: "transcript.steps")
            .allElementsBoundByIndex.last(where: { $0.isHittable })
        else {
            XCTFail("no step row was on screen to open")
            return
        }
        visibleRow.tap()

        let sheet = app.descendants(matching: .any)["transcript.stepSheet"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "the step sheet never appeared")

        let sheetShot = XCTAttachment(screenshot: app.screenshot())
        sheetShot.name = "transcript-step-sheet"
        sheetShot.lifetime = .keepAlways
        add(sheetShot)

        // Drilling into a step must reach its command and output. Prefer a file edit when the run
        // contains one — the diff is the richest detail view and the one worth capturing.
        let steps = app.descendants(matching: .any).matching(identifier: "transcript.step")
        XCTAssertTrue(steps.firstMatch.waitForExistence(timeout: 10), "the sheet listed no steps")
        let all = steps.allElementsBoundByIndex
        let step = all.first { $0.label.hasPrefix("Edited") || $0.label.hasPrefix("Created") } ?? all[0]
        step.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["transcript.stepDetail"].waitForExistence(timeout: 10),
            "opening a step showed no detail"
        )

        let detailShot = XCTAttachment(screenshot: app.screenshot())
        detailShot.name = "transcript-step-detail"
        detailShot.lifetime = .keepAlways
        add(detailShot)
    }

    /// Images attached to a message render inline and open a zoomable viewer.
    ///
    /// Separate from the timeline test because it needs a conversation that actually contains
    /// images, and because this path has its own failure mode: the listing carries only
    /// references, so a broken fetch shows placeholders forever rather than erroring.
    @MainActor
    func testInlineImagesRenderAndZoom() throws {
        guard let sessionID = ProcessInfo.processInfo.environment["CODEMAN_TEST_TRANSCRIPT_SESSION"],
              !sessionID.isEmpty
        else { throw XCTSkip("Set CODEMAN_TEST_TRANSCRIPT_SESSION to a session with images.") }

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
        let chat = app.buttons["Chat"]
        XCTAssertTrue(chat.waitForExistence(timeout: 10), "no Chat option in the actions menu")
        chat.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["transcript.\(sessionID)"].waitForExistence(timeout: 20),
            "the transcript view never appeared"
        )

        // ⚠️ Precondition, not a failure. Whether the window contains images depends on which
        // slice of transcript the harness staged, and these tests share one session — a run tuned
        // for scrolling has no pictures in view, which is not a defect in image rendering.
        let images = app.descendants(matching: .any).matching(identifier: "transcript.image")
        guard images.firstMatch.waitForExistence(timeout: 20) else {
            throw XCTSkip("This transcript window contains no images; stage a slice that does.")
        }
        XCTAssertEqual(
            app.descendants(matching: .any).matching(identifier: "transcript.image.failed").count, 0,
            "an image failed to load"
        )

        let stripShot = XCTAttachment(screenshot: app.screenshot())
        stripShot.name = "transcript-image-strip"
        stripShot.lifetime = .keepAlways
        add(stripShot)

        guard let visible = images.allElementsBoundByIndex.first(where: { $0.isHittable }) else {
            XCTFail("no image was on screen to open")
            return
        }
        visible.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["transcript.imageViewer"].waitForExistence(timeout: 10),
            "tapping an image opened no viewer"
        )

        let viewerShot = XCTAttachment(screenshot: app.screenshot())
        viewerShot.name = "transcript-image-viewer"
        viewerShot.lifetime = .keepAlways
        add(viewerShot)
    }

    /// The jump-to-latest button: hidden at the bottom, shown when scrolled away, and it works.
    ///
    /// ⚠️ This test was DISABLED for an a11y-harness stall, and the button then shipped broken
    /// three times running. The stall was real (a `UITextView` exposes every text range as its own
    /// element, and resolution took minutes) but skipping was the wrong answer — the fix belonged
    /// in the composer, which now collapses to a single element. Do not skip this again.
    ///
    /// ⚠️ Asserts `isHittable`, not just `exists`. The two failure modes are indistinguishable to
    /// the user ("I tap it and nothing happens") but have opposite fixes: a button that renders
    /// UNDER the composer is a hit-testing bug, while one that is hittable but does not move the
    /// list is a scroll-targeting bug. Only `isHittable` separates them.
    @MainActor
    func testJumpToLatestAppearsAndWorks() throws {
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
        let chat = app.buttons["Chat"]
        XCTAssertTrue(chat.waitForExistence(timeout: 10))
        chat.tap()

        // ⚠️ `.firstMatch`: `accessibilityIdentifier` on a container propagates to its descendants,
        // so this id matches several elements and an unqualified query cannot be swiped.
        let transcript = app.descendants(matching: .any)
            .matching(identifier: "transcript.\(sessionID)")
            .firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: 25), "the transcript never appeared")
        // Let the initial anchor settle before judging the button.
        Thread.sleep(forTimeInterval: 3)

        let jump = app.descendants(matching: .any)["transcript.jumpToLatest"]
        XCTAssertFalse(jump.exists, "the jump button should be hidden when already at the bottom")

        // Scroll up: it must appear. Drag by coordinates rather than `swipeDown` on the element —
        // the propagated identifier can resolve to a leaf whose own bounds are too small to
        // produce a scroll.
        // ⚠️ Swipe the TRANSCRIPT, not the app. An app-level gesture resolves the whole
        // accessibility hierarchy first, and since the composer became a UITextView that subtree
        // is large enough to stall the query for minutes.
        for _ in 0..<3 { transcript.swipeDown(velocity: .fast) }
        let afterSwipe = XCTAttachment(screenshot: app.screenshot())
        afterSwipe.name = "after-scrolling-up"
        afterSwipe.lifetime = .keepAlways
        add(afterSwipe)
        XCTAssertTrue(jump.waitForExistence(timeout: 8), "scrolling up did not reveal the jump button")
        // ⚠️ The discriminator. The scroll view extends BEHIND the composer (that is what
        // `safeAreaInset` buys), so an overlay aligned to its bottom edge lands inside the
        // composer and the composer eats the tap — visible, and completely inert.
        XCTAssertTrue(jump.isHittable, "the jump button is visible but not hittable — something covers it")

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "jump-button-visible"
        shot.lifetime = .keepAlways
        add(shot)

        // Tapping it must return to the bottom, which hides it again.
        jump.tap()
        Thread.sleep(forTimeInterval: 2.5)
        let afterTap = XCTAttachment(screenshot: app.screenshot())
        afterTap.name = "after-tapping-jump"
        afterTap.lifetime = .keepAlways
        add(afterTap)
        XCTAssertFalse(jump.exists, "tapping jump-to-latest did not return to the bottom")
    }

    /// Project Files opens from the session's "…" menu and lists real files.
    @MainActor
    func testProjectFilesOpensFromMenu() throws {
        guard let sessionID = ProcessInfo.processInfo.environment["CODEMAN_TEST_TRANSCRIPT_SESSION"],
              !sessionID.isEmpty
        else { throw XCTSkip("Set CODEMAN_TEST_TRANSCRIPT_SESSION.") }

        let app = XCUIApplication()
        app.launchArguments += [
            "-ui-testing", "-reset-state",
            "-server-url", serverURL,
            "-server-password", password,
        ]
        app.launch()
        XCTAssertTrue(waitForWorkspace(in: app), "never reached the workspace")

        let card = app.descendants(matching: .any)["home.session.\(sessionID)"]
        XCTAssertTrue(card.waitForExistence(timeout: 30), "the session never appeared")
        card.tap()

        let actions = app.descendants(matching: .any)["terminal.actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 20), "the pane toolbar never appeared")
        actions.tap()

        // ⚠️ `.firstMatch`: the compact toolbar and the iPad pane header each carry this menu, so
        // the label matches more than one element even though only one is on screen.
        let files = app.buttons.matching(identifier: "Project Files").firstMatch
        XCTAssertTrue(files.waitForExistence(timeout: 10), "no Project Files entry in the menu")
        files.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["projectFiles"].waitForExistence(timeout: 20),
            "the file browser never appeared"
        )
        // Real content, not an empty shell.
        let entries = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "projectFiles."))
        XCTAssertTrue(entries.firstMatch.waitForExistence(timeout: 15), "the browser listed nothing")

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "project-files"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
