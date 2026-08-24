import Foundation

/// Finds image file paths inside a message so they can render as pictures, not text.
///
/// ⚠️ Codeman's input path is a TERMINAL: an attachment is uploaded and its **path** is typed into
/// the prompt, because that is what the agent can open. So a message the user sent with a picture
/// arrives in the transcript as a line of text ending in `/…/paste-1787577301065.jpg`, and rendering
/// it verbatim shows a path where the user attached an image.
///
/// This is deliberately narrow. It matches absolute paths with an image extension and nothing else:
/// a message that merely *mentions* a `.png` in prose still gets a thumbnail, which is acceptable,
/// but a relative or quoted fragment does not, which keeps prose from being chewed up.
enum AttachedImagePaths {
    /// Extensions worth previewing. Mirrors what the attachment routes will serve as an image.
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif"]

    struct Match: Equatable, Identifiable, Sendable {
        var path: String
        var id: String { path }
    }

    /// Absolute paths ending in an image extension.
    ///
    /// ⚠️ The leading lookbehind is load-bearing. Without it, `images/logo.png` matches its own
    /// `/logo.png` substring and a relative mention in prose sprouts a thumbnail — the path has to
    /// START the token, not merely appear inside one.
    private static let pattern = try? NSRegularExpression(
        pattern: #"(?<=^|[\s(\[])(/(?:[^\s"'<>|]+/)*[^\s"'<>|]+\.(?:png|jpe?g|gif|webp|heic|heif))"#,
        options: [.caseInsensitive]
    )

    static func matches(in text: String) -> [Match] {
        guard let pattern, !text.isEmpty else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var seen: Set<String> = []
        var found: [Match] = []
        for result in pattern.matches(in: text, range: range) {
            guard let swiftRange = Range(result.range, in: text) else { continue }
            let path = String(text[swiftRange])
            guard !seen.contains(path) else { continue }
            seen.insert(path)
            found.append(Match(path: path))
        }
        return found
    }

    /// The message with its image paths removed, for rendering alongside the thumbnails.
    ///
    /// Returns `nil` when nothing but paths remains — an attachment sent with no words should show
    /// as a picture and not as an empty bubble with a stray blank line.
    static func strippingPaths(from text: String) -> String? {
        var remaining = text
        for match in matches(in: text) {
            remaining = remaining.replacingOccurrences(of: match.path, with: "")
        }
        let cleaned = remaining
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return cleaned.isEmpty ? nil : cleaned
    }
}
