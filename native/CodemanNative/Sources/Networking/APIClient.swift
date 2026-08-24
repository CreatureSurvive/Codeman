import Foundation

/// The REST surface the app uses, as a protocol so tests can substitute a transport without any
/// mock ever entering a production path.
protocol APIClientProtocol: Sendable {
    func nodeInfo(scope: NodeScope) async throws -> NodeInfo
    func listNodes() async throws -> NodeListResponse
    func upsertNode(_ request: UpsertNodeRequest, id: String?) async throws -> NodeRecordDTO
    func deleteNode(id: String) async throws
    func testNode(id: String) async throws -> NodeTestResponse
    func pairNode(_ request: PairNodeRequest) async throws -> NodeRecordDTO

    func listSessions(scope: NodeScope) async throws -> [SessionSnapshot]
    func session(id: String, scope: NodeScope) async throws -> SessionSnapshot
    func quickStart(_ request: QuickStartRequest, scope: NodeScope) async throws -> QuickStartResponse
    func createSession(_ request: CreateSessionRequest, scope: NodeScope) async throws -> SessionSnapshot
    func startInteractive(id: String, clearBreaker: Bool, scope: NodeScope) async throws
    func startShell(id: String, scope: NodeScope) async throws
    func renameSession(id: String, name: String, scope: NodeScope) async throws
    func deleteSession(id: String, killMux: Bool, scope: NodeScope) async throws
    func setPinned(id: String, pinned: Bool, scope: NodeScope) async throws
    func sendInput(_ request: SessionInputRequest, id: String, scope: NodeScope) async throws -> SessionInputResponse
    func sendNewlineKey(id: String, scope: NodeScope) async throws
    func resize(_ request: ResizeRequest, id: String, scope: NodeScope) async throws
    func terminalSnapshot(id: String, full: Bool, tailBytes: Int?, scope: NodeScope) async throws -> TerminalSnapshot
    func transcript(id: String, limit: Int?, maxBytes: Int?, before: Int?, since: Int?, scope: NodeScope) async throws
        -> TranscriptResponse
    func transcriptImage(id: String, ref: String, scope: NodeScope) async throws -> Data
    func projectFiles(id: String, depth: Int, scope: NodeScope) async throws -> FileTreeResponse
    func slashCommands(id: String, scope: NodeScope) async throws -> SlashCommandsResponse
    func fileContent(id: String, path: String, scope: NodeScope) async throws -> FileContent
    func historySessions(scope: NodeScope) async throws -> [HistorySession]

    func listCases(scope: NodeScope) async throws -> [CaseInfo]
    func createCase(_ request: CreateCaseRequest, scope: NodeScope) async throws -> CreateCaseResponse
    func browse(path: String?, sessionID: String?, showHidden: Bool, scope: NodeScope) async throws -> FilesystemListing

    func uploadImage(_ data: Data, filename: String, mimeType: String, sessionID: String, scope: NodeScope) async throws -> PasteImageResponse
    func attachmentData(id: String, sessionID: String, scope: NodeScope) async throws -> Data
    func registerAttachment(path: String, notify: Bool, sessionID: String, scope: NodeScope) async throws -> AttachmentDescriptor

    func settings(scope: NodeScope) async throws -> ServerSettings
    func updateSettings(_ update: SettingsUpdate, scope: NodeScope) async throws
    func approvals(scope: NodeScope) async throws -> [ApprovalItem]
    func answerApproval(id: String, request: ApprovalAnswerRequest, scope: NodeScope) async throws
    func subagents(scope: NodeScope) async throws -> [SubagentInfo]
    func logout(scope: NodeScope) async throws
}

/// `URLSession`-backed implementation of the Codeman REST contract.
///
/// Header policy (Architecture §3.2): `Authorization` + `Accept` on everything,
/// `X-Codeman-CSRF` on every non-GET. `Host` and `Origin` are deliberately never set — see
/// API-Audit §3.
actor APIClient: APIClientProtocol {
    private let session: URLSession
    private let credentials: any CredentialStoring
    private let server: ServerConfiguration
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    /// Only `paste-image` requires this, but sending it on every mutation is free and matches
    /// what the server's own node proxy does (`proxyFetch` sets `X-Codeman-CSRF: node-proxy`).
    static let csrfHeaderValue = "codeman-native"

    init(server: ServerConfiguration, credentials: any CredentialStoring, session: URLSession) {
        self.server = server
        self.credentials = credentials
        self.session = session

        decoder = JSONDecoder()
        encoder = JSONEncoder()
        // The server omits keys it does not set rather than sending null, and `.optional()` Zod
        // fields reject an explicit null on the wire — so absent must stay absent.
        encoder.outputFormatting = []
    }

    // MARK: - Request plumbing

    private func makeURL(_ path: String, scope: NodeScope, query: [URLQueryItem] = []) throws -> URL {
        guard let base = server.baseURL,
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        else { throw APIError.badURL }

        components.path = (components.path.isEmpty ? "" : components.path) + scope.apiPath(path)
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw APIError.badURL }
        return url
    }

    private func authorizedRequest(url: URL, method: String) async -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let header = await credentials.credential(for: server.id).authorizationHeader {
            request.setValue(header, forHTTPHeaderField: "Authorization")
        }
        if method != "GET" && method != "HEAD" {
            request.setValue(Self.csrfHeaderValue, forHTTPHeaderField: "X-Codeman-CSRF")
        }
        return request
    }

    private func perform<Response: Decodable & Sendable>(
        _ method: String,
        _ path: String,
        scope: NodeScope,
        query: [URLQueryItem] = [],
        body: (any Encodable & Sendable)? = nil,
        as type: Response.Type = Response.self
    ) async throws -> Response {
        let url = try makeURL(path, scope: scope, query: query)
        var request = await authorizedRequest(url: url, method: method)

        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(body)
        }

        let (data, response) = try await send(request)
        try Self.throwIfFailure(response: response, data: data, decoder: decoder)
        return try APIEnvelope.decode(Response.self, from: data, decoder: decoder)
    }

    private func performVoid(
        _ method: String,
        _ path: String,
        scope: NodeScope,
        query: [URLQueryItem] = [],
        body: (any Encodable & Sendable)? = nil
    ) async throws {
        _ = try await perform(method, path, scope: scope, query: query, body: body, as: EmptyResponse.self)
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw APIError.decoding("Response was not HTTP.")
            }
            Log.net.debug("\(request.httpMethod ?? "GET", privacy: .public) \(http.statusCode, privacy: .public) \(request.url?.path ?? "", privacy: .private)")
            return (data, http)
        } catch let error as URLError {
            throw APIError.transport(error)
        }
    }

    static func throwIfFailure(response: HTTPURLResponse, data: Data, decoder: JSONDecoder) throws {
        guard !(200...299).contains(response.statusCode) else { return }

        if response.statusCode == 429 {
            let retryAfter = (response.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
            throw APIError.rateLimited(retryAfter: retryAfter)
        }
        throw APIEnvelope.decodeFailure(status: response.statusCode, data: data, decoder: decoder)
    }

    // MARK: - Nodes

    func nodeInfo(scope: NodeScope) async throws -> NodeInfo {
        try await perform("GET", "/api/node/info", scope: scope)
    }

    func listNodes() async throws -> NodeListResponse {
        try await perform("GET", "/api/nodes", scope: .local)
    }

    func upsertNode(_ request: UpsertNodeRequest, id: String?) async throws -> NodeRecordDTO {
        if let id {
            let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
            return try await perform("PUT", "/api/nodes/\(encoded)", scope: .local, body: request)
        }
        return try await perform("POST", "/api/nodes", scope: .local, body: request)
    }

    func deleteNode(id: String) async throws {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        try await performVoid("DELETE", "/api/nodes/\(encoded)", scope: .local)
    }

    func testNode(id: String) async throws -> NodeTestResponse {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        return try await perform("POST", "/api/nodes/\(encoded)/test", scope: .local)
    }

    func pairNode(_ request: PairNodeRequest) async throws -> NodeRecordDTO {
        try await perform("POST", "/api/nodes/pair", scope: .local, body: request)
    }

    // MARK: - Sessions

    func listSessions(scope: NodeScope) async throws -> [SessionSnapshot] {
        try await perform("GET", "/api/sessions", scope: scope)
    }

    func session(id: String, scope: NodeScope) async throws -> SessionSnapshot {
        try await perform("GET", "/api/sessions/\(Self.escape(id))", scope: scope)
    }

    func quickStart(_ request: QuickStartRequest, scope: NodeScope) async throws -> QuickStartResponse {
        try await perform("POST", "/api/quick-start", scope: scope, body: request)
    }

    func createSession(_ request: CreateSessionRequest, scope: NodeScope) async throws -> SessionSnapshot {
        let response: CreateSessionResponse = try await perform("POST", "/api/sessions", scope: scope, body: request)
        return response.session
    }

    func startInteractive(id: String, clearBreaker: Bool, scope: NodeScope) async throws {
        // The body is optional server-side; sending `{clearBreaker:false}` is equivalent to the
        // frontend's bodyless auto-reattach and must never clear a tripped PTY breaker.
        struct Body: Encodable, Sendable { var clearBreaker: Bool }
        try await performVoid("POST", "/api/sessions/\(Self.escape(id))/interactive", scope: scope,
                              body: Body(clearBreaker: clearBreaker))
    }

    func startShell(id: String, scope: NodeScope) async throws {
        try await performVoid("POST", "/api/sessions/\(Self.escape(id))/shell", scope: scope)
    }

    func renameSession(id: String, name: String, scope: NodeScope) async throws {
        try await performVoid("PUT", "/api/sessions/\(Self.escape(id))", scope: scope,
                              body: RenameSessionRequest(name: name))
    }

    func deleteSession(id: String, killMux: Bool, scope: NodeScope) async throws {
        try await performVoid("DELETE", "/api/sessions/\(Self.escape(id))", scope: scope,
                              query: killMux ? [URLQueryItem(name: "killMux", value: "true")] : [])
    }

    func setPinned(id: String, pinned: Bool, scope: NodeScope) async throws {
        struct Body: Encodable, Sendable { var pinned: Bool }
        try await performVoid("POST", "/api/sessions/\(Self.escape(id))/pin", scope: scope, body: Body(pinned: pinned))
    }

    func sendInput(_ request: SessionInputRequest, id: String, scope: NodeScope) async throws -> SessionInputResponse {
        try await perform("POST", "/api/sessions/\(Self.escape(id))/input", scope: scope, body: request)
    }

    /// `S-Enter` is one of only two keys `POST /api/sessions/:id/send-key` accepts; it maps to
    /// hex `0a` (LF), which Claude Code's Ink input reads as "insert newline" rather than submit.
    func sendNewlineKey(id: String, scope: NodeScope) async throws {
        struct Body: Encodable, Sendable { var key: String }
        try await performVoid("POST", "/api/sessions/\(Self.escape(id))/send-key", scope: scope,
                              body: Body(key: "S-Enter"))
    }

    func resize(_ request: ResizeRequest, id: String, scope: NodeScope) async throws {
        try await performVoid("POST", "/api/sessions/\(Self.escape(id))/resize", scope: scope, body: request)
    }

    func terminalSnapshot(id: String, full: Bool, tailBytes: Int?, scope: NodeScope) async throws -> TerminalSnapshot {
        var query: [URLQueryItem] = []
        if full { query.append(URLQueryItem(name: "full", value: "1")) }
        if let tailBytes { query.append(URLQueryItem(name: "tail", value: String(tailBytes))) }
        return try await perform("GET", "/api/sessions/\(Self.escape(id))/terminal", scope: scope, query: query)
    }

    /// The conversation as structured blocks, for the native transcript view.
    ///
    /// Distinct from the terminal snapshot, which is rendered ANSI: this is the parsed JSONL
    /// Claude Code writes, so reasoning, tool calls and file edits arrive as data rather than as
    /// pixels in a grid. Answers `available:false` rather than an error for a session type that
    /// writes no Claude transcript.
    func transcript(
        id: String,
        limit: Int?,
        maxBytes: Int?,
        before: Int?,
        since: Int?,
        scope: NodeScope
    ) async throws -> TranscriptResponse {
        var query: [URLQueryItem] = []
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        if let maxBytes { query.append(URLQueryItem(name: "maxBytes", value: String(maxBytes))) }
        if let before { query.append(URLQueryItem(name: "before", value: String(before))) }
        if let since { query.append(URLQueryItem(name: "since", value: String(since))) }
        return try await perform("GET", "/api/sessions/\(Self.escape(id))/transcript", scope: scope, query: query)
    }

    /// Bytes for one `TranscriptImageRef`.
    ///
    /// Returns raw data rather than an envelope — the endpoint answers with the image itself, so
    /// there is no `{success,data}` wrapper to unwrap.
    func transcriptImage(id: String, ref: String, scope: NodeScope) async throws -> Data {
        let url = try makeURL("/api/sessions/\(Self.escape(id))/transcript/image", scope: scope,
                              query: [URLQueryItem(name: "ref", value: ref)])
        var request = await authorizedRequest(url: url, method: "GET")
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        let (data, response) = try await send(request)
        try Self.throwIfFailure(response: response, data: data, decoder: decoder)
        return data
    }

    /// The session's project file tree. Server-scoped to the working directory, with generated
    /// trees already excluded.
    func projectFiles(id: String, depth: Int, scope: NodeScope) async throws -> FileTreeResponse {
        try await perform("GET", "/api/sessions/\(Self.escape(id))/files", scope: scope,
                          query: [URLQueryItem(name: "depth", value: String(depth))])
    }

    /// One file's contents for preview. ⚠️ Truncates at 500 lines — never treat the result as the
    /// whole file.
    func fileContent(id: String, path: String, scope: NodeScope) async throws -> FileContent {
        try await perform("GET", "/api/sessions/\(Self.escape(id))/file-content", scope: scope,
                          query: [URLQueryItem(name: "path", value: path)])
    }

    /// Slash commands available to this session — the user's own files plus the CLI built-ins.
    func slashCommands(id: String, scope: NodeScope) async throws -> SlashCommandsResponse {
        try await perform("GET", "/api/sessions/\(Self.escape(id))/slash-commands", scope: scope)
    }

    func historySessions(scope: NodeScope) async throws -> [HistorySession] {
        try await perform("GET", "/api/history/sessions", scope: scope)
    }

    // MARK: - Workspace

    func listCases(scope: NodeScope) async throws -> [CaseInfo] {
        try await perform("GET", "/api/cases", scope: scope)
    }

    func createCase(_ request: CreateCaseRequest, scope: NodeScope) async throws -> CreateCaseResponse {
        try await perform("POST", "/api/cases", scope: scope, body: request)
    }

    func browse(path: String?, sessionID: String?, showHidden: Bool, scope: NodeScope) async throws -> FilesystemListing {
        var query: [URLQueryItem] = []
        if let path { query.append(URLQueryItem(name: "path", value: path)) }
        // The session id is an ownership-scoped hint: passing one the caller cannot access is a
        // 404, so it is included only when a session is genuinely in context.
        if let sessionID { query.append(URLQueryItem(name: "sessionId", value: sessionID)) }
        if showHidden { query.append(URLQueryItem(name: "showHidden", value: "true")) }
        return try await perform("GET", "/api/filesystem/browse", scope: scope, query: query)
    }

    // MARK: - Attachments

    /// `POST /api/sessions/:id/paste-image` — multipart, field name **must** be `image`, and
    /// `X-Codeman-CSRF` is **mandatory** because this route's hand-rolled CSRF check does not
    /// share the global guard's "missing Origin is fine" rule (API-Audit §3.4).
    func uploadImage(
        _ data: Data,
        filename: String,
        mimeType: String,
        sessionID: String,
        scope: NodeScope
    ) async throws -> PasteImageResponse {
        let url = try makeURL("/api/sessions/\(Self.escape(sessionID))/paste-image", scope: scope)
        var request = await authorizedRequest(url: url, method: "POST")

        let boundary = "codeman-native-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"image\"; filename=\"\(Self.sanitizeFilename(filename))\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(data)
        append("\r\n--\(boundary)--\r\n")
        request.httpBody = body

        let (responseData, response) = try await send(request)
        try Self.throwIfFailure(response: response, data: responseData, decoder: decoder)
        return try APIEnvelope.decode(PasteImageResponse.self, from: responseData, decoder: decoder)
    }

    /// Bytes of a registered attachment.
    ///
    /// The `/raw` route streams the real file and is range-aware; it returns the image itself, so
    /// there is no envelope to unwrap.
    func attachmentData(id: String, sessionID: String, scope: NodeScope) async throws -> Data {
        let url = try makeURL(
            "/api/sessions/\(Self.escape(sessionID))/attachments/\(Self.escape(id))/raw",
            scope: scope
        )
        var request = await authorizedRequest(url: url, method: "GET")
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        let (data, response) = try await send(request)
        try Self.throwIfFailure(response: response, data: data, decoder: decoder)
        return data
    }

    func registerAttachment(path: String, notify: Bool, sessionID: String, scope: NodeScope) async throws -> AttachmentDescriptor {
        try await perform("POST", "/api/sessions/\(Self.escape(sessionID))/attachments", scope: scope,
                          body: AttachmentRegistrationRequest(path: path, notify: notify))
    }

    // MARK: - Settings, approvals, agents

    func settings(scope: NodeScope) async throws -> ServerSettings {
        try await perform("GET", "/api/settings", scope: scope)
    }

    func updateSettings(_ update: SettingsUpdate, scope: NodeScope) async throws {
        guard !update.isEmpty else { return }
        try await performVoid("PUT", "/api/settings", scope: scope, body: update)
    }

    func approvals(scope: NodeScope) async throws -> [ApprovalItem] {
        try await perform("GET", "/api/approvals", scope: scope)
    }

    func answerApproval(id: String, request: ApprovalAnswerRequest, scope: NodeScope) async throws {
        try await performVoid("POST", "/api/approvals/\(Self.escape(id))/answer", scope: scope, body: request)
    }

    func subagents(scope: NodeScope) async throws -> [SubagentInfo] {
        try await perform("GET", "/api/subagents", scope: scope)
    }

    func logout(scope: NodeScope) async throws {
        try await performVoid("POST", "/api/logout", scope: scope)
    }

    // MARK: - Helpers

    static func escape(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? component
    }

    /// Keeps a quote or CR/LF in a picked filename from breaking the multipart header.
    static func sanitizeFilename(_ name: String) -> String {
        name.replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
    }
}

// MARK: - Session factory

enum CodemanURLSession {
    /// The shared configuration for every network call the app makes.
    ///
    /// `httpCookieStorage` is left enabled so the sliding `codeman_session` cookie is carried
    /// opportunistically; `Authorization` is still sent on every request, so a dropped cookie is
    /// never load-bearing.
    static func make(delegate: ServerTrustEvaluator) -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 120
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .onlyFromMainDocumentDomain
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    /// A session for long-lived streams. Separate from the REST session so a 20 s request
    /// timeout cannot kill an SSE connection that is legitimately idle between events.
    static func makeStreaming(delegate: ServerTrustEvaluator) -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = .infinity
        configuration.timeoutIntervalForResource = .infinity
        configuration.httpShouldSetCookies = true
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.shouldUseExtendedBackgroundIdleMode = true
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }
}
