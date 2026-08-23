import SwiftUI

/// Everything you can do *to* the session you are looking at.
///
/// The iPad detail column has always shown session facts (`InspectorView`), but nothing anywhere
/// offered the actions — rename, pin, restart, close — and on iPhone there was no session-scoped
/// surface at all. This is that surface, reachable at every size from the terminal's own toolbar.
///
/// Terminal appearance lives here too rather than only in app settings: font size and the prompt
/// composer are decisions you make while looking at a specific pane, and walking out to a global
/// settings screen to change them loses the thing you were judging them against.
struct SessionSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let sessionID: String

    @State private var renamedTo = ""
    @State private var confirmingClose = false
    @State private var isWorking = false

    private var session: SessionSnapshot? { model.session(id: sessionID) }

    var body: some View {
        @Bindable var model = model

        Form {
            if let session {
                Section {
                    TextField("Session name", text: $renamedTo)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("sessionSettings.name")
                        .onSubmit { Task { await rename() } }

                    Button("Rename") { Task { await rename() } }
                        .disabled(renamedTo.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
                        .accessibilityIdentifier("sessionSettings.rename")

                    Toggle("Pinned", isOn: pinBinding(session))
                        .accessibilityIdentifier("sessionSettings.pin")
                } header: {
                    Text("Session")
                } footer: {
                    Text(session.workingDir ?? "")
                        .font(.caption2)
                        .truncationMode(.head)
                }

                Section {
                    Picker("View", selection: Binding(
                        get: { model.viewMode(for: sessionID) },
                        set: { model.setViewMode($0, for: sessionID) }
                    )) {
                        ForEach(SessionViewMode.allCases) { mode in
                            Label(mode.title, systemImage: mode.symbolName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("sessionSettings.viewMode")

                    Toggle("Use this view for new sessions", isOn: Binding(
                        get: { model.preferences.defaultSessionViewMode == model.viewMode(for: sessionID) },
                        set: { on in
                            guard on else { return }
                            let current = model.viewMode(for: sessionID)
                            model.updatePreferences { $0.defaultSessionViewMode = current }
                        }
                    ))
                    .accessibilityIdentifier("sessionSettings.viewModeDefault")
                } header: {
                    Text("Presentation")
                } footer: {
                    // Say what each surface is FOR, because "Chat" being read-only is the one
                    // thing a user cannot discover by looking at it.
                    Text(session.mode == .claude
                         ? "Terminal is the live agent surface and accepts typing. Chat is a native, read-only view of the same conversation."
                         : "Chat needs a Claude transcript; \(session.mode?.displayName ?? "this") sessions only have the terminal.")
                }

                Section("Terminal") {
                    Stepper(
                        "Font size \(Int(model.preferences.terminalFontSize))",
                        value: Binding(
                            get: { model.preferences.terminalFontSize },
                            set: { size in model.updatePreferences { $0.terminalFontSize = size } }
                        ),
                        in: 8...24,
                        step: 1
                    )
                    .accessibilityIdentifier("sessionSettings.fontSize")

                    Picker("Theme", selection: Binding(
                        get: { model.preferences.terminalTheme },
                        set: { theme in model.updatePreferences { $0.terminalTheme = theme } }
                    )) {
                        ForEach(CodemanTerminalTheme.allCases) { theme in
                            Text(theme.displayName).tag(theme)
                        }
                    }
                    .accessibilityIdentifier("sessionSettings.theme")

                }

                Section {
                    NavigationLink {
                        InspectorView()
                    } label: {
                        Label("Details & Usage", systemImage: "info.circle")
                    }
                    .accessibilityIdentifier("sessionSettings.details")
                }

                Section {
                    Button {
                        Task { await restart() }
                    } label: {
                        Label("Restart Terminal", systemImage: "arrow.clockwise")
                    }
                    .disabled(isWorking)
                    .accessibilityIdentifier("sessionSettings.restart")

                    Button(role: .destructive) {
                        confirmingClose = true
                    } label: {
                        Label(closeTitle(session), systemImage: "xmark.circle")
                    }
                    .accessibilityIdentifier("sessionSettings.close")
                } footer: {
                    Text(session.remote?.owned == false
                         ? "This session was started elsewhere. Detaching leaves it running on the remote host."
                         : "The agent stops. Its conversation transcript is kept.")
                }
            } else {
                ContentUnavailableView("Session unavailable", systemImage: "questionmark.circle")
            }
        }
        .navigationTitle(session?.displayName ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
        .confirmationDialog(
            session.map { "Close \($0.displayName)?" } ?? "",
            isPresented: $confirmingClose,
            titleVisibility: .visible
        ) {
            if let session {
                let isAttachedRemote = session.remote?.owned == false
                Button(isAttachedRemote ? "Detach" : "Close Session", role: .destructive) {
                    Task { await close(killMux: false) }
                }
                if !isAttachedRemote {
                    Button("Close and Kill tmux Session", role: .destructive) {
                        Task { await close(killMux: true) }
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
        .onAppear { renamedTo = session?.name ?? session?.displayName ?? "" }
    }

    private func closeTitle(_ session: SessionSnapshot) -> String {
        session.remote?.owned == false ? "Detach Session" : "Close Session"
    }

    private func pinBinding(_ session: SessionSnapshot) -> Binding<Bool> {
        Binding(
            get: { session.pinned ?? false },
            set: { pinned in Task { await setPinned(pinned) } }
        )
    }

    // MARK: - Actions

    private func rename() async {
        guard let api = model.apiClient, !isWorking else { return }
        let name = renamedTo.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await api.renameSession(id: sessionID, name: name, scope: model.scope)
            await model.refreshSessions()
        } catch {
            model.report(error, title: "Could not rename")
        }
    }

    private func setPinned(_ pinned: Bool) async {
        guard let api = model.apiClient else { return }
        do {
            try await api.setPinned(id: sessionID, pinned: pinned, scope: model.scope)
            await model.refreshSessions()
        } catch {
            model.report(error, title: "Could not change the pin")
        }
    }

    private func restart() async {
        guard let api = model.apiClient, let session, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            if session.mode == .shell {
                try await api.startShell(id: sessionID, scope: model.scope)
            } else {
                // An explicit, user-initiated restart is the one gesture that clears a tripped
                // PTY-exit breaker — deliberately true here and nowhere else.
                try await api.startInteractive(id: sessionID, clearBreaker: true, scope: model.scope)
            }
            model.terminal(for: sessionID)?.stop()
            model.terminal(for: sessionID)?.start()
            await model.refreshSessions()
        } catch {
            model.report(error, title: "Could not restart")
        }
    }

    private func close(killMux: Bool) async {
        guard let api = model.apiClient else { return }
        do {
            try await api.deleteSession(id: sessionID, killMux: killMux, scope: model.scope)
            await model.refreshSessions()
            dismiss()
        } catch {
            model.report(error, title: "Could not close the session")
        }
    }
}
