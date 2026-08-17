/**
 * @fileoverview Centralized API fetch helpers mixed into CodemanApp.prototype.
 *
 * Provides _api(), _apiJson(), _apiPost(), _apiPut(), _apiDelete() methods that handle
 * JSON serialization, Content-Type headers, and error swallowing. All API calls in the
 * frontend route through these helpers.
 *
 * @mixin Extends CodemanApp.prototype via Object.assign
 * @dependency app.js (CodemanApp class must be defined)
 * @loadorder 14 of 15 — loaded after ralph-wizard.js
 */

// Codeman — Centralized API fetch helpers for CodemanApp
// Loaded after app.js (needs CodemanApp class defined)

Object.assign(CodemanApp.prototype, {
  _shouldProxyNodePath(path) {
    if (!this.currentNodeId || this.currentNodeId === 'local') return false;
    if (typeof path !== 'string' || !path.startsWith('/api/')) return false;
    return [
      '/api/status',
      '/api/events',
      '/api/cases',
      '/api/filesystem',
      '/api/history',
      '/api/quick-start',
      '/api/search',
      '/api/sessions',
      '/api/opencode',
      '/api/codex',
      '/api/gemini',
      '/api/antigravity',
      '/api/remote-hosts',
      '/api/docker-hosts',
      '/api/docker-cases',
      '/api/docker-exports',
    ].some((prefix) => path === prefix || path.startsWith(prefix + '/') || path.startsWith(prefix + '?'));
  },

  _nodeApiPath(path) {
    if (!this._shouldProxyNodePath(path)) return path;
    return `/api/nodes/${encodeURIComponent(this.currentNodeId)}/proxy${path}`;
  },

  _nodeFetch(path, init) {
    const url = this._nodeApiPath(path);
    const fetcher = window.__codemanNativeFetch || window.fetch.bind(window);
    return fetcher(url, init);
  },

  _installNodeFetchProxy() {
    if (window.__codemanNodeFetchProxyInstalled) return;
    window.__codemanNodeFetchProxyInstalled = true;
    window.__codemanNativeFetch = window.fetch.bind(window);
    window.fetch = (resource, init) => {
      try {
        const app = window.app;
        if (!app || !app._nodeApiPath) return window.__codemanNativeFetch(resource, init);
        if (typeof resource === 'string') {
          return window.__codemanNativeFetch(app._nodeApiPath(resource), init);
        }
        if (resource instanceof URL && resource.origin === location.origin) {
          const next = new URL(app._nodeApiPath(resource.pathname + resource.search), location.origin);
          return window.__codemanNativeFetch(next, init);
        }
        if (resource instanceof Request && resource.url.startsWith(location.origin + '/api/')) {
          const url = new URL(resource.url);
          const next = new Request(app._nodeApiPath(url.pathname + url.search), resource);
          return window.__codemanNativeFetch(next, init);
        }
      } catch {
        /* fall through to native fetch */
      }
      return window.__codemanNativeFetch(resource, init);
    };
  },

  async loadFederationNodes() {
    const res = await (window.__codemanNativeFetch || fetch)('/api/nodes').catch(() => null);
    if (!res || !res.ok) return;
    const body = await res.json().catch(() => null);
    const data = body?.success === true ? body.data : body;
    const local = data?.local ? [{ ...data.local, id: 'local' }] : [{ id: 'local', name: 'Local', enabled: true }];
    this.nodes = [...local, ...(Array.isArray(data?.nodes) ? data.nodes : [])];
    if (!this.nodes.some((node) => node.id === this.currentNodeId && node.enabled !== false))
      this.currentNodeId = 'local';
    this.renderNodeSelector?.();
    this.renderFederationNodes?.();
    this.refreshCliAvailability?.();
  },

  renderNodeSelector() {
    const select = document.getElementById('nodeSelector');
    if (!select) return;
    const nodeList = this.nodes.length ? this.nodes : [{ id: 'local', name: 'Local' }];
    select.replaceChildren();
    for (const node of nodeList) {
      const option = document.createElement('option');
      option.value = node.id;
      option.textContent =
        node.id === 'local' ? `${node.name || 'Local'} (local)` : node.name || node.baseUrl || node.id;
      option.disabled = node.enabled === false;
      select.appendChild(option);
    }
    select.value = this.currentNodeId || 'local';
    select.parentElement?.classList.toggle('node-selector--remote', select.value !== 'local');
    const trigger = document.getElementById('nodeSelectorMobileTrigger');
    if (trigger) {
      const current = nodeList.find((node) => node.id === select.value) || nodeList[0];
      const name =
        current?.id === 'local' ? current?.name || 'Local' : current?.name || current?.baseUrl || current?.id;
      trigger.title = `Switch Codeman node: ${name || 'Local'}`;
      trigger.setAttribute('aria-label', `Switch Codeman node. Current: ${name || 'Local'}`);
    }
    this.renderNodeMenu?.();
  },

  renderNodeMenu() {
    const menu = document.getElementById('nodeSelectorMenu');
    if (!menu) return;
    const nodeList = this.nodes.length ? this.nodes : [{ id: 'local', name: 'Local' }];
    menu.replaceChildren();
    for (const node of nodeList) {
      const item = document.createElement('button');
      item.type = 'button';
      item.className = 'node-selector-menu-item';
      item.dataset.nodeId = node.id;
      item.disabled = node.enabled === false;
      const selected = node.id === (this.currentNodeId || 'local');
      item.setAttribute('aria-pressed', String(selected));
      if (selected) item.classList.add('selected');
      const name = node.id === 'local' ? node.name || 'Local' : node.name || node.baseUrl || node.id;
      item.innerHTML = `
        <span class="node-selector-menu-dot" aria-hidden="true"></span>
        <span class="node-selector-menu-label"></span>
        <span class="node-selector-menu-check" aria-hidden="true">${selected ? '✓' : ''}</span>
      `;
      item.querySelector('.node-selector-menu-label').textContent = node.id === 'local' ? `${name} (local)` : name;
      item.addEventListener('click', () => this.selectNodeFromMenu(node.id));
      menu.appendChild(item);
    }
  },

  toggleNodeMenu(event) {
    event?.preventDefault?.();
    event?.stopPropagation?.();
    const menu = document.getElementById('nodeSelectorMenu');
    const trigger = document.getElementById('nodeSelectorMobileTrigger');
    if (!menu || !trigger) return;
    const willOpen = menu.hidden;
    if (willOpen) {
      if (menu.parentElement !== document.body) document.body.appendChild(menu);
      this.renderNodeMenu?.();
      menu.hidden = false;
      trigger.setAttribute('aria-expanded', 'true');
      this._nodeMenuOutsideHandler = (outsideEvent) => {
        if (menu.contains(outsideEvent.target) || trigger.contains(outsideEvent.target)) return;
        this.closeNodeMenu?.();
      };
      document.addEventListener('pointerdown', this._nodeMenuOutsideHandler, { capture: true });
    } else {
      this.closeNodeMenu?.();
    }
  },

  closeNodeMenu() {
    const menu = document.getElementById('nodeSelectorMenu');
    const trigger = document.getElementById('nodeSelectorMobileTrigger');
    if (menu) menu.hidden = true;
    if (trigger) trigger.setAttribute('aria-expanded', 'false');
    if (this._nodeMenuOutsideHandler) {
      document.removeEventListener('pointerdown', this._nodeMenuOutsideHandler, { capture: true });
      this._nodeMenuOutsideHandler = null;
    }
  },

  async selectNodeFromMenu(nodeId) {
    this.closeNodeMenu?.();
    await this.setCurrentNode(nodeId);
  },

  async setCurrentNode(nodeId) {
    const next = nodeId || 'local';
    if (next === this.currentNodeId) return;
    this.currentNodeId = next;
    try {
      localStorage.setItem('codeman-current-node', next);
    } catch {}
    this.renderNodeSelector?.();
    this._disconnectWs?.();
    if (this.eventSource) {
      this.eventSource.close();
      this.eventSource = null;
    }
    this.sessions.clear();
    this.sessionOrder = [];
    this.activeSessionId = null;
    this.cases = [];
    this._historyAll = [];
    this._historyCases = [];
    this._mobileOverviewHistory = [];
    this._folderHistoryState = null;
    this.renderSessionTabs?.();
    this.connectSSE?.();
    await this.loadState?.();
    this.loadQuickStartCases?.();
    this.refreshCliAvailability?.();
    if (this.isMobileOverviewVisible?.()) {
      this.renderMobileOverview?.();
      this.loadMobileOverviewHistory?.();
    } else if (document.getElementById('welcomeOverlay')?.classList.contains('visible')) {
      this.loadHistorySessions?.();
    }
  },

  async saveFederationNodeFromSettings() {
    const name = document.getElementById('nodeNameInput')?.value.trim() || '';
    const baseUrl = document.getElementById('nodeUrlInput')?.value.trim() || '';
    const token = document.getElementById('nodeTokenInput')?.value.trim() || '';
    if (!name || !baseUrl) {
      this.showToast?.('Node needs a name and URL', 'error');
      return;
    }
    const res = await (window.__codemanNativeFetch || fetch)('/api/nodes', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ name, baseUrl, token }),
    }).catch(() => null);
    if (!res || !res.ok) {
      this.showToast?.('Could not save node', 'error');
      return;
    }
    ['nodeNameInput', 'nodeUrlInput', 'nodeTokenInput'].forEach((id) => {
      const el = document.getElementById(id);
      if (el) el.value = '';
    });
    await this.loadFederationNodes();
    this.showToast?.('Node saved', 'success');
  },

  async testFederationNode(nodeId) {
    const res = await (window.__codemanNativeFetch || fetch)(`/api/nodes/${encodeURIComponent(nodeId)}/test`, {
      method: 'POST',
    }).catch(() => null);
    const body = await res?.json?.().catch(() => null);
    await this.loadFederationNodes();
    const ok = (body?.success === true ? body.data : body)?.ok === true;
    this.showToast?.(ok ? 'Node is reachable' : 'Node check failed', ok ? 'success' : 'error');
  },

  async removeFederationNode(nodeId) {
    await (window.__codemanNativeFetch || fetch)(`/api/nodes/${encodeURIComponent(nodeId)}`, {
      method: 'DELETE',
    }).catch(() => null);
    if (this.currentNodeId === nodeId) await this.setCurrentNode('local');
    await this.loadFederationNodes();
  },

  renderFederationNodes() {
    const list = document.getElementById('appSettingsNodesList');
    if (!list) return;
    const remoteNodes = (this.nodes || []).filter((node) => node.id !== 'local');
    if (remoteNodes.length === 0) {
      list.innerHTML = '<div class="set-empty">No remote nodes yet.</div>';
      return;
    }
    list.replaceChildren();
    for (const node of remoteNodes) {
      const row = document.createElement('div');
      row.className = 'node-settings-row';
      const text = document.createElement('div');
      text.className = 'node-settings-text';
      const name = document.createElement('span');
      name.className = 'node-settings-name';
      name.textContent = node.name || node.id;
      const url = document.createElement('span');
      url.className = 'node-settings-url';
      const status = node.lastHealth?.ok === true ? 'online' : node.lastHealth?.ok === false ? 'offline' : 'unchecked';
      url.textContent = `${node.baseUrl} · ${status}`;
      text.append(name, url);

      const actions = document.createElement('div');
      actions.className = 'node-settings-actions';
      const select = document.createElement('button');
      select.type = 'button';
      select.className = 'btn-toolbar btn-sm';
      select.textContent = 'Use';
      select.addEventListener('click', () => this.setCurrentNode(node.id));
      const test = document.createElement('button');
      test.type = 'button';
      test.className = 'btn-toolbar btn-sm';
      test.textContent = 'Test';
      test.addEventListener('click', () => this.testFederationNode(node.id));
      const remove = document.createElement('button');
      remove.type = 'button';
      remove.className = 'btn-toolbar btn-sm';
      remove.textContent = 'Remove';
      remove.addEventListener('click', () => this.removeFederationNode(node.id));
      actions.append(select, test, remove);
      row.append(text, actions);
      list.appendChild(row);
    }
  },

  /**
   * Send a JSON API request. Handles Content-Type, JSON serialization, and error swallowing.
   * @param {string} path - API path (e.g., '/api/sessions/123/input')
   * @param {object} [opts] - { method, body, signal }
   * @returns {Promise<Response|null>} Response or null on error
   */
  async _api(path, opts = {}) {
    const { method = 'GET', body, signal } = opts;
    const fetchOpts = { method, signal };
    if (body !== undefined) {
      fetchOpts.headers = { 'Content-Type': 'application/json' };
      fetchOpts.body = JSON.stringify(body);
    }
    try {
      const res = await this._nodeFetch(path, fetchOpts);
      return res;
    } catch {
      return null;
    }
  },

  /**
   * Send a JSON API request and parse the response as JSON.
   * @param {string} path - API path
   * @param {object} [opts] - { method, body, signal }
   * @returns {Promise<any|null>} Parsed JSON or null on error
   */
  async _apiJson(path, opts = {}) {
    const res = await this._api(path, opts);
    if (!res || !res.ok) return null;
    let body;
    try {
      body = await res.json();
    } catch {
      return null;
    }
    // Uniform API envelope (stable HTTP contract): unwrap { success:true, data } → data;
    // { success:false } → null (errors also surface as a non-ok HTTP status above).
    // Legacy/bare bodies pass through unchanged.
    if (body && typeof body === 'object') {
      if (body.success === false) return null;
      if (body.success === true && 'data' in body) return body.data;
    }
    return body;
  },

  /**
   * POST JSON to an API endpoint (most common pattern).
   * @param {string} path - API path
   * @param {object} body - JSON body
   * @returns {Promise<Response|null>}
   */
  async _apiPost(path, body) {
    return this._api(path, { method: 'POST', body });
  },

  /**
   * PUT JSON to an API endpoint.
   * @param {string} path - API path
   * @param {object} body - JSON body
   * @returns {Promise<Response|null>}
   */
  async _apiPut(path, body) {
    return this._api(path, { method: 'PUT', body });
  },

  /**
   * DELETE an API resource.
   * @param {string} path - API path
   * @returns {Promise<Response|null>}
   */
  async _apiDelete(path) {
    return this._api(path, { method: 'DELETE' });
  },
});
