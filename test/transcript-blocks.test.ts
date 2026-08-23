import { describe, it, expect } from 'vitest';
import { parseTranscriptBlocks, type ToolCallBlock, type DiffBlock } from '../src/transcript-blocks.js';

/**
 * Shapes here are copied from a real Claude Code transcript, not invented: entry
 * types, block types and field names were read off a live 12.5 MB JSONL file
 * (630 tool_use / 630 tool_result / 299 thinking / 201 text blocks). If Claude
 * changes the format these fixtures are what should be updated first.
 */
function jsonl(...entries: unknown[]): string {
  return entries.map((entry) => JSON.stringify(entry)).join('\n');
}

const assistant = (uuid: string, content: unknown[]) => ({
  type: 'assistant',
  uuid,
  timestamp: '2026-08-23T19:28:46.969Z',
  message: { role: 'assistant', content },
});

const user = (uuid: string, content: unknown, extra: Record<string, unknown> = {}) => ({
  type: 'user',
  uuid,
  timestamp: '2026-08-23T19:28:40.000Z',
  message: { role: 'user', content },
  ...extra,
});

describe('parseTranscriptBlocks', () => {
  it('reads a plain user prompt, which arrives as a bare string not a block list', () => {
    const { blocks } = parseTranscriptBlocks(jsonl(user('u1', 'ship the transcript view')));
    expect(blocks).toEqual([expect.objectContaining({ kind: 'user', text: 'ship the transcript view', id: 'u1:0' })]);
  });

  it('emits assistant prose and keeps reasoning that carries text', () => {
    const { blocks } = parseTranscriptBlocks(
      jsonl(
        assistant('a1', [
          { type: 'thinking', thinking: 'weigh the options', signature: 'CAIS...' },
          { type: 'text', text: 'Here is the plan.' },
        ])
      )
    );
    expect(blocks.map((b) => b.kind)).toEqual(['thinking', 'assistant']);
    expect(blocks[0]).toMatchObject({ text: 'weigh the options' });
  });

  // Claude writes a `signature` for every reasoning block but the plaintext only
  // sometimes. A textless one would render as a pill saying nothing, and a long
  // session produces dozens in a row (measured: 302 of 302 empty in one file).
  it('drops reasoning blocks that carry only a signature', () => {
    const { blocks } = parseTranscriptBlocks(
      jsonl(
        assistant('a1', [
          { type: 'thinking', thinking: '', signature: 'CAIS6QMKpgEIERgC' },
          { type: 'text', text: 'Done.' },
        ])
      )
    );
    expect(blocks.map((b) => b.kind)).toEqual(['assistant']);
  });

  it('correlates a tool result back to its call across the assistant/user boundary', () => {
    // Claude records the request on an assistant row and the RESULT on a user row.
    const { blocks } = parseTranscriptBlocks(
      jsonl(
        assistant('a1', [{ type: 'tool_use', id: 'toolu_1', name: 'Bash', input: { command: 'ls -la\nsecond line' } }]),
        user('u1', [{ type: 'tool_result', tool_use_id: 'toolu_1', content: 'total 8', is_error: false }])
      )
    );
    expect(blocks).toHaveLength(1);
    const tool = blocks[0] as ToolCallBlock;
    expect(tool.kind).toBe('toolCall');
    expect(tool.name).toBe('Bash');
    // The summary is one line so a collapsed accordion stays readable.
    expect(tool.summary).toBe('ls -la');
    expect(tool.result).toBe('total 8');
    expect(tool.isError).toBeUndefined();
  });

  // The first line of a multi-line script is usually setup — a variable assignment or a `cd` —
  // and summarising the row with it says nothing about what ran.
  it('prefers the tool description over the first line of a multi-line command', () => {
    const { blocks } = parseTranscriptBlocks(
      jsonl(
        assistant('a1', [
          {
            type: 'tool_use',
            id: 't1',
            name: 'Bash',
            input: { command: 'B=http://127.0.0.1:5177\ncurl -s "$B/api/status"', description: 'Probe the server' },
          },
        ])
      )
    );
    expect(blocks[0]).toMatchObject({ summary: 'Probe the server' });
  });

  it('keeps a single-line command as its own summary, being more precise than a description', () => {
    const { blocks } = parseTranscriptBlocks(
      jsonl(
        assistant('a1', [
          { type: 'tool_use', id: 't1', name: 'Bash', input: { command: 'npm test', description: 'Run tests' } },
        ])
      )
    );
    expect(blocks[0]).toMatchObject({ summary: 'npm test' });
  });

  it('falls back to the first line when a multi-line command has no description', () => {
    const { blocks } = parseTranscriptBlocks(
      jsonl(assistant('a1', [{ type: 'tool_use', id: 't1', name: 'Bash', input: { command: 'cd /tmp\nls' } }]))
    );
    expect(blocks[0]).toMatchObject({ summary: 'cd /tmp' });
  });

  it('marks a failed tool call', () => {
    const { blocks } = parseTranscriptBlocks(
      jsonl(
        assistant('a1', [{ type: 'tool_use', id: 't1', name: 'Bash', input: { command: 'false' } }]),
        user('u1', [{ type: 'tool_result', tool_use_id: 't1', content: 'exit 1', is_error: true }])
      )
    );
    expect(blocks[0]).toMatchObject({ kind: 'toolCall', isError: true, result: 'exit 1' });
  });

  // Normal when reading only the tail of a long transcript: the result is in the
  // window but the call that produced it is not. An orphan has no context to
  // render against, so it is dropped rather than shown as a nameless card.
  it('drops a tool result whose call is outside the parsed window', () => {
    const { blocks } = parseTranscriptBlocks(
      jsonl(user('u1', [{ type: 'tool_result', tool_use_id: 'gone', content: 'orphan' }]))
    );
    expect(blocks).toEqual([]);
  });

  it('renders Edit as a diff with both sides', () => {
    const { blocks } = parseTranscriptBlocks(
      jsonl(
        assistant('a1', [
          {
            type: 'tool_use',
            id: 't1',
            name: 'Edit',
            input: { file_path: '/repo/a.ts', old_string: 'before', new_string: 'after' },
          },
        ])
      )
    );
    const diff = blocks[0] as DiffBlock;
    expect(diff).toMatchObject({ kind: 'diff', filePath: '/repo/a.ts', oldText: 'before', newText: 'after' });
  });

  it('renders Write as a diff with no prior side, because the transcript has none', () => {
    const { blocks } = parseTranscriptBlocks(
      jsonl(
        assistant('a1', [
          { type: 'tool_use', id: 't1', name: 'Write', input: { file_path: '/repo/new.ts', content: 'hello' } },
        ])
      )
    );
    expect(blocks[0]).toMatchObject({ kind: 'diff', filePath: '/repo/new.ts', newText: 'hello' });
    expect((blocks[0] as DiffBlock).oldText).toBeUndefined();
  });

  // MCP editors are user-installed, so a name allowlist can never be complete.
  // Carrying both sides of a replacement is what makes a call a diff.
  it('recognises an unknown MCP editor as a diff from its shape', () => {
    const { blocks } = parseTranscriptBlocks(
      jsonl(
        assistant('a1', [
          {
            type: 'tool_use',
            id: 't1',
            name: 'mcp__gortex__edit',
            input: { match: 'old code', replacement: 'new code' },
          },
        ])
      )
    );
    expect(blocks[0]).toMatchObject({ kind: 'diff', name: 'mcp__gortex__edit', oldText: 'old code' });
  });

  it('leaves a non-editing tool as a tool call even when it names a file', () => {
    const { blocks } = parseTranscriptBlocks(
      jsonl(assistant('a1', [{ type: 'tool_use', id: 't1', name: 'Read', input: { file_path: '/repo/a.ts' } }]))
    );
    expect(blocks[0]).toMatchObject({ kind: 'toolCall', name: 'Read', summary: '/repo/a.ts' });
  });

  // A successful edit's result is boilerplate and the diff already shows the
  // change; only a failure adds anything.
  it('keeps a diff result only when the edit failed', () => {
    const ok = parseTranscriptBlocks(
      jsonl(
        assistant('a1', [{ type: 'tool_use', id: 't1', name: 'Edit', input: { old_string: 'a', new_string: 'b' } }]),
        user('u1', [{ type: 'tool_result', tool_use_id: 't1', content: 'The file has been updated.' }])
      )
    );
    expect((ok.blocks[0] as DiffBlock).result).toBeUndefined();

    const failed = parseTranscriptBlocks(
      jsonl(
        assistant('a1', [{ type: 'tool_use', id: 't1', name: 'Edit', input: { old_string: 'a', new_string: 'b' } }]),
        user('u1', [{ type: 'tool_result', tool_use_id: 't1', content: 'String not found', is_error: true }])
      )
    );
    expect(failed.blocks[0]).toMatchObject({ isError: true, result: 'String not found' });
  });

  it('skips sidechains, which belong to subagents and would interleave incoherently', () => {
    const { blocks } = parseTranscriptBlocks(
      jsonl(
        { ...assistant('a1', [{ type: 'text', text: 'subagent chatter' }]), isSidechain: true },
        assistant('a2', [{ type: 'text', text: 'main thread' }])
      )
    );
    expect(blocks).toHaveLength(1);
    expect(blocks[0]).toMatchObject({ text: 'main thread' });
  });

  it('skips Claude-generated user rows that no human typed', () => {
    const { blocks } = parseTranscriptBlocks(
      jsonl(
        user('u1', '<system-reminder>internal</system-reminder>'),
        user('u2', '[Image: original 1206x2622, displayed at 920x2000.]'),
        user('u3', 'meta row', { isMeta: true }),
        user('u4', 'a real prompt')
      )
    );
    expect(blocks.map((b) => (b as { text: string }).text)).toEqual(['a real prompt']);
  });

  // A screenshot is megabytes of base64. It must never reach the wire.
  it('reports an image attachment as a count and never forwards its payload', () => {
    const { blocks } = parseTranscriptBlocks(
      jsonl(
        user('u1', [
          { type: 'text', text: 'look at this' },
          { type: 'image', source: { type: 'base64', media_type: 'image/jpeg', data: 'A'.repeat(5000) } },
        ])
      )
    );
    expect(blocks[0]).toMatchObject({ kind: 'user', text: 'look at this', imageCount: 1 });
    expect(JSON.stringify(blocks)).not.toContain('AAAA');
  });

  it('caps oversized text and says that it did', () => {
    const { blocks } = parseTranscriptBlocks(jsonl(user('u1', 'x'.repeat(500))), { maxTextChars: 100 });
    expect((blocks[0] as { text: string }).text).toHaveLength(100);
    expect(blocks[0]).toMatchObject({ truncated: true });
  });

  it('caps a tool result but reports its real length', () => {
    const { blocks } = parseTranscriptBlocks(
      jsonl(
        assistant('a1', [{ type: 'tool_use', id: 't1', name: 'Bash', input: { command: 'cat big' } }]),
        user('u1', [{ type: 'tool_result', tool_use_id: 't1', content: 'y'.repeat(9000) }])
      ),
      { maxResultChars: 50 }
    );
    expect(blocks[0]).toMatchObject({ resultTruncated: true, resultLength: 9000 });
    expect((blocks[0] as ToolCallBlock).result).toHaveLength(50);
  });

  it('flattens a structured tool result and reduces image parts to a marker', () => {
    const { blocks } = parseTranscriptBlocks(
      jsonl(
        assistant('a1', [{ type: 'tool_use', id: 't1', name: 'Read', input: {} }]),
        user('u1', [
          {
            type: 'tool_result',
            tool_use_id: 't1',
            content: [
              { type: 'text', text: 'line one' },
              { type: 'image', source: { data: 'B'.repeat(4000) } },
            ],
          },
        ])
      )
    );
    expect((blocks[0] as ToolCallBlock).result).toBe('line one\n[image]');
  });

  it('merges an adjacent run of assistant paragraphs into one block', () => {
    const { blocks } = parseTranscriptBlocks(
      jsonl(
        assistant('a1', [
          { type: 'text', text: 'first' },
          { type: 'text', text: 'second' },
        ])
      )
    );
    expect(blocks).toHaveLength(1);
    expect(blocks[0]).toMatchObject({ text: 'first\n\nsecond' });
  });

  // The agent spoke, acted, then spoke again — collapsing across the action would
  // misrepresent the order of events.
  it('does not merge assistant prose across a tool call', () => {
    const { blocks } = parseTranscriptBlocks(
      jsonl(
        assistant('a1', [
          { type: 'text', text: 'before' },
          { type: 'tool_use', id: 't1', name: 'Bash', input: { command: 'ls' } },
          { type: 'text', text: 'after' },
        ])
      )
    );
    expect(blocks.map((b) => b.kind)).toEqual(['assistant', 'toolCall', 'assistant']);
  });

  it('keeps the NEWEST blocks when the cap bites, and reports the real total', () => {
    const entries = Array.from({ length: 10 }, (_, i) => user(`u${i}`, `prompt ${i}`));
    const { blocks, truncated, totalBlocks } = parseTranscriptBlocks(jsonl(...entries), { maxBlocks: 3 });
    expect(truncated).toBe(true);
    expect(totalBlocks).toBe(10);
    expect(blocks.map((b) => (b as { text: string }).text)).toEqual(['prompt 7', 'prompt 8', 'prompt 9']);
  });

  // A tail read starts mid-line by construction, and a live transcript can end
  // mid-write. Both must be survivable, not fatal.
  it('survives a truncated first and last line', () => {
    const good = JSON.stringify(user('u1', 'intact'));
    const { blocks } = parseTranscriptBlocks(`{"type":"assis\n${good}\n{"type":"user","mess`);
    expect(blocks).toHaveLength(1);
    expect(blocks[0]).toMatchObject({ text: 'intact' });
  });

  it('gives every block a stable id so a re-fetch can be deduped', () => {
    const source = jsonl(
      user('u1', 'hello'),
      assistant('a1', [
        { type: 'text', text: 'hi' },
        { type: 'tool_use', id: 't1', name: 'Bash', input: {} },
      ])
    );
    const first = parseTranscriptBlocks(source).blocks.map((b) => b.id);
    const second = parseTranscriptBlocks(source).blocks.map((b) => b.id);
    expect(first).toEqual(second);
    expect(new Set(first).size).toBe(first.length);
  });
});
