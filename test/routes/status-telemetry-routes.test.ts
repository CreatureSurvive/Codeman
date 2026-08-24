/**
 * Route tests for POST /api/status-telemetry — the Claude statusline exporter
 * endpoint that feeds the header "Plan Usage Limits" chip.
 *
 * Covers: broadcast on real telemetry + footer print-through, unknown-session
 * skip, per-session change-detection (dedup), rebroadcast on a displayed change,
 * NO rebroadcast on context-only drift, null-tolerance of Claude's undocumented
 * fields (the .nullish() schema — the project's recurring .optional()/null trap),
 * and 400 on a malformed body.
 */
import { describe, it, expect, beforeEach } from 'vitest';
import { createRouteTestHarness, type RouteTestHarness } from './_route-test-utils.js';
import { registerStatusTelemetryRoutes } from '../../src/web/routes/status-telemetry-routes.js';
import { SessionStatusTelemetry, SessionModelInfo } from '../../src/web/sse-events.js';

const SID = 'test-session-1'; // default id created by createMockRouteContext

const REAL = {
  rate_limits: {
    five_hour: { used_percentage: 15, resets_at: 1781409000 },
    seven_day: { used_percentage: 34, resets_at: 1781827200 },
  },
  context_window: { used_percentage: 56, total_input_tokens: 562411, total_output_tokens: 1188 },
  cost: { total_cost_usd: 0.0415 },
  model: { display_name: 'Opus 4.8 (1M context)' },
};

describe('POST /api/status-telemetry', () => {
  let h: RouteTestHarness;

  beforeEach(async () => {
    h = await createRouteTestHarness(registerStatusTelemetryRoutes, { sessionId: SID });
  });

  const post = (body: unknown) => h.app.inject({ method: 'POST', url: '/api/status-telemetry', payload: body });

  /**
   * Broadcasts of ONE event.
   *
   * ⚠️ These assertions are about the plan-usage feed specifically, so they must not count the
   * whole `broadcast` mock: the same POST also emits `session:modelInfo` on a model change, and a
   * bare call count would make a dedup test fail for a completely unrelated reason.
   */
  const calls = (event: string) => h.ctx.broadcast.mock.calls.filter(([name]: [string]) => name === event);

  it('broadcasts plan-usage telemetry and returns the session-status footer', async () => {
    const res = await post({ sessionId: SID, data: REAL });
    expect(res.statusCode).toBe(200);
    expect(res.headers['content-type']).toContain('text/plain');
    expect(res.body).toBe('Opus 4.8 (1M context)  in:562,411 out:1,188  ctx:56%');
    expect(calls(SessionStatusTelemetry)).toHaveLength(1);
    const [, payload] = calls(SessionStatusTelemetry)[0];
    expect(payload).toMatchObject({
      sessionId: SID,
      fiveHour: { usedPercentage: 15 },
      sevenDay: { usedPercentage: 34 },
    });
  });

  it('does not broadcast for an unknown session; returns the brand footer', async () => {
    const res = await post({ sessionId: 'does-not-exist', data: REAL });
    expect(res.statusCode).toBe(200);
    expect(res.body).toBe('codeman');
    expect(h.ctx.broadcast).not.toHaveBeenCalled();
  });

  it('dedups identical telemetry — rebroadcasts only once', async () => {
    await post({ sessionId: SID, data: REAL });
    await post({ sessionId: SID, data: REAL });
    expect(calls(SessionStatusTelemetry)).toHaveLength(1);
  });

  it('rebroadcasts when a displayed window percentage changes', async () => {
    await post({ sessionId: SID, data: REAL });
    const moved = {
      ...REAL,
      rate_limits: { ...REAL.rate_limits, five_hour: { used_percentage: 16, resets_at: 1781409000 } },
    };
    await post({ sessionId: SID, data: moved });
    expect(calls(SessionStatusTelemetry)).toHaveLength(2);
  });

  it('does NOT rebroadcast on context-only drift (the chip never shows context %)', async () => {
    await post({ sessionId: SID, data: REAL });
    await post({ sessionId: SID, data: { ...REAL, context_window: { ...REAL.context_window, used_percentage: 91 } } });
    expect(calls(SessionStatusTelemetry)).toHaveLength(1);
  });

  it("tolerates null in Claude's undocumented fields (no 400) and ignores them", async () => {
    const res = await post({
      sessionId: SID,
      data: {
        rate_limits: { five_hour: { used_percentage: 20, resets_at: 1781409000 }, seven_day: null },
        cost: { total_cost_usd: null },
        model: { display_name: null },
        context_window: { used_percentage: null, total_input_tokens: null, total_output_tokens: null },
      },
    });
    expect(res.statusCode).toBe(200);
    expect(calls(SessionStatusTelemetry)).toHaveLength(1);
    const [, payload] = calls(SessionStatusTelemetry)[0];
    expect(payload).toMatchObject({ fiveHour: { usedPercentage: 20 } });
    expect(payload.sevenDay).toBeUndefined();
  });

  // ⚠️ These two fields reach the parser ONLY because StatusTelemetrySchema models them —
  // z.object strips unknown keys, so an unmodeled `effort` is dropped silently and the live
  // readout is permanently empty with no error to explain it.
  it('broadcasts the live model and effort, and survives the schema', async () => {
    await post({
      sessionId: SID,
      data: { ...REAL, model: { id: 'claude-opus-4-5-20251101', display_name: 'Opus 4.5' }, effort: { level: 'high' } },
    });
    expect(calls(SessionModelInfo)).toHaveLength(1);
    const [, payload] = calls(SessionModelInfo)[0];
    expect(payload).toMatchObject({
      sessionId: SID,
      model: 'Opus 4.5',
      modelId: 'claude-opus-4-5-20251101',
      effort: 'high',
    });
  });

  // The statusline fires on every assistant message; model and effort move about once a day.
  it('does not rebroadcast model info while the model is unchanged', async () => {
    const data = { ...REAL, model: { id: 'm', display_name: 'Opus 4.5' }, effort: { level: 'high' } };
    await post({ sessionId: SID, data });
    await post({ sessionId: SID, data: { ...data, context_window: { ...REAL.context_window, used_percentage: 91 } } });
    expect(calls(SessionModelInfo)).toHaveLength(1);
  });

  it('rebroadcasts when the user switches effort in-session', async () => {
    const data = { ...REAL, model: { id: 'm', display_name: 'Opus 4.5' }, effort: { level: 'high' } };
    await post({ sessionId: SID, data });
    await post({ sessionId: SID, data: { ...data, effort: { level: 'xhigh' } } });
    expect(calls(SessionModelInfo)).toHaveLength(2);
    expect(calls(SessionModelInfo)[1][1]).toMatchObject({ effort: 'xhigh' });
  });

  // A model with no effort dial omits the key entirely. Treating that as "effort cleared" would
  // blank a control the UI is showing, so the last known-good value stays.
  it('keeps a known effort when a later render omits the key', async () => {
    await post({ sessionId: SID, data: { ...REAL, model: { display_name: 'Opus 4.5' }, effort: { level: 'high' } } });
    await post({ sessionId: SID, data: { ...REAL, model: { display_name: 'Sonnet 4.5' } } });
    expect(calls(SessionModelInfo)[1][1]).toMatchObject({ model: 'Sonnet 4.5', effort: 'high' });
  });

  it('rejects a malformed body (missing sessionId) with 400', async () => {
    const res = await post({ data: REAL });
    expect(res.statusCode).toBe(400);
  });
});
