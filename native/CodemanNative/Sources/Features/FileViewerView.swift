import SwiftUI
import UIKit

/// One project file, with line numbers.
///
/// Read-only on purpose: `PUT /api/sessions/:id/file-content` exists, but editing needs the
/// no-truncation read (`edit=1`), optimistic concurrency on a sha256 `baseHash`, and CRLF/UTF-8
/// round-trip guards. Shipping a save button over the TRUNCATED preview buffer would silently
/// delete everything past line 500.
struct FileViewerView: View {
    let sessionID: String
    let path: String

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var file: FileContent?
    @State private var loadFailed: String?

    private var fileName: String { (path as NSString).lastPathComponent }

    var body: some View {
        NavigationStack {
            Group {
                if let file {
                    content(file)
                } else if let loadFailed {
                    ContentUnavailableView("Couldn't open the file", systemImage: "doc.badge.exclamationmark",
                                           description: Text(loadFailed))
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(fileName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { CodeDisplayMenu() }
                ToolbarItem(placement: .primaryAction) {
                    if let file {
                        ShareLink(item: file.content, preview: SharePreview(fileName)) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
            }
        }
        .task(id: path) { await load() }
        .accessibilityIdentifier("fileViewer")
    }

    @Environment(\.colorScheme) private var scheme
    @Bindable private var display = CodeDisplayOptions.shared

    private func content(_ file: FileContent) -> some View {
        let rawLines = file.content.components(separatedBy: "\n")
        let lines = display.showInvisibles ? rawLines.map(CodeDisplayOptions.revealing) : rawLines
        let language = SyntaxHighlighter.Language.named(file.extension_)
        // Tokenised up front so multi-line block comments carry correctly; doing it per row would
        // restart the state on every line.
        var inBlockComment = false
        let highlighted = lines.map {
            SyntaxHighlighter.highlight($0, language: language, scheme: scheme, inBlockComment: &inBlockComment)
        }
        // ⚠️ Horizontal scrolling is DISABLED when wrapping, or the content keeps its unwrapped
        // width and the wrap never takes effect.
        return ScrollView(display.wrapLines ? [.vertical] : [.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(highlighted.enumerated()), id: \.offset) { index, line in
                    HStack(alignment: .top, spacing: 10) {
                        // Fixed width so the gutter does not jitter as the number of digits grows.
                        Text("\(index + 1)")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .frame(width: 34, alignment: .trailing)
                        line
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            // ⚠️ `.topLeading`, and only when wrapping: a wrapped line grows
                            // downward, and the gutter number must stay beside its FIRST row
                            // rather than centring against the whole wrapped block.
                            .frame(maxWidth: display.wrapLines ? .infinity : nil, alignment: .leading)
                            .fixedSize(horizontal: !display.wrapLines, vertical: false)
                        if !display.wrapLines { Spacer(minLength: 0) }
                    }
                    .padding(.vertical, 1)
                }

                if file.truncated == true {
                    Label(
                        "Preview truncated\(file.totalLines.map { " — \($0) lines total" } ?? "")",
                        systemImage: "scissors"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 10)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .accessibilityIdentifier("fileViewer.content")
    }

    private func load() async {
        guard let api = model.apiClient else { return }
        do {
            file = try await api.fileContent(id: sessionID, path: path, scope: model.scope)
        } catch {
            loadFailed = error.localizedDescription
        }
    }
}
