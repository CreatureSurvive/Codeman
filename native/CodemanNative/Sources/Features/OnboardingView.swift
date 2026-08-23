import SwiftUI

/// First run and server switching.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var showsAddServer = false

    var body: some View {
        NavigationStack {
            Group {
                if model.servers.isEmpty {
                    ContentUnavailableView {
                        Label("Connect to Codeman", systemImage: "server.rack")
                    } description: {
                        Text("Enter your Codeman server's address, or scan the QR code from its Settings screen.")
                    } actions: {
                        Button("Add Server") { showsAddServer = true }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("onboarding.addServer")
                    }
                } else {
                    List {
                        Section("Saved servers") {
                            ForEach(model.servers) { server in
                                Button {
                                    Task { await model.activate(server: server) }
                                } label: {
                                    ServerRow(server: server)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("server.\(server.id.uuidString)")
                                .swipeActions {
                                    Button(role: .destructive) {
                                        Task { await model.removeServer(server) }
                                    } label: {
                                        Label("Remove", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Codeman")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showsAddServer = true } label: { Label("Add Server", systemImage: "plus") }
                        .accessibilityIdentifier("onboarding.add")
                }
            }
            .sheet(isPresented: $showsAddServer) {
                NavigationStack { AddServerView() }
            }
        }
    }
}

private struct ServerRow: View {
    let server: ServerConfiguration

    var body: some View {
        HStack {
            Image(systemName: server.isCleartext ? "lock.open" : "lock")
                .foregroundStyle(server.isCleartext ? .orange : .green)
            VStack(alignment: .leading, spacing: 1) {
                Text(server.displayName).font(.body)
                Text(server.baseURLString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Add server

struct AddServerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var prefilled: QuickConnectRequest?

    @State private var address = ""
    @State private var displayName = ""
    @State private var authMode: AuthMode = .password
    @State private var username = "admin"
    @State private var password = ""
    @State private var token = ""
    @State private var testState: TestState = .idle
    @State private var isSaving = false
    @State private var showsScanner = false
    @State private var pendingCertificate: CertificatePrompt?

    private enum AuthMode: String, CaseIterable, Identifiable {
        case password = "Password"
        case token = "Token"
        case none = "None"
        var id: String { rawValue }
    }

    private enum TestState: Equatable {
        case idle
        case testing
        case success(name: String, version: String)
        case failure(String)
    }

    private struct CertificatePrompt: Identifiable {
        let id = UUID()
        var host: String
        var sha256: String
    }

    var body: some View {
        Form {
            Section {
                TextField("host, host:port, or full URL", text: $address)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .accessibilityIdentifier("addServer.address")

                TextField("Name (optional)", text: $displayName)
                    .accessibilityIdentifier("addServer.name")
            } header: {
                Text("Server")
            } footer: {
                if let normalized = ServerConfiguration.normalize(address) {
                    Text("Will connect to \(normalized)")
                        .font(.caption)
                } else if !address.isEmpty {
                    Text("That does not look like a server address.").foregroundStyle(.red)
                } else {
                    Text("A LAN or `.local` address defaults to http; anything else defaults to https.")
                }
            }

            Section("Authentication") {
                Picker("Method", selection: $authMode) {
                    ForEach(AuthMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("addServer.authMode")

                switch authMode {
                case .password:
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("addServer.username")
                    SecureField("CODEMAN_PASSWORD", text: $password)
                        .accessibilityIdentifier("addServer.password")
                case .token:
                    SecureField("Node pairing / federation token", text: $token)
                        .accessibilityIdentifier("addServer.token")
                    Text("A federation token also grants node management.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .none:
                    Text("Only works when the server runs single-user with no CODEMAN_PASSWORD set.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button {
                    Task { await test() }
                } label: {
                    HStack {
                        Text("Test Connection")
                        Spacer()
                        switch testState {
                        case .idle: EmptyView()
                        case .testing: ProgressView().controlSize(.small)
                        case .success: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        case .failure: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                        }
                    }
                }
                .disabled(ServerConfiguration.normalize(address) == nil || testState == .testing)
                .accessibilityIdentifier("addServer.test")

                if case let .success(name, version) = testState {
                    Label("\(name) · Codeman \(version)", systemImage: "checkmark.seal")
                        .font(.callout)
                        .foregroundStyle(.green)
                }
                if case let .failure(message) = testState {
                    Text(message).font(.callout).foregroundStyle(.red)
                }
            }

            Section {
                Button {
                    showsScanner = true
                } label: {
                    Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                }
                .accessibilityIdentifier("addServer.scan")
            } footer: {
                Text("Codeman shows a QR code for this at /api/native/connect.")
            }
        }
        .navigationTitle("Add Server")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                // Saving persists the credential and then connects, which is a full network round
                // trip. Without the spinner the button looks inert for the whole of it.
                if isSaving {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Save") { Task { await save() } }
                        .disabled(ServerConfiguration.normalize(address) == nil)
                        .accessibilityIdentifier("addServer.save")
                }
            }
        }
        .sheet(isPresented: $showsScanner) {
            QRScannerView { payload in
                showsScanner = false
                guard let request = QuickConnectRequest(scannedPayload: payload) else { return }
                apply(request)
            }
        }
        .alert(item: $pendingCertificate) { prompt in
            Alert(
                title: Text("Untrusted certificate"),
                message: Text("""
                \(prompt.host) presented a certificate iOS does not trust.

                SHA-256: \(ServerTrustEvaluator.displayFingerprint(prompt.sha256))

                Only continue if this matches your own Codeman server.
                """),
                primaryButton: .destructive(Text("Trust")) {
                    trustedFingerprint = prompt.sha256
                    Task { await test() }
                },
                secondaryButton: .cancel()
            )
        }
        .onAppear {
            if let prefilled { apply(prefilled) }
        }
    }

    @State private var trustedFingerprint: String?

    private func apply(_ request: QuickConnectRequest) {
        address = request.baseURLString
        if displayName.isEmpty, let name = request.name { displayName = name }
    }

    private func buildConfiguration() -> ServerConfiguration? {
        guard let normalized = ServerConfiguration.normalize(address) else { return nil }
        let host = URL(string: normalized)?.host() ?? normalized
        return ServerConfiguration(
            displayName: displayName.trimmingCharacters(in: .whitespaces).isEmpty ? host : displayName,
            baseURLString: normalized,
            username: authMode == .password ? username : "admin",
            usesBearerToken: authMode == .token,
            pinnedCertificateSHA256: trustedFingerprint
        )
    }

    private var credential: ServerCredential {
        switch authMode {
        case .password: .basic(username: username, password: password)
        case .token: .bearer(token)
        case .none: .none
        }
    }

    private func test() async {
        guard let configuration = buildConfiguration() else { return }
        testState = .testing
        do {
            let info = try await model.probeServer(configuration, credential: credential)
            testState = .success(name: info.name, version: info.version)
        } catch {
            if let rejected = model.lastRejectedCertificate() {
                pendingCertificate = CertificatePrompt(host: rejected.host, sha256: rejected.sha256)
                testState = .failure("Certificate not trusted.")
                return
            }
            let message = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
            testState = .failure(message)
        }
    }

    private func save() async {
        guard let configuration = buildConfiguration(), !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await model.addServer(configuration, credential: credential)
            dismiss()
        } catch {
            // Surfaced by `AppAlertHost`, which presents from the front-most controller — a plain
            // `.alert` on the root view would be swallowed while this sheet is up.
            model.report(error, title: "Could not save the server")
        }
    }
}
