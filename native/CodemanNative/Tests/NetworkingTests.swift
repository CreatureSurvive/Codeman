import Foundation
import Testing
@testable import Codeman

@Suite("Node scoping and URL construction")
struct NodeScopeTests {
    @Test("local scope leaves the API path alone")
    func localPath() {
        #expect(NodeScope.local.apiPath("/api/sessions") == "/api/sessions")
        #expect(NodeScope.local.apiPath("api/sessions") == "/api/sessions")
    }

    /// `app.all('/api/nodes/:nodeId/proxy/*')` — the remote path is the local one prefixed.
    @Test("remote scope prefixes the node proxy")
    func remotePath() {
        let scope = NodeScope.remote(id: "build-box")
        #expect(scope.apiPath("/api/sessions") == "/api/nodes/build-box/proxy/api/sessions")
        #expect(scope.apiPath("/api/quick-start") == "/api/nodes/build-box/proxy/api/quick-start")
    }

    @Test("a node id with URL-unsafe characters is escaped")
    func escapesNodeID() {
        let scope = NodeScope.remote(id: "box one")
        #expect(scope.apiPath("/api/sessions") == "/api/nodes/box%20one/proxy/api/sessions")
    }

    @Test("terminal socket paths differ by scope")
    func socketPaths() {
        #expect(NodeScope.local.terminalSocketPath(sessionID: "abc") == "/ws/sessions/abc/terminal")
        #expect(
            NodeScope.remote(id: "n1").terminalSocketPath(sessionID: "abc")
                == "/ws/nodes/n1/sessions/abc/terminal"
        )
    }

    @Test("nodeID and isLocal agree")
    func identity() {
        #expect(NodeScope.local.nodeID == "local")
        #expect(NodeScope.local.isLocal)
        #expect(NodeScope.remote(id: "x").nodeID == "x")
        #expect(!NodeScope.remote(id: "x").isLocal)
    }
}

@Suite("Server address normalisation")
struct ServerAddressTests {
    /// A LAN address must default to http: that is what a default Codeman serves, and it is the
    /// only cleartext ATS permits through `NSAllowsLocalNetworking`.
    @Test("private addresses default to http", arguments: [
        "192.168.1.20:3000", "10.0.0.5", "172.16.4.4:3000", "127.0.0.1:3000",
        "localhost:3000", "mac-studio.local:3000",
    ])
    func privateDefaultsToHTTP(address: String) throws {
        let normalized = try #require(ServerConfiguration.normalize(address))
        #expect(normalized.hasPrefix("http://"), "\(address) → \(normalized)")
    }

    /// A typo must not silently downgrade a public host to cleartext (ATS would block it anyway).
    @Test("public addresses default to https", arguments: [
        "box.tail1234.ts.net", "codeman.example.com:8443", "abc-def.trycloudflare.com",
    ])
    func publicDefaultsToHTTPS(address: String) throws {
        let normalized = try #require(ServerConfiguration.normalize(address))
        #expect(normalized.hasPrefix("https://"), "\(address) → \(normalized)")
    }

    @Test("an explicit scheme is preserved")
    func preservesScheme() throws {
        #expect(try #require(ServerConfiguration.normalize("http://box.example.com")) == "http://box.example.com")
        #expect(try #require(ServerConfiguration.normalize("https://192.168.1.9:3000")) == "https://192.168.1.9:3000")
    }

    @Test("trailing slashes, queries and fragments are stripped")
    func stripsNoise() throws {
        let normalized = try #require(ServerConfiguration.normalize("https://box.example.com/?a=1#x"))
        #expect(normalized == "https://box.example.com")
    }

    @Test("garbage is rejected", arguments: ["", "   ", "ftp://box", "://", "http://"])
    func rejectsGarbage(address: String) {
        #expect(ServerConfiguration.normalize(address) == nil)
    }

    @Test("172.32 is public, 172.31 is private")
    func rfc1918Boundary() throws {
        #expect(ServerConfiguration.isLocalNetworkHost("172.31.255.1"))
        #expect(!ServerConfiguration.isLocalNetworkHost("172.32.0.1"))
        #expect(!ServerConfiguration.isLocalNetworkHost("172.15.0.1"))
    }
}

@Suite("Credentials")
struct CredentialTests {
    @Test("basic auth builds the header the server compares against")
    func basicHeader() {
        // The server precomputes `'Basic ' + base64("user:pass")` and timing-safe compares it.
        let credential = ServerCredential.basic(username: "admin", password: "hunter2")
        #expect(credential.authorizationHeader == "Basic YWRtaW46aHVudGVyMg==")
    }

    @Test("bearer is used verbatim — verifyFederationBearer grants admin")
    func bearerHeader() {
        #expect(ServerCredential.bearer("tok_123").authorizationHeader == "Bearer tok_123")
    }

    @Test("no credential means no header, not an empty one")
    func noneHeader() {
        #expect(ServerCredential.none.authorizationHeader == nil)
    }

    @Test("a password containing a colon round-trips")
    func colonInPassword() throws {
        let credential = ServerCredential.basic(username: "admin", password: "a:b:c")
        let header = try #require(credential.authorizationHeader)
        let encoded = String(header.dropFirst("Basic ".count))
        let decoded = String(data: try #require(Data(base64Encoded: encoded)), encoding: .utf8)
        #expect(decoded == "admin:a:b:c")
    }

    @Test("keychain blobs round-trip both credential kinds")
    func keychainRoundTrip() throws {
        let basic = ServerCredential.basic(username: "alice", password: "p@ss w0rd")
        let encodedBasic = try #require(KeychainCredentialStore.encode(basic))
        #expect(KeychainCredentialStore.decode(encodedBasic) == basic)

        let bearer = ServerCredential.bearer("abc-123")
        let encodedBearer = try #require(KeychainCredentialStore.encode(bearer))
        #expect(KeychainCredentialStore.decode(encodedBearer) == bearer)

        // `.none` means "no secret to keep" — it must not encode to an empty stored password that
        // would later decode as a valid empty credential.
        #expect(KeychainCredentialStore.encode(.none) == nil)
        #expect(KeychainCredentialStore.decode("garbage") == .none)
    }

    /// Exercises the real Keychain, not just the blob encoding.
    ///
    /// The pure round-trip above passes even when `SecItemAdd` refuses the query outright, which
    /// is exactly the gap that shipped a dead Save button: an attribute that is not part of the
    /// item class's schema is rejected at the Security framework boundary and nowhere else.
    @Test("a credential round-trips through the real Keychain")
    func liveKeychainRoundTrip() async throws {
        let store = KeychainCredentialStore(service: "cloud.creature.codeman.native.tests")
        let id = UUID()
        try await store.remove(for: id)

        let basic = ServerCredential.basic(username: "alice", password: "p@ss w0rd")
        try await store.store(basic, for: id)
        var loaded = await store.credential(for: id)
        #expect(loaded == basic)

        // A second save must update in place, not fail as a duplicate item.
        let bearer = ServerCredential.bearer("tok_abc")
        try await store.store(bearer, for: id)
        loaded = await store.credential(for: id)
        #expect(loaded == bearer)

        // `.none` means "no secret to keep": the stored item goes away entirely.
        try await store.store(.none, for: id)
        loaded = await store.credential(for: id)
        #expect(loaded == .none)

        // Two servers must not share one item.
        let other = UUID()
        try await store.store(.bearer("other"), for: other)
        try await store.store(.bearer("mine"), for: id)
        let mine = await store.credential(for: id)
        let theirs = await store.credential(for: other)
        #expect(mine == .bearer("mine"))
        #expect(theirs == .bearer("other"))

        try await store.remove(for: id)
        try await store.remove(for: other)
    }
}

@Suite("Terminal WebSocket framing")
struct TerminalFramingTests {
    @Test("decodes output frames")
    func decodesOutput() {
        let frame = TerminalServerFrame.decode(#"{"t":"o","d":"hello\r\n"}"#)
        #expect(frame == .output("hello\r\n"))
    }

    /// The server wraps every batch in DEC 2026 markers. They are part of the byte stream and
    /// must reach Ghostty untouched.
    @Test("keeps DEC 2026 synchronised-update markers intact")
    func keepsSyncMarkers() throws {
        let esc = "\u{1B}"
        let payload = "\(esc)[?2026hpayload\(esc)[?2026l"
        // Build the frame the way the server does, so the ESC bytes are real rather than escaped
        // twice by the test source.
        let json = String(
            data: try JSONSerialization.data(withJSONObject: ["t": "o", "d": payload]),
            encoding: .utf8
        )
        guard case let .output(text)? = TerminalServerFrame.decode(try #require(json)) else {
            Issue.record("expected output")
            return
        }
        #expect(text == payload)
        #expect(text.hasPrefix("\(esc)[?2026h"))
        #expect(text.hasSuffix("\(esc)[?2026l"))
    }

    @Test("decodes control frames")
    func decodesControl() {
        #expect(TerminalServerFrame.decode(#"{"t":"c"}"#) == .clear)
        #expect(TerminalServerFrame.decode(#"{"t":"r"}"#) == .needsRefresh)
        #expect(TerminalServerFrame.decode(#"{"t":"ia","seq":7}"#) == .inputAck(7))
    }

    @Test("ignores malformed and unknown frames rather than treating them as output")
    func ignoresJunk() {
        #expect(TerminalServerFrame.decode("not json") == nil)
        #expect(TerminalServerFrame.decode(#"{"t":"zz"}"#) == nil)
        #expect(TerminalServerFrame.decode(#"{"t":"o"}"#) == nil)
        #expect(TerminalServerFrame.decode(#"{"t":"ia"}"#) == nil)
    }

    @Test("encodes input with the reliable-delivery tags")
    func encodesInput() throws {
        let encoded = try #require(TerminalClientFrame.input(text: "ls\r", seq: 3, clientID: "cid1").encoded())
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any]
        )
        #expect(object["t"] as? String == "i")
        #expect(object["d"] as? String == "ls\r")
        #expect(object["seq"] as? Int == 3)
        #expect(object["cid"] as? String == "cid1")
    }

    @Test("encodes resize with the viewport class")
    func encodesResize() throws {
        let encoded = try #require(
            TerminalClientFrame.resize(cols: 120, rows: 40, viewport: "tablet", force: false).encoded()
        )
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any]
        )
        #expect(object["t"] as? String == "z")
        #expect(object["c"] as? Int == 120)
        #expect(object["r"] as? Int == 40)
        #expect(object["v"] as? String == "tablet")
        #expect(object["f"] as? Bool == false)
    }

    @Test("omits the viewport key when unknown rather than sending null")
    func omitsViewport() throws {
        let encoded = try #require(
            TerminalClientFrame.resize(cols: 80, rows: 24, viewport: nil, force: true).encoded()
        )
        #expect(!encoded.contains("\"v\""))
        #expect(encoded.contains("\"f\":true"))
    }

    @Test("close codes map to the reasons the UI acts on")
    func closeCodes() {
        #expect(TerminalDisconnectReason(closeCode: .invalid, rawCode: 4003) == .forbidden)
        #expect(TerminalDisconnectReason(closeCode: .invalid, rawCode: 4004) == .sessionNotFound)
        #expect(TerminalDisconnectReason(closeCode: .invalid, rawCode: 4008) == .tooManyConnections)
        #expect(TerminalDisconnectReason(closeCode: .invalid, rawCode: 4009) == .sessionTerminated)
        #expect(TerminalDisconnectReason(closeCode: .invalid, rawCode: 4010) == .supersededByReconnect)
        #expect(TerminalDisconnectReason(closeCode: .normalClosure, rawCode: 1000) == .normal)
    }

    /// Retrying these would either spin against a session that is gone or burn the per-session
    /// slot cap; a supersede or a transport blip is exactly what *should* reconnect.
    @Test("terminal reasons stop the reconnect loop")
    func terminalReasons() {
        #expect(TerminalDisconnectReason.forbidden.isTerminal)
        #expect(TerminalDisconnectReason.sessionNotFound.isTerminal)
        #expect(TerminalDisconnectReason.sessionTerminated.isTerminal)
        #expect(!TerminalDisconnectReason.supersededByReconnect.isTerminal)
        #expect(!TerminalDisconnectReason.tooManyConnections.isTerminal)
        #expect(!TerminalDisconnectReason.transport("blip").isTerminal)
    }
}

@Suite("Backoff")
struct BackoffTests {
    @Test("grows and is capped")
    func growsAndCaps() {
        var backoff = Backoff(initial: .milliseconds(500), maximum: .seconds(30))
        // Full jitter with the randomness pinned to its ceiling gives the deterministic envelope.
        let ceilings = (0..<10).map { _ in backoff.next(randomness: { $0.upperBound }).seconds }
        #expect(ceilings[0] == 0.5)
        #expect(ceilings[1] == 1.0)
        #expect(ceilings[2] == 2.0)
        #expect(ceilings.last == 30.0)
        #expect(ceilings.allSatisfy { $0 <= 30.0 })
    }

    /// Full jitter can pick a tiny value; flooring at the initial delay stops a retry storm from
    /// collapsing into an effectively immediate loop.
    @Test("never returns less than the initial delay")
    func floorsAtInitial() {
        var backoff = Backoff(initial: .milliseconds(500), maximum: .seconds(30))
        for _ in 0..<10 {
            #expect(backoff.next(randomness: { _ in 0 }).seconds == 0.5)
        }
    }

    @Test("reset restarts the sequence")
    func resets() {
        var backoff = Backoff(initial: .milliseconds(500), maximum: .seconds(30))
        _ = backoff.next(randomness: { $0.upperBound })
        _ = backoff.next(randomness: { $0.upperBound })
        #expect(backoff.attempt == 2)
        backoff.reset()
        #expect(backoff.attempt == 0)
        #expect(backoff.next(randomness: { $0.upperBound }).seconds == 0.5)
    }
}

/// Node payloads, pinned to what a real Codeman host actually sends.
///
/// Both bugs these cover were silent: an optional property decoded from the wrong key just stays
/// `nil`, and a present-but-wrong-shaped key makes the *whole* response throw, which a `try?` at
/// the call site turns into "the node is unreachable". A healthy node reported itself as offline
/// and no test noticed, because nothing exercised the real JSON.
@Suite("Node payload decoding")
struct NodeDecodingTests {
    /// Verbatim from `GET /api/nodes` on a 1.19.3 host with one connected node.
    static let nodeListJSON = """
    {
      "local": { "id": "local", "name": "creaturecloud", "baseUrl": "http://10.8.0.2:3010",
                 "enabled": true, "headless": false },
      "nodes": [
        { "id": "0ctPUSZIH159jg", "name": "macbook", "baseUrl": "http://192.168.40.151:3000",
          "enabled": true, "createdAt": 1786717657340, "updatedAt": 1787499135619,
          "lastHealth": { "ok": true, "status": 200, "checkedAt": 1787499135619 },
          "hasToken": true }
      ]
    }
    """

    /// Verbatim from `POST /api/nodes/:id/test`. Note `info` is the node's own **envelope**,
    /// forwarded by the host rather than unwrapped.
    static let nodeTestJSON = """
    {
      "ok": true, "status": 200, "checkedAt": 1787499382951,
      "info": { "success": true,
                "data": { "id": "MacBook-Pro.local", "name": "macbook", "version": "1.19.3",
                          "headless": true, "baseUrl": "http://192.168.40.151:3000",
                          "capabilities": ["api", "sse", "websocket", "headless", "pairing"] } }
    }
    """

    @Test("the health key is lastHealth, and it is read")
    func readsLastHealth() throws {
        let response = try JSONDecoder().decode(NodeListResponse.self, from: Data(Self.nodeListJSON.utf8))
        let remote = try #require(response.nodes.first)
        #expect(remote.health?.ok == true)
        #expect(remote.hasToken == true)

        // A node the host says is healthy must not start out looking broken.
        let state = NodeState(dto: remote, isLocal: false)
        #expect(state.reachability == .online(version: nil))
    }

    @Test("a node with no health record reads as unknown, never as offline")
    func unknownWithoutHealth() throws {
        let json = #"{"id":"n1","name":"box","baseUrl":"http://x:3000","enabled":true}"#
        let dto = try JSONDecoder().decode(NodeRecordDTO.self, from: Data(json.utf8))
        #expect(NodeState(dto: dto, isLocal: false).reachability == .unknown)
    }

    @Test("a probe's double-wrapped info decodes instead of throwing")
    func decodesWrappedProbeInfo() throws {
        let response = try JSONDecoder().decode(NodeTestResponse.self, from: Data(Self.nodeTestJSON.utf8))
        #expect(response.ok)
        #expect(response.status == 200)
        // The whole response used to fail here, turning ok:true into "could not reach this node".
        #expect(response.info?.version == "1.19.3")
        #expect(response.info?.id == "MacBook-Pro.local")
    }

    @Test("a flat info object still decodes")
    func decodesFlatProbeInfo() throws {
        let json = #"{"ok":true,"info":{"id":"n","name":"n","version":"1.0.0"}}"#
        let response = try JSONDecoder().decode(NodeTestResponse.self, from: Data(json.utf8))
        #expect(response.info?.version == "1.0.0")
    }

    @Test("a failed probe decodes without an info object")
    func decodesFailedProbe() throws {
        let json = #"{"ok":false,"status":0,"message":"connect ECONNREFUSED"}"#
        let response = try JSONDecoder().decode(NodeTestResponse.self, from: Data(json.utf8))
        #expect(!response.ok)
        #expect(response.message == "connect ECONNREFUSED")
        #expect(response.info == nil)
    }

    /// Remote work must go through the host's proxy — never straight at the node's own address,
    /// which the phone usually cannot reach and which would bypass the host's auth entirely.
    @Test("remote calls are addressed to the host, not the node")
    func remoteCallsUseTheHostProxy() {
        let scope = NodeScope.remote(id: "0ctPUSZIH159jg")
        #expect(scope.apiPath("/api/sessions") == "/api/nodes/0ctPUSZIH159jg/proxy/api/sessions")
        #expect(scope.terminalSocketPath(sessionID: "abc")
                == "/ws/nodes/0ctPUSZIH159jg/sessions/abc/terminal")
    }
}
