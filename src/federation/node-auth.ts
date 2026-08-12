/**
 * @fileoverview Inbound federation token store.
 *
 * Remote dashboards authenticate to a Codeman node with a bearer token. The node
 * stores only sha256 hashes on disk; the plaintext token is returned once when
 * created or claimed during pairing.
 */

import { randomBytes, createHash, timingSafeEqual } from 'node:crypto';
import { mkdirSync } from 'node:fs';
import fs from 'node:fs/promises';
import { dirname } from 'node:path';
import { dataPath } from '../config/instance.js';

export interface FederationTokenRecord {
  id: string;
  name: string;
  tokenHash: string;
  createdAt: number;
  lastUsedAt?: number;
  revokedAt?: number;
}

interface FederationTokensFile {
  version: 1;
  tokens: FederationTokenRecord[];
}

const TOKENS_PATH = dataPath('node-tokens.json');
const PAIRING_TTL_MS = 5 * 60 * 1000;

const pairingCodes = new Map<string, { name: string; createdAt: number; expiresAt: number }>();

function now(): number {
  return Date.now();
}

function tokenHash(token: string): string {
  return createHash('sha256').update(token).digest('hex');
}

async function readFile(): Promise<FederationTokensFile> {
  try {
    const raw = await fs.readFile(TOKENS_PATH, 'utf-8');
    const parsed = JSON.parse(raw) as FederationTokensFile;
    if (parsed?.version === 1 && Array.isArray(parsed.tokens)) return parsed;
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code !== 'ENOENT') {
      console.error('Failed to read federation node tokens:', err);
    }
  }
  return { version: 1, tokens: [] };
}

async function writeFile(file: FederationTokensFile): Promise<void> {
  mkdirSync(dirname(TOKENS_PATH), { recursive: true, mode: 0o700 });
  const tmp = `${TOKENS_PATH}.${process.pid}.tmp`;
  await fs.writeFile(tmp, JSON.stringify(file, null, 2), { encoding: 'utf-8', mode: 0o600 });
  await fs.rename(tmp, TOKENS_PATH);
}

function constantTimeEqualHex(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  try {
    return timingSafeEqual(Buffer.from(a, 'hex'), Buffer.from(b, 'hex'));
  } catch {
    return false;
  }
}

export function createPairingCode(name = 'dashboard'): { code: string; expiresAt: number } {
  const code = randomBytes(18).toString('base64url');
  const createdAt = now();
  const expiresAt = createdAt + PAIRING_TTL_MS;
  pairingCodes.set(code, { name: name.slice(0, 80) || 'dashboard', createdAt, expiresAt });
  return { code, expiresAt };
}

export async function claimPairingCode(
  code: string,
  name?: string
): Promise<{ id: string; name: string; token: string; createdAt: number } | null> {
  const record = pairingCodes.get(code);
  if (!record || record.expiresAt < now()) {
    pairingCodes.delete(code);
    return null;
  }
  pairingCodes.delete(code);
  return createFederationToken(name || record.name);
}

export async function createFederationToken(name = 'dashboard'): Promise<{
  id: string;
  name: string;
  token: string;
  createdAt: number;
}> {
  const createdAt = now();
  const token = `codeman_node_${randomBytes(32).toString('base64url')}`;
  const item: FederationTokenRecord = {
    id: randomBytes(10).toString('base64url'),
    name: name.slice(0, 80) || 'dashboard',
    tokenHash: tokenHash(token),
    createdAt,
  };
  const file = await readFile();
  file.tokens.push(item);
  await writeFile(file);
  return { id: item.id, name: item.name, token, createdAt };
}

export async function listFederationTokens(): Promise<Array<Omit<FederationTokenRecord, 'tokenHash'>>> {
  const file = await readFile();
  return file.tokens.map(({ tokenHash: _tokenHash, ...item }) => item);
}

export async function revokeFederationToken(id: string): Promise<boolean> {
  const file = await readFile();
  const item = file.tokens.find((token) => token.id === id && !token.revokedAt);
  if (!item) return false;
  item.revokedAt = now();
  await writeFile(file);
  return true;
}

export async function verifyFederationBearer(header: string | undefined): Promise<boolean> {
  const match = /^Bearer\s+(.+)$/i.exec(header || '');
  if (!match) return false;
  const hash = tokenHash(match[1]);
  const file = await readFile();
  let changed = false;
  for (const item of file.tokens) {
    if (item.revokedAt) continue;
    if (constantTimeEqualHex(item.tokenHash, hash)) {
      item.lastUsedAt = now();
      changed = true;
      if (changed) await writeFile(file);
      return true;
    }
  }
  return false;
}
