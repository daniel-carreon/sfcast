import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { promises as fsp } from 'node:fs';
import { startStatic, insideRoot } from '../lib/static-server.js';

// request HTTP CRUDO (fetch/URL normalizan %2e%2e client-side y esconderían el bug)
function rawGet(port, rawPath) {
  return new Promise((resolve, reject) => {
    const req = http.request({ host: '127.0.0.1', port, path: rawPath, method: 'GET' }, (res) => {
      let body = '';
      res.on('data', (d) => (body += d));
      res.on('end', () => resolve({ status: res.statusCode, body }));
    });
    req.on('error', reject);
    req.end();
  });
}

test('insideRoot: frontera de separador (hermano con prefijo compartido NO pasa)', () => {
  assert.equal(insideRoot('/tmp/root-card', '/tmp/root-card/x.txt'), true);
  assert.equal(insideRoot('/tmp/root-card', '/tmp/root-card'), true);
  assert.equal(insideRoot('/tmp/root-card', '/tmp/root-card-evil/secret.txt'), false); // el bug cazado
  assert.equal(insideRoot('/tmp/root-card', '/etc/passwd'), false);
});

test('traversal %2e%2e hacia hermano con prefijo → bloqueado (regresión revisión 18 jul)', async () => {
  const tmp = await fsp.mkdtemp(path.join(os.tmpdir(), 'sfsrv-'));
  const root = path.join(tmp, 'root-card');
  const evil = path.join(tmp, 'root-card-evil');
  await fsp.mkdir(root, { recursive: true });
  await fsp.mkdir(evil, { recursive: true });
  await fsp.writeFile(path.join(root, 'index.html'), 'ok');
  await fsp.writeFile(path.join(evil, 'secret.txt'), 'SECRET');
  const srv = await startStatic(root);
  try {
    const legit = await rawGet(srv.port, '/index.html');
    assert.equal(legit.status, 200);
    const atk1 = await rawGet(srv.port, '/%2e%2e/root-card-evil/secret.txt');
    assert.notEqual(atk1.status, 200, 'traversal por hermano-prefijo debe bloquearse');
    assert.ok(!atk1.body.includes('SECRET'));
    const atk2 = await rawGet(srv.port, '/%2e%2e/%2e%2e/etc/passwd');
    assert.notEqual(atk2.status, 200);
  } finally {
    await srv.close();
    await fsp.rm(tmp, { recursive: true, force: true });
  }
});

test('sin header CORS wildcard (una web ajena no debe leer los media locales)', async () => {
  const tmp = await fsp.mkdtemp(path.join(os.tmpdir(), 'sfsrv-'));
  await fsp.writeFile(path.join(tmp, 'index.html'), 'ok');
  const srv = await startStatic(tmp);
  try {
    const r = await new Promise((resolve, reject) => {
      http.get({ host: '127.0.0.1', port: srv.port, path: '/index.html' }, (res) => resolve(res)).on('error', reject);
    });
    assert.equal(r.headers['access-control-allow-origin'], undefined);
  } finally {
    await srv.close();
    await fsp.rm(tmp, { recursive: true, force: true });
  }
});
