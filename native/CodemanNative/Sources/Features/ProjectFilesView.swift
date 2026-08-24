import SwiftUI

/// The session's project files, as a browsable tree with search.
///
/// Scoped to the session's working directory by the server, which also excludes the generated
/// trees — so this is "the project", not a filesystem browser. `DirectoryBrowserView` remains the
/// filesystem picker used when LINKING a case; the two answer different questions and deliberately
/// stay separate.
struct ProjectFilesView: View {
    let sessionID: String

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var response: FileTreeResponse?
    @State private var loadFailed: String?
    @State private var expanded: Set<String> = []
    @State private var search = ""
    @State private var opened: OpenedFile?

    private struct OpenedFile: Identifiable {
        let path: String
        var id: String { path }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let response {
                    list(response)
                } else if let loadFailed {
                    ContentUnavailableView("Couldn't load files", systemImage: "folder.badge.questionmark",
                                           description: Text(loadFailed))
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Files")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close")
                }
            }
            // Bottom placement keeps the field reachable one-handed, which matters in a sheet that
            // is mostly a long list.
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search files")
        }
        .task(id: sessionID) { await load() }
        .sheet(item: $opened) { file in
            FileViewerView(sessionID: sessionID, path: file.path)
        }
        .accessibilityIdentifier("projectFiles")
    }

    @ViewBuilder
    private func list(_ response: FileTreeResponse) -> some View {
        List {
            if search.isEmpty {
                // The tree, expanded on demand.
                FileTreeRows(nodes: response.tree, depth: 0, expanded: $expanded) { opened = OpenedFile(path: $0) }
            } else {
                // ⚠️ Search flattens to FILES only. Matching directories too would bury the file
                // you are looking for under the folders on the way to it.
                let matches = response.tree
                    .flatMap(\.allFiles)
                    .filter { $0.path.localizedCaseInsensitiveContains(search) }
                    .prefix(200)
                if matches.isEmpty {
                    ContentUnavailableView.search(text: search)
                } else {
                    ForEach(Array(matches)) { file in
                        Button { opened = OpenedFile(path: file.path) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Label(file.name, systemImage: "doc.text").font(.body)
                                Text(file.path)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if response.truncated {
                // Say it rather than letting a capped walk look like the whole project.
                Text("Listing was capped; some files are not shown.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.plain)
    }

    private func load() async {
        guard let api = model.apiClient else { return }
        do {
            response = try await api.projectFiles(id: sessionID, depth: 6, scope: model.scope)
        } catch {
            loadFailed = error.localizedDescription
        }
    }
}


/// One level of the tree, recursing into expanded folders.
///
/// ⚠️ A separate `View` rather than a recursive `@ViewBuilder` method: a function that returns
/// `some View` and calls itself defines its opaque type in terms of itself, which does not compile.
/// A struct's `body` can recurse because the type is named.
private struct FileTreeRows: View {
    let nodes: [FileTreeNode]
    let depth: Int
    @Binding var expanded: Set<String>
    let onOpen: (String) -> Void

    var body: some View {
        ForEach(nodes) { node in
            if node.isDirectory {
                Button {
                    if expanded.contains(node.path) { expanded.remove(node.path) }
                    else { expanded.insert(node.path) }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: expanded.contains(node.path) ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 12)
                        Image(systemName: expanded.contains(node.path) ? "folder" : "folder.fill")
                            .foregroundStyle(.secondary)
                        Text(node.name)
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, CGFloat(depth) * 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("projectFiles.dir")

                if expanded.contains(node.path), let children = node.children {
                    FileTreeRows(nodes: children, depth: depth + 1, expanded: $expanded, onOpen: onOpen)
                }
            } else {
                Button { onOpen(node.path) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text").foregroundStyle(.secondary)
                        Text(node.name)
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, CGFloat(depth) * 14 + 20)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("projectFiles.file")
            }
        }
    }
}
