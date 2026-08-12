/**
 * @fileoverview Dashboard-side registry of Codeman nodes.
 */

import { randomBytes } from 'node:crypto';
import { mkdirSync } from 'node:fs';
import fs from 'node:fs/promises';
import { dirname } from 'node:path';
import { dataPath } from '../config/instance.js';

export interface NodeHealth {
  ok: boolean;
  checkedAt: number;
  status?: number;
  message?: string;
}

export interface NodeRecord {
  id: string;
  name: string;
  baseUrl: string;
  token?: string;
  enabled: boolean;
  createdAt: number;
  updatedAt: number;
  lastHealth?: NodeHealth;
}

export type PublicNodeRecord = Omit<NodeRecord, 'token'> & { hasToken: boolean };

interface NodesFile {
  version: 1;
  nodes: NodeRecord[];
}

const NODES_PATH = dataPath('nodes.json');

function now(): number {
  return Date.now();
}

function normalizeBaseUrl(value: string): string {
  const url = new URL(value);
  if (url.protocol !== 'http:' && url.protocol !== 'https:') throw new Error('baseUrl must be http or https');
  url.hash = '';
  url.search = '';
  url.pathname = url.pathname.replace(/\/+$/, '');
  return url.toString().replace(/\/$/, '');
}

async function readFile(): Promise<NodesFile> {
  try {
    const raw = await fs.readFile(NODES_PATH, 'utf-8');
    const parsed = JSON.parse(raw) as NodesFile;
    if (parsed?.version === 1 && Array.isArray(parsed.nodes)) return parsed;
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code !== 'ENOENT') {
      console.error('Failed to read federation nodes:', err);
    }
  }
  return { version: 1, nodes: [] };
}

async function writeFile(file: NodesFile): Promise<void> {
  mkdirSync(dirname(NODES_PATH), { recursive: true, mode: 0o700 });
  const tmp = `${NODES_PATH}.${process.pid}.tmp`;
  await fs.writeFile(tmp, JSON.stringify(file, null, 2), { encoding: 'utf-8', mode: 0o600 });
  await fs.rename(tmp, NODES_PATH);
}

export function publicNode(node: NodeRecord): PublicNodeRecord {
  const { token: _token, ...rest } = node;
  return { ...rest, hasToken: !!node.token };
}

export async function listNodes(): Promise<PublicNodeRecord[]> {
  const file = await readFile();
  return file.nodes.map(publicNode);
}

export async function getNode(id: string): Promise<NodeRecord | null> {
  const file = await readFile();
  return file.nodes.find((node) => node.id === id) ?? null;
}

export async function upsertNode(input: {
  id?: string;
  name: string;
  baseUrl: string;
  token?: string;
  enabled?: boolean;
}): Promise<PublicNodeRecord> {
  const file = await readFile();
  const id = input.id || randomBytes(10).toString('base64url');
  const at = now();
  const existing = file.nodes.find((node) => node.id === id);
  if (existing) {
    existing.name = input.name.slice(0, 80) || existing.name;
    existing.baseUrl = normalizeBaseUrl(input.baseUrl);
    if (input.token !== undefined) existing.token = input.token;
    if (input.enabled !== undefined) existing.enabled = input.enabled;
    existing.updatedAt = at;
    await writeFile(file);
    return publicNode(existing);
  }
  const node: NodeRecord = {
    id,
    name: input.name.slice(0, 80) || 'Node',
    baseUrl: normalizeBaseUrl(input.baseUrl),
    token: input.token,
    enabled: input.enabled ?? true,
    createdAt: at,
    updatedAt: at,
  };
  file.nodes.push(node);
  await writeFile(file);
  return publicNode(node);
}

export async function removeNode(id: string): Promise<boolean> {
  const file = await readFile();
  const before = file.nodes.length;
  file.nodes = file.nodes.filter((node) => node.id !== id);
  if (file.nodes.length === before) return false;
  await writeFile(file);
  return true;
}

export async function setNodeHealth(id: string, health: NodeHealth): Promise<void> {
  const file = await readFile();
  const node = file.nodes.find((item) => item.id === id);
  if (!node) return;
  node.lastHealth = health;
  node.updatedAt = now();
  await writeFile(file);
}
