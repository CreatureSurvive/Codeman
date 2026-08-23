import SwiftUI

/// The open-session tab bar, in the spirit of Xcode's document tabs.
///
/// Tabs are the *workspace*, not the server's session list: `AppModel.openSessionIDs` holds what
/// the user opened, so closing a tab puts a session away without stopping the agent, and going
/// back to Home leaves every tab where it was.
///
/// Horizontally scrolling with `scrollPosition` rather than `scrollTo`: the active tab must be
/// reachable on a phone where three tabs already overflow the width.
struct SessionTabStrip: View {
    @Environment(AppModel.self) private var model

    /// Shown at the leading edge on compact widths, where there is no sidebar to go back to.
    var onHome: (() -> Void)?
    var onNewSession: (() -> Void)?

    @State private var scrolledTab: String?

    var body: some View {
        HStack(spacing: 0) {
            if let onHome {
                Button(action: onHome) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 40, height: 34)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Home")
                .accessibilityIdentifier("tabs.home")

                Divider().frame(height: 20)
            }

            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(model.openSessions) { session in
                        SessionTab(
                            session: session,
                            isActive: session.id == model.selectedSessionID,
                            needsAttention: model.needsAttention.contains(session.id),
                            waiting: model.waitingForInput.contains(session.id),
                            onSelect: { model.selectedSessionID = session.id },
                            onClose: { model.closeTab(session.id) }
                        )
                        .id(session.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollPosition(id: $scrolledTab, anchor: .center)
            .scrollIndicators(.hidden)

            if let onNewSession {
                Divider().frame(height: 20)

                Button(action: onNewSession) {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 40, height: 34)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New Session")
                .accessibilityIdentifier("tabs.new")
            }
        }
        .frame(height: 34)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        // Keep the active tab on screen when it changes from elsewhere (a tab closing, an
        // approval card jumping to a session, a deep link).
        .onChange(of: model.selectedSessionID) { _, id in
            guard let id else { return }
            withAnimation(.snappy) { scrolledTab = id }
        }
        .accessibilityIdentifier("session.tabs")
    }
}

private struct SessionTab: View {
    let session: SessionSnapshot
    let isActive: Bool
    let needsAttention: Bool
    let waiting: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(session: session, needsAttention: needsAttention, waiting: waiting)
                .scaleEffect(0.8)

            Text(session.displayName)
                .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                .lineLimit(1)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close \(session.displayName)")
            .accessibilityIdentifier("tab.close.\(session.id)")
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .frame(maxWidth: 180)
        .background(isActive ? Color(.systemBackground) : Color.clear)
        .overlay(alignment: .bottom) {
            // An active tab is joined to the content below it; the strip's own bottom rule is
            // what makes that read as one surface rather than a floating chip.
            Rectangle()
                .fill(isActive ? Color.accentColor : Color.clear)
                .frame(height: 2)
        }
        .overlay(alignment: .trailing) { Divider().frame(height: 20) }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .hoverEffect(.highlight)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tab.\(session.id)")
    }
}
