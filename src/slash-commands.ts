/**
 * @fileoverview Discovery of Claude Code slash commands — the PURE parse half.
 *
 * A slash command is a markdown file: `~/.claude/commands/<name>.md` for user-level commands and
 * `<project>/.claude/commands/<name>.md` for project-level ones. The file's *content* is the
 * prompt; what a picker needs is the name and a one-line description.
 *
 * ⚠️ Two description formats, and both occur in the wild. The documented one is YAML frontmatter
 * with a `description:` key; the one every command on this machine actually uses is a leading H1
 * (measured: 20 of 20 user commands, 0 with frontmatter). Supporting only the documented format
 * would produce a picker of nameless rows.
 *
 * IO lives in the route; everything here is pure so the shapes can be tested against fixtures.
 */

/** Where a command came from, which decides precedence and how it is labelled. */
export type SlashCommandScope = 'project' | 'user' | 'builtin';

export interface SlashCommand {
  /** Invoked as `/<name>`. */
  name: string;
  /** One line for the picker. */
  description?: string;
  scope: SlashCommandScope;
  /** Absent for built-ins, which have no file. */
  path?: string;
  /** `namespace:name` when the file sits in a subdirectory. */
  namespace?: string;
}

/**
 * Claude Code's own commands.
 *
 * ⚠️ Hardcoded because they are not files — they are built into the CLI, so nothing on disk can
 * be enumerated. Kept deliberately short: only the ones that are stable and useful from a phone.
 * A command listed here that a future CLI drops is a dead menu entry, so this errs on the side of
 * omission rather than completeness.
 */
export const BUILTIN_SLASH_COMMANDS: SlashCommand[] = [
  { name: 'clear', description: 'Clear the conversation history', scope: 'builtin' },
  { name: 'compact', description: 'Compact the conversation to free context', scope: 'builtin' },
  { name: 'context', description: 'Show what is currently in the context window', scope: 'builtin' },
  { name: 'cost', description: 'Show token usage and cost for this session', scope: 'builtin' },
  { name: 'effort', description: 'Change the effort level for this session', scope: 'builtin' },
  { name: 'help', description: 'List available commands', scope: 'builtin' },
  { name: 'init', description: 'Generate a CLAUDE.md for this project', scope: 'builtin' },
  { name: 'model', description: 'Switch the model for this session', scope: 'builtin' },
  { name: 'review', description: 'Review the current changes', scope: 'builtin' },
  { name: 'status', description: 'Show account, model and connection status', scope: 'builtin' },
];

/**
 * Pull a one-line description out of a command file.
 *
 * Reads only the head of the file — a command body can be thousands of words, and none of it past
 * the title matters to a picker.
 */
export function parseCommandDescription(head: string): string | undefined {
  const text = head.replace(/^﻿/, '');

  // Documented format: YAML frontmatter with a description key.
  if (text.startsWith('---')) {
    const end = text.indexOf('\n---', 3);
    const block = end === -1 ? text : text.slice(0, end);
    const match = block.match(/^description:\s*(.+)$/m);
    if (match) return cleanDescription(match[1]);
  }

  for (const rawLine of text.split('\n')) {
    const line = rawLine.trim();
    if (!line || line === '---') continue;
    // Actual format on disk: a leading H1 is the command's title.
    if (line.startsWith('#')) return cleanDescription(line.replace(/^#+\s*/, ''));
    // A file that opens with prose rather than a heading: take that first line.
    if (!line.startsWith('<!--')) return cleanDescription(line);
  }
  return undefined;
}

function cleanDescription(raw: string): string | undefined {
  const cleaned = raw
    .trim()
    .replace(/^["']|["']$/g, '')
    // Strip inline markdown so a picker row is plain text.
    .replace(/[*_`]/g, '')
    .trim();
  if (!cleaned) return undefined;
  return cleaned.length > 120 ? `${cleaned.slice(0, 117)}…` : cleaned;
}

/** `foo.md` → `foo`; `git/commit.md` → `git:commit`, matching how Claude Code namespaces them. */
export function commandNameFromRelativePath(relativePath: string): string | null {
  if (!relativePath.endsWith('.md')) return null;
  const withoutExtension = relativePath.slice(0, -3);
  const parts = withoutExtension.split('/').filter(Boolean);
  if (parts.length === 0) return null;
  // Reject anything that could not be typed after a slash.
  if (parts.some((part) => !/^[A-Za-z0-9._-]+$/.test(part))) return null;
  return parts.join(':');
}

/**
 * Merge the three sources into one list.
 *
 * ⚠️ Precedence is project → user → builtin, matching Claude Code: a project command of the same
 * name shadows a user one, and both shadow a built-in. Listing duplicates would offer the user a
 * choice the CLI does not actually give them.
 */
export function mergeSlashCommands(
  project: SlashCommand[],
  user: SlashCommand[],
  builtin: SlashCommand[] = BUILTIN_SLASH_COMMANDS
): SlashCommand[] {
  const seen = new Set<string>();
  const out: SlashCommand[] = [];
  for (const group of [project, user, builtin]) {
    for (const command of group) {
      if (seen.has(command.name)) continue;
      seen.add(command.name);
      out.push(command);
    }
  }
  return out.sort((a, b) => a.name.localeCompare(b.name));
}

/**
 * Filter for what the user has typed after the slash.
 *
 * Prefix matches rank above substring matches, because typing `/mo` should surface `model` before
 * `gortex-commit-model`.
 */
export function filterSlashCommands(commands: SlashCommand[], query: string): SlashCommand[] {
  const needle = query.trim().toLowerCase();
  if (!needle) return commands;
  const prefix: SlashCommand[] = [];
  const contains: SlashCommand[] = [];
  for (const command of commands) {
    const name = command.name.toLowerCase();
    if (name.startsWith(needle)) prefix.push(command);
    else if (name.includes(needle)) contains.push(command);
  }
  return [...prefix, ...contains];
}
