import SwiftUI
import UIKit

/// Top-level shell. iPad gets a three-column split view; iPhone gets a terminal-first stack with
/// the session list as a drawer.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        @Bindable var model = model

        Group {
            if model.activeServer == nil {
                OnboardingView()
            } else if horizontalSizeClass == .regular {
                RegularLayout()
            } else {
                CompactLayout()
            }
        }
        .background(AppAlertHost(alert: $model.alert))
        .sheet(item: $model.pendingQuickConnect) { request in
            NavigationStack {
                AddServerView(prefilled: request)
            }
        }
        .overlay(alignment: .top) { ConnectionBanner() }
    }
}

// MARK: - Error presentation

/// Presents `AppModel.alert` from the front-most view controller.
///
/// ⚠️ **A SwiftUI `.alert` attached to the root view cannot appear while a sheet is up.** UIKit
/// refuses to present on a controller that is already presenting, so the alert is dropped and the
/// failure is silent. That is not a corner case here: every error-raising surface in this app —
/// Add Server, Add Node, Pair Node, New Case, custom actions, rename — lives *inside* a sheet, so
/// the root-attached alert was invisible in exactly the places errors are most likely. A save that
/// threw looked like a dead button.
///
/// Attaching a second `.alert` inside each sheet would fix the symptom and introduce a worse
/// problem: both would be bound to the same optional and race to present it. One host that walks
/// to the front-most controller keeps a single alert in flight and covers every sheet, present and
/// future, without each one having to remember.
private struct AppAlertHost: UIViewControllerRepresentable {
    @Binding var alert: AppModel.AppAlert?

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        /// The alert currently on screen, so a re-render does not stack a duplicate.
        var presentedID: UUID?
    }

    func makeUIViewController(context: Context) -> UIViewController {
        // Zero-size and untouchable: this exists only to reach the window it is installed in.
        let controller = UIViewController()
        controller.view.isUserInteractionEnabled = false
        controller.view.backgroundColor = .clear
        return controller
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        guard let alert, context.coordinator.presentedID != alert.id else { return }
        guard let presenter = Self.frontmostController(from: controller) else { return }

        context.coordinator.presentedID = alert.id
        let sheet = UIAlertController(title: alert.title, message: alert.message, preferredStyle: .alert)
        sheet.addAction(UIAlertAction(title: "OK", style: .default) { _ in
            context.coordinator.presentedID = nil
            self.alert = nil
        })
        presenter.present(sheet, animated: true)
    }

    /// Walks the presentation chain from the window root. A controller mid-dismissal cannot
    /// present, so stop short of it rather than losing the alert to a UIKit no-op.
    private static func frontmostController(from anchor: UIViewController) -> UIViewController? {
        guard var top = anchor.view.window?.rootViewController else { return nil }
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top.isBeingDismissed ? nil : top
    }
}

// MARK: - iPad

private struct RegularLayout: View {
    @Environment(AppModel.self) private var model
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var model = model

        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
        } content: {
            TerminalWorkspace()
        } detail: {
            if model.preferences.showInspector {
                InspectorView()
                    .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 420)
            } else {
                // A collapsed detail column still needs content, or the split view shows a blank
                // third pane rather than giving its width back.
                Color.clear.frame(width: 0)
            }
        }
        .navigationSplitViewStyle(.balanced)
    }
}

/// The content column: the tab strip over one terminal, or two side by side.
///
/// The strip is always present once a tab is open, including while Home is showing, so switching
/// back to a running agent is one tap from anywhere — the Xcode arrangement, where the editor
/// changes under a stable row of documents.
private struct TerminalWorkspace: View {
    @Environment(AppModel.self) private var model
    @State private var splitRatio: Double = 0.5
    @State private var showsLaunch = false

    var body: some View {
        VStack(spacing: 0) {
            if !model.openSessions.isEmpty {
                SessionTabStrip(
                    onHome: model.selectedSessionID == nil ? nil : { model.leaveSession() },
                    onNewSession: { showsLaunch = true }
                )
            }

            Group {
                if let primary = model.selectedSessionID {
                    if let secondary = model.secondarySessionID {
                        SplitTerminals(primary: primary, secondary: secondary, ratio: $splitRatio)
                    } else {
                        TerminalPaneView(sessionID: primary, isPrimary: true)
                    }
                } else {
                    HomeView(onNewSession: { showsLaunch = true })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $showsLaunch) { LaunchSheet() }
    }
}

private struct SplitTerminals: View {
    let primary: String
    let secondary: String
    @Binding var ratio: Double

    private static let minimumPaneWidth: CGFloat = 240

    var body: some View {
        GeometryReader { proxy in
            let total = proxy.size.width
            let dividerWidth: CGFloat = 10
            let usable = max(total - dividerWidth, 1)
            let leading = min(max(usable * ratio, Self.minimumPaneWidth), usable - Self.minimumPaneWidth)

            HStack(spacing: 0) {
                TerminalPaneView(sessionID: primary, isPrimary: true)
                    .frame(width: max(leading, 0))

                PaneDivider(width: dividerWidth) { translation in
                    let next = (leading + translation) / usable
                    ratio = min(max(next, 0.15), 0.85)
                }

                TerminalPaneView(sessionID: secondary, isPrimary: false)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct PaneDivider: View {
    let width: CGFloat
    let onDrag: (CGFloat) -> Void

    @State private var isDragging = false

    var body: some View {
        Rectangle()
            .fill(isDragging ? Color.accentColor.opacity(0.5) : Color(.separator))
            .frame(width: width)
            .overlay {
                Capsule()
                    .fill(Color(.tertiaryLabel))
                    .frame(width: 3, height: 36)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        isDragging = true
                        onDrag(value.translation.width)
                    }
                    .onEnded { _ in isDragging = false }
            )
            .hoverEffect(.highlight)
            .accessibilityLabel("Resize terminal panes")
            .accessibilityAddTraits(.isButton)
    }
}

// MARK: - iPhone

/// iPhone: Home is the root, a session is a screen pushed on top of it, and the tab strip lets you
/// move between open sessions without going back first.
///
/// The back button is deliberately the standard navigation one. The previous layout had no route
/// out of a session at all — the terminal *was* the root view, so there was nothing to go back to.
private struct CompactLayout: View {
    @Environment(AppModel.self) private var model
    /// One sheet slot — see the note in `SidebarView`.
    @State private var presented: Presentation?

    private enum Presentation: String, Identifiable {
        case launch
        case settings
        case nodes
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            HomeView(
                onNewSession: { presented = .launch },
                onManageNodes: { presented = .nodes }
            )
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        presented = .settings
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .accessibilityIdentifier("toolbar.settings")
                }
            }
            // Driven by the model rather than by a `NavigationLink`, because a session is opened
            // from many places — a home card, a tab, an approval, a launch that just succeeded —
            // and they must all land on the same screen.
            .navigationDestination(isPresented: sessionPresented) {
                CompactSessionScreen(onNewSession: { presented = .launch })
            }
        }
        .sheet(item: $presented) { destination in
            switch destination {
            case .launch:
                LaunchSheet()
            case .settings:
                NavigationStack { SettingsView() }
            case .nodes:
                NavigationStack { NodeManagerView() }
            }
        }
    }

    private var sessionPresented: Binding<Bool> {
        Binding(
            get: { model.selectedSessionID != nil },
            // Only react to a dismissal: the push itself is driven by the selection changing.
            set: { if !$0 { model.leaveSession() } }
        )
    }
}

/// The pushed session screen: open tabs on top, the active terminal below.
private struct CompactSessionScreen: View {
    @Environment(AppModel.self) private var model
    let onNewSession: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if model.openSessions.count > 1 {
                // One tab is just the screen you are already on; the strip earns its row only
                // when there is somewhere else to go.
                SessionTabStrip(onNewSession: onNewSession)
            }

            if let id = model.selectedSessionID {
                TerminalPaneView(sessionID: id, isPrimary: true)
            } else {
                // Reached only for the instant between the last tab closing and the pop.
                Color(.systemBackground)
            }
        }
        .navigationTitle(model.selectedSessionID.flatMap { model.session(id: $0)?.displayName } ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Shared

/// Non-blocking connection banner. Deliberately a banner rather than a blocking overlay once
/// state has loaded: the terminal scrollback stays readable while the link is down.
private struct ConnectionBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.connectionState {
            case let .reconnecting(attempt, reason):
                banner(
                    text: attempt <= 1 ? "Reconnecting…" : "Reconnecting (attempt \(attempt))…",
                    detail: reason,
                    tint: .orange,
                    symbol: "arrow.triangle.2.circlepath"
                )
            case .unauthorized:
                banner(
                    text: "Sign-in required",
                    detail: "This server rejected the saved credentials.",
                    tint: .red,
                    symbol: "lock.trianglebadge.exclamationmark"
                )
            case let .failed(message):
                banner(text: "Not connected", detail: message, tint: .red, symbol: "wifi.exclamationmark")
            case .connecting, .connected, .disconnected:
                EmptyView()
            }
        }
        .animation(.snappy, value: model.connectionState)
    }

    private func banner(text: String, detail: String, tint: Color, symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(text).font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Button("Retry") {
                Task { await model.refreshEverything() }
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(tint.opacity(0.35))
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("banner.connection")
    }
}
