import SwiftUI

/// Nodes, sessions, and the launch entry point.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    var onSelect: (() -> Void)?

    /// One sheet slot: SwiftUI ignores every `.sheet` modifier after the first on a given view.
    @State private var presented: Presentation?
    @State private var deleteTarget: SessionSnapshot?

    private enum Presentation: Identifiable {
        case launch
        case nodeManager
        case rename(SessionSnapshot)

        var id: String {
            switch self {
            case .launch: "launch"
            case .nodeManager: "nodes"
            case let .rename(session): "rename-\(session.id)"
            }
        }
    }

    var body: some View {
        List(selection: sessionSelection) {
            if model.nodes.count > 1 || model.nodeManagementAvailable {
                nodeSection
            }
            if !model.approvals.isEmpty {
                approvalSection
            }
            sessionSection
            if !model.historySessions.isEmpty {
                historySection
            }
        }
        .listStyle(.sidebar)
        .refreshable { await model.refreshEverything() }
        .navigationTitle(model.activeServer?.displayName ?? "Codeman")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { presented = .launch } label: {
                    Label("New Session", systemImage: "plus")
                }
                .accessibilityIdentifier("sidebar.newSession")
            }
            ToolbarItem(placement: .secondaryAction) {
                NavigationLink { SettingsView() } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        .sheet(item: $presented) { destination in
            switch destination {
            case .launch:
                LaunchSheet()
            case .nodeManager:
                NavigationStack { NodeManagerView() }
            case let .rename(session):
                NavigationStack { RenameSessionView(session: session) }
                    .presentationDetents([.height(220)])
            }
        }
        .confirmationDialog(
            deleteTarget.map { "Close \($0.displayName)?" } ?? "",
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
            titleVisibility: .visible
        ) {
            if let target = deleteTarget {
                // An attached (non-owned) remote session detaches rather than dies, and saying so
                // is the difference between "closed a tab" and "killed a colleague's agent".
                let isAttachedRemote = target.remote?.owned == false
                Button(isAttachedRemote ? "Detach" : "Close Session", role: .destructive) {
                    Task { await close(target, killMux: false) }
                }
                if !isAttachedRemote {
                    Button("Close and Kill tmux Session", role: .destructive) {
                        Task { await close(target, killMux: true) }
                    }
                }
                Button("Cancel", role: .cancel) { deleteTarget = nil }
            }
        } message: {
            if deleteTarget?.remote?.owned == false {
                Text("This session was started elsewhere. Detaching leaves it running on the remote host.")
            } else {
                Text("The agent stops. Its conversation transcript is kept.")
            }
        }
    }

    private var sessionSelection: Binding<String?> {
        Binding(
            get: { model.selectedSessionID },
            set: { value in
                guard let value else { return }
                model.selectedSessionID = value
                onSelect?()
            }
        )
    }

    // MARK: - Sections

    @ViewBuilder
    private var nodeSection: some View {
        Section {
            ForEach(model.nodes) { node in
                Button {
                    Task { await model.selectNode(node.id) }
                } label: {
                    NodeRow(node: node, isSelected: node.id == model.selectedNodeID)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("node.\(node.id)")
            }
        } header: {
            HStack {
                Text("Nodes")
                Spacer()
                if model.nodeManagementAvailable {
                    Button("Manage") { presented = .nodeManager }
                        .font(.caption)
                        .accessibilityIdentifier("sidebar.manageNodes")
                }
            }
        }
    }

    @ViewBuilder
    private var approvalSection: some View {
        Section("Needs you") {
            ForEach(model.approvals) { item in
                ApprovalRow(item: item)
            }
        }
    }

    @ViewBuilder
    private var sessionSection: some View {
        Section("Sessions") {
            if model.orderedSessions.isEmpty {
                Text("No sessions running.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            ForEach(model.orderedSessions) { session in
                SessionRow(
                    session: session,
                    needsAttention: model.needsAttention.contains(session.id),
                    waiting: model.waitingForInput.contains(session.id)
                )
                .tag(session.id)
                .contextMenu {
                    Button("Rename…", systemImage: "pencil") { presented = .rename(session) }
                    Button(session.pinned == true ? "Unpin" : "Pin",
                           systemImage: session.pinned == true ? "pin.slash" : "pin") {
                        Task { await togglePin(session) }
                    }
                    Divider()
                    Button("Open in Second Pane", systemImage: "rectangle.split.2x1") {
                        model.secondarySessionID = session.id
                    }
                    Divider()
                    Button("Close…", systemImage: "xmark.circle", role: .destructive) {
                        deleteTarget = session
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { deleteTarget = session } label: {
                        Label("Close", systemImage: "xmark")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var historySection: some View {
        Section("Past sessions") {
            ForEach(model.historySessions.prefix(20)) { row in
                Button {
                    Task { await resume(row) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.rowLabel)
                            .lineLimit(1)
                            .font(.callout)
                        if let path = row.path {
                            Text(path)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Actions

    private func togglePin(_ session: SessionSnapshot) async {
        guard let api = model.apiClient else { return }
        do {
            try await api.setPinned(id: session.id, pinned: !(session.pinned ?? false), scope: model.scope)
            await model.refreshSessions()
        } catch {
            model.report(error, title: "Could not change the pin")
        }
    }

    private func close(_ session: SessionSnapshot, killMux: Bool) async {
        deleteTarget = nil
        guard let api = model.apiClient else { return }
        do {
            try await api.deleteSession(id: session.id, killMux: killMux, scope: model.scope)
            await model.refreshSessions()
        } catch {
            model.report(error, title: "Could not close the session")
        }
    }

    private func resume(_ row: HistorySession) async {
        await model.resumeHistorySession(row)
        onSelect?()
    }
}

// MARK: - Rows

private struct NodeRow: View {
    let node: NodeState
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: node.isLocal ? "desktopcomputer" : "network")
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(node.name).font(.callout.weight(isSelected ? .semibold : .regular))
                Text(reachabilityText)
                    .font(.caption2)
                    .foregroundStyle(reachabilityColor)
            }

            Spacer(minLength: 0)

            if isSelected {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .contentShape(Rectangle())
        .accessibilityLabel("\(node.name), \(reachabilityText)\(isSelected ? ", selected" : "")")
    }

    private var reachabilityText: String {
        switch node.reachability {
        case .unknown: "Checking…"
        case let .online(version): version.map { "Online · \($0)" } ?? "Online"
        case let .reconnecting(attempt): "Reconnecting (\(attempt))"
        case let .offline(reason): "Offline · \(reason)"
        }
    }

    private var reachabilityColor: Color {
        switch node.reachability {
        case .online: .green
        case .reconnecting: .orange
        case .offline: .red
        case .unknown: .secondary
        }
    }
}

private struct SessionRow: View {
    let session: SessionSnapshot
    let needsAttention: Bool
    let waiting: Bool

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(session: session, needsAttention: needsAttention, waiting: waiting)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if session.parentSessionId != nil {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    Text(session.displayName)
                        .font(.callout.weight(needsAttention ? .semibold : .regular))
                        .lineLimit(1)
                    if session.pinned == true {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .accessibilityLabel("Pinned")
                    }
                }

                HStack(spacing: 5) {
                    if let mode = session.mode {
                        Badge(text: mode.displayName, symbol: mode.symbolName, tint: .accentColor)
                    }
                    if let backend = session.backendBadge {
                        Badge(text: backend, symbol: nil, tint: .purple)
                    }
                    if let modelName = session.modelBadge {
                        Badge(text: modelName, symbol: nil, tint: .teal)
                    }
                    if let location = session.locationBadge {
                        Badge(text: location, symbol: "network", tint: .orange)
                    }
                }
            }

            Spacer(minLength: 0)

            if let tokens = totalTokens {
                Text(tokens)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(tokens) tokens")
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("session.\(session.id)")
    }

    private var totalTokens: String? {
        let total = (session.inputTokens ?? 0) + (session.outputTokens ?? 0)
        guard total > 0 else { return nil }
        if total >= 1000 { return String(format: "%.1fk", Double(total) / 1000) }
        return String(total)
    }
}

/// Status language shared with the web home screens: green when fine, pulsing while working,
/// yellow when waiting for input, red when a question is pending.
struct StatusDot: View {
    let session: SessionSnapshot
    let needsAttention: Bool
    let waiting: Bool

    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(tint)
            .frame(width: 9, height: 9)
            .overlay {
                if isWorking {
                    Circle()
                        .stroke(tint.opacity(0.5), lineWidth: 2)
                        .scaleEffect(pulse ? 2.1 : 1)
                        .opacity(pulse ? 0 : 1)
                }
            }
            .onAppear {
                guard isWorking else { return }
                withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) { pulse = true }
            }
            .accessibilityLabel(accessibilityText)
    }

    private var isWorking: Bool { session.effectiveStatus == .busy }

    private var tint: Color {
        if needsAttention { return .red }
        if waiting { return .yellow }
        switch session.effectiveStatus {
        case .busy: return .green
        case .error: return .red
        case .stopped: return .secondary
        case .idle: return session.pid == nil ? .secondary : .green.opacity(0.65)
        }
    }

    private var accessibilityText: String {
        if needsAttention { return "Needs your input" }
        if waiting { return "Waiting for a prompt" }
        switch session.effectiveStatus {
        case .busy: return "Working"
        case .error: return "Error"
        case .stopped: return "Stopped"
        case .idle: return session.pid == nil ? "Not running" : "Idle"
        }
    }
}

struct Badge: View {
    let text: String
    var symbol: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 3) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 8, weight: .semibold))
            }
            Text(text).font(.system(size: 10, weight: .medium))
        }
        .lineLimit(1)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(tint.opacity(0.15), in: Capsule())
        .foregroundStyle(tint)
    }
}

private struct ApprovalRow: View {
    @Environment(AppModel.self) private var model
    let item: ApprovalItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.title ?? model.session(id: item.sessionId)?.displayName ?? "Waiting")
                .font(.callout.weight(.semibold))
            if let body = item.body, !body.isEmpty {
                Text(body)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }

            if let options = item.options, !options.isEmpty {
                // A digit is only accepted when it matches an option the server parsed from the
                // pane, and the answer path re-captures the pane first — so these are the only
                // safe answers to offer, and a stale one legitimately fails with 409.
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    if let digit = option.digit {
                        Button(option.label ?? digit) {
                            Task { await answer(option: digit) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            HStack {
                Button("Open") { model.selectedSessionID = item.sessionId }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("Escape", role: .destructive) { Task { await answer(escape: true) } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("approval.\(item.id)")
    }

    private func answer(option: String? = nil, escape: Bool = false) async {
        guard let api = model.apiClient else { return }
        do {
            try await api.answerApproval(
                id: item.id,
                request: ApprovalAnswerRequest(option: option, text: nil, escape: escape ? true : nil),
                scope: model.scope
            )
            await model.refreshApprovals()
        } catch {
            model.report(error, title: "Could not answer")
        }
    }
}

private struct RenameSessionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let session: SessionSnapshot

    @State private var name: String = ""

    var body: some View {
        Form {
            TextField("Session name", text: $name)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("rename.field")
        }
        .navigationTitle("Rename")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear { name = session.name ?? session.displayName }
    }

    private func save() async {
        guard let api = model.apiClient else { return }
        do {
            try await api.renameSession(id: session.id, name: name, scope: model.scope)
            await model.refreshSessions()
            dismiss()
        } catch {
            model.report(error, title: "Could not rename")
        }
    }
}
