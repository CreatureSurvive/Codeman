import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model

        Form {
            Section("Server") {
                if let server = model.activeServer {
                    LabeledContent("Name", value: server.displayName)
                    LabeledContent("Address", value: server.baseURLString)
                    if let version = model.serverVersion {
                        LabeledContent("Codeman", value: version)
                    }
                    LabeledContent("Connection", value: connectionText)
                }

                NavigationLink {
                    OnboardingView()
                } label: {
                    Label("Switch server", systemImage: "arrow.left.arrow.right")
                }
                .accessibilityIdentifier("settings.switchServer")

                Button(role: .destructive) {
                    Task { await model.signOut() }
                } label: {
                    Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                }
                .accessibilityIdentifier("settings.signOut")
            }

            Section("Terminal") {
                Picker("Theme", selection: Binding(
                    get: { model.preferences.terminalTheme },
                    set: { value in model.updatePreferences { $0.terminalTheme = value } }
                )) {
                    ForEach(CodemanTerminalTheme.allCases) { Text($0.displayName).tag($0) }
                }
                .accessibilityIdentifier("settings.theme")

                VStack(alignment: .leading) {
                    HStack {
                        Text("Font size")
                        Spacer()
                        Text("\(Int(model.preferences.terminalFontSize)) pt")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(
                        value: Binding(
                            get: { model.preferences.terminalFontSize },
                            set: { value in model.updatePreferences { $0.terminalFontSize = value.rounded() } }
                        ),
                        in: 9...24,
                        step: 1
                    )
                    .accessibilityIdentifier("settings.fontSize")
                    .accessibilityValue("\(Int(model.preferences.terminalFontSize)) points")
                }

                NavigationLink {
                    AccessoryShortcutsView()
                } label: {
                    Label("Keyboard shortcuts", systemImage: "keyboard")
                }
                .accessibilityIdentifier("settings.shortcuts")
            }

            Section("Sessions") {
                NavigationLink {
                    CustomActionsView()
                } label: {
                    Label("Custom actions", systemImage: "bolt")
                }
                .accessibilityIdentifier("settings.customActions")

                Toggle("Confirm before closing", isOn: Binding(
                    get: { model.preferences.confirmBeforeDeletingSessions },
                    set: { value in model.updatePreferences { $0.confirmBeforeDeletingSessions = value } }
                ))
            }

            Section {
                Toggle("Show inspector", isOn: Binding(
                    get: { model.preferences.showInspector },
                    set: { value in model.updatePreferences { $0.showInspector = value } }
                ))
                .accessibilityIdentifier("settings.inspector")
            } header: {
                Text("Layout")
            } footer: {
                Text("The inspector column appears on iPad and in wide windows.")
            }

            Section {
                Toggle("Notify when an agent needs you", isOn: Binding(
                    get: { model.preferences.notificationsEnabled },
                    set: { value in
                        model.updatePreferences { $0.notificationsEnabled = value }
                        NotificationPresenter.shared.setEnabled(value)
                        if value {
                            Task { _ = await NotificationPresenter.shared.requestAuthorizationIfNeeded() }
                        }
                    }
                ))
                .accessibilityIdentifier("settings.notifications")
            } header: {
                Text("Notifications")
            } footer: {
                Text("Alerts are raised from the live event stream, so they arrive while Codeman is open or recently backgrounded.")
            }

            if model.nodeManagementAvailable {
                Section("Nodes") {
                    NavigationLink {
                        NodeManagerView()
                    } label: {
                        Label("Manage nodes", systemImage: "network")
                    }
                    .accessibilityIdentifier("settings.nodes")
                }
            }

            Section {
                LabeledContent("App", value: Bundle.main.shortVersion)
            } header: {
                Text("About")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var connectionText: String {
        switch model.connectionState {
        case .connected: "Connected"
        case .connecting: "Connecting…"
        case let .reconnecting(attempt, _): "Reconnecting (\(attempt))"
        case .unauthorized: "Sign-in required"
        case let .failed(message): message
        case .disconnected: "Not connected"
        }
    }
}

struct AccessoryShortcutsView: View {
    @Environment(AppModel.self) private var model
    @State private var draft: [String] = []
    @State private var newShortcut = ""

    var body: some View {
        Form {
            Section {
                ForEach(Array(draft.enumerated()), id: \.offset) { index, value in
                    HStack {
                        Text(value).font(.body.monospaced())
                        Spacer()
                        Button(role: .destructive) {
                            draft.remove(at: index)
                            commit()
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                        .accessibilityLabel("Remove \(value)")
                    }
                }

                HStack {
                    TextField("Add a character or string", text: $newShortcut)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("shortcuts.new")
                    Button("Add") {
                        let trimmed = newShortcut.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty, draft.count < 6 else { return }
                        draft.append(trimmed)
                        newShortcut = ""
                        commit()
                    }
                    .disabled(newShortcut.trimmingCharacters(in: .whitespaces).isEmpty || draft.count >= 6)
                }
            } header: {
                Text("Keyboard accessory")
            } footer: {
                Text("These appear on the terminal keyboard bar after Esc, Tab, Ctrl, Option and the arrows. Up to six.")
            }
        }
        .navigationTitle("Shortcuts")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { draft = model.preferences.accessoryShortcuts }
    }

    private func commit() {
        let snapshot = draft
        model.updatePreferences { $0.accessoryShortcuts = snapshot }
    }
}

extension Bundle {
    var shortVersion: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }
}
