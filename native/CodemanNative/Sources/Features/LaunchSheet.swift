import SwiftUI

/// Starts a session: pick a case, a backend (or a saved custom action), and go.
///
/// Everything routes through `POST /api/quick-start`, which creates the case if it is missing,
/// resolves remote-SSH and Docker cases, *and* starts the session. `POST /api/sessions`
/// stat-validates `workingDir` locally and would reject a remote case, so it is not used here.
struct LaunchSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var caseName = ""
    @State private var selection: LaunchSelection = .mode(.claude)
    @State private var sessionName = ""
    @State private var workingDirectory: String?
    @State private var isLaunching = false
    @State private var launchError: String?

    enum LaunchSelection: Hashable {
        case mode(SessionMode)
        case action(String)
    }

    /// The browser and the new-case form are **pushed**, not presented as sheets.
    ///
    /// This view is itself inside a sheet, and a sheet-from-a-sheet does not reliably present in
    /// SwiftUI — the inner one silently never appears. Pushing is also the idiomatic drill-down
    /// inside a sheet. `NavigationLink`'s destination-closure form is used rather than
    /// `navigationDestination(for:)`: the latter is declared on a `Form`, which is a lazy
    /// container, and did not register reliably here.
    var body: some View {
        NavigationStack {
            content
        }
    }

    private var content: some View {
        Form {
            Section("Case") {
                Picker("Case", selection: $caseName) {
                    Text("Choose…").tag("")
                    ForEach(model.cases) { item in
                        Text(item.name).tag(item.name)
                    }
                }
                .accessibilityIdentifier("launch.case")

                NavigationLink {
                    DirectoryBrowserView(initialPath: nil, sessionID: model.selectedSessionID) { chosen in
                        workingDirectory = chosen
                        // A browsed path is only a hint: quick-start takes a case NAME, and the
                        // last path component is the natural candidate. The user can override it.
                        if caseName.isEmpty, let last = chosen.split(separator: "/").last {
                            let sanitized = last.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
                            if !sanitized.isEmpty { caseName = String(sanitized) }
                        }
                    }
                } label: {
                    HStack {
                        Label("Browse directories", systemImage: "folder")
                        Spacer()
                        if let workingDirectory {
                            Text(workingDirectory)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                }
                .accessibilityIdentifier("launch.browse")

                NavigationLink {
                    NewCaseView { created in
                        caseName = created
                        Task { await model.refreshCases() }
                    }
                } label: {
                    Label("New case…", systemImage: "plus.rectangle.on.folder")
                }
                .accessibilityIdentifier("launch.newCase")
            }

            Section("Start with") {
                Picker("Backend", selection: $selection) {
                    ForEach(SessionMode.allCases) { mode in
                        Label(mode.displayName, systemImage: mode.symbolName)
                            .tag(LaunchSelection.mode(mode))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .accessibilityIdentifier("launch.mode")
            }

            if !model.customActions.isEmpty {
                Section {
                    ForEach(model.customActions) { action in
                        Button {
                            selection = .action(action.id)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(action.label)
                                    Text(action.command)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    if let env = action.env, !env.isEmpty {
                                        Text("\(env.count) environment variable\(env.count == 1 ? "" : "s")")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                Spacer()
                                if selection == .action(action.id) {
                                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("launch.action.\(action.id)")
                    }
                } header: {
                    Text("Custom actions")
                } footer: {
                    Text("Custom actions launch a shell session with your command and environment.")
                }
            }

            Section("Options") {
                TextField("Session name (optional)", text: $sessionName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("launch.sessionName")
            }

            if let launchError {
                Section {
                    Text(launchError)
                        .foregroundStyle(.red)
                        .font(.callout)
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("New Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task { await launch() }
                } label: {
                    if isLaunching { ProgressView().controlSize(.small) } else { Text("Start") }
                }
                .disabled(caseName.isEmpty || isLaunching)
                .accessibilityIdentifier("launch.start")
            }
        }
        .task {
            if model.cases.isEmpty { await model.refreshCases() }
            if caseName.isEmpty { caseName = model.cases.first?.name ?? "" }
        }
    }

    private func launch() async {
        isLaunching = true
        launchError = nil
        defer { isLaunching = false }

        do {
            let id: String
            switch selection {
            case let .mode(mode):
                id = try await model.launchSession(
                    caseName: caseName,
                    mode: mode,
                    sessionName: sessionName.isEmpty ? nil : sessionName
                )
            case let .action(actionID):
                guard let action = model.customActions.first(where: { $0.id == actionID }) else {
                    launchError = "That custom action no longer exists."
                    return
                }
                id = try await model.launchCustomAction(action, caseName: caseName)
            }
            model.selectedSessionID = id
            dismiss()
        } catch {
            // The server's own message is more useful than anything we could compose — a missing
            // CLI comes back with the exact install command, and a remote/docker case explains
            // which fields do not cross the boundary.
            launchError = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

struct NewCaseView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let onCreate: (String) -> Void

    @State private var name = ""
    @State private var summary = ""
    @State private var isCreating = false

    var body: some View {
        Form {
            TextField("Case name", text: $name)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("newCase.name")
            TextField("Description (optional)", text: $summary)
                .accessibilityIdentifier("newCase.description")
        }
        .navigationTitle("New Case")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Create") { Task { await create() } }
                    .disabled(!isValid || isCreating)
                    .accessibilityIdentifier("newCase.create")
            }
        }
    }

    /// Server rule: `/^[a-zA-Z0-9_-]+$/`. Checked here so the user is not told "Invalid case path"
    /// after a round trip.
    private var isValid: Bool {
        !name.isEmpty && name.allSatisfy { $0.isLetter && $0.isASCII || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    private func create() async {
        guard let api = model.apiClient else { return }
        isCreating = true
        defer { isCreating = false }
        do {
            let response = try await api.createCase(
                CreateCaseRequest(name: name, description: summary.isEmpty ? nil : summary),
                scope: model.scope
            )
            onCreate(response.case.name)
            // Pushed, so `dismiss` pops back to the launch form rather than closing the sheet.
            dismiss()
        } catch {
            model.report(error, title: "Could not create the case")
        }
    }
}
