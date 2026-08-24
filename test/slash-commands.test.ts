import { describe, it, expect } from 'vitest';
import {
  BUILTIN_SLASH_COMMANDS,
  commandNameFromRelativePath,
  filterSlashCommands,
  mergeSlashCommands,
  parseCommandDescription,
  type SlashCommand,
} from '../src/slash-commands.js';

describe('parseCommandDescription', () => {
  // The documented format.
  it('reads a description out of YAML frontmatter', () => {
    const head = ['---', 'description: Review the diff for regressions', 'model: opus', '---', '', '# Title'].join(
      '\n'
    );
    expect(parseCommandDescription(head)).toBe('Review the diff for regressions');
  });

  // ⚠️ The format every command on a real machine actually uses — measured 20 of 20 user commands
  // with an H1 and none with frontmatter. Supporting only frontmatter yields a nameless picker.
  it('falls back to the leading H1, which is what commands really use', () => {
    expect(parseCommandDescription('# Debug with Gortex\n\n1. Localize the symptom')).toBe('Debug with Gortex');
  });

  it('takes the first prose line when there is no heading', () => {
    expect(parseCommandDescription('Run the release checklist.\n\nSteps:')).toBe('Run the release checklist.');
  });

  it('strips inline markdown so a row renders as plain text', () => {
    expect(parseCommandDescription('# Run `npm test` **now**')).toBe('Run npm test now');
  });

  it('truncates a description too long for one row', () => {
    const long = `# ${'x'.repeat(200)}`;
    const parsed = parseCommandDescription(long)!;
    expect(parsed.length).toBeLessThanOrEqual(120);
    expect(parsed.endsWith('…')).toBe(true);
  });

  it('returns nothing for an empty or comment-only file', () => {
    expect(parseCommandDescription('')).toBeUndefined();
    expect(parseCommandDescription('   \n\n')).toBeUndefined();
  });
});

describe('commandNameFromRelativePath', () => {
  it('maps a file to the name typed after the slash', () => {
    expect(commandNameFromRelativePath('deploy.md')).toBe('deploy');
  });

  // Claude Code namespaces a nested command with a colon.
  it('namespaces a nested command', () => {
    expect(commandNameFromRelativePath('git/commit.md')).toBe('git:commit');
  });

  it('rejects non-markdown and untypeable names', () => {
    expect(commandNameFromRelativePath('README.txt')).toBeNull();
    expect(commandNameFromRelativePath('has space.md')).toBeNull();
    expect(commandNameFromRelativePath('.md')).toBeNull();
  });
});

describe('mergeSlashCommands', () => {
  const make = (name: string, scope: SlashCommand['scope']): SlashCommand => ({ name, scope });

  // Matches Claude Code's own precedence; listing duplicates would offer a choice the CLI does
  // not actually give.
  it('shadows user commands with project ones, and built-ins with both', () => {
    const merged = mergeSlashCommands(
      [make('review', 'project')],
      [make('review', 'user'), make('deploy', 'user')],
      [make('review', 'builtin'), make('clear', 'builtin')]
    );
    expect(merged.find((c) => c.name === 'review')?.scope).toBe('project');
    expect(merged.map((c) => c.name)).toEqual(['clear', 'deploy', 'review']);
  });

  it('includes the built-ins by default', () => {
    const merged = mergeSlashCommands([], []);
    expect(merged.map((c) => c.name)).toEqual(BUILTIN_SLASH_COMMANDS.map((c) => c.name).sort());
  });
});

describe('filterSlashCommands', () => {
  const commands: SlashCommand[] = [
    { name: 'model', scope: 'builtin' },
    { name: 'gortex-commit-model', scope: 'user' },
    { name: 'compact', scope: 'builtin' },
  ];

  // Typing `/mo` should surface `model`, not a command that merely contains it.
  it('ranks prefix matches above substring matches', () => {
    expect(filterSlashCommands(commands, 'mo').map((c) => c.name)).toEqual(['model', 'gortex-commit-model']);
  });

  it('is case-insensitive and returns everything for an empty query', () => {
    expect(filterSlashCommands(commands, 'MODEL').map((c) => c.name)).toEqual(['model', 'gortex-commit-model']);
    expect(filterSlashCommands(commands, '  ')).toHaveLength(3);
  });
});
