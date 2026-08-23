import Foundation

/// Which Codeman node a call is addressed to.
///
/// This is the **only** place that knows the federation URL shapes. Every REST call and every
/// terminal socket goes through it, so switching nodes cannot leave a half-scoped call behind.
///
/// - local: `<base>/api/...` and `<wsBase>/ws/sessions/<id>/terminal`
/// - remote: `<base>/api/nodes/<nodeId>/proxy/api/...` and
///           `<wsBase>/ws/nodes/<nodeId>/sessions/<id>/terminal`
///
/// The proxy (`node-routes.ts` `proxyFetch`) copies the upstream status, preserves the response
/// envelope, and pipes `text/event-stream` through — so a proxied SSE stream and a proxied API
/// call behave identically to their local counterparts.
enum NodeScope: Sendable, Hashable {
    case local
    case remote(id: String)

    var nodeID: String {
        switch self {
        case .local: "local"
        case let .remote(id): id
        }
    }

    var isLocal: Bool {
        if case .local = self { return true }
        return false
    }

    /// Maps an unscoped API path (always beginning `/api/`) into this scope.
    func apiPath(_ path: String) -> String {
        let normalized = path.hasPrefix("/") ? path : "/" + path
        switch self {
        case .local:
            return normalized
        case let .remote(id):
            let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
            return "/api/nodes/\(encoded)/proxy\(normalized)"
        }
    }

    func terminalSocketPath(sessionID: String) -> String {
        let session = sessionID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionID
        switch self {
        case .local:
            return "/ws/sessions/\(session)/terminal"
        case let .remote(id):
            let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
            return "/ws/nodes/\(encoded)/sessions/\(session)/terminal"
        }
    }
}

/// How the app authenticates to one server.
enum ServerCredential: Sendable, Hashable {
    /// HTTP Basic. `username` defaults to `admin`, matching `CODEMAN_USERNAME`.
    case basic(username: String, password: String)
    /// A federation token from `POST /api/node/pair/claim` or `POST /api/node/tokens`.
    /// `verifyFederationBearer` grants **admin**, which is what the node-management routes need.
    case bearer(String)
    /// The server runs with no `CODEMAN_PASSWORD` in single-user mode.
    case none

    var authorizationHeader: String? {
        switch self {
        case let .basic(username, password):
            let raw = "\(username):\(password)"
            guard let data = raw.data(using: .utf8) else { return nil }
            return "Basic " + data.base64EncodedString()
        case let .bearer(token):
            return "Bearer " + token
        case .none:
            return nil
        }
    }
}

/// A saved server, minus its secret (which lives in the Keychain, keyed by `id`).
struct ServerConfiguration: Sendable, Hashable, Identifiable, Codable {
    var id: UUID
    var displayName: String
    /// Absolute base URL, no trailing slash, e.g. `https://box.tail1234.ts.net` or
    /// `http://192.168.1.20:3000`.
    var baseURLString: String
    var username: String
    var usesBearerToken: Bool
    /// SHA-256 of the leaf certificate the user explicitly accepted for a self-signed HTTPS
    /// server. `nil` means standard system trust evaluation, which is the default.
    var pinnedCertificateSHA256: String?
    var createdAt: Date
    var lastUsedAt: Date?

    init(
        id: UUID = UUID(),
        displayName: String,
        baseURLString: String,
        username: String = "admin",
        usesBearerToken: Bool = false,
        pinnedCertificateSHA256: String? = nil,
        createdAt: Date = .now,
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.baseURLString = ServerConfiguration.normalize(baseURLString) ?? baseURLString
        self.username = username
        self.usesBearerToken = usesBearerToken
        self.pinnedCertificateSHA256 = pinnedCertificateSHA256
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }

    var baseURL: URL? { URL(string: baseURLString) }

    var host: String? { baseURL?.host() }

    var isCleartext: Bool { baseURL?.scheme?.lowercased() == "http" }

    /// Normalises whatever the user typed into an absolute base URL.
    ///
    /// Scheme inference: an address that is unambiguously on a local network gets `http`, because
    /// that is what a default Codeman install serves and what ATS's `NSAllowsLocalNetworking`
    /// permits. Everything else gets `https`, so a typo cannot silently downgrade a public host
    /// to cleartext (ATS would block it anyway).
    static func normalize(_ input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if !text.contains("://") {
            let hostPart = text.split(separator: "/", maxSplits: 1).first.map(String.init) ?? text
            let bareHost = hostPart.split(separator: ":").first.map(String.init) ?? hostPart
            text = (isLocalNetworkHost(bareHost) ? "http://" : "https://") + text
        }

        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty
        else { return nil }

        components.scheme = scheme
        // Strip a trailing slash so path joining is unambiguous.
        while components.path.hasSuffix("/") { components.path.removeLast() }
        components.query = nil
        components.fragment = nil
        return components.url?.absoluteString
    }

    /// Hosts ATS's `NSAllowsLocalNetworking` exception covers, plus loopback.
    static func isLocalNetworkHost(_ host: String) -> Bool {
        let lower = host.lowercased()
        if lower == "localhost" || lower.hasSuffix(".local") || lower.hasSuffix(".localhost") { return true }
        if lower == "::1" || lower == "[::1]" { return true }

        let octets = lower.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        switch (octets[0], octets[1]) {
        case (127, _): return true
        case (10, _): return true
        case (192, 168): return true
        case (169, 254): return true
        case (172, 16...31): return true
        default: return false
        }
    }
}
