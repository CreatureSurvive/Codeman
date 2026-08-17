const STORAGE_KEY = 'codeman.mobile.servers.v1';
const SELECTED_KEY = 'codeman.mobile.selectedServerId';

const plugins = () => window.Capacitor?.Plugins || {};
const tryPlugin = (pluginName, methodName, args) => {
  try {
    const result = plugins()[pluginName]?.[methodName]?.(args || {});
    if (result && typeof result.catch === 'function') result.catch(() => {});
  } catch {
    // Native shell conveniences should not prevent manual server entry.
  }
};

function normalizeUrl(value) {
  const trimmed = String(value || '').trim();
  if (!trimmed) return '';
  let withScheme = trimmed;
  if (!/^[a-z][a-z0-9+.-]*:\/\//i.test(trimmed)) {
    const host = trimmed.split('/')[0].split('@').pop().split(':')[0];
    const isPrivateHost =
      host === 'localhost' ||
      host.endsWith('.local') ||
      /^127\./.test(host) ||
      /^10\./.test(host) ||
      /^192\.168\./.test(host) ||
      /^172\.(1[6-9]|2\d|3[01])\./.test(host);
    withScheme = `${isPrivateHost ? 'http' : 'https'}://${trimmed}`;
  }
  const url = new URL(withScheme);
  url.hash = '';
  return url.toString().replace(/\/$/, '');
}

function parseConnectPayload(raw) {
  const value = String(raw || '').trim();
  if (!value) return null;
  let url;
  try {
    url = new URL(value);
  } catch {
    return null;
  }
  if (url.protocol === 'codeman:') {
    const serverUrl = url.searchParams.get('url');
    if (!serverUrl) return null;
    return {
      name: url.searchParams.get('name') || new URL(serverUrl).host,
      url: normalizeUrl(serverUrl),
    };
  }
  if (url.pathname === '/api/native/connect') {
    const serverUrl = url.searchParams.get('url') || url.origin;
    return {
      name: url.searchParams.get('name') || new URL(serverUrl).host,
      url: normalizeUrl(serverUrl),
    };
  }
  return {
    name: url.host,
    url: normalizeUrl(url.toString()),
  };
}

async function prefsGet(key) {
  const Preferences = plugins().Preferences;
  if (Preferences?.get) return (await Preferences.get({ key })).value;
  return localStorage.getItem(key);
}

async function prefsSet(key, value) {
  const Preferences = plugins().Preferences;
  if (Preferences?.set) return Preferences.set({ key, value });
  localStorage.setItem(key, value);
}

async function loadServers() {
  const raw = await prefsGet(STORAGE_KEY);
  try {
    const parsed = JSON.parse(raw || '[]');
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}

async function saveServers(servers) {
  await prefsSet(STORAGE_KEY, JSON.stringify(servers));
}

async function launchServer(server) {
  await prefsSet(SELECTED_KEY, server.id);
  plugins().Haptics?.selectionChanged?.().catch(() => {});
  window.location.href = server.url;
}

async function testServer(url) {
  const baseUrl = normalizeUrl(url);
  const res = await fetch(`${baseUrl}/api/status`, {
    cache: 'no-store',
    credentials: 'omit',
    mode: 'no-cors',
  });
  if (res.type !== 'opaque' && !res.ok) throw new Error(`HTTP ${res.status}`);
  return baseUrl;
}

function renderServers(servers) {
  const list = document.getElementById('serverList');
  list.replaceChildren();
  if (servers.length === 0) {
    const empty = document.createElement('div');
    empty.className = 'empty';
    empty.textContent = 'No servers saved yet.';
    list.append(empty);
    return;
  }
  for (const server of servers) {
    const row = document.createElement('button');
    row.type = 'button';
    row.className = 'server-row';
    row.addEventListener('click', () => launchServer(server));
    const text = document.createElement('div');
    const name = document.createElement('strong');
    name.textContent = server.name;
    const url = document.createElement('span');
    url.textContent = server.url;
    text.append(name, url);
    const del = document.createElement('button');
    del.type = 'button';
    del.className = 'delete';
    del.textContent = 'x';
    del.addEventListener('click', async (event) => {
      event.stopPropagation();
      const next = servers.filter((item) => item.id !== server.id);
      await saveServers(next);
      renderServers(next);
    });
    row.append(text, del);
    list.append(row);
  }
}

async function addServer(input) {
  const baseUrl = normalizeUrl(input.url);
  const servers = await loadServers();
  const existing = servers.find((server) => server.url === baseUrl);
  const server = {
    id: existing?.id || crypto.randomUUID(),
    name: input.name || new URL(baseUrl).host,
    url: baseUrl,
    createdAt: existing?.createdAt || new Date().toISOString(),
    lastUsedAt: new Date().toISOString(),
    isTrustedLan: /^http:\/\/(localhost|127\.|10\.|172\.(1[6-9]|2\d|3[01])\.|192\.168\.)/.test(baseUrl),
  };
  const next = [server, ...servers.filter((item) => item.id !== server.id)];
  await saveServers(next);
  renderServers(next);
  return server;
}

async function scanQr() {
  const Scanner = plugins().CapacitorBarcodeScanner;
  if (!Scanner?.scanBarcode) {
    alert('QR scanning is not available in this build.');
    return;
  }
  let result;
  try {
    result = await Scanner.scanBarcode({
      hint: 0,
      scanInstructions: 'Scan a Codeman quick-connect QR code',
      scanButton: false,
      cameraDirection: 1,
      scanOrientation: 3,
      cancelButtonAccessibilityLabel: 'Cancel',
      torchButtonOnAccessibilityLabel: 'Turn flashlight off',
      torchButtonOffAccessibilityLabel: 'Turn flashlight on',
    });
  } catch (error) {
    const message = String(error?.message || error || '');
    if (/cancel|cancelled|canceled/i.test(message)) return;
    throw error;
  }
  const payload = parseConnectPayload(result?.ScanResult);
  if (!payload) {
    alert('That QR code is not a Codeman connection.');
    return;
  }
  document.getElementById('serverName').value = payload.name;
  document.getElementById('serverUrl').value = payload.url;
  const server = await addServer(payload);
  await launchServer(server);
}

async function init() {
  tryPlugin('SplashScreen', 'hide');
  tryPlugin('StatusBar', 'setOverlaysWebView', { overlay: false });
  tryPlugin('StatusBar', 'setBackgroundColor', { color: '#0b0f17' });
  tryPlugin('Keyboard', 'setResizeMode', { mode: 'body' });
  plugins().App?.addListener?.('appUrlOpen', async ({ url }) => {
    const payload = parseConnectPayload(url);
    if (!payload) return;
    const server = await addServer(payload);
    await launchServer(server);
  });

  const servers = await loadServers();
  renderServers(servers);
  document.getElementById('scanQrBtn').addEventListener('click', () => {
    scanQr().catch((error) => alert(error.message || 'Could not scan QR code'));
  });
  document.getElementById('testBtn').addEventListener('click', async () => {
    const url = document.getElementById('serverUrl').value;
    try {
      await testServer(url);
      alert('Server is reachable.');
    } catch (error) {
      alert(error.message || 'Server check failed.');
    }
  });
  document.getElementById('serverForm').addEventListener('submit', async (event) => {
    event.preventDefault();
    const name = document.getElementById('serverName').value.trim();
    const url = document.getElementById('serverUrl').value.trim();
    try {
      const server = await addServer({ name, url });
      await launchServer(server);
    } catch (error) {
      alert(error.message || 'Could not save server.');
    }
  });
}

init().catch((error) => {
  console.error(error);
  alert(error.message || 'Codeman failed to start.');
});
