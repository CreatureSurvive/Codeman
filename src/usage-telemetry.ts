/**
 * @fileoverview Pure parsing + formatting of Claude Code statusline telemetry.
 *
 * Claude Code (v2.1.80+) pipes a JSON blob to a configured `statusLine.command`
 * on each render. On Pro/Max subscriptions that blob carries a `rate_limits`
 * object with the 5-hour rolling and 7-day weekly plan windows. The
 * Codeman-managed statusLine exporter (see `hooks-config.generateStatusLineCommand`)
 * POSTs that blob to `/api/status-telemetry`; these helpers normalize the subset
 * Codeman displays and format the compact in-terminal footer string.
 *
 * Confirmed schema (empirically captured, CC 2.1.177, Claude Max — see
 * `docs/usage-limits-display-plan.md`):
 *   rate_limits.{five_hour,seven_day}.{used_percentage: number 0-100,
 *                                      resets_at: number EPOCH-SECONDS}
 * Only those two windows exist (no Opus-weekly field). `rate_limits` is absent
 * before the first API response and for non-subscriber auth — both yield null.
 *
 * All functions are pure for testability. See `test/usage-telemetry.test.ts`.
 *
 * @module usage-telemetry
 */

/** A single normalized plan-usage window. */
export interface UsageWindow {
  /** Percent of the window consumed, 0–100. */
  usedPercentage: number;
  /** Epoch MILLISECONDS when the window resets (statusline reports seconds). */
  resetAt: number;
}

/** Normalized telemetry Codeman broadcasts to the UI. */
export interface StatusTelemetry {
  fiveHour?: UsageWindow;
  sevenDay?: UsageWindow;
  /** Context-window percent used, 0–100 (bonus field from the same payload). */
  contextUsedPercentage?: number;
  /** Session cost in USD (bonus field). */
  costUsd?: number;
  /** Model display name, e.g. "Opus 4.8 (1M context)" (bonus field). */
  modelDisplayName?: string;
}

/** Raw subset of the statusline stdin JSON (snake_case, as Claude emits it). */
export interface RawStatuslinePayload {
  rate_limits?: {
    five_hour?: { used_percentage?: number; resets_at?: number };
    seven_day?: { used_percentage?: number; resets_at?: number };
  };
  context_window?: { used_percentage?: number; total_input_tokens?: number; total_output_tokens?: number };
  cost?: { total_cost_usd?: number };
  model?: { id?: string; display_name?: string };
  /**
   * The session's LIVE effort level.
   *
   * ⚠️ Present only for models that support effort — CC 2.1.241 builds the payload as
   * `...supportsEffort(model) && { effort: { level } }`, so an absent key means "this model has
   * no effort dial", NOT "effort is unset". The value is always one of
   * low|medium|high|xhigh|max: `auto` and `ultracode` are *inputs* to `/effort`, never values it
   * reports back (the CLI resolves them before rendering).
   */
  effort?: { level?: string };
}

function clampPct(n: number): number {
  if (!Number.isFinite(n)) return 0;
  return Math.max(0, Math.min(100, n));
}

function parseWindow(w?: { used_percentage?: number; resets_at?: number }): UsageWindow | undefined {
  if (!w || typeof w.used_percentage !== 'number' || typeof w.resets_at !== 'number') return undefined;
  if (!Number.isFinite(w.resets_at) || w.resets_at <= 0) return undefined;
  return { usedPercentage: clampPct(w.used_percentage), resetAt: Math.round(w.resets_at * 1000) };
}

/**
 * Normalize a raw statusline payload to the telemetry Codeman displays. Returns
 * null when there is no plan-limit data to show (pre-first-response or a
 * non-subscriber account) so the caller can skip broadcasting.
 */
export function parseStatusTelemetry(data: RawStatuslinePayload | undefined): StatusTelemetry | null {
  if (!data) return null;
  const fiveHour = parseWindow(data.rate_limits?.five_hour);
  const sevenDay = parseWindow(data.rate_limits?.seven_day);
  if (!fiveHour && !sevenDay) return null;

  const t: StatusTelemetry = {};
  if (fiveHour) t.fiveHour = fiveHour;
  if (sevenDay) t.sevenDay = sevenDay;
  if (typeof data.context_window?.used_percentage === 'number') {
    t.contextUsedPercentage = clampPct(data.context_window.used_percentage);
  }
  if (typeof data.cost?.total_cost_usd === 'number' && Number.isFinite(data.cost.total_cost_usd)) {
    t.costUsd = data.cost.total_cost_usd;
  }
  if (typeof data.model?.display_name === 'string' && data.model.display_name) {
    t.modelDisplayName = data.model.display_name.slice(0, 60);
  }
  return t;
}

/**
 * Current-session status for the in-terminal statusline footer. This is the
 * "status of the current session" the user sees in Claude's footer — distinct
 * from the account-wide plan limits, which live ONLY in the Codeman header chip.
 */
export interface SessionStatus {
  modelDisplayName?: string;
  inputTokens?: number;
  outputTokens?: number;
  contextUsedPercentage?: number;
}

/**
 * The session's LIVE model and effort, as Claude itself reports them on every statusline render.
 *
 * ⚠️ This is the only reliable source for either value. `Session._cliModel` is scraped from the
 * CLI's startup BANNER, which scrolls away and is gone entirely after a tmux recovery — measured
 * null on all 11 live sessions. `Session._effort` is the SPAWN-time soft default, so it goes stale
 * the moment the user runs `/effort` in-session. The statusline blob carries both, already flows
 * into `POST /api/status-telemetry` on every assistant message, and costs nothing extra to read.
 *
 * Null when the payload carries neither, so a caller can leave a known-good value in place rather
 * than blanking it on a partial render.
 */
export interface SessionModelInfo {
  /** Canonical id, e.g. `claude-opus-4-5-20251101`. */
  modelId?: string;
  /** What the user sees, e.g. `Opus 4.5` or `Opus 4.8 (1M context)`. */
  modelDisplayName?: string;
  /** low|medium|high|xhigh|max — absent when the model has no effort dial. */
  effortLevel?: string;
}

/**
 * Effort levels Claude's statusline can report, which is also the set `/effort` accepts as a
 * concrete level.
 *
 * ⚠️ Deliberately NOT `EFFORT_LEVELS` from `types/session.ts`: that one includes `ultracode`,
 * which is a Codeman spawn flag (`--settings '{"ultracode":true}'`) rather than a level the CLI
 * ever reports, and importing it here would couple this pure parser to the session types.
 */
export const STATUSLINE_EFFORT_LEVELS = ['low', 'medium', 'high', 'xhigh', 'max'] as const;

/**
 * Extract the live model + effort from a raw statusline payload.
 *
 * Separate from `parseSessionStatus` because the two have different lifetimes: session status is
 * per-render display data that the footer rebuilds every time, while model/effort is durable state
 * worth storing on the Session and broadcasting only when it CHANGES.
 */
export function parseSessionModelInfo(data: RawStatuslinePayload | undefined): SessionModelInfo | null {
  if (!data) return null;
  const info: SessionModelInfo = {};
  if (typeof data.model?.id === 'string' && data.model.id) {
    info.modelId = data.model.id.slice(0, 80);
  }
  if (typeof data.model?.display_name === 'string' && data.model.display_name) {
    info.modelDisplayName = data.model.display_name.slice(0, 60);
  }
  const level = data.effort?.level;
  // Ignore an unrecognized level rather than storing it: a future CLI could add one, and a value
  // the UI cannot render is worse than showing the last known-good one.
  if (typeof level === 'string' && (STATUSLINE_EFFORT_LEVELS as readonly string[]).includes(level)) {
    info.effortLevel = level;
  }
  return Object.keys(info).length ? info : null;
}

/** Group a non-negative integer with thousands separators: 562411 → "562,411". */
function withCommas(n: number): string {
  return Math.max(0, Math.round(n))
    .toString()
    .replace(/\B(?=(\d{3})+(?!\d))/g, ',');
}

/** Extract current-session status (footer) from the raw payload. */
export function parseSessionStatus(data: RawStatuslinePayload | undefined): SessionStatus | null {
  if (!data) return null;
  const s: SessionStatus = {};
  if (typeof data.model?.display_name === 'string' && data.model.display_name) {
    s.modelDisplayName = data.model.display_name.slice(0, 60);
  }
  const cw = data.context_window;
  if (typeof cw?.total_input_tokens === 'number' && Number.isFinite(cw.total_input_tokens)) {
    s.inputTokens = Math.max(0, cw.total_input_tokens);
  }
  if (typeof cw?.total_output_tokens === 'number' && Number.isFinite(cw.total_output_tokens)) {
    s.outputTokens = Math.max(0, cw.total_output_tokens);
  }
  if (typeof cw?.used_percentage === 'number') {
    s.contextUsedPercentage = clampPct(cw.used_percentage);
  }
  return Object.keys(s).length ? s : null;
}

/**
 * Format the in-terminal statusline footer: the CURRENT SESSION's status —
 * `Opus 4.8 (1M context)  in:562,411 out:1,188  ctx:56%` — NOT the plan limits,
 * which live in the Codeman header chip. Claude requires a statusLine command to
 * emit the rate_limits JSON at all, so this is what that command prints back.
 */
export function formatSessionStatusText(s: SessionStatus | null): string {
  if (!s) return 'codeman';
  const groups: string[] = [];
  if (s.modelDisplayName) groups.push(s.modelDisplayName);
  const tok: string[] = [];
  if (s.inputTokens != null) tok.push(`in:${withCommas(s.inputTokens)}`);
  if (s.outputTokens != null) tok.push(`out:${withCommas(s.outputTokens)}`);
  if (tok.length) groups.push(tok.join(' '));
  if (s.contextUsedPercentage != null) groups.push(`ctx:${Math.round(clampPct(s.contextUsedPercentage))}%`);
  return groups.length ? groups.join('  ') : 'codeman';
}

/**
 * Stable signature for change-detection — the statusline fires on every
 * assistant message, so the route only rebroadcasts when this value changes.
 *
 * Keys on EXACTLY the values the header chip displays: the two windows' ROUNDED
 * percentages (the chip renders `Math.round`) + their reset times. Deliberately
 * excludes contextUsedPercentage / costUsd / modelDisplayName — none are shown
 * in the chip, and contextUsedPercentage in particular drifts on every assistant
 * message, which would defeat the dedup and fan out a redundant SSE broadcast +
 * localStorage write + identical chip re-render each time.
 */
export function telemetrySignature(t: StatusTelemetry): string {
  return JSON.stringify([
    t.fiveHour ? Math.round(t.fiveHour.usedPercentage) : null,
    t.fiveHour?.resetAt ?? null,
    t.sevenDay ? Math.round(t.sevenDay.usedPercentage) : null,
    t.sevenDay?.resetAt ?? null,
  ]);
}
