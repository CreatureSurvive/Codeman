import Foundation

/// `GET /api/node/info` — the one node route that is **not** admin-gated, so it doubles as the
/// "is this a Codeman server?" connection test and the per-node reachability probe.
struct NodeInfo: Decodable, Sendable, Hashable {
    var id: String
    var name: String
    var version: String
    var headless: Bool?
    var baseUrl: String?
    var capabilities: [String]?
}

/// An entry of `GET /api/nodes` → `nodes[]`, and the `local` object (which carries no health).
struct NodeRecordDTO: Codable, Sendable, Hashable, Identifiable {
    struct Health: Codable, Sendable, Hashable {
        var ok: Bool?
        var status: Int?
        var checkedAt: Double?
        var message: String?
    }

    var id: String
    var name: String
    var baseUrl: String
    var enabled: Bool?
    var headless: Bool?
    /// ⚠️ The server calls this **`lastHealth`**, not `health`.
    ///
    /// Decoding the wrong key is silent — the property is optional, so it simply stays `nil` and
    /// every remote node looks like one that has never been checked. A node the host had just
    /// health-checked `ok: true` therefore arrived with no health at all, and the UI fell through
    /// to whatever the client's own probe said. `health` is still accepted as a fallback so an
    /// older server keeps working.
    var health: Health?
    var hasToken: Bool?
    /// Never populated by the client and never persisted outside the Keychain-backed server
    /// record; declared only because the server echoes the field on some responses.
    var token: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, baseUrl, enabled, headless, lastHealth, health, hasToken, token
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        baseUrl = try container.decode(String.self, forKey: .baseUrl)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
        headless = try container.decodeIfPresent(Bool.self, forKey: .headless)
        health = try container.decodeIfPresent(Health.self, forKey: .lastHealth)
            ?? container.decodeIfPresent(Health.self, forKey: .health)
        hasToken = try container.decodeIfPresent(Bool.self, forKey: .hasToken)
        token = try container.decodeIfPresent(String.self, forKey: .token)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(baseUrl, forKey: .baseUrl)
        try container.encodeIfPresent(enabled, forKey: .enabled)
        try container.encodeIfPresent(headless, forKey: .headless)
        try container.encodeIfPresent(health, forKey: .lastHealth)
    }
}

struct NodeListResponse: Decodable, Sendable {
    var local: NodeRecordDTO
    var nodes: [NodeRecordDTO]
}

struct NodeTestResponse: Decodable, Sendable {
    var ok: Bool
    var status: Int?
    var message: String?
    var checkedAt: Double?
    var info: NodeInfo?

    private enum CodingKeys: String, CodingKey { case ok, status, message, checkedAt, info }

    /// ⚠️ **`info` arrives double-wrapped.** The host forwards the node's `/api/node/info`
    /// *response* verbatim, envelope and all, so the field is `{"success":true,"data":{…}}` rather
    /// than a bare `NodeInfo`.
    ///
    /// This was not a cosmetic mismatch. `info` is optional, but a key that is present and the
    /// wrong shape makes the synthesized decoder **throw**, so the whole `NodeTestResponse` failed
    /// to decode — and the call site's `try?` turned a perfectly healthy `{"ok":true}` into `nil`,
    /// which the UI reported as "Offline · Could not reach this node." The node was fine; the
    /// client could not read the answer.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decodeIfPresent(Bool.self, forKey: .ok) ?? false
        status = try container.decodeIfPresent(Int.self, forKey: .status)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        checkedAt = try container.decodeIfPresent(Double.self, forKey: .checkedAt)

        if let wrapped = ((try? container.decodeIfPresent(WrappedInfo.self, forKey: .info)) ?? nil),
           wrapped.data != nil {
            info = wrapped.data
        } else {
            info = try? container.decodeIfPresent(NodeInfo.self, forKey: .info)
        }
    }

    /// The forwarded `{"success":true,"data":{…}}` the host relays from the node.
    private struct WrappedInfo: Decodable {
        var success: Bool?
        var data: NodeInfo?
    }
}

struct UpsertNodeRequest: Encodable, Sendable {
    var name: String
    var baseUrl: String
    var token: String?
    var enabled: Bool?
}

struct PairNodeRequest: Encodable, Sendable {
    var baseUrl: String
    var code: String
    var name: String?
}

/// Reachability of a node as the UI presents it.
enum NodeReachability: Sendable, Hashable {
    case unknown
    case online(version: String?)
    case reconnecting(attempt: Int)
    case offline(reason: String)

    var isUsable: Bool {
        if case .online = self { return true }
        return false
    }
}

/// A node as the app models it: the server's record plus locally-tracked reachability.
struct NodeState: Sendable, Hashable, Identifiable {
    var id: String
    var name: String
    var baseURLString: String
    var isLocal: Bool
    var enabled: Bool
    var headless: Bool
    var reachability: NodeReachability

    var scope: NodeScope { isLocal ? .local : .remote(id: id) }

    init(dto: NodeRecordDTO, isLocal: Bool) {
        id = isLocal ? "local" : dto.id
        name = dto.name
        baseURLString = dto.baseUrl
        self.isLocal = isLocal
        enabled = dto.enabled ?? true
        headless = dto.headless ?? false

        reachability = Self.initialReachability(health: dto.health, isLocal: isLocal)
    }

    /// How a node reads *before* this client has probed it.
    ///
    /// ⚠️ The server's stored `health` is the result of **its** last check, which may be from
    /// hours ago or may never have run. Only `ok == true` is evidence of anything: `ok == false`
    /// is stale history and a missing `ok` is no answer at all. Both used to render as
    /// "Offline · Node did not respond." — a definitive-sounding error the client had not
    /// established and, in the reported case, was simply wrong. Anything short of a positive
    /// health check is `.unknown` ("Checking…") until `probeRemoteNodes` says otherwise.
    static func initialReachability(health: NodeRecordDTO.Health?, isLocal: Bool) -> NodeReachability {
        if isLocal { return .online(version: nil) }
        return health?.ok == true ? .online(version: nil) : .unknown
    }

    init(id: String, name: String, baseURLString: String, isLocal: Bool,
         enabled: Bool = true, headless: Bool = false, reachability: NodeReachability = .unknown) {
        self.id = id
        self.name = name
        self.baseURLString = baseURLString
        self.isLocal = isLocal
        self.enabled = enabled
        self.headless = headless
        self.reachability = reachability
    }
}
