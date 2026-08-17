/**
 * @fileoverview Codeman federation routes.
 *
 * A full UI instance acts as a dashboard by registering remote Codeman nodes.
 * Remote machines may run the same server in headless mode and expose only API,
 * SSE and WebSocket surfaces. Dashboard requests are proxied server-to-server
 * with a bearer token so browser clients never store remote node credentials.
 */

import { FastifyInstance, type FastifyReply, type FastifyRequest } from 'fastify';
import { createRequire } from 'node:module';
import { Readable } from 'node:stream';
import { hostname } from 'node:os';
import type { WebSocket } from 'ws';
import { WebSocket as WsClient } from 'ws';
import { ApiErrorCode, createErrorResponse } from '../../types.js';
import {
  claimPairingCode,
  createFederationToken,
  createPairingCode,
  listFederationTokens,
  revokeFederationToken,
} from '../../federation/node-auth.js';
import { getNode, listNodes, removeNode, setNodeHealth, upsertNode } from '../../federation/node-store.js';
import { requireAdmin } from '../route-helpers.js';

const require = createRequire(import.meta.url);
const { version: APP_VERSION } = require('../../../package.json') as { version: string };

interface NodeRouteOptions {
  headless: boolean;
  port: number;
  https: boolean;
  host: string;
}

function inferBaseUrl(req: FastifyRequest, options: NodeRouteOptions): string {
  const proto = options.https || req.headers['x-forwarded-proto'] === 'https' ? 'https' : 'http';
  const host = req.headers.host || `${options.host}:${options.port}`;
  return `${proto}://${host}`;
}

function responseJson(response: Response): Promise<unknown> {
  return response.json().catch(() => null);
}

function outboundHeaders(nodeToken?: string): Headers {
  const headers = new Headers();
  headers.set('Accept', 'application/json');
  if (nodeToken) headers.set('Authorization', `Bearer ${nodeToken}`);
  return headers;
}

async function proxyFetch(
  req: FastifyRequest,
  reply: FastifyReply,
  nodeId: string,
  upstreamPath: string
): Promise<void> {
  const node = await getNode(nodeId);
  if (!node || !node.enabled) {
    reply.code(404).send(createErrorResponse(ApiErrorCode.NOT_FOUND, 'Node not found'));
    return;
  }
  const url = new URL(upstreamPath, node.baseUrl);
  const headers = outboundHeaders(node.token);
  const requestHeaders = req.headers as Record<string, string | string[] | undefined>;
  if (requestHeaders.accept)
    headers.set('Accept', Array.isArray(requestHeaders.accept) ? requestHeaders.accept[0] : requestHeaders.accept);
  if (requestHeaders['content-type']) {
    headers.set(
      'Content-Type',
      Array.isArray(requestHeaders['content-type']) ? requestHeaders['content-type'][0] : requestHeaders['content-type']
    );
  }
  if (req.method !== 'GET' && req.method !== 'HEAD') headers.set('X-Codeman-CSRF', 'node-proxy');

  let body: string | Buffer | NodeJS.ReadableStream | undefined;
  if (req.method !== 'GET' && req.method !== 'HEAD') {
    const contentType = headers.get('Content-Type') || '';
    if (contentType.includes('multipart/form-data')) {
      body = req.raw;
    } else if (req.body !== undefined) {
      body = typeof req.body === 'string' || req.body instanceof Buffer ? req.body : JSON.stringify(req.body);
      if (!headers.has('Content-Type')) headers.set('Content-Type', 'application/json');
    }
  }

  try {
    const init: RequestInit & { duplex?: 'half' } = { method: req.method, headers, body: body as RequestInit['body'] };
    if (body && typeof body !== 'string' && !Buffer.isBuffer(body)) init.duplex = 'half';
    const upstream = await fetch(url, init);
    reply.code(upstream.status);
    upstream.headers.forEach((value, key) => {
      const lower = key.toLowerCase();
      if (lower === 'content-encoding' || lower === 'content-length' || lower === 'transfer-encoding') return;
      reply.header(key, value);
    });
    if (!upstream.body) {
      reply.send();
      return;
    }
    if ((upstream.headers.get('content-type') || '').includes('text/event-stream')) {
      const inherited: Record<string, number | string | string[]> = {};
      for (const [name, value] of Object.entries(reply.getHeaders())) {
        if (value !== undefined) inherited[name] = value;
      }
      reply.raw.writeHead(upstream.status, {
        ...inherited,
        'Content-Type': 'text/event-stream',
        'Cache-Control': 'no-cache',
        Connection: 'keep-alive',
        'X-Accel-Buffering': 'no',
      });
      try {
        for await (const chunk of Readable.fromWeb(upstream.body)) {
          if (reply.raw.destroyed) break;
          reply.raw.write(chunk);
        }
      } finally {
        if (!reply.raw.destroyed) reply.raw.end();
      }
      return;
    }
    reply.send(Buffer.from(await upstream.arrayBuffer()));
  } catch (err) {
    const message = err instanceof Error ? err.message : 'Could not reach node';
    reply.code(502).send(createErrorResponse(ApiErrorCode.OPERATION_FAILED, message));
  }
}

async function testNode(nodeId: string): Promise<{ ok: boolean; status?: number; message?: string; info?: unknown }> {
  const node = await getNode(nodeId);
  if (!node || !node.enabled) return { ok: false, status: 404, message: 'Node not found' };
  try {
    const res = await fetch(new URL('/api/node/info', node.baseUrl), { headers: outboundHeaders(node.token) });
    const body = await responseJson(res);
    const ok = res.ok;
    const health = {
      ok,
      status: res.status,
      checkedAt: Date.now(),
      message: ok ? undefined : `HTTP ${res.status}`,
    };
    await setNodeHealth(nodeId, health);
    return { ...health, info: body };
  } catch (err) {
    const message = err instanceof Error ? err.message : 'Could not reach node';
    await setNodeHealth(nodeId, { ok: false, checkedAt: Date.now(), message });
    return { ok: false, message };
  }
}

function bridgeWebSockets(browser: WebSocket, nodeId: string, sessionId: string, cid?: string): void {
  void (async () => {
    const node = await getNode(nodeId);
    if (!node || !node.enabled) {
      browser.close(4004, 'Node not found');
      return;
    }
    const base = new URL(node.baseUrl);
    base.protocol = base.protocol === 'https:' ? 'wss:' : 'ws:';
    base.pathname = `/ws/sessions/${encodeURIComponent(sessionId)}/terminal`;
    base.search = cid ? `?cid=${encodeURIComponent(cid)}` : '';
    const remote = new WsClient(base, { headers: node.token ? { Authorization: `Bearer ${node.token}` } : undefined });

    const closeBoth = (code?: number, reason?: Buffer) => {
      try {
        if (browser.readyState === WsClient.OPEN) browser.close(code, reason?.toString('utf-8'));
      } catch {
        /* ignore */
      }
      try {
        if (remote.readyState === WsClient.OPEN) remote.close(code, reason);
      } catch {
        /* ignore */
      }
    };

    remote.on('message', (data, isBinary) => {
      if (browser.readyState === WsClient.OPEN) browser.send(data, { binary: isBinary });
    });
    browser.on('message', (data, isBinary) => {
      if (remote.readyState === WsClient.OPEN) remote.send(data, { binary: isBinary });
    });
    remote.on('close', closeBoth);
    browser.on('close', () => closeBoth());
    remote.on('error', () => closeBoth(1011));
  })().catch(() => browser.close(1011, 'Proxy failed'));
}

export function registerNodeRoutes(app: FastifyInstance, options: NodeRouteOptions): void {
  app.get('/api/node/info', async (req) => ({
    id: hostname(),
    name: process.env.CODEMAN_NODE_NAME || hostname(),
    version: APP_VERSION,
    headless: options.headless,
    baseUrl: inferBaseUrl(req, options),
    capabilities: ['api', 'sse', 'websocket', 'headless', 'pairing'],
  }));

  app.post('/api/node/pair/start', async (req, reply) => {
    if (!requireAdmin(req, reply)) return;
    const body = (req.body || {}) as { name?: string };
    const pair = createPairingCode(body.name);
    return { ...pair, baseUrl: inferBaseUrl(req, options) };
  });

  app.post('/api/node/pair/claim', async (req, reply) => {
    const body = (req.body || {}) as { code?: string; name?: string };
    if (!body.code) return reply.code(400).send(createErrorResponse(ApiErrorCode.INVALID_INPUT, 'code required'));
    const token = await claimPairingCode(body.code, body.name);
    if (!token)
      return reply.code(404).send(createErrorResponse(ApiErrorCode.NOT_FOUND, 'Pairing code expired or invalid'));
    return {
      ...token,
      nodeName: process.env.CODEMAN_NODE_NAME || hostname(),
      nodeId: hostname(),
      version: APP_VERSION,
    };
  });

  app.post('/api/node/tokens', async (req, reply) => {
    if (!requireAdmin(req, reply)) return;
    const body = (req.body || {}) as { name?: string };
    return createFederationToken(body.name);
  });

  app.get('/api/node/tokens', async (req, reply) => {
    if (!requireAdmin(req, reply)) return;
    return listFederationTokens();
  });

  app.delete('/api/node/tokens/:id', async (req, reply) => {
    if (!requireAdmin(req, reply)) return;
    const { id } = req.params as { id: string };
    const ok = await revokeFederationToken(id);
    reply.code(ok ? 204 : 404).send(ok ? undefined : createErrorResponse(ApiErrorCode.NOT_FOUND, 'Token not found'));
  });

  app.get('/api/nodes', async (req, reply) => {
    if (!requireAdmin(req, reply)) return;
    return {
      local: {
        id: 'local',
        name: process.env.CODEMAN_NODE_NAME || hostname(),
        baseUrl: inferBaseUrl(req, options),
        enabled: true,
        headless: options.headless,
      },
      nodes: await listNodes(),
    };
  });

  app.post('/api/nodes', async (req, reply) => {
    if (!requireAdmin(req, reply)) return;
    const body = (req.body || {}) as { name?: string; baseUrl?: string; token?: string; enabled?: boolean };
    if (!body.name || !body.baseUrl) {
      return reply.code(400).send(createErrorResponse(ApiErrorCode.INVALID_INPUT, 'name and baseUrl required'));
    }
    try {
      return upsertNode({ name: body.name, baseUrl: body.baseUrl, token: body.token, enabled: body.enabled });
    } catch (err) {
      return reply
        .code(400)
        .send(createErrorResponse(ApiErrorCode.INVALID_INPUT, err instanceof Error ? err.message : 'Invalid node'));
    }
  });

  app.put('/api/nodes/:id', async (req, reply) => {
    if (!requireAdmin(req, reply)) return;
    const { id } = req.params as { id: string };
    const existing = await getNode(id);
    if (!existing) return reply.code(404).send(createErrorResponse(ApiErrorCode.NOT_FOUND, 'Node not found'));
    const body = (req.body || {}) as { name?: string; baseUrl?: string; token?: string; enabled?: boolean };
    return upsertNode({
      id,
      name: body.name ?? existing.name,
      baseUrl: body.baseUrl ?? existing.baseUrl,
      token: body.token === undefined ? existing.token : body.token,
      enabled: body.enabled ?? existing.enabled,
    });
  });

  app.delete('/api/nodes/:id', async (req, reply) => {
    if (!requireAdmin(req, reply)) return;
    const { id } = req.params as { id: string };
    const ok = await removeNode(id);
    reply.code(ok ? 204 : 404).send(ok ? undefined : createErrorResponse(ApiErrorCode.NOT_FOUND, 'Node not found'));
  });

  app.post('/api/nodes/:id/test', async (req, reply) => {
    if (!requireAdmin(req, reply)) return;
    const { id } = req.params as { id: string };
    return testNode(id);
  });

  app.post('/api/nodes/pair', async (req, reply) => {
    if (!requireAdmin(req, reply)) return;
    const body = (req.body || {}) as { baseUrl?: string; code?: string; name?: string };
    if (!body.baseUrl || !body.code) {
      return reply.code(400).send(createErrorResponse(ApiErrorCode.INVALID_INPUT, 'baseUrl and code required'));
    }
    try {
      const res = await fetch(new URL('/api/node/pair/claim', body.baseUrl), {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
        body: JSON.stringify({ code: body.code, name: body.name || 'dashboard' }),
      });
      const claimed = (await responseJson(res)) as {
        success?: boolean;
        data?: { token?: string; nodeName?: string };
        token?: string;
        nodeName?: string;
      } | null;
      const data = claimed?.success === true ? claimed.data : claimed;
      if (!res.ok || !data?.token) {
        return reply.code(502).send(createErrorResponse(ApiErrorCode.OPERATION_FAILED, 'Pairing failed'));
      }
      return upsertNode({ name: data.nodeName || body.name || 'Node', baseUrl: body.baseUrl, token: data.token });
    } catch (err) {
      return reply
        .code(502)
        .send(
          createErrorResponse(ApiErrorCode.OPERATION_FAILED, err instanceof Error ? err.message : 'Pairing failed')
        );
    }
  });

  app.all('/api/nodes/:nodeId/proxy/*', { compress: false }, async (req, reply) => {
    if (!requireAdmin(req, reply)) return;
    const params = req.params as { nodeId: string; '*': string };
    const query = req.url.includes('?') ? `?${req.url.split('?').slice(1).join('?')}` : '';
    await proxyFetch(req, reply, params.nodeId, `/${params['*']}${query}`);
  });

  app.get<{ Params: { nodeId: string; id: string }; Querystring: { cid?: string } }>(
    '/ws/nodes/:nodeId/sessions/:id/terminal',
    { websocket: true },
    (socket: WebSocket, req) => {
      bridgeWebSockets(socket, req.params.nodeId, req.params.id, req.query.cid);
    }
  );
}
