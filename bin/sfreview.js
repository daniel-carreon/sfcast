#!/usr/bin/env node
// sfreview <project-dir> [--port 3010] [--roots a,b] — la Sala de Revisión.
// sfreview --gallery [--port 3010]                     — solo la GALERÍA (sin proyecto abierto).
//
// Sirve la app (web/) + los media del proyecto (con HTTP Range) + API de fixes.json + la API de
// la Galería de Lanzamientos (⌘⌥G). La Galería se portó DESDE sfstudio (main) el 27 ago 2026:
// este binario ya tenía los tres controles de Daniel (tecla C, velocidad 3x, cortes arrastrables)
// y le faltaba el catálogo. El port es ADITIVO — main nunca se toca, y así hay UN SOLO binario.
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { promises as fsp } from 'node:fs';
import { spawn } from 'node:child_process';
import { startStatic, serveFile, insideRoot } from '../lib/static-server.js';
import { STAGES, STAGE_COMMANDS, parseTranscript, segmentTranscript, applyEdl } from '../lib/publish.js';
import {
  defaultRoots, scanRoots, resolveId, readCard, readDossier, applyGalleryPatch,
  computeTranscriptFor, listThumbs,
} from '../lib/gallery.js';

const WEB = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'web');

function usage(code = 1) {
  process.stderr.write('uso: sfreview <project-dir> [--port 3010] [--roots dir1,dir2]\n' +
    '     sfreview --gallery [--port 3010]   (solo la Galería, sin proyecto)\n');
  process.exit(code);
}

const args = process.argv.slice(2);
if (!args.length || args.includes('-h') || args.includes('--help')) usage(args.length ? 0 : 1);
let projectDir = null;
let port = 3010;
let galleryOnly = false;
let roots = null;
for (let i = 0; i < args.length; i++) {
  const a = args[i];
  if (a === '--port') port = parseInt(args[++i], 10);
  else if (a === '--gallery') galleryOnly = true;
  else if (a === '--roots') roots = args[++i].split(',').map((s) => path.resolve(s.trim())).filter(Boolean);
  else if (!a.startsWith('-') && !projectDir) projectDir = path.resolve(a);
  else usage();
}
if (!projectDir && !galleryOnly) usage();
roots = roots || defaultRoots();

const tlPath = projectDir ? path.join(projectDir, 'timeline.json') : null;
let timeline = null;
if (projectDir) {
  try {
    timeline = JSON.parse(await fsp.readFile(tlPath, 'utf8'));
  } catch (e) {
    process.stderr.write(`sfreview ERROR: no pude leer ${tlPath}: ${e.message}\n` +
      '  (si solo querías el catálogo de lanzamientos: sfreview --gallery)\n');
    process.exit(1);
  }
}

// ── Galería: se escanea en CADA request. Son decenas de carpetas: el escaneo cuesta microsegundos
// y un cache aquí solo produce "no aparece mi proyecto nuevo".
async function galleryEntry(id) {
  const r = resolveId(roots, id);
  if (!r) return null;
  try { await fsp.access(path.join(r.dir, 'publish.json')); } catch { return null; }
  return { id, dir: r.dir, name: r.name, root: roots[r.rootIdx] };
}

function json(res, code, obj) {
  res.writeHead(code, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
  res.end(JSON.stringify(obj));
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
// /api/transcript: cache por PROMESA (mismo patrón que wavePromise — sin race entre requests).
// Solo el éxito con corte final queda cacheado para siempre; found:false o cut:'raw' se
// recomputan en el siguiente request (el transcript/EDL pueden aparecer DESPUÉS de abrir la sala).
let transcriptPromise = null;
let thumbsDir = null; // /api/thumbs fija el dir real; /thumbs/ sirve desde ahí
async function computeTranscript() {
  for (const dir of [projectDir, path.dirname(projectDir)]) {
    for (const sub of ['edit/transcripts', 'transcripts', 'edit']) {
      try {
        const d = path.join(dir, sub);
        for (const f of (await fsp.readdir(d)).filter((x) => x.endsWith('.json'))) {
          try {
            let tr = parseTranscript(await fsp.readFile(path.join(d, f), 'utf8'));
            if (tr.words.length <= 10) continue;
            let cut = 'raw';
            for (const edlName of ['edl_breathed.json', 'edl.json']) {
              try {
                const edl = JSON.parse(await fsp.readFile(path.join(dir, 'edit', edlName), 'utf8'));
                if (Array.isArray(edl.ranges) && edl.ranges.length) {
                  tr = { ...applyEdl(tr.words, edl.ranges), text: '' };
                  cut = 'final';
                  break;
                }
              } catch { /* sin edl */ }
            }
            return { found: true, file: f, cut, words: tr.words.length, duration: tr.duration, segments: segmentTranscript(tr.words) };
          } catch { /* no es transcript */ }
        }
      } catch { /* dir no existe */ }
    }
  }
  return { found: false, segments: [] };
}

// ── waveform del base: peaks min/max a 50/s, computado UNA vez con ffmpeg y cacheado en el proyecto
const wavePath = path.join(projectDir, 'waveform.json');
let wavePromise = null;
// firma del base: si cambia (re-corte, otro fps, zoom nuevo), el waveform cacheado MIENTE
// (bug 25 jul: el base se reemplazó 3 veces con el mismo nombre y la sala siguió pintando la onda
//  del PRIMERO → Daniel veía silencio donde había voz). La firma invalida el caché sola.
async function baseSignature() {
  const basePath = path.join(projectDir, timeline.base.src);
  try {
    const st = await fsp.stat(basePath);
    return `${st.size}:${Math.round(st.mtimeMs)}`;
  } catch { return 'no-base'; }
}

async function computeWaveform() {
  const basePath = path.join(projectDir, timeline.base.src);
  const RATE = 50, SR = 4000, BUCKET = Math.round(SR / RATE);
  const hasAudio = await new Promise((resolve) => {
    const pr = spawn('ffprobe', ['-v', 'error', '-select_streams', 'a', '-show_entries', 'stream=codec_type', '-of', 'default=nk=1:nw=1', basePath]);
    let out = '';
    pr.stdout.on('data', (d) => (out += d));
    pr.on('close', () => resolve(out.trim() !== ''));
    pr.on('error', () => resolve(false));
  });
  const peaks = [];
  if (hasAudio) {
    const buf = await new Promise((resolve, reject) => {
      const pr = spawn('ffmpeg', ['-nostdin', '-v', 'error', '-i', basePath, '-map', 'a:0', '-ac', '1', '-ar', String(SR), '-c:a', 'pcm_s16le', '-f', 's16le', '-']);
      const chunks = [];
      pr.stdout.on('data', (d) => chunks.push(d));
      pr.on('close', (c) => (c === 0 ? resolve(Buffer.concat(chunks)) : reject(new Error('ffmpeg waveform exit ' + c))));
      pr.on('error', reject);
    });
    const samples = new Int16Array(buf.buffer, buf.byteOffset, Math.floor(buf.byteLength / 2));
    for (let i = 0; i < samples.length; i += BUCKET) {
      let mn = 0, mx = 0;
      const end = Math.min(i + BUCKET, samples.length);
      for (let j = i; j < end; j++) {
        const v = samples[j];
        if (v < mn) mn = v;
        if (v > mx) mx = v;
      }
      peaks.push(Math.round(mn / 327.68), Math.round(mx / 327.68)); // normalizado a -100..100
    }
  }
  const data = { rate: RATE, peaks, sig: await baseSignature(), base: timeline.base.src };
  await fsp.writeFile(wavePath, JSON.stringify(data));
  return data;
}

let srv;
try {
  srv = await startStatic(WEB, {
  port,
  routes: {
    '/api/project': async (req, res) => {
      res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
      if (!projectDir) return res.end(JSON.stringify({ gallery_only: true, name: 'Galería de Lanzamientos' }));
      const fresh = JSON.parse(await fsp.readFile(tlPath, 'utf8'));
      res.end(JSON.stringify({ ...fresh, projectDir }));
    },
    // Sello de build de web/: la pestaña se recarga sola cuando cambia. Sin esto, una pestaña
    // abierta desde antes de un deploy sigue corriendo el JS viejo y parece que la app perdió cosas.
    '/api/version': async (req, res) => {
      let stamp = 0;
      for (const f of await fsp.readdir(WEB)) {
        if (!/\.(js|css|html)$/.test(f)) continue;
        const st = await fsp.stat(path.join(WEB, f));
        stamp = Math.max(stamp, Math.floor(st.mtimeMs));
      }
      res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
      res.end(JSON.stringify({ stamp }));
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
    // dossier ⌘Y: transcript segmentado con timestamps (word-level de la sala o del proyecto
    // raíz — edit/transcripts es el canónico — remapeado al corte final si hay EDL)
    '/api/transcript': async (req, res) => {
      res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
      try {
        transcriptPromise = transcriptPromise || computeTranscript();
        const data = await transcriptPromise;
        // solo el estado terminal (corte final encontrado) queda cacheado; lo demás puede mejorar
        // (el transcript o el EDL pueden aparecer DESPUÉS de abrir la sala) → recomputar
        if (!(data.found && data.cut === 'final')) transcriptPromise = null;
        res.end(JSON.stringify(data));
      } catch (e) {
        transcriptPromise = null;
        res.end(JSON.stringify({ found: false, segments: [], error: e.message }));
      }
    },
    // dossier ⌘Y: miniaturas candidatas para A/B (viven en <proyecto raíz>/thumbs/)
    '/api/thumbs': async (req, res) => {
      res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
      for (const dir of [path.join(projectDir, 'thumbs'), path.join(path.dirname(projectDir), 'thumbs')]) {
        try {
          const files = (await fsp.readdir(dir)).filter((f) => /\.(png|jpe?g|webp)$/i.test(f)).sort();
          if (files.length) {
            thumbsDir = dir;
            res.end(JSON.stringify({ found: true, files }));
            return;
          }
        } catch { /* sin thumbs aún */ }
      }
      res.end(JSON.stringify({ found: false, files: [] }));
    },
    '/thumbs': async (req, res) => {
      const rel = decodeURIComponent(req.url.replace(/^\/thumbs\/?/, '').split('?')[0]);
      const dir = thumbsDir || path.join(path.dirname(projectDir), 'thumbs');
      const fp = path.normalize(path.join(dir, rel));
      if (!insideRoot(dir, fp)) {
        res.writeHead(403); res.end('403');
        return;
      }
      await serveFile(req, res, fp);
    },
    // panel ⌘Y (SFPublish): la sala solo LEE publish.json — lo escriben los comandos sfpublish.
    // El proyecto de la sala suele ser <proyecto>/sfreview_project → publish.json vive en el padre.
    '/api/publish': async (req, res) => {
      res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
      for (const dir of [projectDir, path.dirname(projectDir)]) {
        try {
          const p = path.join(dir, 'publish.json');
          const pub = JSON.parse(await fsp.readFile(p, 'utf8'));
          res.end(JSON.stringify({ found: true, publish: pub, path: p, project: dir, stages: STAGES, commands: STAGE_COMMANDS }));
          return;
        } catch { /* siguiente candidato */ }
      }
      res.end(JSON.stringify({ found: false, project: path.dirname(projectDir), stages: STAGES, commands: STAGE_COMMANDS }));
    },
    '/api/waveform': async (req, res) => {
      try {
        const txt = await fsp.readFile(wavePath, 'utf8');
        const cached = JSON.parse(txt);
        // GUARD: el caché solo vale si corresponde AL BASE ACTUAL (ver baseSignature)
        if (cached.sig && cached.sig === (await baseSignature())) {
          res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
          res.end(txt);
          return;
        }
        process.stdout.write('  waveform: el base cambió → recomputando\n');
        wavePromise = null;
        await fsp.unlink(wavePath).catch(() => {});
      } catch { /* aún no computado */ }
      try {
        wavePromise = wavePromise || computeWaveform();
        const data = await wavePromise;
        res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
        res.end(JSON.stringify(data));
      } catch (e) {
        wavePromise = null; // permitir reintento
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: e.message }));
      }
    },
    // ── GALERÍA DE LANZAMIENTOS (⌘⌥G) ──────────────────────────────────────────────
    // /api/gallery            → la rejilla (una tarjeta por proyecto con publish.json)
    // /api/gallery/item?id=   → GET la ficha completa · POST el patch (post/portada/título)
    // /gallery/thumb?id=&f=   → la imagen de un proyecto cualquiera (sandbox: solo bajo las raíces)
    '/api/gallery': async (req, res) => {
      const u = new URL(req.url, 'http://x');
      if (u.pathname === '/api/gallery/item') {
        const entry = await galleryEntry(u.searchParams.get('id'));
        if (!entry) return json(res, 404, { error: 'proyecto no encontrado en las raíces de la galería' });
        if (req.method === 'POST') {
          try {
            const patch = JSON.parse(await readBody(req));
            const { changed } = await applyGalleryPatch(entry.dir, patch);
            const dossier = await readDossier(entry);
            return json(res, 200, { ok: true, changed, item: dossier });
          } catch (e) {
            return json(res, 400, { ok: false, error: e.message });
          }
        }
        try { return json(res, 200, await readDossier(entry)); }
        catch (e) { return json(res, 500, { error: e.message }); }
      }
      if (u.pathname !== '/api/gallery') { res.writeHead(404); res.end('404'); return; }
      try {
        const entries = await scanRoots(roots);
        const now = new Date();
        const items = [];
        for (const e of entries) {
          try { items.push(await readCard(e, now)); }
          catch (err) { items.push({ id: e.id, name: e.name, dir: e.dir, error: err.message }); }
        }
        items.sort((a, b) => (b.updated_at || '').localeCompare(a.updated_at || '') || a.name.localeCompare(b.name));
        json(res, 200, { roots, count: items.length, items, open: projectDir || null });
      } catch (e) {
        json(res, 500, { error: e.message, roots, items: [] });
      }
    },
    '/gallery/thumb': async (req, res) => {
      const u = new URL(req.url, 'http://x');
      const entry = await galleryEntry(u.searchParams.get('id'));
      const f = u.searchParams.get('f') || '';
      if (!entry || !f || f.includes('/') || f.includes('\\') || f.includes('..')) {
        res.writeHead(404); res.end('404');
        return;
      }
      const { dir: sub } = await listThumbs(entry.dir);
      const fp = path.normalize(path.join(entry.dir, sub || 'thumbs', f));
      if (!insideRoot(entry.dir, fp)) { res.writeHead(403); res.end('403'); return; }
      await serveFile(req, res, fp);
    },

    '/media': async (req, res) => {
      if (!projectDir) { res.writeHead(404); res.end('404'); return; }
      const rel = decodeURIComponent(req.url.replace(/^\/media\/?/, '').split('?')[0]);
      const fp = path.normalize(path.join(projectDir, rel));
      if (!insideRoot(projectDir, fp)) { // frontera con separador (no startsWith desnudo)
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
