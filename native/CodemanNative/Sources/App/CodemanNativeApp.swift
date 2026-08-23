import GhosttyTerminal
import SwiftUI

@main
struct CodemanNativeApp: App {
    @State private var model: AppModel
    @State private var bootstrapped = false
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let launch = LaunchConfiguration.current

        // A failure to open the store is not recoverable by retrying, and shipping an app that
        // silently forgets every server would be worse than an in-memory fallback the user is
        // told about. `PersistenceStore` surfaces the condition through `AppModel`.
        let persistence: any ServerPersisting
        do {
            // Under UI testing the store is in-memory so a run starts from a known state and
            // cannot mutate the developer's real saved servers.
            persistence = try PersistenceStore(inMemory: launch.usesEphemeralStorage)
        } catch {
            Log.store.error("Persistent store unavailable: \(error.localizedDescription, privacy: .public)")
            persistence = EphemeralServerStore()
        }

        // ⚠️ UI tests use the **real** Keychain, isolated by service name rather than replaced by
        // a double. A double is what let a broken `SecItemAdd` ship: the Security framework
        // rejects an invalid query only at its own boundary, so an in-memory stand-in reports
        // success for a call that can never work on a device.
        let credentials = KeychainCredentialStore(
            service: launch.isUITesting ? LaunchConfiguration.uiTestKeychainService : LaunchConfiguration.keychainService
        )

        // Ghostty's own surface-lifecycle trace, under UI testing only.
        //
        // Surface teardown and rebuild are invisible from the app side — the host sees a session
        // it wrote bytes into and a view that shows nothing — so without this the only way to
        // explain a blank pane is to guess. Deliberately `.lifecycle` alone: the `output` and
        // `input` categories would put the user's terminal bytes into the log.
        if launch.isUITesting {
            TerminalDebugLog.categories = .lifecycle
            TerminalDebugLog.sink = { message in
                Log.terminal.debug("ghostty: \(message, privacy: .public)")
            }
            TerminalDebugLog.isEnabled = true
        }

        if launch.resetsState {
            LaunchConfiguration.clearLocalPreferences()
            KeychainCredentialStore.removeAll(service: LaunchConfiguration.uiTestKeychainService)
        }

        let model = AppModel(persistence: persistence, credentials: credentials)
        model.pendingPreconnect = launch.preconnect
        _model = State(initialValue: model)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task {
                    guard !bootstrapped else { return }
                    bootstrapped = true
                    await model.bootstrap()
                    if model.preferences.notificationsEnabled {
                        _ = await NotificationPresenter.shared.requestAuthorizationIfNeeded()
                    }
                }
                .onOpenURL { url in
                    Task { await handleDeepLink(url) }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            model.handleScenePhase(phase)
        }
    }

    /// `codeman://connect?url=…&name=…` — the contract `GET /api/native/connect` encodes into its
    /// QR code (`native-routes.ts` `buildNativeConnectUrl`).
    @MainActor
    private func handleDeepLink(_ url: URL) async {
        guard let request = QuickConnectRequest(url: url) else { return }
        model.pendingQuickConnect = request
    }
}

/// How the process was launched. UI tests need a clean, isolated app; nothing here changes
/// behaviour for a normally launched build.
struct LaunchConfiguration: Sendable {
    var isUITesting: Bool
    var resetsState: Bool

    /// UI tests must not read or write the developer's SwiftData store.
    var usesEphemeralStorage: Bool { isUITesting }

    /// Keychain service for saved server credentials.
    static let keychainService = "cloud.creature.codeman.native"

    /// Separate service for UI tests, so a run exercises the real Security framework without
    /// touching — or being able to delete — the developer's own saved servers.
    static let uiTestKeychainService = "cloud.creature.codeman.native.uitests"

    /// A server to connect to at launch, skipping onboarding entirely.
    ///
    /// ⚠️ **Honoured only under `-ui-testing`.** A shipped app that connected to whatever a launch
    /// argument named would be a way to point someone's client at someone else's server. This
    /// exists so a UI test does not have to type an address and a password through the keyboard
    /// on every run — which was most of the wall-clock time of the server-backed suites.
    struct Preconnect: Sendable, Equatable {
        var url: String
        var username: String
        var password: String
    }

    var preconnect: Preconnect?

    static var current: LaunchConfiguration {
        let arguments = ProcessInfo.processInfo.arguments
        let isUITesting = arguments.contains("-ui-testing")

        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            let candidate = arguments[index + 1]
            return candidate.hasPrefix("-") ? nil : candidate
        }

        var preconnect: Preconnect?
        if isUITesting, let url = value(after: "-server-url"), let password = value(after: "-server-password") {
            preconnect = Preconnect(url: url, username: value(after: "-server-username") ?? "admin", password: password)
        }

        return LaunchConfiguration(
            isUITesting: isUITesting,
            resetsState: arguments.contains("-reset-state"),
            preconnect: preconnect
        )
    }

    /// Clears only this app's own `UserDefaults` keys — never `removePersistentDomain`, which
    /// would also wipe system-managed keys for the bundle.
    static func clearLocalPreferences() {
        for key in ["codeman.native.preferences", "codeman.native.installID"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

/// Fallback used only when the SwiftData store cannot be opened. Servers added in this state last
/// for the session; the UI says so rather than pretending they were saved.
actor EphemeralServerStore: ServerPersisting {
    private var servers: [UUID: ServerConfiguration] = [:]

    func loadServers() async throws -> [ServerConfiguration] {
        servers.values.sorted { $0.createdAt < $1.createdAt }
    }

    func upsert(_ server: ServerConfiguration) async throws {
        servers[server.id] = server
    }

    func delete(id: UUID) async throws {
        servers.removeValue(forKey: id)
    }
}

/// A parsed `codeman://connect` deep link.
struct QuickConnectRequest: Sendable, Equatable, Identifiable {
    var baseURLString: String
    var name: String?

    /// The address is the identity: presenting the same link twice should not stack two sheets.
    var id: String { baseURLString }

    init?(url: URL) {
        guard url.scheme?.lowercased() == "codeman", url.host()?.lowercased() == "connect",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let raw = components.queryItems?.first(where: { $0.name == "url" })?.value,
              let normalized = ServerConfiguration.normalize(raw)
        else { return nil }

        baseURLString = normalized
        name = components.queryItems?.first(where: { $0.name == "name" })?.value
    }

    private init(baseURLString: String, name: String?) {
        self.baseURLString = baseURLString
        self.name = name
    }

    /// Accepts either a `codeman://connect` link or a plain server URL — some deployments print
    /// the bare address rather than the deep link.
    init?(scannedPayload: String) {
        if let url = URL(string: scannedPayload), url.scheme?.lowercased() == "codeman" {
            guard let parsed = QuickConnectRequest(url: url) else { return nil }
            self = parsed
            return
        }
        guard let normalized = ServerConfiguration.normalize(scannedPayload) else { return nil }
        self.init(baseURLString: normalized, name: nil)
    }
}
