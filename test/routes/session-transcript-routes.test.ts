import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import Fastify, { type FastifyInstance } from 'fastify';
import fastifyCookie from '@fastify/cookie';
import fastifyMultipart from '@fastify/multipart';
import { mkdir, writeFile, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { registerSessionRoutes } from '../../src/web/routes/session-routes.js';
import { createMockRouteContext, type MockRouteContext } from '../mocks/index.js';
import { installRouteErrorHandler } from '../../src/web/route-error-handler.js';
import { ApiErrorCode, httpStatusForErrorCode } from '../../src/types.js';

/**
 * `GET /api/sessions/:id/transcript` — the structured conversation feed behind the
 * native transcript view.
 *
 * ⚠️ `test/setup.ts` gives every test file a temporary HOME, so writing a fixture
 * under `~/.claude/projects` here touches nothing real. The route resolves the
 * transcript from that tree exactly as it does in production.
 */
describe('GET /api/sessions/:id/transcript', () => {
  let app: FastifyInstance;
  let ctx: MockRouteContext;
  let projectsDir: string;

  const entry = (value: unknown) => JSON.stringify(value);

  beforeEach(async () => {
    app = Fastify({ logger: false });
    await app.register(fastifyCookie);
    await app.register(fastifyMultipart, { limits: { fileSize: 1024, files: 1, fields: 4, parts: 5 } });
    ctx = createMockRouteContext();
    registerSessionRoutes(app, ctx);
    app.addHook('preSerialization', (req, reply, payload: unknown, done) => {
      if (!req.url.startsWith('/api') || payload === null || typeof payload !== 'object') return done(null, payload);
      const p = payload as { success?: unknown; errorCode?: unknown };
      if (p.success === false) {
        if (reply.statusCode === 200 && typeof p.errorCode === 'string') {
          reply.code(httpStatusForErrorCode(p.errorCode as ApiErrorCode));
        }
        return done(null, payload);
      }
      if (p.success === true) return done(null, payload);
      return done(null, { success: true, data: payload });
    });
    installRouteErrorHandler(app);
    await app.ready();

    projectsDir = join(process.env.HOME!, '.claude', 'projects', 'test-project');
    await mkdir(projectsDir, { recursive: true });
  });

  afterEach(async () => {
    await app.close();
    await rm(join(process.env.HOME!, '.claude'), { recursive: true, force: true });
  });

  async function writeTranscript(sessionId: string, lines: string[]) {
    await writeFile(join(projectsDir, `${sessionId}.jsonl`), lines.join('\n'), 'utf8');
  }

  it('returns typed blocks for a claude session', async () => {
    ctx._session.mode = 'claude';
    await writeTranscript(ctx._sessionId, [
      entry({ type: 'user', uuid: 'u1', message: { role: 'user', content: 'build the view' } }),
      entry({
        type: 'assistant',
        uuid: 'a1',
        message: {
          role: 'assistant',
          content: [
            { type: 'text', text: 'On it.' },
            { type: 'tool_use', id: 't1', name: 'Bash', input: { command: 'ls' } },
          ],
        },
      }),
      entry({
        type: 'user',
        uuid: 'u2',
        message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 't1', content: 'a.ts' }] },
      }),
    ]);

    const res = await app.inject({ method: 'GET', url: `/api/sessions/${ctx._sessionId}/transcript` });
    expect(res.statusCode).toBe(200);
    const data = JSON.parse(res.body).data;
    expect(data.available).toBe(true);
    expect(data.blocks.map((b: { kind: string }) => b.kind)).toEqual(['user', 'assistant', 'toolCall']);
    expect(data.blocks[2]).toMatchObject({ name: 'Bash', result: 'a.ts' });
  });

  // A codex/opencode pane is working perfectly; it simply writes no Claude transcript.
  // Reporting that as an error would make the UI cry wolf.
  it('answers 200 with available:false for a mode that writes no Claude transcript', async () => {
    ctx._session.mode = 'codex';
    const res = await app.inject({ method: 'GET', url: `/api/sessions/${ctx._sessionId}/transcript` });
    expect(res.statusCode).toBe(200);
    const data = JSON.parse(res.body).data;
    expect(data).toMatchObject({ available: false, blocks: [] });
    expect(data.reason).toContain('codex');
  });

  // A plain shell pane attempts discovery like any claude pane and answers by what it finds:
  // nothing. Artifact-driven availability — no launch-command/backend heuristic decides whether
  // a shell pane "counts" as claude, which is what the GLM custom actions need.
  it('answers available:false with no transcript found for a plain shell pane', async () => {
    ctx._session.mode = 'shell';
    const res = await app.inject({ method: 'GET', url: `/api/sessions/${ctx._sessionId}/transcript` });
    expect(res.statusCode).toBe(200);
    const data = JSON.parse(res.body).data;
    expect(data).toMatchObject({ available: false, blocks: [] });
    expect(data.reason).toBe('No transcript file yet');
  });

  // The GLM custom action: `mode: 'shell'` + a launch command that runs the claude CLI. The TOOL
  // in the pane is claude and writes a normal Claude transcript, which discovery now finds —
  // availability follows the artifact, not the session's mode classification.
  it('serves the transcript for a shell session whose tool is claude', async () => {
    ctx._session.mode = 'shell';
    ctx._session.launchCommand = 'claude';
    await writeTranscript(ctx._sessionId, [
      entry({ type: 'user', uuid: 'u1', message: { role: 'user', content: 'build the view' } }),
      entry({
        type: 'assistant',
        uuid: 'a1',
        message: { role: 'assistant', content: [{ type: 'text', text: 'On it.' }] },
      }),
    ]);

    const res = await app.inject({ method: 'GET', url: `/api/sessions/${ctx._sessionId}/transcript` });
    expect(res.statusCode).toBe(200);
    const data = JSON.parse(res.body).data;
    expect(data.available).toBe(true);
    expect(data.blocks.map((b: { kind: string }) => b.kind)).toEqual(['user', 'assistant']);

    // The composer's slash picker rides the same tool gate.
    const commands = await app.inject({ method: 'GET', url: `/api/sessions/${ctx._sessionId}/slash-commands` });
    expect(JSON.parse(commands.body).data.available).toBe(true);
  });

  it('answers available:false when the session has no transcript file yet', async () => {
    ctx._session.mode = 'claude';
    const res = await app.inject({ method: 'GET', url: `/api/sessions/${ctx._sessionId}/transcript` });
    expect(res.statusCode).toBe(200);
    expect(JSON.parse(res.body).data).toMatchObject({ available: false, blocks: [] });
  });

  it('honours ?limit and reports the untrimmed total', async () => {
    ctx._session.mode = 'claude';
    await writeTranscript(
      ctx._sessionId,
      Array.from({ length: 8 }, (_, i) =>
        entry({ type: 'user', uuid: `u${i}`, message: { role: 'user', content: `prompt ${i}` } })
      )
    );

    const res = await app.inject({ method: 'GET', url: `/api/sessions/${ctx._sessionId}/transcript?limit=2` });
    const data = JSON.parse(res.body).data;
    expect(data.blocks).toHaveLength(2);
    expect(data.totalBlocks).toBe(8);
    expect(data.truncated).toBe(true);
    // The newest survive the trim — a transcript view opens at the bottom.
    expect(data.blocks.map((b: { text: string }) => b.text)).toEqual(['prompt 6', 'prompt 7']);
  });

  // The tail read starts at an arbitrary byte offset, so the first line it sees is
  // usually a fragment. It must be discarded, never half-parsed.
  it('drops the partial first line when only the tail is read', async () => {
    ctx._session.mode = 'claude';
    // Must exceed the 64KB floor `maxBytes` clamps to, or the whole file fits in
    // one read, the tail path never runs and this test passes vacuously.
    const filler = Array.from({ length: 400 }, (_, i) =>
      entry({ type: 'user', uuid: `f${i}`, message: { role: 'user', content: `filler ${'x'.repeat(400)} ${i}` } })
    );
    await writeTranscript(ctx._sessionId, [
      ...filler,
      entry({ type: 'user', uuid: 'last', message: { role: 'user', content: 'the newest prompt' } }),
    ]);

    const res = await app.inject({
      method: 'GET',
      url: `/api/sessions/${ctx._sessionId}/transcript?maxBytes=65536`,
    });
    const data = JSON.parse(res.body).data;
    expect(data.available).toBe(true);
    expect(data.blocks.at(-1)).toMatchObject({ text: 'the newest prompt' });
  });

  // Scrolling to the top of a long conversation must reach the beginning, not stop at whatever
  // the first window happened to hold.
  describe('paging backwards', () => {
    it('reports a window cursor and walks to the start of the file', async () => {
      ctx._session.mode = 'claude';
      await writeTranscript(
        ctx._sessionId,
        Array.from({ length: 300 }, (_, i) =>
          entry({
            type: 'user',
            uuid: `u${i}`,
            message: { role: 'user', content: `prompt ${i} ${'x'.repeat(500)}` },
          })
        )
      );

      // A small window forces several pages.
      const first = await app.inject({
        method: 'GET',
        url: `/api/sessions/${ctx._sessionId}/transcript?maxBytes=65536`,
      });
      const page1 = JSON.parse(first.body).data;
      expect(page1.hasMore).toBe(true);
      expect(page1.windowStart).toBeGreaterThan(0);
      // The live tail always ends at the newest block.
      expect(page1.blocks.at(-1).text).toContain('prompt 299');

      const seen = new Set<string>(page1.blocks.map((b: { id: string }) => b.id));
      let cursor = page1.windowStart;
      let pages = 1;
      let reachedStart = false;
      while (pages < 30) {
        const res = await app.inject({
          method: 'GET',
          url: `/api/sessions/${ctx._sessionId}/transcript?maxBytes=65536&before=${cursor}`,
        });
        const page = JSON.parse(res.body).data;
        pages += 1;
        // Pages must not overlap: an overlapping cursor would duplicate blocks on screen.
        for (const block of page.blocks) {
          expect(seen.has(block.id)).toBe(false);
          seen.add(block.id);
        }
        if (!page.hasMore) {
          reachedStart = true;
          expect(page.blocks[0].text).toContain('prompt 0');
          break;
        }
        // Cursor must strictly decrease, or paging would loop forever.
        expect(page.windowStart).toBeLessThan(cursor);
        cursor = page.windowStart;
      }

      expect(reachedStart).toBe(true);
      expect(seen.size).toBe(300);
    });

    it('reports hasMore false when the whole file fits in one window', async () => {
      ctx._session.mode = 'claude';
      await writeTranscript(ctx._sessionId, [
        entry({ type: 'user', uuid: 'u1', message: { role: 'user', content: 'only prompt' } }),
      ]);
      const res = await app.inject({ method: 'GET', url: `/api/sessions/${ctx._sessionId}/transcript` });
      const data = JSON.parse(res.body).data;
      expect(data.hasMore).toBe(false);
      expect(data.windowStart).toBe(0);
    });
  });

  describe('image references', () => {
    const png = Buffer.from(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
      'base64'
    );

    async function transcriptWithImage(mediaType: string) {
      await writeTranscript(ctx._sessionId, [
        entry({
          type: 'user',
          uuid: 'u1',
          message: {
            role: 'user',
            content: [
              { type: 'text', text: 'look at this' },
              { type: 'image', source: { type: 'base64', media_type: mediaType, data: png.toString('base64') } },
            ],
          },
        }),
      ]);
    }

    // The transcript ships references precisely so the megabytes stay out of it; this is the
    // other half of that contract.
    it('serves the bytes behind a reference the transcript issued', async () => {
      ctx._session.mode = 'claude';
      await transcriptWithImage('image/png');

      const listing = await app.inject({ method: 'GET', url: `/api/sessions/${ctx._sessionId}/transcript` });
      const ref = JSON.parse(listing.body).data.blocks[0].images[0].ref;
      expect(ref).toBe('u1:1');

      const res = await app.inject({
        method: 'GET',
        url: `/api/sessions/${ctx._sessionId}/transcript/image?ref=${encodeURIComponent(ref)}`,
      });
      expect(res.statusCode).toBe(200);
      expect(res.headers['content-type']).toBe('image/png');
      expect(res.headers['x-content-type-options']).toBe('nosniff');
      expect(res.rawPayload.equals(png)).toBe(true);
    });

    // `media_type` is written into the transcript by whatever produced the image, so echoing it
    // verbatim would let that value choose the Content-Type a browser renders under.
    it('refuses to echo an unrecognised media type', async () => {
      ctx._session.mode = 'claude';
      await transcriptWithImage('text/html');

      const res = await app.inject({
        method: 'GET',
        url: `/api/sessions/${ctx._sessionId}/transcript/image?ref=u1:1`,
      });
      expect(res.statusCode).toBe(200);
      expect(res.headers['content-type']).toBe('application/octet-stream');
    });

    it('rejects a malformed reference', async () => {
      ctx._session.mode = 'claude';
      await transcriptWithImage('image/png');
      for (const ref of ['../../etc/passwd', 'u1', 'u1:notanumber', '']) {
        const res = await app.inject({
          method: 'GET',
          url: `/api/sessions/${ctx._sessionId}/transcript/image?ref=${encodeURIComponent(ref)}`,
        });
        expect(res.statusCode).toBe(400);
      }
    });

    it('404s a reference that points at a non-image block', async () => {
      ctx._session.mode = 'claude';
      await transcriptWithImage('image/png');
      const res = await app.inject({
        method: 'GET',
        url: `/api/sessions/${ctx._sessionId}/transcript/image?ref=u1:0`,
      });
      expect(res.statusCode).toBe(404);
    });
  });

  it('rejects a session the caller cannot see', async () => {
    const res = await app.inject({ method: 'GET', url: '/api/sessions/does-not-exist/transcript' });
    expect(res.statusCode).toBe(404);
  });

  // ── Incremental polling (`since`) ───────────────────────────────────────────────────────
  //
  // ⚠️ These pin the fix for a MEASURED bug, not a hypothetical one. A poll used to read only the
  // 1 MB TAIL, and on a real transcript that is frequently not a single prompt — the 1 MB tail of
  // a 37 MB session parsed to 130 blocks and ZERO user prompts, because tool results dominate the
  // bytes. So a client that stopped polling for a few minutes of active work (backgrounded on
  // iOS) came back to a window that began AFTER prompts the user had sent; those prompts appeared
  // in no window it ever saw, and backwards paging walks upward from the FIRST window, never into
  // a hole that opened at the tail. Prompts sent from another client vanished while the
  // processing they triggered showed up.
  describe('since (incremental poll)', () => {
    const lines = (n: number, pad = '') =>
      Array.from({ length: n }, (_, i) =>
        entry({ type: 'user', uuid: `u${i}`, message: { role: 'user', content: `prompt ${i}${pad}` } })
      );

    /**
     * ⚠️ Trailing newline, because Claude Code writes one (verified on this machine's three most
     * recent transcripts: all end in 0x0a). Without it the final line is indistinguishable from an
     * append still in progress, `windowEnd` conservatively stops short of it, and the poll
     * re-delivers it forever — a fixture artifact that would look like a cursor bug.
     */
    const write = (sessionId: string, ls: string[]) =>
      writeFile(join(projectsDir, `${sessionId}.jsonl`), ls.join('\n') + '\n', 'utf8');

    it('returns only what was appended after the cursor', async () => {
      ctx._session.mode = 'claude';
      await write(ctx._sessionId, lines(3));
      const first = JSON.parse(
        (await app.inject({ method: 'GET', url: `/api/sessions/${ctx._sessionId}/transcript` })).body
      ).data;
      expect(first.blocks).toHaveLength(3);
      expect(first.gap).toBe(false);

      await write(ctx._sessionId, [...lines(3), ...lines(2).map((l) => l.replace('prompt', 'later'))]);
      const next = JSON.parse(
        (
          await app.inject({
            method: 'GET',
            url: `/api/sessions/${ctx._sessionId}/transcript?since=${first.windowEnd}`,
          })
        ).body
      ).data;
      expect(next.gap).toBe(false);
      expect(next.blocks.map((b: { text: string }) => b.text)).toEqual(['later 0', 'later 1']);
    });

    it('reports no new blocks when nothing was appended', async () => {
      ctx._session.mode = 'claude';
      await write(ctx._sessionId, lines(3));
      const first = JSON.parse(
        (await app.inject({ method: 'GET', url: `/api/sessions/${ctx._sessionId}/transcript` })).body
      ).data;
      const again = JSON.parse(
        (
          await app.inject({
            method: 'GET',
            url: `/api/sessions/${ctx._sessionId}/transcript?since=${first.windowEnd}`,
          })
        ).body
      ).data;
      expect(again.blocks).toEqual([]);
      expect(again.gap).toBe(false);
    });

    // ⚠️ The subtle one. A transcript is appended to WHILE it is read, so a window routinely ends
    // mid-line. `windowEnd` is the end of the last COMPLETE line for exactly this reason: resuming
    // at the raw window end would start the next read partway through an entry, that fragment
    // would not parse, and the entry would be lost between two windows that each looked fine.
    it('resumes on a line boundary so an entry split across two reads survives', async () => {
      ctx._session.mode = 'claude';
      const all = lines(4);
      // Cut the file mid-way through the LAST entry, as an in-progress append would.
      const partial = all.slice(0, 3).join('\n') + '\n' + all[3].slice(0, 20);
      await writeFile(join(projectsDir, `${ctx._sessionId}.jsonl`), partial, 'utf8');
      const first = JSON.parse(
        (await app.inject({ method: 'GET', url: `/api/sessions/${ctx._sessionId}/transcript` })).body
      ).data;
      expect(first.blocks).toHaveLength(3); // the fragment does not parse, correctly

      // The writer finishes the line.
      await write(ctx._sessionId, all);
      const next = JSON.parse(
        (
          await app.inject({
            method: 'GET',
            url: `/api/sessions/${ctx._sessionId}/transcript?since=${first.windowEnd}`,
          })
        ).body
      ).data;
      expect(next.blocks.map((b: { text: string }) => b.text)).toEqual(['prompt 3']);
    });

    // The agent outran the client. Say so and name where the hole ends, rather than lagging
    // further behind on every poll or pretending the window is continuous.
    it('flags a gap when the transcript grew past the window, and the hole is back-fillable', async () => {
      ctx._session.mode = 'claude';
      await write(ctx._sessionId, lines(2));
      const first = JSON.parse(
        (await app.inject({ method: 'GET', url: `/api/sessions/${ctx._sessionId}/transcript` })).body
      ).data;

      // Grow well past the smallest window the route accepts (64 KB).
      await write(ctx._sessionId, [...lines(2), ...lines(400, 'x'.repeat(600))]);
      const next = JSON.parse(
        (
          await app.inject({
            method: 'GET',
            url: `/api/sessions/${ctx._sessionId}/transcript?since=${first.windowEnd}&maxBytes=65536`,
          })
        ).body
      ).data;
      expect(next.gap).toBe(true);
      expect(next.windowStart).toBeGreaterThan(first.windowEnd);

      // The named hole is reachable through the existing backwards paging.
      const back = JSON.parse(
        (
          await app.inject({
            method: 'GET',
            url: `/api/sessions/${ctx._sessionId}/transcript?before=${next.windowStart}&maxBytes=65536`,
          })
        ).body
      ).data;
      expect(back.blocks.length).toBeGreaterThan(0);
      expect(back.windowStart).toBeLessThan(next.windowStart);
    });

    it('ignores since while paging backwards — they ask different questions', async () => {
      ctx._session.mode = 'claude';
      await write(ctx._sessionId, lines(5));
      const first = JSON.parse(
        (await app.inject({ method: 'GET', url: `/api/sessions/${ctx._sessionId}/transcript` })).body
      ).data;
      const paged = JSON.parse(
        (
          await app.inject({
            method: 'GET',
            url: `/api/sessions/${ctx._sessionId}/transcript?before=${first.windowEnd}&since=${first.windowEnd}`,
          })
        ).body
      ).data;
      expect(paged.blocks.length).toBeGreaterThan(0);
      expect(paged.gap).toBe(false);
    });

    it('tolerates a cursor past the end of a truncated file', async () => {
      ctx._session.mode = 'claude';
      await write(ctx._sessionId, lines(1));
      const res = await app.inject({
        method: 'GET',
        url: `/api/sessions/${ctx._sessionId}/transcript?since=999999999`,
      });
      expect(res.statusCode).toBe(200);
      const data = JSON.parse(res.body).data;
      expect(data.blocks).toEqual([]);
      expect(data.gap).toBe(false);
    });
  });
});
