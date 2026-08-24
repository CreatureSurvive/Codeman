/**
 * @fileoverview Structured transcript blocks — the PURE parse of a Claude Code
 * JSONL transcript into typed conversation blocks.
 *
 * WHY this exists alongside `parseClaudeResponseTranscript` (session-routes.ts):
 * that parser answers "what did the agent last SAY", so it keeps `type:'text'`
 * blocks and throws away everything else. A transcript *view* needs the parts it
 * discards — reasoning, tool calls and their results, file edits — which is most
 * of a modern turn (measured on a real 12.5 MB transcript: 630 tool_use, 630
 * tool_result and 299 thinking blocks against 201 text blocks). Widening the
 * existing parser would change what every response-viewer caller receives, so
 * this is a second, additive reader over the same file.
 *
 * Pure and IO-free on purpose: the route owns locating and reading the file, and
 * every shape decision here is unit-testable against fixture JSONL.
 *
 * ⚠️ **Everything here is size-bounded.** A transcript is unbounded (megabytes of
 * tool output, base64 images) and the consumer is a phone. Every text field is
 * capped, every cap is reported rather than silent, and base64 image payloads are
 * never emitted — only a marker that an image was present.
 */

/** Discriminator for a rendered conversation block. */
export type TranscriptBlockKind = 'user' | 'thinking' | 'assistant' | 'toolCall' | 'diff';

interface BlockBase {
  /** Stable across re-fetches: the transcript entry's uuid plus the block's index within it. */
  id: string;
  kind: TranscriptBlockKind;
  timestamp?: string;
}

/**
 * A renderable image held in the transcript.
 *
 * ⚠️ Carries a REFERENCE, never the bytes. Claude stores images as base64 inline, and a single
 * screenshot is megabytes — inlining even one would dwarf an entire conversation's worth of text.
 * The client fetches `GET /api/sessions/:id/transcript/image?ref=…` when a view actually needs it,
 * so an off-screen image costs nothing.
 */
export interface TranscriptImageRef {
  /** `<entryUuid>:<blockIndex>` or `<entryUuid>:<blockIndex>:<contentIndex>` inside a tool result. */
  ref: string;
  mediaType?: string;
  /** Decoded byte length, so the client can size a placeholder before fetching. */
  bytes?: number;
}

export interface UserBlock extends BlockBase {
  kind: 'user';
  text: string;
  truncated?: boolean;
  /** Images attached to this message, as references. */
  images?: TranscriptImageRef[];
}

export interface ThinkingBlock extends BlockBase {
  kind: 'thinking';
  /**
   * Always non-empty. Claude persists a `signature` for every reasoning block but
   * the plaintext only when the account/model records it (measured across 40 real
   * transcripts: 1039 of 3729 blocks carried text); textless ones are dropped by
   * the parser rather than surfaced as empty pills.
   */
  text: string;
  truncated?: boolean;
}

export interface AssistantBlock extends BlockBase {
  kind: 'assistant';
  text: string;
  truncated?: boolean;
}

export interface ToolCallBlock extends BlockBase {
  kind: 'toolCall';
  /** Raw tool name, e.g. `Bash`, `Read`, `mcp__gortex__search`. */
  name: string;
  /** One-line human summary of the invocation (the command, the path, the query). */
  summary?: string;
  /** Pretty-printed input, capped. */
  input?: string;
  inputTruncated?: boolean;
  /** Result text once the matching `tool_result` is seen; absent while still running. */
  result?: string;
  resultTruncated?: boolean;
  /** Total result length before capping, so the UI can say how much it is hiding. */
  resultLength?: number;
  isError?: boolean;
  /** Images the tool returned (a screenshot, a rendered chart), as references. */
  images?: TranscriptImageRef[];
}

export interface DiffBlock extends BlockBase {
  kind: 'diff';
  /** The editing tool this came from, kept so the UI can label it accurately. */
  name: string;
  filePath?: string;
  /** Absent for a whole-file write, which has no prior content in the transcript. */
  oldText?: string;
  newText?: string;
  oldTruncated?: boolean;
  newTruncated?: boolean;
  /**
   * Line counts for the `+N -N` badge, computed BEFORE the text is capped — a truncated diff
   * would otherwise under-report the size of the change it is truncating.
   */
  addedLines?: number;
  removedLines?: number;
  isError?: boolean;
  /** Error text when the edit failed; a successful edit's result is uninteresting. */
  result?: string;
}

export type TranscriptBlock = UserBlock | ThinkingBlock | AssistantBlock | ToolCallBlock | DiffBlock;

export interface ParseTranscriptOptions {
  /** Hard cap on emitted blocks; the NEWEST are kept. */
  maxBlocks?: number;
  /** Cap for prose (user/assistant/thinking) text. */
  maxTextChars?: number;
  /** Cap for a tool result. Kept smaller than prose: results are the bulk of a transcript. */
  maxResultChars?: number;
  /** Cap for each side of a diff. */
  maxDiffChars?: number;
}

export interface ParsedTranscript {
  blocks: TranscriptBlock[];
  /** True when `maxBlocks` dropped older blocks. */
  truncated: boolean;
  /** Blocks parsed before the cap, so the UI can say what it is not showing. */
  totalBlocks: number;
}

export const TRANSCRIPT_DEFAULTS = {
  maxBlocks: 200,
  maxTextChars: 20_000,
  maxResultChars: 4_000,
  maxDiffChars: 8_000,
} as const;

/** Tools whose invocation IS a file edit, and where to find each side of it. */
const DIFF_TOOLS: Record<string, { path: string[]; old?: string[]; next: string[] }> = {
  Edit: { path: ['file_path'], old: ['old_string'], next: ['new_string'] },
  Write: { path: ['file_path'], next: ['content'] },
  NotebookEdit: { path: ['notebook_path', 'file_path'], old: ['old_source'], next: ['new_source'] },
};

/**
 * Generic fallback for edit tools this build has never heard of (MCP editors are
 * user-installed, so an allowlist can never be complete). A tool qualifies only
 * when it carries BOTH sides of a replacement — that is what makes it renderable
 * as a diff rather than guesswork about the name.
 */
const GENERIC_OLD_KEYS = ['old_string', 'match', 'old_text', 'search'];
const GENERIC_NEW_KEYS = ['new_string', 'replacement', 'new_text', 'replace'];
const GENERIC_PATH_KEYS = ['file_path', 'path', 'filePath', 'file'];

interface RawEntry {
  type?: string;
  uuid?: string;
  timestamp?: string;
  isMeta?: boolean;
  isSidechain?: boolean;
  isCompactSummary?: boolean;
  message?: { content?: unknown };
}

interface RawBlock {
  type?: string;
  text?: string;
  thinking?: string;
  id?: string;
  name?: string;
  input?: unknown;
  tool_use_id?: string;
  content?: unknown;
  is_error?: boolean;
}

function cap(text: string, limit: number): { text: string; truncated: boolean } {
  if (text.length <= limit) return { text, truncated: false };
  return { text: text.slice(0, limit), truncated: true };
}

function firstString(input: Record<string, unknown>, keys: string[]): string | undefined {
  for (const key of keys) {
    const value = input[key];
    if (typeof value === 'string') return value;
  }
  return undefined;
}

/**
 * Flatten a `tool_result.content`, which is a string for most tools and a block
 * list for the ones that return structured output.
 *
 * ⚠️ Image blocks are dropped to a marker here. A screenshot result is a
 * multi-megabyte base64 string; forwarding it would dwarf the rest of the
 * response and the client cannot render it from this endpoint anyway.
 */
function flattenResultContent(content: unknown, imageBase: string): { text: string; images: TranscriptImageRef[] } {
  if (typeof content === 'string') return { text: content, images: [] };
  if (!Array.isArray(content)) return { text: '', images: [] };
  const parts: string[] = [];
  const images: TranscriptImageRef[] = [];
  content.forEach((raw, index) => {
    if (!raw || typeof raw !== 'object') return;
    const block = raw as RawBlock;
    if (block.type === 'text' && typeof block.text === 'string') parts.push(block.text);
    else if (block.type === 'image') images.push(describeImage(block, `${imageBase}:${index}`));
  });
  return { text: parts.join('\n'), images };
}

/** Turn an image block into a reference, reading only its metadata — never its data. */
function describeImage(block: RawBlock, ref: string): TranscriptImageRef {
  const source = (block as { source?: { media_type?: string; data?: string } }).source;
  const data = typeof source?.data === 'string' ? source.data : '';
  return {
    ref,
    ...(source?.media_type ? { mediaType: source.media_type } : {}),
    // base64 is 4 chars per 3 bytes; exact enough to size a placeholder.
    ...(data ? { bytes: Math.floor((data.length * 3) / 4) } : {}),
  };
}

/** Lines a diff side spans, for the `+N -N` badge. */
function lineCount(text: string | undefined): number {
  if (!text) return 0;
  return text.split('\n').length;
}

/** One-line summary of a tool invocation, so a collapsed accordion is still readable. */
function summarizeToolInput(input: Record<string, unknown>): string | undefined {
  const command = input.command;
  const description = input.description;
  if (typeof command === 'string') {
    const firstLine = command.split('\n')[0];
    // ⚠️ For a MULTI-LINE script the first line is usually setup — a variable assignment or a
    // `cd` — and summarising the row as `B=http://127.0.0.1:5177` tells the reader nothing about
    // what ran. The tool's own description is the better one-liner when there is one.
    // Single-line commands keep the command itself, which is more precise than any description.
    if (command.includes('\n') && typeof description === 'string' && description.trim()) {
      return description;
    }
    return firstLine;
  }
  const path = firstString(input, GENERIC_PATH_KEYS);
  if (path) return path;
  const query = input.query ?? input.pattern ?? input.task;
  if (typeof query === 'string') return query;
  if (typeof description === 'string') return description;
  const url = input.url;
  if (typeof url === 'string') return url;
  return undefined;
}

function describeDiff(
  name: string,
  input: Record<string, unknown>
): { path?: string; old?: string; next: string } | null {
  const known = DIFF_TOOLS[name];
  if (known) {
    const next = firstString(input, known.next);
    if (typeof next !== 'string') return null;
    return {
      path: firstString(input, known.path),
      old: known.old ? firstString(input, known.old) : undefined,
      next,
    };
  }
  const old = firstString(input, GENERIC_OLD_KEYS);
  const next = firstString(input, GENERIC_NEW_KEYS);
  if (old === undefined || next === undefined) return null;
  return { path: firstString(input, GENERIC_PATH_KEYS), old, next };
}

/**
 * User rows Claude writes for its own bookkeeping rather than because a human
 * typed something. Mirrors `isClaudeSyntheticUserMessage` in session-routes.ts —
 * deliberately duplicated rather than shared, because that one is scoped to the
 * response viewer's notion of a "turn" and the two are free to diverge.
 */
function isSyntheticUserText(entry: RawEntry, text: string): boolean {
  if (entry.isMeta || entry.isCompactSummary) return true;
  return /^(?:<local-command|<command-name>|<task-notification>|<system-reminder>|<teammate-message\b|\[Image: original \d|Another Claude session sent a message:|Base directory for this skill:)/i.test(
    text
  );
}

/**
 * Parse JSONL transcript content into ordered, typed blocks.
 *
 * Tool results are correlated back to their call by `tool_use_id`. A result whose
 * call is not in this slice (normal when reading only the tail of a long file) is
 * dropped rather than emitted as an orphan with no context.
 */
export function parseTranscriptBlocks(content: string, options: ParseTranscriptOptions = {}): ParsedTranscript {
  const maxBlocks = options.maxBlocks ?? TRANSCRIPT_DEFAULTS.maxBlocks;
  const maxTextChars = options.maxTextChars ?? TRANSCRIPT_DEFAULTS.maxTextChars;
  const maxResultChars = options.maxResultChars ?? TRANSCRIPT_DEFAULTS.maxResultChars;
  const maxDiffChars = options.maxDiffChars ?? TRANSCRIPT_DEFAULTS.maxDiffChars;

  const blocks: TranscriptBlock[] = [];
  /** tool_use_id → the block awaiting its result. */
  const pendingTools = new Map<string, ToolCallBlock | DiffBlock>();

  for (const line of content.split('\n')) {
    if (!line) continue;
    let entry: RawEntry;
    try {
      entry = JSON.parse(line) as RawEntry;
    } catch {
      // A tail read starts mid-line by construction, and a transcript being
      // appended to can end mid-line. Both are ordinary, not errors.
      continue;
    }
    // Sidechains are subagent conversations; they have their own viewers and would
    // interleave incoherently with the main thread.
    if (entry.isSidechain) continue;
    if (entry.type !== 'user' && entry.type !== 'assistant') continue;

    const uuid = entry.uuid || `${blocks.length}`;
    const timestamp = entry.timestamp;
    const content_ = entry.message?.content;

    if (typeof content_ === 'string') {
      const text = content_.trim();
      if (!text || isSyntheticUserText(entry, text)) continue;
      const capped = cap(text, maxTextChars);
      blocks.push({
        id: `${uuid}:0`,
        kind: 'user',
        timestamp,
        text: capped.text,
        ...(capped.truncated ? { truncated: true } : {}),
      });
      continue;
    }

    if (!Array.isArray(content_)) continue;

    const entryImages: TranscriptImageRef[] = [];
    content_.forEach((raw, index) => {
      if (!raw || typeof raw !== 'object') return;
      const block = raw as RawBlock;
      const id = `${uuid}:${index}`;

      switch (block.type) {
        case 'text': {
          const text = (block.text ?? '').trim();
          if (!text) return;
          if (entry.type === 'user') {
            if (isSyntheticUserText(entry, text)) return;
            const capped = cap(text, maxTextChars);
            blocks.push({
              id,
              kind: 'user',
              timestamp,
              text: capped.text,
              ...(capped.truncated ? { truncated: true } : {}),
            });
          } else {
            const capped = cap(text, maxTextChars);
            blocks.push({
              id,
              kind: 'assistant',
              timestamp,
              text: capped.text,
              ...(capped.truncated ? { truncated: true } : {}),
            });
          }
          return;
        }

        case 'thinking': {
          const capped = cap((block.thinking ?? '').trim(), maxTextChars);
          // ⚠️ A reasoning block with no plaintext is DROPPED, not rendered empty.
          // Claude always writes a `signature` but records the text only for some
          // accounts/models (measured: 0 of 302 in one transcript, 1039 of 3729
          // across forty). Those turns are not thoughtless — the tool calls that
          // follow show the work — so a stack of "reasoning happened, contents
          // unavailable" pills would be clutter standing in for information we do
          // not have. When the text IS recorded it renders in full.
          if (!capped.text) return;
          blocks.push({
            id,
            kind: 'thinking',
            timestamp,
            text: capped.text,
            ...(capped.truncated ? { truncated: true } : {}),
          });
          return;
        }

        case 'image': {
          entryImages.push(describeImage(block, id));
          return;
        }

        case 'tool_use': {
          const name = block.name ?? 'tool';
          const input = (block.input && typeof block.input === 'object' ? block.input : {}) as Record<string, unknown>;
          const diff = describeDiff(name, input);
          if (diff) {
            const oldCap = diff.old === undefined ? undefined : cap(diff.old, maxDiffChars);
            const newCap = cap(diff.next, maxDiffChars);
            const removedLines = lineCount(diff.old);
            const addedLines = lineCount(diff.next);
            const made: DiffBlock = {
              id,
              kind: 'diff',
              timestamp,
              name,
              ...(diff.path ? { filePath: diff.path } : {}),
              ...(oldCap ? { oldText: oldCap.text } : {}),
              newText: newCap.text,
              ...(oldCap?.truncated ? { oldTruncated: true } : {}),
              ...(newCap.truncated ? { newTruncated: true } : {}),
              ...(addedLines ? { addedLines } : {}),
              ...(removedLines ? { removedLines } : {}),
            };
            blocks.push(made);
            if (block.id) pendingTools.set(block.id, made);
            return;
          }
          let rendered = '';
          try {
            rendered = JSON.stringify(input, null, 2);
          } catch {
            rendered = '';
          }
          const inputCap = cap(rendered, maxResultChars);
          const made: ToolCallBlock = {
            id,
            kind: 'toolCall',
            timestamp,
            name,
            ...(summarizeToolInput(input) ? { summary: summarizeToolInput(input) } : {}),
            ...(inputCap.text ? { input: inputCap.text } : {}),
            ...(inputCap.truncated ? { inputTruncated: true } : {}),
          };
          blocks.push(made);
          if (block.id) pendingTools.set(block.id, made);
          return;
        }

        case 'tool_result': {
          const target = block.tool_use_id ? pendingTools.get(block.tool_use_id) : undefined;
          if (!target) return;
          const flattened = flattenResultContent(block.content, id);
          const text = flattened.text;
          const capped = cap(text, maxResultChars);
          if (block.is_error) target.isError = true;
          if (flattened.images.length && target.kind === 'toolCall') target.images = flattened.images;
          // A successful edit's result is boilerplate ("the file has been updated"),
          // and the diff above already shows what changed. A FAILED one is the only
          // thing worth the space, so it is the only one kept.
          if (target.kind === 'diff') {
            if (block.is_error && capped.text) target.result = capped.text;
          } else {
            target.result = capped.text;
            target.resultLength = text.length;
            if (capped.truncated) target.resultTruncated = true;
          }
          pendingTools.delete(block.tool_use_id!);
          return;
        }

        default:
          return;
      }
    });

    if (entryImages.length > 0) {
      // Attach to the user block this entry just produced, or stand alone when the
      // message was images only.
      const last = blocks.at(-1);
      if (last?.kind === 'user' && last.id.startsWith(`${uuid}:`)) {
        last.images = entryImages;
      } else {
        blocks.push({ id: `${uuid}:img`, kind: 'user', timestamp, text: '', images: entryImages });
      }
    }
  }

  const merged = coalesceAdjacentProse(blocks, maxTextChars);
  const totalBlocks = merged.length;
  if (totalBlocks <= maxBlocks) return { blocks: merged, truncated: false, totalBlocks };
  return { blocks: merged.slice(totalBlocks - maxBlocks), truncated: true, totalBlocks };
}

/**
 * Merge runs of adjacent same-kind prose into one block.
 *
 * Claude emits one reasoning stretch as many `thinking` blocks and one spoken
 * paragraph run as many `text` blocks — measured on a real transcript, a single
 * turn produced 52 thinking fragments. Rendered one-per-card that is 52 pills for
 * what the user experienced as one thought, and with reasoning plaintext usually
 * absent they would all be *empty* pills.
 *
 * ⚠️ Only ADJACENT blocks merge. A tool call between two assistant paragraphs is
 * real structure — the agent said something, acted, then spoke again — and
 * flattening across it would misrepresent the order of events.
 */
function coalesceAdjacentProse(blocks: TranscriptBlock[], maxTextChars: number): TranscriptBlock[] {
  const out: TranscriptBlock[] = [];
  for (const block of blocks) {
    const previous = out.at(-1);
    const mergeable = block.kind === 'thinking' || block.kind === 'assistant';
    if (mergeable && previous?.kind === block.kind) {
      const joined = previous.text && block.text ? `${previous.text}\n\n${block.text}` : previous.text || block.text;
      const capped = cap(joined, maxTextChars);
      previous.text = capped.text;
      if (capped.truncated || block.truncated) previous.truncated = true;
      // The run's timestamp becomes its LAST fragment's: the block is displayed as
      // one unit, and when it finished is more useful than when it started.
      if (block.timestamp) previous.timestamp = block.timestamp;
      continue;
    }
    out.push(block);
  }
  return out;
}
