import SwiftUI

/// Add, edit, pair, and test federated Codeman nodes.
///
/// Every route behind this screen is `requireAdmin`-gated. In single-user mode the synthetic
/// admin makes them all work; in multi-user mode a non-admin gets `403`, and `AppModel` hides the
/// entry point rather than letting the user walk into a wall of errors.
struct NodeManagerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var editing: NodeDraft?
    @State private var pairing = false

    var body: some View {
        List {
            Section {
                ForEach(model.nodes) { node in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(node.name)
                            Text(node.baseURLString)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        reachabilityBadge(node.reachability)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard !node.isLocal else { return }
                        editing = NodeDraft(node: node)
                    }
                    .swipeActions {
                        if !node.isLocal {
                            Button(role: .destructive) {
                                Task { await remove(node) }
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                        Button {
                            Task { await test(node) }
                        } label: {
                            Label("Test", systemImage: "bolt.horizontal")
                        }
                        .tint(.blue)
                    }
                    .accessibilityIdentifier("nodeManager.\(node.id)")
                }
            } header: {
                Text("Nodes")
            } footer: {
                Text("Requests to a remote node are proxied by this server, so the app never holds that node's token.")
            }

            Section {
                Button {
                    editing = NodeDraft()
                } label: {
                    Label("Add node manually", systemImage: "plus")
                }
                .accessibilityIdentifier("nodeManager.add")

                Button {
                    pairing = true
                } label: {
                    Label("Pair with a code", systemImage: "key")
                }
                .accessibilityIdentifier("nodeManager.pair")
            }
        }
        .navigationTitle("Nodes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
        }
        .refreshable { await model.refreshNodes() }
        .sheet(item: $editing) { draft in
            NavigationStack { NodeEditorView(draft: draft) }
        }
        .sheet(isPresented: $pairing) {
            NavigationStack { NodePairView() }
                .presentationDetents([.height(330)])
        }
    }

    @ViewBuilder
    private func reachabilityBadge(_ reachability: NodeReachability) -> some View {
        switch reachability {
        case .unknown: Badge(text: "Unknown", tint: .secondary)
        case let .online(version): Badge(text: version.map { "Online · \($0)" } ?? "Online", tint: .green)
        case .reconnecting: Badge(text: "Reconnecting", tint: .orange)
        case .offline: Badge(text: "Offline", tint: .red)
        }
    }

    private func remove(_ node: NodeState) async {
        guard let api = model.apiClient else { return }
        do {
            try await api.deleteNode(id: node.id)
            await model.refreshNodes()
        } catch {
            model.report(error, title: "Could not remove the node")
        }
    }

    private func test(_ node: NodeState) async {
        guard let api = model.apiClient else { return }
        if node.isLocal {
            await model.refreshNodes()
            return
        }
        do {
            _ = try await api.testNode(id: node.id)
            await model.refreshNodes()
        } catch {
            model.report(error, title: "Node test failed")
        }
    }
}

struct NodeDraft: Identifiable {
    var id: String
    var isNew: Bool
    var name: String
    var baseURL: String
    var token: String
    var enabled: Bool

    init() {
        id = UUID().uuidString
        isNew = true
        name = ""
        baseURL = ""
        token = ""
        enabled = true
    }

    init(node: NodeState) {
        id = node.id
        isNew = false
        name = node.name
        baseURL = node.baseURLString
        token = ""
        enabled = node.enabled
    }
}

struct NodeEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State var draft: NodeDraft
    @State private var isSaving = false

    var body: some View {
        Form {
            Section("Node") {
                TextField("Name", text: $draft.name)
                    .accessibilityIdentifier("nodeEditor.name")
                TextField("https://host:3000", text: $draft.baseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .accessibilityIdentifier("nodeEditor.url")
                Toggle("Enabled", isOn: $draft.enabled)
            }

            Section {
                SecureField(draft.isNew ? "Federation token" : "Replace token (leave blank to keep)",
                            text: $draft.token)
                    .accessibilityIdentifier("nodeEditor.token")
            } header: {
                Text("Token")
            } footer: {
                Text("Generated on the remote node with `codeman` node tokens, or obtained by pairing.")
            }
        }
        .navigationTitle(draft.isNew ? "Add Node" : draft.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }
                    .disabled(draft.name.isEmpty || draft.baseURL.isEmpty || isSaving)
                    .accessibilityIdentifier("nodeEditor.save")
            }
        }
    }

    private func save() async {
        guard let api = model.apiClient else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            _ = try await api.upsertNode(
                UpsertNodeRequest(
                    name: draft.name,
                    baseUrl: draft.baseURL,
                    token: draft.token.isEmpty ? nil : draft.token,
                    enabled: draft.enabled
                ),
                id: draft.isNew ? nil : draft.id
            )
            await model.refreshNodes()
            dismiss()
        } catch {
            model.report(error, title: "Could not save the node")
        }
    }
}

struct NodePairView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var baseURL = ""
    @State private var code = ""
    @State private var name = ""
    @State private var isPairing = false

    var body: some View {
        Form {
            Section {
                TextField("Node address", text: $baseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .accessibilityIdentifier("pair.url")
                TextField("Pairing code", text: $code)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("pair.code")
                TextField("Label (optional)", text: $name)
            } footer: {
                Text("Run `codeman node pair` on the other machine to get a code.")
            }
        }
        .navigationTitle("Pair Node")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Pair") { Task { await pair() } }
                    .disabled(baseURL.isEmpty || code.isEmpty || isPairing)
                    .accessibilityIdentifier("pair.submit")
            }
        }
    }

    private func pair() async {
        guard let api = model.apiClient else { return }
        isPairing = true
        defer { isPairing = false }
        do {
            _ = try await api.pairNode(PairNodeRequest(
                baseUrl: baseURL,
                code: code,
                name: name.isEmpty ? nil : name
            ))
            await model.refreshNodes()
            dismiss()
        } catch {
            model.report(error, title: "Pairing failed")
        }
    }
}
