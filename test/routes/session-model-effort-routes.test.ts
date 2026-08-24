/**
 * @fileoverview `GET/POST /api/sessions/:id/model` and `POST /api/sessions/:id/effort`.
 *
 * The read half is trivial (report what the statusline observed); the tests that matter are about
 * the WRITE half, which is not an API call but a keystroke typed into Claude's composer:
 *
 *  - a model name is allowlisted, not sanitized — a newline would submit the line early and leave
 *    the remainder sitting in the composer as a prompt;
 *  - the response never claims a switch it has not observed, because the CLI confirms only on its
 *    next statusline render;
 *  - an explicit effort change persists to the spawn default (so a respawn keeps it) while a
 *    passive observation does not;
 *  - `/model` and `/effort` are Claude Code commands, so every other CLI mode is refused rather
 *    than sent a string that would land in its prompt.
 *
 * Uses app.inject(), so no real HTTP port is needed.
 */

import { describe, it, expect, beforeEach } from 'vitest';
import Fastify, { type FastifyInstance } from 'fastify';
import fastifyCookie from '@fastify/cookie';
import { createMockRouteContext, type MockRouteContext } from '../mocks/index.js';
import { installRouteErrorHandler } from '../../src/web/route-error-handler.js';
import { registerSessionRoutes } from '../../src/web/routes/session-routes.js';

const SID = 'test-session-1'; // the id the mock context pre-populates

describe('session model + effort routes', () => {
  let app: FastifyInstance;
  let ctx: MockRouteContext;

  beforeEach(async () => {
    app = Fastify({ logger: false });
    await app.register(fastifyCookie);
    ctx = createMockRouteContext();
    registerSessionRoutes(app, ctx);
    installRouteErrorHandler(app);
    await app.ready();
  });

  const session = () => ctx.sessions.get(SID)!;
  const written = () => session().writeBuffer as string[];

  const get = () => app.inject({ method: 'GET', url: `/api/sessions/${SID}/model` });
  const setModel = (payload: unknown) => app.inject({ method: 'POST', url: `/api/sessions/${SID}/model`, payload });
  const setEffort = (payload: unknown) => app.inject({ method: 'POST', url: `/api/sessions/${SID}/effort`, payload });

  const body = (res: { body: string }) => {
    const parsed = JSON.parse(res.body);
    return parsed.data ?? parsed;
  };

  describe('GET /model', () => {
    // A session whose workspace has no statusLine exporter has nothing to report. Saying so is
    // the point: a UI that renders a guess here would show a model the session is not using.
    it('reports pending when nothing has been observed', async () => {
      const res = await get();
      expect(res.statusCode).toBe(200);
      expect(body(res)).toMatchObject({ available: true, pending: true });
      expect(body(res).model).toBeUndefined();
    });

    it('reports the observed model and effort once the statusline has rendered', async () => {
      session().applyModelObservation({
        modelId: 'claude-opus-4-5-20251101',
        modelDisplayName: 'Opus 4.5',
        effortLevel: 'high',
      });
      const res = await get();
      expect(body(res)).toMatchObject({
        available: true,
        pending: false,
        model: 'Opus 4.5',
        modelId: 'claude-opus-4-5-20251101',
        effort: 'high',
        effortSupported: true,
      });
    });

    // ⚠️ An observed model carrying no effort means the model has NO effort dial — different from
    // "not yet known", and the client should hide the control rather than disable it.
    it('distinguishes a model with no effort dial from an unobserved one', async () => {
      session().applyModelObservation({ modelDisplayName: 'Haiku 4.5' });
      expect(body(await get())).toMatchObject({ pending: false, effortSupported: false });
    });

    it('offers auto alongside the concrete levels', async () => {
      expect(body(await get()).effortOptions).toContain('auto');
      expect(body(await get()).effortOptions).toContain('xhigh');
    });

    it('reports unavailable for a non-Claude session instead of guessing', async () => {
      session().mode = 'codex';
      expect(body(await get())).toMatchObject({ available: false, pending: false });
    });
  });

  describe('POST /model', () => {
    it('types the slash command into the pane, ending with a carriage return', async () => {
      const res = await setModel({ model: 'opus' });
      expect(res.statusCode).toBe(200);
      // ⚠️ Without the trailing \r the command is never submitted — it just sits in the composer.
      expect(written()).toContain('/model opus\r');
    });

    it('accepts a full model id and the 1M-context suffix', async () => {
      expect((await setModel({ model: 'claude-opus-4-5-20251101' })).statusCode).toBe(200);
      expect((await setModel({ model: 'claude-opus-4-5-20251101[1m]' })).statusCode).toBe(200);
    });

    // The allowlist is the safety property: a newline would end the typed line early and leave
    // "rm -rf ..." sitting in the composer as a prompt.
    it('refuses a name that could break out of the typed line', async () => {
      for (const model of ['opus\rrm -rf /', 'opus\nx', 'opus; echo hi', 'opus $(id)']) {
        const res = await setModel({ model });
        expect(res.statusCode).toBe(400);
      }
      expect(written()).toHaveLength(0);
    });

    // The CLI confirms only on its next statusline render, so reporting a new model here would be
    // asserting something we have not seen.
    it('never claims the switch took effect', async () => {
      const res = body(await setModel({ model: 'opus' }));
      expect(res).toMatchObject({ sent: true, confirmPending: true });
      expect(res.model).toBeUndefined();
      expect(body(await get()).model).toBeUndefined();
    });

    it('surfaces a delivery failure rather than reporting success', async () => {
      session().failWrites = true;
      expect((await setModel({ model: 'opus' })).statusCode).toBe(503);
    });

    it('refuses a non-Claude session', async () => {
      session().mode = 'opencode';
      expect((await setModel({ model: 'opus' })).statusCode).toBe(400);
      expect(written()).toHaveLength(0);
    });

    it('rejects a malformed body', async () => {
      expect((await setModel({})).statusCode).toBe(400);
      expect((await setModel({ model: '' })).statusCode).toBe(400);
    });
  });

  describe('POST /effort', () => {
    it('types the slash command and persists the level as the new spawn default', async () => {
      const res = await setEffort({ effort: 'xhigh' });
      expect(res.statusCode).toBe(200);
      expect(written()).toContain('/effort xhigh\r');
      // ⚠️ An EXPLICIT change is a durable preference, so a respawn must relaunch at this level.
      expect(session().configuredEffort).toBe('xhigh');
      expect(ctx.persistSessionState).toHaveBeenCalled();
    });

    // `auto` tells the CLI to choose; there is no level to rebuild `--effort` from.
    it('sends auto but does not persist it as a level', async () => {
      await setEffort({ effort: 'auto' });
      expect(written()).toContain('/effort auto\r');
      expect(session().configuredEffort).toBeUndefined();
    });

    it('rejects a level the CLI does not accept', async () => {
      expect((await setEffort({ effort: 'turbo' })).statusCode).toBe(400);
      expect(written()).toHaveLength(0);
    });

    it('refuses a non-Claude session', async () => {
      session().mode = 'gemini';
      expect((await setEffort({ effort: 'high' })).statusCode).toBe(400);
      expect(written()).toHaveLength(0);
    });

    it('surfaces a delivery failure and leaves the spawn default alone', async () => {
      session().failWrites = true;
      expect((await setEffort({ effort: 'low' })).statusCode).toBe(503);
      expect(session().configuredEffort).toBeUndefined();
    });
  });
});
