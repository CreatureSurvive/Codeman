import GhosttyTerminal
import UIKit
import XCTest
@testable import Codeman

/// Terminal rendering, tested against a real Ghostty surface in a real window — with no server,
/// no onboarding and no UI navigation.
///
/// The unit bundle is hosted by the app, so UIKit and Metal are both available. That matters for
/// iteration speed: the equivalent XCUITest boots a throwaway Codeman, installs the app, types
/// through onboarding and taps to a session, which is minutes per attempt. These run in about a
/// second and answer the only question that was ever hard — whether bytes handed to
/// `InMemoryTerminalSession` end up on the grid.
@MainActor
final class TerminalSurfaceTests: XCTestCase {
    private var window: UIWindow!
    private var controller: TerminalController!
    private var view: AccessibleTerminalView!
    private var session: InMemoryTerminalSession!

    override func setUp() async throws {
        try await super.setUp()

        session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        controller = TerminalController(theme: CodemanTerminalTheme.tokyoNight.resolved())

        // A real, visible window: the surface refuses to build for a detached view or one with a
        // zero size, which is exactly the state an offscreen view would be in.
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        view = AccessibleTerminalView(frame: window.bounds)
        view.terminalSession = session
        view.controller = controller
        view.configuration = TerminalSurfaceOptions(
            backend: .inMemory(session),
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

    override func tearDown() async throws {
        view.removeFromSuperview()
        window.rootViewController = nil
        window.isHidden = true
        window = nil
        view = nil
        controller = nil
        session = nil
        try await super.tearDown()
    }

    /// Spins the run loop until `predicate` holds, because the surface builds and drains its
    /// writes on the main run loop rather than on a queue the test can await.
    private func waitForViewport(
        timeout: TimeInterval = 10,
        until predicate: (String) -> Bool
    ) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var latest = ""
        repeat {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            latest = session.readViewportText() ?? ""
            if predicate(latest) { return latest }
        } while Date() < deadline
        return latest
    }

    func testTheSurfaceAttaches() {
        let attached = waitForViewport { _ in true }
        XCTAssertNotNil(session.readViewportText(), "no surface attached: \(attached)")
    }

    func testWrittenBytesReachTheViewport() {
        session.receive(Data("hello-from-the-host\r\n".utf8))
        let text = waitForViewport { $0.contains("hello-from-the-host") }
        XCTAssertTrue(text.contains("hello-from-the-host"), "viewport was: \(text.debugDescription)")
    }

    /// Bytes written before the surface exists must survive: the snapshot for a reconnecting pane
    /// is fetched as soon as the socket opens, which routinely beats the view being laid out.
    func testBytesWrittenBeforeAttachAreFlushed() {
        let early = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        early.receive(Data("written-before-attach\r\n".utf8))

        let lateView = AccessibleTerminalView(frame: window.bounds)
        lateView.terminalSession = early
        lateView.controller = controller
        lateView.configuration = TerminalSurfaceOptions(
            backend: .inMemory(early),
            fontSize: 13,
            resizeThrottleMilliseconds: 0
        )
        window.addSubview(lateView)
        lateView.layoutIfNeeded()
        lateView.fitToSize()
        defer { lateView.removeFromSuperview() }

        let deadline = Date().addingTimeInterval(10)
        var text = ""
        repeat {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            text = early.readViewportText() ?? ""
            if text.contains("written-before-attach") { break }
        } while Date() < deadline

        XCTAssertTrue(text.contains("written-before-attach"), "viewport was: \(text.debugDescription)")
    }

    /// The exact byte sequence `applySnapshot` writes: clear scrollback, home, clear screen, then
    /// the captured buffer. This is the path that showed a blank pane on first open.
    func testSnapshotSequenceRendersTheCapturedBuffer() {
        let reset = "\u{1B}[3J\u{1B}[H\u{1B}[2J"
        let capture = reset
            + "~/codeman-cases/demo $ echo SCROLLBACK-MARKER\r\n"
            + "SCROLLBACK-MARKER\r\n"
            + "~/codeman-cases/demo $ "
        session.receive(Data(capture.utf8))

        let text = waitForViewport { $0.contains("SCROLLBACK-MARKER") }
        XCTAssertTrue(text.contains("SCROLLBACK-MARKER"), "viewport was: \(text.debugDescription)")
    }

    /// What the accessibility layer publishes must be what is on the grid — this is the only way
    /// anything outside the process can see the terminal's contents.
    func testAccessibilityValueReportsTheViewport() {
        session.receive(Data("accessible-content\r\n".utf8))
        _ = waitForViewport { $0.contains("accessible-content") }
        XCTAssertEqual(view.accessibilityValue, session.readViewportText())
        XCTAssertTrue(view.accessibilityValue?.contains("accessible-content") == true)
    }
}

/// Font size must survive the surface being rebuilt.
///
/// A rebuild happens on far more than a font change — a tab switch, a rotation, backgrounding —
/// and every rebuild constructs a brand-new ghostty surface from `TerminalSurfaceOptions`. If the
/// host's configured size is not carried into that, the pane silently returns to the package
/// default while the setting still reads what the user chose.
@MainActor
final class TerminalFontSizeTests: XCTestCase {
    private var window: UIWindow!
    private var controller: TerminalController!
    private var view: AccessibleTerminalView!
    private var session: InMemoryTerminalSession!
    /// The resize closure is called from the package's own queue, so the observed grid lives in a
    /// lock-guarded box rather than on this `@MainActor` test.
    private let gridBox = GridBox()

    final class GridBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: (columns: UInt16, rows: UInt16)?
        func set(_ columns: UInt16, _ rows: UInt16) { lock.lock(); value = (columns, rows); lock.unlock() }
        var rows: Int { lock.lock(); defer { lock.unlock() }; return Int(value?.rows ?? 0) }
    }

    override func setUp() async throws {
        try await super.setUp()
        session = InMemoryTerminalSession(
            write: { _ in },
            resize: { [gridBox] viewport in gridBox.set(viewport.columns, viewport.rows) }
        )
        controller = TerminalController(theme: CodemanTerminalTheme.tokyoNight.resolved())
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
    }

    override func tearDown() async throws {
        view?.removeFromSuperview()
        window?.rootViewController = nil
        window?.isHidden = true
        view = nil; window = nil; controller = nil; session = nil
        try await super.tearDown()
    }

    private func attach(fontSize: Float) {
        view?.removeFromSuperview()
        view = AccessibleTerminalView(frame: window.bounds)
        view.terminalSession = session
        view.controller = controller
        view.configuration = TerminalSurfaceOptions(
            backend: .inMemory(session),
            fontSize: fontSize,
            resizeThrottleMilliseconds: 0
        )
        let host = UIViewController()
        host.view.addSubview(view)
        window.rootViewController = host
        window.isHidden = false
        view.frame = window.bounds
        view.layoutIfNeeded()
        view.fitToSize()
        settle()
    }

    private func settle(_ seconds: TimeInterval = 0.4) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// Cell height is the observable consequence of font size — a bigger font means fewer, taller
    /// rows in the same frame.
    private func rows() -> Int { gridBox.rows }

    func testABiggerFontProducesFewerRows() {
        attach(fontSize: 10)
        let smallFontRows = rows()
        XCTAssertGreaterThan(smallFontRows, 0, "the grid was never measured")

        attach(fontSize: 24)
        let largeFontRows = rows()
        XCTAssertLessThan(largeFontRows, smallFontRows,
                          "a 24pt font produced \(largeFontRows) rows, same as 10pt")
    }

    /// Probes whether ghostty accepts an absolute font size, which would make the restore a single
    /// call instead of stepping from a baseline read out of the config.
    func testAbsoluteFontSizeBindingAction() {
        attach(fontSize: 10)
        let smallRows = rows()
        XCTAssertGreaterThan(smallRows, 0)

        let accepted = view.performBindingAction("set_font_size:24")
        settle(0.5)
        let after = rows()
        print("PROBEFONT set_font_size accepted=\(accepted) rows \(smallRows) -> \(after)")
        XCTAssertTrue(accepted, "set_font_size was rejected")
        XCTAssertLessThan(after, smallRows, "set_font_size did not change the grid")
    }

    /// The reported bug: the setting sticks, the terminal does not.
    ///
    /// A theme change pushes the controller's config onto every live surface, and that config has
    /// no per-surface font size — so upstream the terminal snapped back to the default while the
    /// setting still read what the user chose. Our fork restores it.
    func testFontSizeSurvivesAControllerConfigPush() {
        attach(fontSize: 22)
        let before = rows()
        XCTAssertGreaterThan(before, 0)

        _ = controller.setTheme(CodemanTerminalTheme.gruvboxDark.resolved())
        settle(0.6)

        XCTAssertEqual(rows(), before,
                       "a theme change reset the terminal's font size")
    }

    /// Repeated reconfiguration must be a no-op, not a drift.
    ///
    /// The restore used to step from a baseline read out of the config; when that baseline was
    /// wrong the font moved a little further every time, which showed up as the terminal
    /// shrinking on every background/foreground cycle.
    func testRepeatedConfigPushesDoNotDriftTheFontSize() {
        attach(fontSize: 18)
        let before = rows()
        XCTAssertGreaterThan(before, 0)

        let themes: [CodemanTerminalTheme] = [.gruvboxDark, .nord, .dracula, .tokyoNight, .nord]
        for theme in themes {
            _ = controller.setTheme(theme.resolved())
            settle(0.3)
        }

        XCTAssertEqual(rows(), before,
                       "the font size drifted across \(themes.count) reconfigurations")
    }

    /// The reported bug: the setting sticks, the terminal does not.
    func testFontSizeSurvivesASurfaceRebuild() {
        attach(fontSize: 22)
        let before = rows()
        XCTAssertGreaterThan(before, 0)

        // Exactly what a tab switch or a foreground transition does.
        view.removeFromSuperview()
        settle(0.2)
        let host = UIViewController()
        host.view.addSubview(view)
        window.rootViewController = host
        view.frame = window.bounds
        view.layoutIfNeeded()
        view.fitToSize()
        settle()

        XCTAssertEqual(rows(), before,
                       "the rebuilt surface came back at a different font size")
    }
}


/// The replacement policy is pure, so it is tested on numbers alone.
final class SnapshotReplacementPolicyTests: XCTestCase {
    func testAnythingAppliesToAnEmptyGrid() {
        XCTAssertTrue(SnapshotReplacementPolicy.shouldApply(renderedBytes: 0, incomingBytes: 0))
        XCTAssertTrue(SnapshotReplacementPolicy.shouldApply(renderedBytes: 0, incomingBytes: 4000))
    }

    func testGrowthAlwaysApplies() {
        XCTAssertTrue(SnapshotReplacementPolicy.shouldApply(renderedBytes: 100, incomingBytes: 100))
        XCTAssertTrue(SnapshotReplacementPolicy.shouldApply(renderedBytes: 100, incomingBytes: 5000))
    }

    /// The measured failure: a 4000-line pane answering with 31 bytes.
    func testACollapsedCaptureIsRefused() {
        XCTAssertFalse(SnapshotReplacementPolicy.shouldApply(renderedBytes: 120_000, incomingBytes: 31))
    }

    /// Ordinary churn must still apply — a cleared screen or a TUI redrawing smaller is not a
    /// server fault, and refusing it would freeze the pane on stale content.
    func testModestShrinkageStillApplies() {
        XCTAssertTrue(SnapshotReplacementPolicy.shouldApply(renderedBytes: 1000, incomingBytes: 800))
        XCTAssertTrue(SnapshotReplacementPolicy.shouldApply(renderedBytes: 1000, incomingBytes: 500))
        XCTAssertFalse(SnapshotReplacementPolicy.shouldApply(renderedBytes: 1000, incomingBytes: 499))
    }
}
