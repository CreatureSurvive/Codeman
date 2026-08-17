import Fastify from 'fastify';
import { describe, expect, it } from 'vitest';
import { registerNativeRoutes } from '../src/web/routes/native-routes.js';

describe('native app routes', () => {
  it('returns a quick-connect payload and QR SVG', async () => {
    const app = Fastify({ logger: false });
    registerNativeRoutes(app);

    const response = await app.inject({
      method: 'GET',
      url: '/api/native/connect?name=MacBook',
      headers: {
        host: '192.168.40.151:3010',
        'x-forwarded-proto': 'https',
      },
    });

    expect(response.statusCode).toBe(200);
    const body = response.json();
    expect(body.name).toBe('MacBook');
    expect(body.baseUrl).toBe('https://192.168.40.151:3010');
    expect(body.connectUrl).toContain('codeman://connect?');
    expect(body.connectUrl).toContain('url=https%3A%2F%2F192.168.40.151%3A3010');
    expect(body.svg).toContain('<svg');

    await app.close();
  });
});
