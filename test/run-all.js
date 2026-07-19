#!/usr/bin/env node
// Arnés único de SFStudio: sintaxis + unit tests + humo sfrender + humo sfstudio-apply (real)
// + humo Playwright de sfreview. Es EL comando de validación: `npm test`.
import { spawn, spawnSync } from 'node:child_process';
import { promises as fsp } from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';

const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const results = [];
let failed = false;

function report(name, ok, detail = '') {
  results.push({ name, ok, detail });
  process.stdout.write(`${ok ? '✓' : '✗'} ${name}${detail ? ` — ${detail}` : ''}\n`);
  if (!ok) failed = true;
}

function sh(cmd, args, opts = {}) {
  const r = spawnSync(cmd, args, { cwd: ROOT, encoding: 'utf8', timeout: opts.timeout || 180000, ...opts });
  return { code: r.status, out: (r.stdout || '') + (r.stderr || '') };
}

// ── 1. sintaxis de todos los JS
{
  const files = ['bin/sfrender.js', 'bin/sfreview.js', 'bin/sfstudio-apply.js',
    'lib/render.js', 'lib/static-server.js', 'web/app.js', 'web/model.js',
    'test/model.test.js', 'test/server.test.js'];
  let bad = files.filter((f) => sh('node', ['--check', path.join(ROOT, f)]).code !== 0);
  report(`sintaxis (node --check x${files.length})`, bad.length === 0, bad.join(', '));
}

// ── 2. unit tests: modelo de trims + server (traversal/CORS, regresión revisión 18 jul)
{
  const r = sh('node', ['--test', 'test/model.test.js', 'test/server.test.js']);
  const pass = /# pass (\d+)/.exec(r.out)?.[1];
  const fail = /# fail (\d+)/.exec(r.out)?.[1];
  report(`modelo + server (node --test)`, r.code === 0 && fail === '0', `${pass} pass / ${fail} fail`);
}

// ── 3. humo sfrender: card-smoke 320x180 @0.5s = 15 frames exactos
const tmp = await fsp.mkdtemp(path.join(os.tmpdir(), 'sfstudio-test-'));
const smokeOut = path.join(tmp, 'smoke.mp4');
{
  const r = sh('node', ['bin/sfrender.js', 'demo/card-smoke', '-o', smokeOut, '--quiet']);
  let frames = null;
  if (r.code === 0) {
    frames = sh('ffprobe', ['-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=nb_frames',
      '-of', 'default=nk=1:nw=1', smokeOut]).out.trim();
  }
  report('sfrender humo (card-smoke → mp4)', r.code === 0 && frames === '15', `frames=${frames}`);
}

// ── 4. humo sfrender alpha: webm con alpha_mode=1
{
  const webmOut = path.join(tmp, 'smoke.webm');
  const r = sh('node', ['bin/sfrender.js', 'demo/card-smoke', '-o', webmOut, '--format', 'webm', '--quiet']);
  let alpha = '';
  if (r.code === 0) {
    alpha = sh('ffprobe', ['-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream_tags=alpha_mode',
      '-of', 'default=nk=1:nw=1', webmOut]).out.trim();
  }
  report('sfrender humo alpha (card-smoke → webm)', r.code === 0 && alpha === '1', `alpha_mode=${alpha}`);
}

// ── 5. humo sfstudio-apply REAL — 3 casos (revisión 18 jul: el caso sin-audio se ESQUIVABA, ahora se cubre)
{
  const probeDur = (f) => parseFloat(sh('ffprobe', ['-v', 'error', '-show_entries', 'format=duration',
    '-of', 'default=nk=1:nw=1', f]).out.trim());
  const fixes = path.join(tmp, 'fixes.json');
  await fsp.writeFile(fixes, JSON.stringify({ video: 'smoke.mp4', trims: [{ start: 0.1, end: 0.2 }], markers: [] }));

  // (a) máster SIN pista de audio (el smoke render sale video-only) → debe funcionar con graph solo-video
  const outNoA = path.join(tmp, 'smoke-fixed-noaudio.mp4');
  const rA = sh('node', ['bin/sfstudio-apply.js', fixes, smokeOut, '-o', outNoA]);
  const durA = rA.code === 0 ? probeDur(outNoA) : null;
  report('sfstudio-apply REAL sin audio', rA.code === 0 && durA !== null && Math.abs(durA - 0.4) < 0.15,
    `dur=${durA}s (esperado ~0.4)`);

  // (b) máster CON audio → path v+a completo
  const withAudio = path.join(tmp, 'smoke-a.mp4');
  sh('ffmpeg', ['-nostdin', '-y', '-loglevel', 'error', '-i', smokeOut, '-f', 'lavfi', '-i', 'anullsrc=r=48000:cl=stereo',
    '-shortest', '-c:v', 'copy', '-c:a', 'aac', withAudio]);
  const outFixed = path.join(tmp, 'smoke-fixed.mp4');
  const rB = sh('node', ['bin/sfstudio-apply.js', fixes, withAudio, '-o', outFixed]);
  const durB = rB.code === 0 ? probeDur(outFixed) : null;
  report('sfstudio-apply REAL con audio', rB.code === 0 && durB !== null && Math.abs(durB - 0.4) < 0.15,
    `dur=${durB}s (esperado ~0.4)`);

  // (c) guard de duración: fixes exportado sobre un timeline de 99s vs máster de 0.5s → abortar con mensaje
  const fixesBad = path.join(tmp, 'fixes-bad.json');
  await fsp.writeFile(fixesBad, JSON.stringify({ video: 'x.mp4', duration: 99, trims: [{ start: 50, end: 51 }], markers: [] }));
  const rC = sh('node', ['bin/sfstudio-apply.js', fixesBad, withAudio, '-o', path.join(tmp, 'nope.mp4')]);
  report('sfstudio-apply guard proxy↔máster', rC.code !== 0 && /máster equivocado|se exportó sobre/.test(rC.out),
    `exit=${rC.code}`);
}

// ── 6. humo sfreview con Playwright: proyecto 9:16, keys S/D, trim visible, export, 0 errores consola
{
  const PORT = 3999;
  const projDir = path.join(ROOT, 'demo', 'project-916');
  const srv = spawn('node', [path.join(ROOT, 'bin', 'sfreview.js'), projDir, '--port', String(PORT)], { stdio: 'ignore' });
  let ok = false, detail = '';
  try {
    // esperar server
    for (let i = 0; i < 40; i++) {
      try {
        const r = await fetch(`http://127.0.0.1:${PORT}/api/project`);
        if (r.ok) break;
      } catch { /* aún no */ }
      await new Promise((r) => setTimeout(r, 250));
    }
    const { chromium } = await import('playwright');
    const browser = await chromium.launch({ headless: true });
    const page = await browser.newPage();
    const errors = [];
    page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });
    page.on('pageerror', (e) => errors.push(String(e)));
    await page.goto(`http://127.0.0.1:${PORT}/`, { waitUntil: 'load' });
    await page.waitForSelector('#track2 .clipItem', { timeout: 10000 });
    // S en 1.0 + D en 0.5 → trim [0.5, 1.0] tachado
    await page.evaluate(() => new Promise((res) => {
      const v = document.getElementById('base');
      v.currentTime = 1.0; v.onseeked = res; setTimeout(res, 2000);
    }));
    await page.keyboard.press('s');
    await page.evaluate(() => new Promise((res) => {
      const v = document.getElementById('base');
      v.currentTime = 0.5; v.onseeked = res; setTimeout(res, 2000);
    }));
    await page.keyboard.press('d');
    await page.waitForSelector('.trimRange', { timeout: 5000 });
    const trimTitle = await page.$eval('.trimRange', (el) => el.title);
    // marcador vía popover
    await page.keyboard.press('m');
    await page.waitForSelector('#popover:not([hidden])', { timeout: 5000 });
    await page.fill('#popInput', 'humo automatizado');
    await page.keyboard.press('Enter');
    // export → escribe fixes.json del proyecto demo
    await page.keyboard.press('e');
    await page.waitForSelector('#modal:not([hidden])', { timeout: 5000 });
    await new Promise((r) => setTimeout(r, 400));
    const fixesTxt = await fsp.readFile(path.join(projDir, 'fixes.json'), 'utf8');
    const fx = JSON.parse(fixesTxt);
    const fixesOk = fx.trims?.length === 1 && Math.abs(fx.trims[0].start - 0.5) < 0.05 && fx.markers?.length === 1;
    // waveform API: proyecto demo sin audio → peaks [] es la respuesta válida
    const wf = await fetch(`http://127.0.0.1:${PORT}/api/waveform`);
    const wj = await wf.json();
    const waveOk = wf.ok && typeof wj.rate === 'number' && Array.isArray(wj.peaks)
      && (await page.$('#waveCanvas')) !== null;
    await browser.close();
    ok = fixesOk && waveOk && errors.length === 0 && /recorte/.test(trimTitle);
    detail = `trim="${trimTitle}" fixes=${fixesOk} wave=${waveOk} consola=${errors.length} errores`;
    if (errors.length) detail += ` :: ${errors.slice(0, 3).join(' | ')}`;
  } catch (e) {
    detail = e.message.split('\n')[0];
  } finally {
    srv.kill();
    await fsp.rm(path.join(projDir, 'fixes.json'), { force: true }); // no ensuciar el demo
    await fsp.rm(path.join(projDir, 'waveform.json'), { force: true });
  }
  report('sfreview humo Playwright (S/D + marcador + export + waveform, 0 errores)', ok, detail);
}

await fsp.rm(tmp, { recursive: true, force: true });
process.stdout.write(`\n${results.filter((r) => r.ok).length}/${results.length} verdes\n`);
process.exit(failed ? 1 : 0);
