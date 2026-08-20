import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';

const source = readFileSync(new URL('../src/web/public/app.js', import.meta.url), 'utf8');

function methodBody(name: string, nextName: string): string {
  const start = source.indexOf(`  ${name}(`);
  const end = source.indexOf(`  ${nextName}(`, start + 1);
  expect(start).toBeGreaterThanOrEqual(0);
  expect(end).toBeGreaterThan(start);
  return source.slice(start, end);
}

describe('terminal output transport ownership', () => {
  it('routes SSE terminal output directly to the terminal pipeline', () => {
    const body = methodBody('_onSSETerminal', '_onSSENeedsRefresh');

    expect(body).toContain('this._onSessionTerminal(data)');
    expect(body).not.toContain('_shouldSuppressSseTerminal');
  });

  it('uses WebSocket only for control and input acknowledgements', () => {
    const body = methodBody('_connectWs', '_disconnectWs');

    expect(body).toContain("if (msg.t === 'ia')");
    expect(body).not.toContain("msg.t === 'o'");
    expect(body).not.toContain("msg.t === 'c'");
    expect(body).not.toContain("msg.t === 'r'");
    expect(source).not.toContain('_markWsTerminalOutput');
    expect(source).not.toContain('_shouldSuppressSseTerminal');
  });
});
