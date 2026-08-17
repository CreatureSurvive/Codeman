/**
 * @fileoverview Native app helper routes.
 *
 * These endpoints support Capacitor shells without changing the browser/PWA
 * runtime. They deliberately expose only connection metadata; authentication
 * remains handled by the existing Codeman auth middleware and QR auth flow.
 */

import { FastifyInstance, FastifyRequest } from 'fastify';
import { hostname as getHostname } from 'node:os';
import { createErrorResponse, ApiErrorCode, getErrorMessage } from '../../types.js';

function firstHeader(value: string | string[] | undefined): string | undefined {
  return Array.isArray(value) ? value[0] : value;
}

function resolvePublicBaseUrl(req: FastifyRequest): string {
  const forwardedProto = firstHeader(req.headers['x-forwarded-proto']);
  const forwardedHost = firstHeader(req.headers['x-forwarded-host']);
  const proto = forwardedProto?.split(',')[0]?.trim() || (req.protocol === 'https' ? 'https' : 'http');
  const host = forwardedHost?.split(',')[0]?.trim() || req.headers.host || `${getHostname()}:3000`;
  return `${proto}://${host}`.replace(/\/+$/, '');
}

function buildNativeConnectUrl(baseUrl: string, name: string): string {
  const params = new URLSearchParams({ url: baseUrl, name });
  return `codeman://connect?${params.toString()}`;
}

export function registerNativeRoutes(app: FastifyInstance): void {
  app.get('/api/native/connect', async (req, reply) => {
    try {
      const baseUrl = resolvePublicBaseUrl(req);
      const name = String((req.query as { name?: string }).name || getHostname()).slice(0, 80);
      const connectUrl = buildNativeConnectUrl(baseUrl, name);
      const QRCode = await import('qrcode');
      const svg: string = await QRCode.toString(connectUrl, { type: 'svg', margin: 2, width: 256 });
      return {
        name,
        baseUrl,
        connectUrl,
        webConnectUrl: `${baseUrl}/api/native/connect?url=${encodeURIComponent(baseUrl)}&name=${encodeURIComponent(name)}`,
        svg,
      };
    } catch (err) {
      return reply.code(500).send(createErrorResponse(ApiErrorCode.OPERATION_FAILED, getErrorMessage(err)));
    }
  });
}
