import Foundation
import SwiftData

/// Non-secret server configuration storage.
protocol ServerPersisting: Sendable {
    func loadServers() async throws -> [ServerConfiguration]
    func upsert(_ server: ServerConfiguration) async throws
    func delete(id: UUID) async throws
}

/// SwiftData record for a saved server.
///
/// **Non-secret only.** Passwords and bearer tokens live in the Keychain keyed by `id`; this
/// store holds the address, display name, username, and the certificate pin the user explicitly
/// accepted (a public digest, not a secret).
@Model
final class ServerRecord {
    @Attribute(.unique) var id: UUID
    var displayName: String
    var baseURLString: String
    var username: String
    var usesBearerToken: Bool
    var pinnedCertificateSHA256: String?
    var createdAt: Date
    var lastUsedAt: Date?

    init(
        id: UUID,
        displayName: String,
        baseURLString: String,
        username: String,
        usesBearerToken: Bool,
        pinnedCertificateSHA256: String?,
        createdAt: Date,
        lastUsedAt: Date?
    ) {
        self.id = id
        self.displayName = displayName
        self.baseURLString = baseURLString
        self.username = username
        self.usesBearerToken = usesBearerToken
        self.pinnedCertificateSHA256 = pinnedCertificateSHA256
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }

    var configuration: ServerConfiguration {
        ServerConfiguration(
            id: id,
            displayName: displayName,
            baseURLString: baseURLString,
            username: username,
            usesBearerToken: usesBearerToken,
            pinnedCertificateSHA256: pinnedCertificateSHA256,
            createdAt: createdAt,
            lastUsedAt: lastUsedAt
        )
    }

    func apply(_ configuration: ServerConfiguration) {
        displayName = configuration.displayName
        baseURLString = configuration.baseURLString
        username = configuration.username
        usesBearerToken = configuration.usesBearerToken
        pinnedCertificateSHA256 = configuration.pinnedCertificateSHA256
        lastUsedAt = configuration.lastUsedAt
    }
}

/// Actor wrapping the SwiftData container so views never touch a `ModelContext` directly.
actor PersistenceStore: ServerPersisting {
    private let container: ModelContainer
    private let context: ModelContext

    init(inMemory: Bool = false) throws {
        let schema = Schema([ServerRecord.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        container = try ModelContainer(for: schema, configurations: [configuration])
        context = ModelContext(container)
        context.autosaveEnabled = false
    }

    func loadServers() async throws -> [ServerConfiguration] {
        let descriptor = FetchDescriptor<ServerRecord>(sortBy: [SortDescriptor(\.createdAt)])
        return try context.fetch(descriptor).map(\.configuration)
    }

    func upsert(_ server: ServerConfiguration) async throws {
        let id = server.id
        let descriptor = FetchDescriptor<ServerRecord>(predicate: #Predicate { $0.id == id })
        if let existing = try context.fetch(descriptor).first {
            existing.apply(server)
        } else {
            context.insert(ServerRecord(
                id: server.id,
                displayName: server.displayName,
                baseURLString: server.baseURLString,
                username: server.username,
                usesBearerToken: server.usesBearerToken,
                pinnedCertificateSHA256: server.pinnedCertificateSHA256,
                createdAt: server.createdAt,
                lastUsedAt: server.lastUsedAt
            ))
        }
        try context.save()
    }

    func delete(id: UUID) async throws {
        let descriptor = FetchDescriptor<ServerRecord>(predicate: #Predicate { $0.id == id })
        for record in try context.fetch(descriptor) { context.delete(record) }
        try context.save()
    }
}
