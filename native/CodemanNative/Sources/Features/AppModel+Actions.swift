import Foundation
import SwiftUI

extension AppModel {
    /// Exposed for views that need to call an endpoint the model does not wrap. Views never
    /// construct a client of their own.
    var apiClient: (any APIClientProtocol)? { currentAPI }

    // MARK: - Launching

    /// Starts a session through `POST /api/quick-start`.
    ///
    /// Quick-start is used rather than `POST /api/sessions` because it creates the case if
    /// missing, resolves remote-SSH and Docker cases, *and* starts the session in one call.
    /// `POST /api/sessions` stat-validates `workingDir` on the local filesystem and has no
    /// `caseName`, so it cannot launch a remote case at all.
    @discardableResult
    func launchSession(caseName: String, mode: SessionMode, sessionName: String?) async throws -> String {
        guard let api = currentAPI else { throw APIError.notAuthenticated }

        let request = QuickStartRequest(
            caseName: caseName,
            sessionName: sessionName,
            mode: mode,
            launchCommand: nil,
            modelOverride: nil,
            envOverrides: nil,
            effort: nil,
            // Lineage is decoration, and the server drops an unresolvable value rather than
            // failing the spawn — so passing the currently-selected session is safe and gives the
            // web client's lineage view something to draw.
            parentSessionId: selectedSessionID
        )
        let response = try await api.quickStart(request, scope: scope)
        await refreshSessions()
        return response.sessionId
    }

    /// Launches a saved custom action as a shell session.
    ///
    /// Mirrors `runCustomAction` in `session-ui.js`, including its remote-node fallback **and**
    /// the refusal that guards it: if the node rejects `envOverrides` and any variable name looks
    /// like a credential, we do **not** retry with the environment folded into the command line,
    /// because that would put a secret into a process argument list.
    @discardableResult
    func launchCustomAction(_ action: CustomRunAction, caseName: String) async throws -> String {
        guard let api = currentAPI else { throw APIError.notAuthenticated }

        let env = action.envOverrides
        let sessionName = nextSessionName(prefix: "x", caseName: caseName)
        let primary = QuickStartRequest(
            caseName: caseName,
            sessionName: sessionName,
            mode: .shell,
            launchCommand: action.command,
            modelOverride: nil,
            envOverrides: env.isEmpty ? nil : env,
            effort: nil,
            parentSessionId: selectedSessionID
        )

        do {
            let response = try await api.quickStart(primary, scope: scope)
            await refreshSessions()
            return response.sessionId
        } catch let error as APIError {
            guard case let .server(_, code, message) = error,
                  code == .invalidInput,
                  !env.isEmpty,
                  scope.isLocal == false,
                  CustomActionLauncher.mentionsEnvRejection(message)
            else { throw error }

            if action.carriesSensitiveEnv {
                throw CustomActionError.sensitiveEnvUnsupportedOnNode(action.label)
            }

            let fallback = QuickStartRequest(
                caseName: caseName,
                sessionName: sessionName,
                mode: .shell,
                launchCommand: CustomActionLauncher.inlineEnvCommand(action),
                modelOverride: nil,
                envOverrides: nil,
                effort: nil,
                parentSessionId: selectedSessionID
            )
            let response = try await api.quickStart(fallback, scope: scope)
            await refreshSessions()
            return response.sessionId
        }
    }

    /// `x1-mycase`, `x2-mycase`, … — the naming the web client uses for action-launched sessions.
    func nextSessionName(prefix: String, caseName: String) -> String {
        let existing = sessions.compactMap { session -> Int? in
            guard let name = session.name, name.hasSuffix("-\(caseName)"), name.hasPrefix(prefix) else { return nil }
            let digits = name.dropFirst(prefix.count).prefix { $0.isNumber }
            return Int(digits)
        }
        return "\(prefix)\((existing.max() ?? 0) + 1)-\(caseName)"
    }

    /// Resumes a past conversation. Claude records the conversation id, and quick-start cannot
    /// carry one, so this uses `POST /api/sessions` with `resumeSessionId` and then starts it.
    func resumeHistorySession(_ row: HistorySession) async {
        guard let api = currentAPI else { return }
        do {
            let created = try await api.createSession(
                CreateSessionRequest(
                    workingDir: row.path,
                    mode: row.mode ?? .claude,
                    name: row.name,
                    parentSessionId: nil,
                    envOverrides: nil,
                    effort: nil,
                    modelOverride: nil,
                    statusLineTelemetry: nil,
                    resumeSessionId: row.claudeSessionId
                ),
                scope: scope
            )
            // `POST /api/sessions` creates but does not start — `pid` stays nil until this call.
            try await api.startInteractive(id: created.id, clearBreaker: false, scope: scope)
            await refreshSessions()
            selectedSessionID = created.id
        } catch {
            report(error, title: "Could not resume that conversation")
        }
    }

    // MARK: - Settings

    /// Persists custom actions to the server so both clients see the same list.
    func saveCustomActions(_ actions: [CustomRunAction]) async throws {
        guard let api = currentAPI else { throw APIError.notAuthenticated }
        try await api.updateSettings(SettingsUpdate(customRunActions: actions, runMode: nil), scope: scope)
        applyCustomActions(actions)
    }

    // MARK: - Connection testing

    /// Probes a candidate server before it is saved, using the one node route that is not
    /// admin-gated. Builds a throwaway client so an unsaved server never mutates app state.
    func probeServer(_ configuration: ServerConfiguration, credential: ServerCredential) async throws -> NodeInfo {
        if let host = configuration.host {
            trustEvaluator.setPin(configuration.pinnedCertificateSHA256, forHost: host)
        }
        let store = EphemeralCredentialStore(credential: credential, serverID: configuration.id)
        let client = APIClient(server: configuration, credentials: store, session: probeSession)
        return try await client.nodeInfo(scope: .local)
    }

    func lastRejectedCertificate() -> (host: String, sha256: String)? {
        trustEvaluator.takeLastRejectedPin()
    }
}

/// Pure helpers for the remote-node launch fallback.
///
/// Deliberately outside `AppModel`: they touch no state, and being main-actor-isolated would
/// force every caller — including the unit tests that pin the shell quoting — onto the main actor
/// for no reason.
enum CustomActionLauncher {
    /// Matches the web client's detection of "this node is too old for `envOverrides`".
    static func mentionsEnvRejection(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("envoverrides")
            || lowered.contains("environment")
            || lowered.contains("disallowed")
            || lowered.contains("not supported")
    }

    /// `KEY=value KEY2=value2 command` — used **only** when no variable name looks like a secret.
    static func inlineEnvCommand(_ action: CustomRunAction) -> String {
        let assignments = (action.env ?? [])
            .filter(\.hasValidKey)
            .map { "\($0.key)=\(shellQuote($0.value))" }
        return (assignments + [action.command]).joined(separator: " ")
    }

    /// Single-quote quoting: everything inside is literal, and an embedded quote is closed,
    /// escaped, and reopened. The result stays a single line, which `launchCommand` requires.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

enum CustomActionError: LocalizedError {
    case sensitiveEnvUnsupportedOnNode(String)

    var errorDescription: String? {
        switch self {
        case let .sensitiveEnvUnsupportedOnNode(label):
            """
            “\(label)” needs hidden environment support on the selected node, and this app will \
            not fall back to putting a secret on the command line. Update Codeman on that node, \
            then start the action again.
            """
        }
    }
}

/// Credential store used only for a pre-save connection test. Holds one credential in memory and
/// never touches the Keychain, so a failed probe leaves nothing behind.
actor EphemeralCredentialStore: CredentialStoring {
    private let credential: ServerCredential
    private let serverID: UUID

    init(credential: ServerCredential, serverID: UUID) {
        self.credential = credential
        self.serverID = serverID
    }

    func credential(for serverID: UUID) async -> ServerCredential {
        serverID == self.serverID ? credential : .none
    }

    func store(_ credential: ServerCredential, for serverID: UUID) async throws {}
    func remove(for serverID: UUID) async throws {}
}
