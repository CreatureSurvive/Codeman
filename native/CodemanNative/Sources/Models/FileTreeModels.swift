import Foundation

/// A node of `GET /api/sessions/:id/files`.
///
/// The server walks the session's working directory, already excluding the heavy generated trees
/// (`.git`, `node_modules`, `dist`, `build`, `coverage`, …) and capping at 5000 entries — so this
/// is project scope by construction, not a whole-filesystem browser.
struct FileTreeNode: Decodable, Sendable, Identifiable, Hashable {
    var name: String
    /// Relative to the session's working directory.
    var path: String
    var type: NodeType
    var size: Int?
    var extension_: String?
    var children: [FileTreeNode]?

    var id: String { path }
    var isDirectory: Bool { type == .directory }

    enum NodeType: String, Decodable, Sendable {
        case file, directory
    }

    private enum CodingKeys: String, CodingKey {
        case name, path, type, size, children
        case extension_ = "extension"
    }

    /// Every file beneath this node, flattened — the search list works on paths, not on the tree.
    var allFiles: [FileTreeNode] {
        if !isDirectory { return [self] }
        return (children ?? []).flatMap(\.allFiles)
    }
}

/// Response of `GET /api/sessions/:id/files`.
struct FileTreeResponse: Decodable, Sendable {
    var root: String
    var tree: [FileTreeNode]
    var totalFiles: Int
    var totalDirectories: Int
    /// True when the 5000-entry cap or the depth limit cut the walk short.
    var truncated: Bool
}

/// Response of `GET /api/sessions/:id/file-content`.
struct FileContent: Decodable, Sendable {
    var path: String
    var content: String
    var size: Int?
    var totalLines: Int?
    /// ⚠️ The preview read truncates at 500 lines. A viewer must say so rather than implying the
    /// file simply ends there.
    var truncated: Bool?
    var extension_: String?
    var editable: Bool?

    private enum CodingKeys: String, CodingKey {
        case path, content, size, totalLines, truncated, editable
        case extension_ = "extension"
    }
}
