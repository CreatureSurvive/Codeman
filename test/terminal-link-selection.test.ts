import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import vm from 'node:vm';
import { describe, expect, it, vi } from 'vitest';

function loadHarness() {
  const CodemanApp = function CodemanApp(this: any) {};
  const opened = vi.fn(() => ({}));
  const nativeOpen = vi.fn(async () => ({}));
  const context = vm.createContext({
    window: { open: opened },
    document: { body: { classList: { contains: () => false } } },
    CodemanApp,
    URL,
    console: { warn: vi.fn(), log: vi.fn() },
    _crashDiag: { log: vi.fn() },
    performance: { now: () => 1_000 },
    requestAnimationFrame: (_fn: () => void) => 1,
    setTimeout: (_fn: () => void) => 1,
    Blob: function Blob() {},
    Worker: function Worker(this: any) {
      this.postMessage = () => {};
    },
    MobileDetection: { isTouchDevice: () => true },
    DEC_SYNC_STRIP_RE: /\x1b\[\?2026[hl]/g,
    TERMINAL_CHUNK_SIZE: 32 * 1024,
  });
  const code = readFileSync(resolve(import.meta.dirname, '../src/web/public/terminal-ui.js'), 'utf8');
  vm.runInContext(code, context, { filename: 'terminal-ui.js' });
  return { app: new (CodemanApp as any)(), window: context.window as any, opened, nativeOpen };
}

function terminal(lines: string[], cols = 40) {
  const select = vi.fn();
  return {
    cols,
    rows: lines.length,
    select,
    buffer: {
      active: {
        viewportY: 0,
        length: lines.length,
        getLine: (row: number) =>
          lines[row] === undefined
            ? undefined
            : { isWrapped: row > 0, translateToString: (trim: boolean) => (trim ? lines[row].trimEnd() : lines[row]) },
      },
    },
  };
}

describe('terminal URL activation', () => {
  it('uses a new browser tab on the web', async () => {
    const { app, opened } = loadHarness();

    await expect(app._openTerminalUrl('https://example.com/a?b=1')).resolves.toBe(true);
    expect(opened).toHaveBeenCalledWith('https://example.com/a?b=1', '_blank', 'noopener,noreferrer');
  });

  it('uses the Capacitor in-app browser when native', async () => {
    const { app, window, opened, nativeOpen } = loadHarness();
    window.CodemanNative = { isNative: true, openExternal: nativeOpen };

    await expect(app._openTerminalUrl('https://example.com/path')).resolves.toBe(true);
    expect(nativeOpen).toHaveBeenCalledWith('https://example.com/path');
    expect(opened).not.toHaveBeenCalled();
  });

  it('rejects non-web schemes', async () => {
    const { app, opened } = loadHarness();

    await expect(app._openTerminalUrl('javascript:alert(1)')).resolves.toBe(false);
    expect(opened).not.toHaveBeenCalled();
  });

  it('finds a URL under a touched cell across wrapped rows', () => {
    const { app } = loadHarness();
    app.terminal = terminal(['prefix https://example.com/a?b=1&', 'c=2 suffix'], 34);
    app._clientPointToCell = () => ({ col: 3, row: 2 });

    expect(app._terminalUrlAtPoint(10, 10)).toBe('https://example.com/a?b=1&c=2');
  });
});

describe('mobile terminal selection', () => {
  it('long-press selection starts with the touched word and can extend', () => {
    const { app } = loadHarness();
    app.terminal = terminal(['alpha beta gamma', 'delta epsilon'], 40);
    app._clientPointToCell = vi.fn().mockReturnValueOnce({ col: 8, row: 1 }).mockReturnValueOnce({ col: 6, row: 2 });

    expect(app._beginMobileTerminalSelection(10, 10)).toBe(true);
    expect(app.terminal.select).toHaveBeenNthCalledWith(1, 6, 0, 4);

    app._updateMobileTerminalSelection(10, 20);
    expect(app.terminal.select).toHaveBeenLastCalledWith(6, 0, 40);
  });
});
