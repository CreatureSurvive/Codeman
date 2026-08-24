import Foundation

/// A command the session can run, from `GET /api/sessions/:id/slash-commands`.
///
/// The server enumerates real files in `<workspace>/.claude/commands` and `~/.claude/commands` and
/// merges in the CLI's built-ins, so this list is what the user can ACTUALLY type — not a
/// hardcoded guess that drifts from their setup.
struct SlashCommand: Decodable, Sendable, Identifiable, Hashable {
    enum Scope: String, Decodable, Sendable {
        case project, user, builtin

        /// Shown as a trailing tag so the origin of a command is visible.
        var label: String? {
            switch self {
            case .project: return "project"
            case .user: return "user"
            case .builtin: return nil
            }
        }
    }

    var name: String
    var description: String?
    var scope: Scope

    var id: String { name }
}

struct SlashCommandsResponse: Decodable, Sendable {
    var available: Bool
    var reason: String?
    var commands: [SlashCommand]

    private enum CodingKeys: String, CodingKey { case available, reason, commands }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        available = ((try? container.decodeIfPresent(Bool.self, forKey: .available)) ?? nil) ?? false
        reason = (try? container.decodeIfPresent(String.self, forKey: .reason)) ?? nil
        commands = ((try? container.decodeIfPresent([SlashCommand].self, forKey: .commands)) ?? nil) ?? []
    }
}
