import SwiftUI

/// Native directory browser over `GET /api/filesystem/browse`.
///
/// The server computes `roots[]` and has already scoped them for the caller — in multi-user mode
/// a non-admin gets only their own case space, because per-user spaces live inside `homedir()`
/// and a `Home` root would expose every other user's workspace. So this view renders exactly the
/// roots it is handed and never synthesises one.
struct DirectoryBrowserView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let initialPath: String?
    let sessionID: String?
    let onSelect: (String) -> Void

    @State private var listing: FilesystemListing?
    @State private var loadState: LoadState = .loading
    @State private var showHidden = false
    @State private var path: String?

    private enum LoadState: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    var body: some View {
        List {
            if let listing {
                if !listing.roots.isEmpty {
                    Section("Roots") {
                        ForEach(listing.roots) { root in
                            Button {
                                Task { await load(path: root.path) }
                            } label: {
                                Label(root.label, systemImage: "externaldrive")
                            }
                            .accessibilityIdentifier("browser.root.\(root.label)")
                        }
                    }
                }

                Section {
                    if let parent = listing.parent {
                        Button {
                            Task { await load(path: parent) }
                        } label: {
                            Label("Up one level", systemImage: "arrow.up.left")
                        }
                        .accessibilityIdentifier("browser.up")
                    }

                    ForEach(listing.entries) { entry in
                        if entry.isDirectory {
                            Button {
                                Task { await load(path: entry.path) }
                            } label: {
                                HStack {
                                    Image(systemName: entry.symlink == true ? "folder.badge.questionmark" : "folder.fill")
                                        .foregroundStyle(Color.accentColor)
                                    Text(entry.name)
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                            .accessibilityIdentifier("browser.dir.\(entry.name)")
                        } else {
                            HStack {
                                Image(systemName: symbol(for: entry)).foregroundStyle(.secondary)
                                Text(entry.name).foregroundStyle(.secondary)
                                Spacer()
                                if let size = entry.size {
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }

                    if listing.entries.isEmpty {
                        Text("Empty directory").foregroundStyle(.secondary)
                    }
                } header: {
                    Text(listing.path).font(.caption).textCase(nil)
                } footer: {
                    if listing.truncated {
                        Text("This directory has more entries than the server returns at once.")
                    }
                }
            } else if case let .failed(message) = loadState {
                ContentUnavailableView {
                    Label("Could not list that directory", systemImage: "folder.badge.questionmark")
                } description: {
                    Text(message)
                } actions: {
                    Button("Retry") { Task { await load(path: path) } }
                }
            } else {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
        }
        .navigationTitle("Choose Directory")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Toggle("Show hidden files", isOn: $showHidden)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityIdentifier("browser.options")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Use This") {
                    guard let current = listing?.path else { return }
                    onSelect(current)
                    // This screen is pushed, so `dismiss` pops back to the caller.
                    dismiss()
                }
                .disabled(listing == nil)
                .accessibilityIdentifier("browser.use")
            }
        }
        .onChange(of: showHidden) { _, _ in Task { await load(path: path) } }
        .task { await load(path: initialPath) }
    }

    private func symbol(for entry: FilesystemEntry) -> String {
        switch entry.previewKind {
        case .image: "photo"
        case .text: "doc.text"
        case .document: "doc.richtext"
        case nil: "doc"
        }
    }

    private func load(path newPath: String?) async {
        guard let api = model.apiClient else { return }
        loadState = .loading
        do {
            let result = try await api.browse(
                path: newPath,
                sessionID: sessionID,
                showHidden: showHidden,
                scope: model.scope
            )
            listing = result
            path = result.path
            loadState = .loaded
        } catch {
            loadState = .failed((error as? any LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }
}
