import SwiftUI

/// Lists and manages the saved custom launch actions.
///
/// These are stored server-side under the `customRunActions` settings key, the same key the web
/// client reads and writes — so an action added here shows up in the browser and vice versa.
struct CustomActionsView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: CustomRunAction?
    @State private var isSaving = false

    var body: some View {
        List {
            Section {
                ForEach(model.customActions) { action in
                    Button {
                        editing = action
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(action.label).font(.body)
                            Text(action.command)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            if let env = action.env, !env.isEmpty {
                                HStack(spacing: 4) {
                                    Image(systemName: action.carriesSensitiveEnv ? "lock.fill" : "character.textbox")
                                        .font(.system(size: 9))
                                    Text("\(env.count) variable\(env.count == 1 ? "" : "s")")
                                        .font(.caption2)
                                }
                                .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("actions.row.\(action.id)")
                }
                .onDelete { offsets in
                    Task { await delete(at: offsets) }
                }
            } header: {
                Text("Actions")
            } footer: {
                Text("Actions run as a shell session with your command and environment. They sync with the Codeman web app.")
            }
        }
        .navigationTitle("Custom Actions")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editing = CustomRunAction()
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .disabled(model.customActions.count >= CustomRunAction.maxActions)
                .accessibilityIdentifier("actions.add")
            }
        }
        .sheet(item: $editing) { action in
            NavigationStack {
                CustomActionEditorView(action: action) { updated in
                    Task { await save(updated) }
                }
            }
        }
        .overlay {
            if model.customActions.isEmpty {
                ContentUnavailableView {
                    Label("No custom actions", systemImage: "bolt.badge.clock")
                } description: {
                    Text("Save a command you run often — a dev server, a test watcher, an agent with a specific model.")
                } actions: {
                    Button("Add Action") { editing = CustomRunAction() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func save(_ action: CustomRunAction) async {
        var next = model.customActions
        if let index = next.firstIndex(where: { $0.id == action.id }) {
            next[index] = action
        } else {
            next.append(action)
        }
        await persist(next)
    }

    private func delete(at offsets: IndexSet) async {
        var next = model.customActions
        next.remove(atOffsets: offsets)
        await persist(next)
    }

    private func persist(_ actions: [CustomRunAction]) async {
        do {
            try await model.saveCustomActions(actions)
        } catch {
            model.report(error, title: "Could not save actions")
        }
    }
}

/// Editor for one action: name, command, and its environment.
struct CustomActionEditorView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var draft: CustomRunAction
    @State private var revealedKeys: Set<UUID> = []
    @State private var showsPresets = false

    private let onSave: (CustomRunAction) -> Void

    init(action: CustomRunAction, onSave: @escaping (CustomRunAction) -> Void) {
        _draft = State(initialValue: action)
        self.onSave = onSave
    }

    private var issues: [CustomRunAction.ValidationIssue] { draft.validate() }
    private var blockingIssues: [CustomRunAction.ValidationIssue] { issues.filter { !$0.isWarning } }
    private var warnings: [CustomRunAction.ValidationIssue] { issues.filter(\.isWarning) }

    var body: some View {
        Form {
            Section("Name") {
                TextField("Dev server", text: $draft.label)
                    .accessibilityIdentifier("actionEditor.label")
            }

            Section {
                TextField("npm run dev", text: $draft.command, axis: .vertical)
                    .font(.body.monospaced())
                    .lineLimit(1...4)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("actionEditor.command")
            } header: {
                Text("Launch command")
            } footer: {
                Text("A single line. It runs in the case directory as a shell session.")
            }

            Section {
                ForEach(envBinding) { $entry in
                    EnvRow(
                        entry: $entry,
                        isRevealed: revealedKeys.contains(entry.id),
                        onToggleReveal: { toggleReveal(entry.id) }
                    )
                }
                .onDelete { offsets in
                    draft.env?.remove(atOffsets: offsets)
                }

                Button {
                    draft.env = (draft.env ?? []) + [CustomActionEnvVar()]
                } label: {
                    Label("Add variable", systemImage: "plus.circle")
                }
                .disabled((draft.env?.count ?? 0) >= CustomRunAction.maxEnvEntries)
                .accessibilityIdentifier("actionEditor.addEnv")

                Button {
                    showsPresets = true
                } label: {
                    Label("Add from presets", systemImage: "list.bullet.rectangle.portrait")
                }
                .accessibilityIdentifier("actionEditor.presets")
            } header: {
                Text("Environment")
            } footer: {
                Text("Values that look like credentials are hidden by default and never appear in logs.")
            }

            if !warnings.isEmpty {
                Section("Warnings") {
                    ForEach(Array(warnings.enumerated()), id: \.offset) { _, issue in
                        Label(issue.message, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                    DisclosureGroup("Allowed variable prefixes") {
                        Text(EnvironmentAllowlist.prefixes.joined(separator: "  ") + "\n"
                             + EnvironmentAllowlist.exactKeys.sorted().joined(separator: "  "))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !blockingIssues.isEmpty {
                Section("Fix before saving") {
                    ForEach(Array(blockingIssues.enumerated()), id: \.offset) { _, issue in
                        Label(issue.message, systemImage: "xmark.octagon")
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .navigationTitle(draft.label.isEmpty ? "New Action" : draft.label)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    onSave(draft)
                    dismiss()
                }
                .disabled(!blockingIssues.isEmpty)
                .accessibilityIdentifier("actionEditor.save")
            }
        }
        .sheet(isPresented: $showsPresets) {
            NavigationStack {
                EnvironmentPresetPicker { key in
                    draft.env = (draft.env ?? []) + [CustomActionEnvVar(key: key, value: "")]
                    showsPresets = false
                }
            }
        }
    }

    /// `env` is optional on the wire (absent means "no variables"), but a `ForEach` needs a
    /// concrete collection binding — so reads unwrap to an empty array and writes normalise an
    /// empty array back to `nil` rather than sending `"env": []`.
    private var envBinding: Binding<[CustomActionEnvVar]> {
        Binding(
            get: { draft.env ?? [] },
            set: { draft.env = $0.isEmpty ? nil : $0 }
        )
    }

    private func toggleReveal(_ id: UUID) {
        if revealedKeys.contains(id) { revealedKeys.remove(id) } else { revealedKeys.insert(id) }
    }
}

private struct EnvRow: View {
    @Binding var entry: CustomActionEnvVar
    let isRevealed: Bool
    let onToggleReveal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("NAME", text: $entry.key)
                .font(.callout.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("env.key")

            HStack {
                if entry.isSensitive && !isRevealed {
                    SecureField("value", text: $entry.value)
                        .font(.callout.monospaced())
                        .accessibilityIdentifier("env.value.secure")
                } else {
                    TextField("value", text: $entry.value)
                        .font(.callout.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("env.value")
                }

                if entry.isSensitive {
                    Button(action: onToggleReveal) {
                        Image(systemName: isRevealed ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(isRevealed ? "Hide value" : "Show value")
                }
            }

            if !entry.key.isEmpty {
                if !entry.hasValidKey {
                    Text("Not a valid variable name.").font(.caption2).foregroundStyle(.red)
                } else if !EnvironmentAllowlist.isLaunchable(entry.key) {
                    Text("The server will refuse this name at launch.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct EnvironmentPresetPicker: View {
    @Environment(\.dismiss) private var dismiss
    let onPick: (String) -> Void

    var body: some View {
        List {
            ForEach(EnvironmentPresets.groups, id: \.self) { group in
                Section(group) {
                    ForEach(EnvironmentPresets.all.filter { $0.group == group }) { preset in
                        Button {
                            onPick(preset.key)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 5) {
                                    Text(preset.key).font(.callout.monospaced())
                                    if preset.isSensitive {
                                        Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(.orange)
                                    }
                                }
                                Text(preset.summary).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle("Common Variables")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        }
    }
}
