import Foundation
import Security

/// Secret storage for server credentials.
protocol CredentialStoring: Sendable {
    func credential(for serverID: UUID) async -> ServerCredential
    func store(_ credential: ServerCredential, for serverID: UUID) async throws
    func remove(for serverID: UUID) async throws
}

enum KeychainError: Error, LocalizedError {
    case unexpectedStatus(OSStatus)
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case let .unexpectedStatus(status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Keychain error: \(message)"
        case .encodingFailed:
            return "The credential could not be encoded for storage."
        }
    }
}

/// Keychain-backed credential storage.
///
/// One `kSecClassGenericPassword` item per server: `kSecAttrService` names the app and
/// `kSecAttrAccount` carries the server's UUID, which together form the item's primary key.
///
/// ⚠️ **Generic, not internet, password.** The obvious-looking `kSecClassInternetPassword` is the
/// wrong class here: its schema has no `kSecAttrService`, so every `SecItemAdd` came back
/// `errSecNoSuchAttr` (-25303) and saving a server failed at its first line. Nothing above this
/// type can detect that — the encoding round-trip is pure and passes either way — so
/// `liveKeychainRoundTrip` in `NetworkingTests` exercises the real Security framework.
///
/// `kSecAttrAccessibleAfterFirstUnlock` so a background reconnect after a device reboot still has
/// the credential; the app never needs it while the device is locked at first boot.
///
/// Secrets never leave this type except as a `ServerCredential`. They are never written to
/// `UserDefaults`, never logged in any privacy mode, and never placed in a URL.
actor KeychainCredentialStore: CredentialStoring {
    private let service: String

    /// No default: the service name decides whose credentials this store can see, so every call
    /// site says which set it means rather than inheriting one by omission.
    init(service: String) {
        self.service = service
    }

    /// The credential kind is stored alongside the secret so a bearer token is never mistaken for
    /// a password. Encoded as a single UTF-8 blob: `"basic\u{0}<username>\u{0}<password>"` or
    /// `"bearer\u{0}<token>"`.
    private static let separator: Character = "\u{0}"

    func credential(for serverID: UUID) async -> ServerCredential {
        var query = baseQuery(for: serverID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let blob = String(data: data, encoding: .utf8)
        else { return .none }

        return Self.decode(blob)
    }

    func store(_ credential: ServerCredential, for serverID: UUID) async throws {
        guard let blob = Self.encode(credential) else {
            // `.none` means "no secret to keep" — remove any stale item rather than storing an
            // empty one that would later decode as a valid empty password.
            try await remove(for: serverID)
            return
        }
        guard let data = blob.data(using: .utf8) else { throw KeychainError.encodingFailed }

        let query = baseQuery(for: serverID)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw KeychainError.unexpectedStatus(updateStatus) }

        var insert = query
        insert.merge(attributes) { _, new in new }
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
    }

    func remove(for serverID: UUID) async throws {
        let status = SecItemDelete(baseQuery(for: serverID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Deletes every credential stored under `service`.
    ///
    /// Synchronous and `static` so app start-up can purge the UI-test service before the model is
    /// built, without racing the bootstrap task.
    static func removeAll(service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            Log.store.error("Keychain purge failed: OSStatus \(status, privacy: .public)")
        }
    }

    private func baseQuery(for serverID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: serverID.uuidString,
        ]
    }

    // MARK: - Encoding (internal for unit tests)

    static func encode(_ credential: ServerCredential) -> String? {
        switch credential {
        case let .basic(username, password):
            "basic\(separator)\(username)\(separator)\(password)"
        case let .bearer(token):
            "bearer\(separator)\(token)"
        case .none:
            nil
        }
    }

    static func decode(_ blob: String) -> ServerCredential {
        let parts = blob.split(separator: separator, omittingEmptySubsequences: false).map(String.init)
        switch parts.first {
        case "basic" where parts.count >= 3:
            // Re-join the tail so a password containing the separator round-trips. (It cannot
            // today — NUL is not typeable — but the invariant should not depend on that.)
            return .basic(username: parts[1], password: parts[2...].joined(separator: String(separator)))
        case "bearer" where parts.count >= 2:
            return .bearer(parts[1...].joined(separator: String(separator)))
        default:
            return .none
        }
    }
}
