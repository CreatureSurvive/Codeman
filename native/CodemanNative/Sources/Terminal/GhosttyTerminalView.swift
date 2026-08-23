import GhosttyTerminal
import GhosttyTheme
import SwiftUI
import UIKit

/// SwiftUI host for a Ghostty Metal terminal surface.
///
/// The package's own `TerminalSurfaceView` is not used, for one concrete reason: its representable
/// assigns `view.delegate = context`, and `TerminalViewState` conforms to the title / grid-resize /
/// focus / close / bell / pwd / scrollbar / lifecycle / text-selection delegates but **not** to
/// `TerminalSurfaceOpenURLDelegate`. A link tapped in the terminal would therefore reach nothing.
/// `UITerminalView` exposes `delegate`, `controller`, `configuration`, `inputAccessoryItems`, and
/// `fitToSize()` as `open`/`public`, so hosting it directly costs a coordinator and buys the URL
/// hook, the accessory bar, and deterministic focus.
struct GhosttyTerminalView: UIViewRepresentable {
    let session: TerminalSession
    let controller: TerminalController
    let fontSize: Float
    let accessoryItems: [TerminalInputAccessoryItem]
    @Binding var isFocused: Bool
    /// Incremented by the host to mean "give up the keyboard now".
    ///
    /// A one-shot counter rather than `isFocused = false`: focus here is UIKit's first-responder
    /// state, which SwiftUI re-evaluates on its own schedule, so a steady-state `false` would
    /// resign the keyboard again every time the view updated. An edge cannot be re-triggered.
    var resignRequest: Int = 0
    /// Filled in with the live view so the pane can paste and present selections.
    let proxy: TerminalSurfaceProxy

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session, isFocused: $isFocused, proxy: proxy)
    }

    func makeUIView(context: Context) -> AccessibleTerminalView {
        let view = AccessibleTerminalView(frame: .zero)
        view.delegate = context.coordinator
        view.controller = controller
        view.configuration = TerminalSurfaceOptions(
            backend: .inMemory(session.ghosttySession),
            fontSize: fontSize,
            // ⚠️ Our fork adds this, but it is OFF until it actually works. Measured: reporting a
            // touch position does not make ghostty raise `MOUSE_OVER_LINK`, so the synthetic click
            // never has a link to activate. Enabling it would only send stray mouse positions.
            opensLinksOnTap: false,
            // Content redraws incrementally, so a coalescing window would read as blinking.
            // Resize coalescing lives in TerminalSession instead, where it can be expressed in
            // terms of what actually goes on the wire.
            resizeThrottleMilliseconds: 0
        )
        view.inputAccessoryItems = accessoryItems
        view.backgroundColor = .clear
        view.isOpaque = false
        view.isAccessibilityElement = true
        // ⚠️ Identified here, on the view itself, and NOT with a SwiftUI `.accessibilityIdentifier`
        // on the representable. SwiftUI's modifier wraps the view in its own accessibility element
        // whose `value` is empty, which hides the one thing worth reading — the live viewport that
        // `AccessibleTerminalView` publishes. A test querying that wrapper sees "" for a terminal
        // full of text.
        view.accessibilityIdentifier = "terminal.pane.\(session.sessionID)"
        view.accessibilityLabel = "Terminal"
        view.accessibilityTraits = [.updatesFrequently]
        view.terminalSession = session.ghosttySession
        context.coordinator.view = view
        context.coordinator.lastResignRequest = resignRequest
        proxy.view = view
        return view
    }

    func updateUIView(_ view: AccessibleTerminalView, context: Context) {
        context.coordinator.session = session
        context.coordinator.isFocusedBinding = $isFocused
        context.coordinator.proxy = proxy
        proxy.view = view
        view.terminalSession = session.ghosttySession
        view.accessibilityIdentifier = "terminal.pane.\(session.sessionID)"

        // ⚠️ A resign and the acquire below must never happen in the same update pass. The
        // delegate reports the focus change back asynchronously, so `isFocused` is still `true`
        // immediately after resigning — and the acquire branch would then put the keyboard
        // straight back up, which is exactly what "dismiss works, then it reopens" was.
        var didResignThisPass = false
        if resignRequest != context.coordinator.lastResignRequest {
            context.coordinator.lastResignRequest = resignRequest
            if view.isFirstResponder {
                _ = view.resignFirstResponder()
                didResignThisPass = true
            }
        }

        let desired = TerminalSurfaceOptions(
            backend: .inMemory(session.ghosttySession),
            fontSize: fontSize,
            opensLinksOnTap: false,
            resizeThrottleMilliseconds: 0
        )
        if !view.configuration.isEquivalentForHost(desired) {
            view.configuration = desired
        }
        if view.controller !== controller {
            view.controller = controller
        }
        if view.inputAccessoryItems != accessoryItems {
            view.inputAccessoryItems = accessoryItems
            view.reloadInputViews()
        }
        if isFocused, !didResignThisPass, !view.isFirstResponder {
            // Acquire-only. Treating `false` as "resign" tears the keyboard down the moment
            // SwiftUI's focus system re-evaluates, and UIKit retires the old first responder on
            // its own when another surface acquires.
            _ = view.acquireProgrammaticFocus()
        }
        view.fitToSize()
    }

    static func dismantleUIView(_ view: AccessibleTerminalView, coordinator: Coordinator) {
        view.delegate = nil
        view.terminalSession = nil
        if coordinator.proxy.view === view { coordinator.proxy.view = nil }
        coordinator.view = nil
    }

    /// The delegate. Conforms to every surface protocol the app acts on, including the URL hook
    /// the package's own state object omits.
    @MainActor
    final class Coordinator: NSObject,
        TerminalSurfaceTitleDelegate,
        TerminalSurfaceResizeDelegate,
        TerminalSurfaceFocusDelegate,
        TerminalSurfaceCloseDelegate,
        TerminalSurfaceOpenURLDelegate,
        TerminalSurfaceLifecycleDelegate,
        TerminalSurfaceTextSelectionRequestDelegate
    {
        var session: TerminalSession
        var isFocusedBinding: Binding<Bool>
        var proxy: TerminalSurfaceProxy
        weak var view: AccessibleTerminalView?
        /// Last `resignRequest` acted on, so one bump resigns once.
        var lastResignRequest = 0

        init(session: TerminalSession, isFocused: Binding<Bool>, proxy: TerminalSurfaceProxy) {
            self.session = session
            isFocusedBinding = isFocused
            self.proxy = proxy
        }

        /// ⚠️ **Without this the terminal has no selection, no copy and no paste menu at all.**
        ///
        /// `handleLongPressForSelection` bails on its very first line when the delegate does not
        /// conform to this protocol, so the long press silently does nothing — and since the edit
        /// menu is what would have offered Paste, that disappears with it. The package cannot
        /// present the selection itself: the grid is Metal, so it hands the text to the host.
        func terminalDidRequestTextSelection(_ request: TerminalTextSelectionRequest) {
            proxy.pendingSelection = TerminalSelectionPayload(
                text: request.text,
                anchorRange: request.anchorRange
            )
        }

        func terminalDidChangeTitle(_ title: String) {
            session.updateTitle(title)
        }

        func terminalDidResize(columns: Int, rows: Int) {
            // Grid metrics also arrive through the in-memory session's resize closure, which is
            // where they are forwarded to the server. This delegate exists so the pane can show
            // the live grid size without reading back through the transport.
            _ = (columns, rows)
        }

        func terminalDidChangeFocus(_ focused: Bool) {
            guard isFocusedBinding.wrappedValue != focused else { return }
            isFocusedBinding.wrappedValue = focused
        }

        func terminalDidClose(processAlive: Bool) {
            _ = processAlive
        }

        /// A fresh Ghostty surface starts with an empty grid, so the pane has to be re-sent its
        /// content. See `TerminalSession.surfaceDidAttach()`.
        func terminalDidAttachSurface(_ surface: TerminalSurface) {
            _ = surface
            session.surfaceDidAttach()
        }

        func terminalDidDetachSurface() {}

        func terminalDidRequestOpenURL(_ url: String, kind: TerminalOpenURLKind) {
            _ = kind
            session.openLink(url)
        }
    }
}

/// A `UITerminalView` that reports what is on the grid.
///
/// The terminal draws with Metal, so its content is invisible to everything that reads a view
/// hierarchy: VoiceOver announced only the word "Terminal", and no UI test could tell a rendered
/// scrollback from a blank one. `readViewportText()` is the package's supported way to read the
/// visible rows, and `accessibilityValue` is evaluated on demand, so this stays current with no
/// polling and costs nothing until something asks.
///
/// Scrollback is deliberately excluded — the API reads the viewport, which is also what
/// "what is on screen" means to a screen reader.
final class AccessibleTerminalView: UITerminalView {
    /// The backend whose grid this view is showing. Weak-by-ownership: the session outlives the
    /// view, and a stale reference here would report another pane's contents.
    weak var terminalSession: InMemoryTerminalSession?

    override var accessibilityValue: String? {
        get { terminalSession?.readViewportText() ?? super.accessibilityValue }
        set { super.accessibilityValue = newValue }
    }
}

extension TerminalSurfaceOptions {
    /// The package's `isEquivalent(to:)` is internal, so the host compares the fields it actually
    /// varies. Backend identity matters most: replacing it tears down the surface and discards the
    /// grid and scrollback.
    func isEquivalentForHost(_ other: TerminalSurfaceOptions) -> Bool {
        guard fontSize == other.fontSize else { return false }
        switch (backend, other.backend) {
        case let (.inMemory(lhs), .inMemory(rhs)): return lhs === rhs
        case (.exec, .exec): return true
        default: return false
        }
    }
}

// MARK: - Themes

/// Terminal appearance, kept separate from the app's own colour scheme.
///
/// A terminal palette is not a UI accent: the agents print ANSI colours and a light-on-dark
/// palette that reads well is a deliberate choice, so the user picks it explicitly rather than
/// inheriting it from Dark Mode.
enum CodemanTerminalTheme: String, CaseIterable, Identifiable, Sendable {
    case systemAdaptive
    case dracula
    case tokyoNight
    case catppuccinMocha
    case gruvboxDark
    case nord
    case solarizedDark
    case oneHalfLight
    case githubLight

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .systemAdaptive: "Match System"
        case .dracula: "Dracula"
        case .tokyoNight: "Tokyo Night"
        case .catppuccinMocha: "Catppuccin Mocha"
        case .gruvboxDark: "Gruvbox Dark"
        case .nord: "Nord"
        case .solarizedDark: "Solarized Dark"
        case .oneHalfLight: "One Half Light"
        case .githubLight: "GitHub Light"
        }
    }

    /// Names in `GhosttyThemeCatalog`. `systemAdaptive` pairs a light and a dark theme and lets
    /// the controller pick per appearance.
    private var catalogNames: (light: String, dark: String) {
        switch self {
        case .systemAdaptive: ("One Half Light", "Tokyo Night")
        case .dracula: ("Dracula", "Dracula")
        case .tokyoNight: ("Tokyo Night", "Tokyo Night")
        case .catppuccinMocha: ("Catppuccin Mocha", "Catppuccin Mocha")
        case .gruvboxDark: ("Gruvbox Dark", "Gruvbox Dark")
        case .nord: ("Nord", "Nord")
        case .solarizedDark: ("Solarized Dark", "Solarized Dark")
        case .oneHalfLight: ("One Half Light", "One Half Light")
        case .githubLight: ("GitHub Light", "GitHub Light")
        }
    }

    /// Resolves to a `TerminalTheme`, falling back to the package defaults when a catalog name is
    /// missing (the catalog ships hundreds of themes, but a rename upstream must not crash us).
    func resolved() -> TerminalTheme {
        let names = catalogNames
        let light = GhosttyThemeCatalog.theme(named: names.light)?.toTerminalConfiguration() ?? .alabaster
        let dark = GhosttyThemeCatalog.theme(named: names.dark)?.toTerminalConfiguration() ?? .afterglow
        return TerminalTheme(light: light, dark: dark)
    }
}
