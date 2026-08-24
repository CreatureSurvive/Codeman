import SwiftUI

/// The command list that appears when the message starts with `/`.
///
/// ⚠️ Triggers only when the slash is the FIRST character of the message. A slash appears in every
/// file path an agent conversation contains, and popping a picker mid-sentence over `src/web` would
/// make the composer unusable.
struct SlashCommandPicker: View {
    let commands: [SlashCommand]
    let onSelect: (SlashCommand) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(commands) { command in
                        Button { onSelect(command) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("/\(command.name)")
                                    .font(.subheadline.weight(.medium).monospaced())
                                    .foregroundStyle(.primary)

                                if let description = command.description {
                                    Text(description)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer(minLength: 0)

                                if let label = command.scope.label {
                                    Text(label)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("slash.command.\(command.name)")

                        if command.id != commands.last?.id {
                            Divider().padding(.leading, 14)
                        }
                    }
                }
            }
            // Tall enough to browse, short enough to leave the conversation visible.
            .frame(maxHeight: 240)
        }
        .glassPanel(cornerRadius: 18)
        .accessibilityIdentifier("slash.picker")
    }
}

/// When to show the picker, and what to filter by.
///
/// Pure so the trigger rule is testable: getting it wrong either hides the feature or breaks
/// ordinary typing.
enum SlashCommandTrigger {
    /// The query after `/`, or `nil` when the picker should stay hidden.
    ///
    /// ⚠️ Hidden once a space is typed. `/model opus` is a command WITH AN ARGUMENT — the user has
    /// finished choosing, and a list that stays up would cover the field while they type the rest.
    static func query(in text: String) -> String? {
        guard text.hasPrefix("/") else { return nil }
        let rest = text.dropFirst()
        guard !rest.contains(" "), !rest.contains("\n") else { return nil }
        return String(rest)
    }
}
