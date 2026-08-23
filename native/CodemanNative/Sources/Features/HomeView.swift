import SwiftUI

/// The workspace home: what is running, what wants you, and what you were doing before.
///
/// Replaces an empty state whose only content was a New Session button. The web client's two home
/// screens both answer "which of these wants me next?" through one ordering rule, and this uses
/// the same `SessionOrdering`, so a phone, a tablet and the browser rank the same sessions the
/// same way.
///
/// Layout is one adaptive grid rather than a phone list and a separate tablet grid: the card is
/// the same object at every size, and a second implementation is a second thing to drift.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var onNewSession: () -> Void
    var onManageNodes: (() -> Void)?

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: horizontalSizeClass == .compact ? 260 : 300), spacing: 12)]
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22, pinnedViews: []) {
                if !model.approvals.isEmpty {
                    section("Needs you", symbol: "exclamationmark.bubble.fill", tint: .red) {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(model.approvals) { item in
                                ApprovalCard(item: item)
                            }
                        }
                    }
                }

                section("Running", symbol: "bolt.horizontal.circle.fill", tint: .green) {
                    if model.orderedSessions.isEmpty {
                        EmptyRunningCard(onNewSession: onNewSession)
                    } else {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(model.orderedSessions) { session in
                                SessionCard(
                                    session: session,
                                    needsAttention: model.needsAttention.contains(session.id),
                                    waiting: model.waitingForInput.contains(session.id),
                                    isOpen: model.openSessionIDs.contains(session.id)
                                ) {
                                    model.selectedSessionID = session.id
                                }
                            }
                        }
                    }
                }

                if !model.historySessions.isEmpty {
                    section("Recent", symbol: "clock.arrow.circlepath", tint: .secondary) {
                        VStack(spacing: 0) {
                            ForEach(model.historySessions.prefix(12)) { row in
                                HistoryRow(row: row) {
                                    Task { await model.resumeHistorySession(row) }
                                }
                                if row.id != model.historySessions.prefix(12).last?.id {
                                    Divider().padding(.leading, 40)
                                }
                            }
                        }
                        .background(Color(.secondarySystemGroupedBackground),
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .refreshable { await model.refreshEverything() }
        .navigationTitle(model.activeServer?.displayName ?? "Codeman")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: onNewSession) {
                    Label("New Session", systemImage: "plus")
                }
                .accessibilityIdentifier("home.newSession")
            }
            if model.nodes.count > 1 || model.nodeManagementAvailable {
                ToolbarItem(placement: .topBarLeading) {
                    // A **switcher**, not just a link to the manager. The compact layout has no
                    // sidebar, so when Home replaced the session drawer this was the only way to
                    // reach another node's sessions — and it was missing.
                    Menu {
                        Picker("Node", selection: nodeSelection) {
                            ForEach(model.nodes) { node in
                                Label(node.name, systemImage: node.isLocal ? "desktopcomputer" : "network")
                                    .tag(node.id)
                            }
                        }
                        if let onManageNodes, model.nodeManagementAvailable {
                            Divider()
                            Button("Manage Nodes…", systemImage: "slider.horizontal.3", action: onManageNodes)
                        }
                    } label: {
                        Label(model.selectedNode?.name ?? "Nodes", systemImage: "network")
                    }
                    .accessibilityIdentifier("home.nodes")
                }
            }
        }
        .accessibilityIdentifier("home")
    }

    private var nodeSelection: Binding<String> {
        Binding(
            get: { model.selectedNodeID },
            set: { id in Task { await model.selectNode(id) } }
        )
    }

    @ViewBuilder
    private func section(
        _ title: String,
        symbol: String,
        tint: Color,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(title).font(.headline)
            } icon: {
                Image(systemName: symbol).foregroundStyle(tint)
            }
            .accessibilityAddTraits(.isHeader)

            content()
        }
    }
}

// MARK: - Cards

private struct SessionCard: View {
    let session: SessionSnapshot
    let needsAttention: Bool
    let waiting: Bool
    let isOpen: Bool
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    StatusDot(session: session, needsAttention: needsAttention, waiting: waiting)
                    Text(session.displayName)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if isOpen {
                        Image(systemName: "macwindow")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .accessibilityLabel("Open in a tab")
                    }
                }

                if let dir = session.workingDir {
                    Text(dir)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }

                HStack(spacing: 5) {
                    if let mode = session.mode {
                        Badge(text: mode.displayName, symbol: mode.symbolName, tint: .accentColor)
                    }
                    if let backend = session.backendBadge {
                        Badge(text: backend, symbol: nil, tint: .purple)
                    }
                    if let location = session.locationBadge {
                        Badge(text: location, symbol: "network", tint: .orange)
                    }
                    Spacer(minLength: 0)
                    Text(statusWord)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(borderTint, lineWidth: needsAttention || waiting ? 1.5 : 0)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home.session.\(session.id)")
    }

    private var borderTint: Color {
        if needsAttention { return .red.opacity(0.6) }
        if waiting { return .yellow.opacity(0.7) }
        return .clear
    }

    private var statusWord: String {
        if needsAttention { return "Needs you" }
        if waiting { return "Waiting" }
        switch session.effectiveStatus {
        case .busy: return "Working"
        case .error: return "Error"
        case .stopped: return "Stopped"
        case .idle: return session.pid == nil ? "Not running" : "Idle"
        }
    }
}

private struct ApprovalCard: View {
    @Environment(AppModel.self) private var model
    let item: ApprovalItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.title ?? model.session(id: item.sessionId)?.displayName ?? "Waiting")
                .font(.callout.weight(.semibold))
                .lineLimit(2)

            if let body = item.body, !body.isEmpty {
                Text(body)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }

            Button("Open Session") { model.selectedSessionID = item.sessionId }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.red.opacity(0.6), lineWidth: 1.5)
        }
        .accessibilityIdentifier("home.approval.\(item.id)")
    }
}

private struct EmptyRunningCard: View {
    let onNewSession: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("Nothing running")
                .font(.callout.weight(.semibold))
            Text("Start an agent and it appears here as a tab.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("New Session", action: onNewSession)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("home.empty.newSession")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 16)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct HistoryRow: View {
    let row: HistorySession
    let onResume: () -> Void

    var body: some View {
        Button(action: onResume) {
            HStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(row.rowLabel)
                        .font(.callout)
                        .lineLimit(1)
                    if let path = row.path {
                        Text(path)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: "arrow.uturn.backward.circle")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home.history.\(row.id)")
    }
}
