#!/usr/bin/env node
// sfreview <project-dir> [--port 3010] — la Sala de Revisión.
// Sirve la app (web/) + los media del proyecto (con HTTP Range) + API de fixes.json.
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { promises as fsp } from 'node:fs';
import { startStatic, serveFile } from '../lib/static-server.js';

const WEB = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'web');

function usage(code = 1) {
  process.stderr.write('uso: sfreview <project-dir> [--port 3010]\n');
  process.exit(code);
}

const args = process.argv.slice(2);
if (!args.length || args.includes('-h') || args.includes('--help')) usage(args.length ? 0 : 1);
let projectDir = null;
let port = 3010;
for (let i = 0; i < args.length; i++) {
  const a = args[i];
  if (a === '--port') port = parseInt(args[++i], 10);
  else if (!a.startsWith('-') && !projectDir) projectDir = path.resolve(a);
  else usage();
}
if (!projectDir) usage();

const tlPath = path.join(projectDir, 'timeline.json');
let timeline;
try {
  timeline = JSON.parse(await fsp.readFile(tlPath, 'utf8'));
} catch (e) {
  process.stderr.write(`sfreview ERROR: no pude leer ${tlPath}: ${e.message}\n`);
  process.exit(1);
}

async function readBody(req) {
  const chunks = [];
  let size = 0;
  for await (const c of req) {
    size += c.length;
    if (size > 10 * 1024 * 1024) throw new Error('body demasiado grande');
    chunks.push(c);
  }
  return Buffer.concat(chunks).toString('utf8');
}

const fixesPath = path.join(projectDir, 'fixes.json');

let srv;
try {
  srv = await startStatic(WEB, {
  port,
  routes: {
    '/api/project': async (req, res) => {
      const fresh = JSON.parse(await fsp.readFile(tlPath, 'utf8'));
      res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
      res.end(JSON.stringify({ ...fresh, projectDir }));
    },
    '/api/fixes': async (req, res) => {
      if (req.method === 'POST') {
        try {
          const body = JSON.parse(await readBody(req));
          await fsp.writeFile(fixesPath, JSON.stringify(body, null, 1));
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ ok: true, path: fixesPath }));
        } catch (e) {
          res.writeHead(400, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ ok: false, error: e.message }));
        }
        return;
      }
      try {
        const txt = await fsp.readFile(fixesPath, 'utf8');
        res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
        res.end(txt);
      } catch {
        // 200 con {} (no 404): sin sesión previa no es un error y la consola debe quedar limpia
        res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
        res.end('{}');
      }
    },
    '/media': async (req, res) => {
      const rel = decodeURIComponent(req.url.replace(/^\/media\/?/, '').split('?')[0]);
      const fp = path.normalize(path.join(projectDir, rel));
      if (!fp.startsWith(path.normalize(projectDir))) {
        res.writeHead(403); res.end('403');
        return;
      }
      await serveFile(req, res, fp);
    },
  },
  });
} catch (e) {
  if (e.code === 'EADDRINUSE') {
    process.stderr.write(`sfreview ERROR: el puerto ${port} ya está ocupado (¿otra sala corriendo?). ` +
      `Mata el proceso previo o usa --port <otro>.\n`);
    process.exit(1);
  }
  throw e;
}

process.stdout.write(`sfreview: ${timeline.name || path.basename(projectDir)}\n`);
process.stdout.write(`  proyecto: ${projectDir}\n`);
process.stdout.write(`  sala:     http://127.0.0.1:${srv.port}\n`);
process.stdout.write(`  fixes:    ${fixesPath}\n`);
