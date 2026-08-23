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

  // A shell or codex pane is working perfectly; it simply writes no Claude
  // transcript. Reporting that as an error would make the UI cry wolf.
  it('answers 200 with available:false for a mode that writes no Claude transcript', async () => {
    ctx._session.mode = 'shell';
    const res = await app.inject({ method: 'GET', url: `/api/sessions/${ctx._sessionId}/transcript` });
    expect(res.statusCode).toBe(200);
    const data = JSON.parse(res.body).data;
    expect(data).toMatchObject({ available: false, blocks: [] });
    expect(data.reason).toContain('shell');
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

  it('rejects a session the caller cannot see', async () => {
    const res = await app.inject({ method: 'GET', url: '/api/sessions/does-not-exist/transcript' });
    expect(res.statusCode).toBe(404);
  });
});
