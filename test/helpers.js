import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
let nextPort = 4100 + Math.floor(Math.random() * 800);

export const tempDir = () => mkdtempSync(path.join(tmpdir(), 'pos-test-'));

export async function startServer(env = {}, dataDir = tempDir()) {
  const port = nextPort++;
  const base = `http://127.0.0.1:${port}`;
  const child = spawn(process.execPath, ['--disable-warning=ExperimentalWarning', 'server.js'], {
    cwd: ROOT,
    env: { ...process.env, STRIPE_SECRET_KEY: '', PORT: String(port), POS_DATA_DIR: dataDir, ...env },
    stdio: ['ignore', 'ignore', 'inherit'],
  });
  for (let i = 0; i < 50; i++) {
    try { await fetch(`${base}/api/store`); break; } catch { await new Promise((r) => setTimeout(r, 100)); }
  }
  const call = async (method, url, body, token) => {
    const res = await fetch(base + url, {
      method,
      headers: { 'Content-Type': 'application/json', ...(token && { Authorization: `Bearer ${token}` }) },
      body: body && JSON.stringify(body),
    });
    const type = res.headers.get('content-type') || '';
    return { status: res.status, data: type.includes('json') ? await res.json() : await res.text() };
  };
  const login = async (username, pin) => (await call('POST', '/api/login', { username, pin })).data.token;
  const stop = () => {
    child.kill();
    try { rmSync(dataDir, { recursive: true, force: true }); } catch { /* Windows may still hold the file */ }
  };
  return { base, call, login, stop };
}
