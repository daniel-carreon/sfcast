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
  const files = ['bin/sfrender.js', 'bin/sfreview.js', 'bin/sfstudio-apply.js', 'bin/sfpublish.js',
    'lib/render.js', 'lib/static-server.js', 'lib/publish.js', 'lib/upload-youtube.js',
    'lib/gallery.js', 'lib/community-draft.js', 'lib/youtube-api.js',
    'web/app.js', 'web/model.js', 'web/gallery.js',
    'test/model.test.js', 'test/server.test.js', 'test/publish.test.js', 'test/gallery.test.js'];
  let bad = files.filter((f) => sh('node', ['--check', path.join(ROOT, f)]).code !== 0);
  report(`sintaxis (node --check x${files.length})`, bad.length === 0, bad.join(', '));
}

// ── 2. unit tests: modelo de trims + server (traversal/CORS) + publish (gate/menciones/slots)
//        + galería (sandbox de ids, estado del lanzamiento, patch sobre publish.json)
{
  const r = sh('node', ['--test', 'test/model.test.js', 'test/server.test.js', 'test/publish.test.js',
    'test/gallery.test.js']);
  const pass = /# pass (\d+)/.exec(r.out)?.[1];
  const fail = /# fail (\d+)/.exec(r.out)?.[1];
  report(`modelo + server + publish + galería (node --test)`, r.code === 0 && fail === '0', `${pass} pass / ${fail} fail`);
}

// ── 3. humo sfrender: card-smoke 320x180 @0.5s = 15 frames exactos
const tmp = await fsp.mkdtemp(path.join(os.tmpdir(), 'sfstudio-test-'));
const smokeOut = path.join(tmp, 'smoke.mp4');

// ── fixture de la GALERÍA: dos "lanzamientos" en una raíz de mentiras (uno completo con fecha
// programada y post; otro a medio hacer, para probar el estado honesto). Se pasa con --roots
// para NUNCA escanear el disco real en un test.
const galRoot = path.join(tmp, 'lanzamientos');
{
  const A = path.join(galRoot, '2026-09-01-lanzamiento-completo');
  const B = path.join(galRoot, '2026-09-02-a-medias');
  await fsp.mkdir(path.join(A, 'thumbs'), { recursive: true });
  await fsp.mkdir(B, { recursive: true });
  const manana = new Date(Date.now() + 36 * 3600 * 1000).toISOString();
  await fsp.writeFile(path.join(A, 'publish.json'), JSON.stringify({
    video: { slug: 'vid-galeria', titulo: 'Lanzamiento completo de humo' },
    stages: { metadata: { status: 'done', evidence: 'ok', updated_at: new Date().toISOString() } },
    log: [],
    data: {
      metadata: { description: 'CTA https://saasfactory.so/go/vid-galeria\n\n00:00 Intro\n02:30 Cierre',
        titles: ['Lanzamiento completo de humo'], keywords: ['humo'] },
      launch: { video_id: 'AAAAAAAAAAA', publish_at: manana, title: 'Lanzamiento completo de humo',
        thumbnail: 'ab-01.png', post_delay_min: 5, post_status: 'sin-aprobar' },
      post_draft: { title: 'Lanzamiento completo de humo', body: 'Comunidad!\n\nCuerpo original del post.',
        source: 'fixture', updated_at: new Date().toISOString(), approved_at: null },
    },
  }));
  for (const [f, c] of [['ab-01.png', 'orange'], ['ab-02.png', 'purple']]) {
    sh('ffmpeg', ['-nostdin', '-y', '-loglevel', 'error', '-f', 'lavfi', '-i', `color=c=${c}:s=64x36`,
      '-frames:v', '1', path.join(A, 'thumbs', f)]);
  }
  await fsp.writeFile(path.join(A, 'TRANSCRIPT-master.txt'),
    Array.from({ length: 6 }, (_, i) => `[00:0${i}.00] frase ${i} del máster`).join('\n'));
  // el "a medias": publish.json recién nacido, sin nada. Debe aparecer con estado honesto.
  await fsp.writeFile(path.join(B, 'publish.json'), JSON.stringify({
    video: { slug: 'vid-a-medias', titulo: '' }, stages: {}, log: [], data: {},
  }));
}
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

// ── 6. humo sfreview con Playwright: proyecto 9:16, keys S/D, trim visible, export, panel ⌘Y, 0 errores consola
{
  const PORT = 3999;
  const projDir = path.join(ROOT, 'demo', 'project-916');
  // fixtures del dossier ⌘Y: publish.json + transcript word-level + 2 thumbs (se limpian al final)
  const pubFixture = {
    video: { slug: 'vid-humo', titulo: 'Título elegido de humo' },
    stages: {
      metadata: { status: 'done', evidence: 'metadata de humo', updated_at: new Date().toISOString() },
      link: { status: 'done', evidence: '/go/vid-humo ✓ 307 · cookies vivas', updated_at: new Date().toISOString() },
      mentions: { status: 'running', evidence: 'buscando…', updated_at: new Date().toISOString() },
      checklist: { status: 'error', evidence: 'gate cerrado', updated_at: new Date().toISOString() },
    },
    log: [],
    data: {
      metadata: {
        description: 'CTA: https://saasfactory.so/go/vid-humo\n\n00:00 Intro\n01:00 Cierre',
        titles: ['Título elegido de humo', 'Alternativa B', 'Alternativa C'],
        keywords: ['humo', 'prueba'],
      },
      link: { url: 'https://saasfactory.so/go/vid-humo', verified: true, status: 307 },
      mentions: [{ t: 1.2, video_id: 'XX', titulo: 'Video previo', frase_detectada: 'frase de humo' }],
    },
  };
  await fsp.writeFile(path.join(projDir, 'publish.json'), JSON.stringify(pubFixture));
  await fsp.mkdir(path.join(projDir, 'transcripts'), { recursive: true });
  await fsp.writeFile(path.join(projDir, 'transcripts', 'humo.json'), JSON.stringify({
    words: Array.from({ length: 30 }, (_, i) => ({ type: 'word', text: `palabra${i}`, start: i * 0.5, end: i * 0.5 + 0.4 })),
  }));
  await fsp.mkdir(path.join(projDir, 'thumbs'), { recursive: true });
  // el tercer nombre trae comilla doble: regresión de inyección de atributos (revisión 19 jul)
  for (const [name, color] of [['thumb-a.png', 'orange'], ['thumb-b.png', 'purple'],
    ['thumb-x" onerror="injected.png', 'gray']]) {
    sh('ffmpeg', ['-nostdin', '-y', '-loglevel', 'error', '-f', 'lavfi', '-i', `color=c=${color}:s=64x36`, '-frames:v', '1',
      path.join(projDir, 'thumbs', name)]);
  }
  const srv = spawn('node', [path.join(ROOT, 'bin', 'sfreview.js'), projDir, '--port', String(PORT),
    '--roots', galRoot], { stdio: 'ignore' });
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
    const bctx = await browser.newContext({ permissions: ['clipboard-read', 'clipboard-write'] });
    const page = await bctx.newPage();
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
    // vista CORTE (default): el trim aparece como COSTURA (línea de corte), no recuadro
    await page.waitForSelector('.cutSeam', { timeout: 5000 });
    const trimTitle = await page.$eval('.cutSeam', (el) => el.title);
    // toggle de vista: raw muestra .trimRange, corte los colapsa a .cutSeam
    await page.click('#viewBtn');
    await page.waitForSelector('.trimRange', { timeout: 5000 });
    const rawViewOk = (await page.$$('.cutSeam')).length === 0;
    await page.click('#viewBtn');
    await page.waitForSelector('.cutSeam', { timeout: 5000 });
    const viewToggleOk = rawViewOk && (await page.$$('.trimRange')).length === 0;
    // ── edición manual de items: drag (mover) + trim de borde + Supr + ⌘Z ──
    const box0 = await page.$eval('#track2 .clipItem', (el) => {
      const r = el.getBoundingClientRect();
      return { x: r.x, y: r.y, w: r.width, h: r.height };
    });
    // drag del cuerpo +60px → mueve el item y lo selecciona
    await page.mouse.move(box0.x + box0.w / 2, box0.y + box0.h / 2);
    await page.mouse.down();
    await page.mouse.move(box0.x + box0.w / 2 + 60, box0.y + box0.h / 2, { steps: 6 });
    await page.mouse.up();
    const movedOk = await page.$eval('#track2 .clipItem', (el) => el.classList.contains('edited') && el.classList.contains('sel'));
    const infoOk = await page.$eval('#itemInfo', (el) => !el.hidden && /logo_google/.test(el.textContent));
    // trim del borde derecho -40px → encoge dur
    const box1 = await page.$eval('#track2 .clipItem', (el) => {
      const r = el.getBoundingClientRect();
      return { x: r.x, y: r.y, w: r.width, h: r.height };
    });
    await page.mouse.move(box1.x + box1.w - 3, box1.y + box1.h / 2);
    await page.mouse.down();
    await page.mouse.move(box1.x + box1.w - 43, box1.y + box1.h / 2, { steps: 5 });
    await page.mouse.up();
    const box2 = await page.$eval('#track2 .clipItem', (el) => el.getBoundingClientRect().width);
    const trimItemOk = box2 < box1.w - 20;
    // Supr borra el item seleccionado; ⌘Z lo revive; ⌘⇧Z rehace el borrado; ⌘Z restaura de nuevo
    await page.keyboard.press('Delete');
    const goneOk = (await page.$$('#track2 .clipItem')).length === 0;
    await page.keyboard.press('Meta+z');
    const backOk = (await page.$$('#track2 .clipItem')).length === 1;
    await page.keyboard.press('Meta+Shift+z');
    const redoOk = (await page.$$('#track2 .clipItem')).length === 0;
    await page.keyboard.press('Meta+z');
    const back2Ok = (await page.$$('#track2 .clipItem')).length === 1;
    // ↑ navega al bloque (lo selecciona) y S con selección parte el asset en dos
    await page.evaluate(() => new Promise((res) => {
      const v = document.getElementById('base');
      v.currentTime = 2.0; v.onseeked = res; setTimeout(res, 2000);
    }));
    await page.keyboard.press('ArrowUp');
    const navSelOk = await page.$eval('#track2 .clipItem', (el) => el.classList.contains('sel'));
    await page.evaluate(() => new Promise((res) => {
      const v = document.getElementById('base');
      v.currentTime = 2.0; v.onseeked = res; setTimeout(res, 2000);
    }));
    await page.keyboard.press('s');
    const splitOk = (await page.$$('#track2 .clipItem')).length === 2;
    await page.keyboard.press('Escape');
    // ⌥-arrastre sobre el ruler = recorte de rango del base (lejos del trim S/D previo)
    const ruler = await page.$eval('#ruler', (el) => {
      const r = el.getBoundingClientRect();
      return { x: r.x, y: r.y, w: r.width, h: r.height };
    });
    await page.keyboard.down('Alt');
    await page.mouse.move(ruler.x + ruler.w * 0.62, ruler.y + ruler.h / 2);
    await page.mouse.down();
    await page.mouse.move(ruler.x + ruler.w * 0.75, ruler.y + ruler.h / 2, { steps: 5 });
    await page.mouse.up();
    await page.keyboard.up('Alt');
    const nRanges = (await page.$$('.cutSeam')).length;
    // arrastrar la COSTURA recién creada: el corte completo se mueve (por si el punto exacto salió mal)
    const tr0 = await page.$eval('.cutSeam[data-tidx="1"]', (el) => {
      const r = el.getBoundingClientRect();
      return { x: r.x, y: r.y, w: r.width, h: r.height };
    });
    await page.mouse.move(tr0.x + tr0.w / 2, tr0.y + tr0.h / 2);
    await page.mouse.down();
    await page.mouse.move(tr0.x + tr0.w / 2 + 20, tr0.y + tr0.h / 2, { steps: 4 });
    await page.mouse.up();
    const tr0b = await page.$eval('.cutSeam[data-tidx="1"]', (el) => el.getBoundingClientRect().x);
    const trimDragOk = tr0b > tr0.x + 10 && (await page.$$('.cutSeam')).length === 2;
    // Q/E: seleccionar todo a un lado del cursor (E a la derecha desde t=0 = todos los assets)
    await page.evaluate(() => new Promise((res) => {
      const v = document.getElementById('base');
      v.currentTime = 0; v.onseeked = res; setTimeout(res, 2000);
    }));
    await page.keyboard.press('e');
    const totalItems = (await page.$$('.clipItem')).length;
    const selRight = (await page.$$('.clipItem.sel')).length;
    await page.keyboard.press('q');
    const selLeft = (await page.$$('.clipItem.sel')).length;
    const qeOk = totalItems > 0 && selRight === totalItems && selLeft === 0;
    await page.keyboard.press('Escape');
    // F: pantalla completa (toggle)
    await page.keyboard.press('f');
    await new Promise((r) => setTimeout(r, 300));
    const fsOn = await page.evaluate(() => !!document.fullscreenElement);
    await page.keyboard.press('f');
    await new Promise((r) => setTimeout(r, 300));
    const fsOk = fsOn && await page.evaluate(() => !document.fullscreenElement);
    const itemsOk = movedOk && infoOk && trimItemOk && goneOk && backOk && redoOk && back2Ok
      && navSelOk && splitOk && nRanges === 2 && trimDragOk && viewToggleOk && qeOk && fsOk;
    // marcador vía popover
    await page.keyboard.press('m');
    await page.waitForSelector('#popover:not([hidden])', { timeout: 5000 });
    await page.fill('#popInput', 'humo automatizado');
    await page.keyboard.press('Enter');
    // export (⌘E: la E sola ahora selecciona a la derecha) → escribe fixes.json del proyecto demo
    await page.keyboard.press('Meta+e');
    await page.waitForSelector('#modal:not([hidden])', { timeout: 5000 });
    await new Promise((r) => setTimeout(r, 400));
    const fixesTxt = await fsp.readFile(path.join(projDir, 'fixes.json'), 'utf8');
    const fx = JSON.parse(fixesTxt);
    const fixesOk = fx.trims?.length === 2 && Math.abs(fx.trims[0].start - 0.5) < 0.05 && fx.markers?.length === 1
      && fx.item_edits?.length === 1 && fx.item_edits[0].id === 'logo_google'
      && typeof fx.item_edits[0].start === 'number' && typeof fx.item_edits[0].dur === 'number'
      && fx.item_adds?.length === 1 && fx.item_adds[0].from === 0
      && typeof fx.item_adds[0].offset === 'number';
    // dossier ⌘Y: togglea, pinta stepper + títulos (elegido) + descripción con /go/ + transcript
    // segmentado + galería de thumbs + menciones, y cierra
    await page.click('#modalClose');
    await page.keyboard.press('y');
    await page.waitForSelector('#publishPanel:not([hidden])', { timeout: 5000 });
    await page.waitForSelector('.ppSeg', { timeout: 8000 });
    await page.waitForSelector('.ppThumb img', { timeout: 8000 });
    const nSteps = await page.$$eval('.ppStep', (els) => els.length);
    const nTitles = await page.$$eval('.ppTitle', (els) => els.length);
    const chosenTx = await page.$eval('.ppTitle.chosen .ppTitleTx', (el) => el.textContent).catch(() => '');
    const goHl = await page.$$eval('.ppGo', (els) => els.length);
    const nSegs = await page.$$eval('.ppSeg', (els) => els.length);
    const nThumbs = await page.$$eval('.ppThumb img', (els) => els.length);
    const nMents = await page.$$eval('.ppMention', (els) => els.length);
    // regresión: el filename con comilla NO debe inyectar atributos en el <img>
    const injected = await page.$$eval('.ppThumb img', (els) => els.some((el) => el.hasAttribute('onerror')));
    // rail: apagar Transcript → columna oculta y grid a 2 tracks; prender → vuelve
    await page.click('.ppRailBtn[data-col="tr"]'); // tr apagada → 2 columnas
    const trHidden = await page.$eval('.ppCol[data-col="tr"]', (el) => el.style.display === 'none');
    const gridCols2 = await page.$eval('#ppGrid', (el) => el.style.gridTemplateColumns.split(' ').length === 2);
    await page.click('.ppRailBtn[data-col="launch"]'); // launch apagada → queda SOLO meta
    const soloOk = await page.$eval('.ppCol[data-col="meta"]', (el) => el.classList.contains('solo'));
    await page.click('.ppRailBtn[data-col="tr"]');
    await page.click('.ppRailBtn[data-col="launch"]'); // restaurar las 3
    // copiar: la descripción del fixture debe llegar al clipboard
    await page.click('#copyDesc');
    const clip = await page.evaluate(() => navigator.clipboard.readText()).catch(() => '');
    const copyOk = /\/go\/vid-humo/.test(clip);
    await page.keyboard.press('y');
    const panelHidden = await page.$eval('#publishPanel', (el) => el.hidden);
    // ⌘⌥G: la GALERÍA abre ENCIMA de la sala y vuelve. Se manda por CODE porque en macOS
    // ⌥+g produce "©" y un handler por e.key jamás dispararía.
    await page.keyboard.press('Meta+Alt+KeyG');
    await page.waitForSelector('#galleryPanel:not([hidden])', { timeout: 5000 });
    await page.waitForSelector('.galCard', { timeout: 8000 });
    const galCards = await page.$$eval('.galCard', (els) => els.length);
    await page.keyboard.press('Meta+Alt+KeyG');
    const galClosed = await page.$eval('#galleryPanel', (el) => el.hidden);
    // la SALA sigue igual detrás: mismas costuras, mismos assets, mismo trim
    const salaIntacta = (await page.$$('.cutSeam')).length === 2 && (await page.$$('.clipItem')).length > 0;
    const galToggleOk = galCards === 2 && galClosed && salaIntacta;
    const panelOk = nSteps >= 9 && nTitles === 3 && /elegido de humo/i.test(chosenTx) && goHl >= 1
      && nSegs >= 2 && nThumbs === 3 && !injected && nMents === 1 && trHidden && gridCols2 && soloOk
      && copyOk && panelHidden && galToggleOk;
    // waveform API: proyecto demo sin audio → peaks [] es la respuesta válida
    const wf = await fetch(`http://127.0.0.1:${PORT}/api/waveform`);
    const wj = await wf.json();
    const waveOk = wf.ok && typeof wj.rate === 'number' && Array.isArray(wj.peaks)
      && (await page.$('#waveCanvas')) !== null;
    // ── GESTO NUEVO (Daniel 22 jul), AL FINAL para no ensuciar los checks previos: arrastrar sobre la
    // ONDA DE AUDIO = seleccionar rango del video principal (audio pegado) → Supr lo borra; clic derecho
    // → Separar audio. La onda NO tiene intercepción de costura (eso es solo track0 en vista corte). ──
    await page.keyboard.press('Escape');
    const wr = await page.$eval('#waveRow', (el) => { const r = el.getBoundingClientRect(); return { x: r.x, y: r.y, w: r.width, h: r.height }; });
    const trimBefore = await page.$eval('#trimSummary', (el) => el.textContent);
    await page.mouse.move(wr.x + wr.w * 0.03, wr.y + wr.h / 2);   // arranque, lejos de trims previos
    await page.mouse.down();
    await page.mouse.move(wr.x + wr.w * 0.11, wr.y + wr.h / 2, { steps: 6 });
    await page.mouse.up();
    const rangeSelOk = (await page.$$('.baseRangePersist')).length === 1;      // rango persistente pintado
    await page.keyboard.press('Delete');
    const trimAfter = await page.$eval('#trimSummary', (el) => el.textContent);
    const rangeDelOk = (await page.$$('.baseRangePersist')).length === 0 && trimAfter !== trimBefore; // recortó
    await page.mouse.click(wr.x + wr.w * 0.5, wr.y + wr.h / 2, { button: 'right' });
    const ctxOk = await page.evaluate(() => { const m = document.getElementById('ctxMenu'); return !!m && !m.hidden && /Separar audio/.test(m.textContent); });
    await page.evaluate(() => { const it = [...document.querySelectorAll('#ctxMenu .ctxItem')].find((d) => /Separar audio/.test(d.textContent)); it && it.click(); });
    const audioSepOk = await page.evaluate(() => document.getElementById('waveRow').classList.contains('detached'));
    const baseGestureOk = rangeSelOk && rangeDelOk && ctxOk && audioSepOk;
    await browser.close();
    ok = fixesOk && waveOk && panelOk && itemsOk && baseGestureOk && errors.length === 0 && /corte/.test(trimTitle);
    detail = `seam="${trimTitle.slice(0, 40)}…" fixes=${fixesOk} wave=${waveOk} panel=${panelOk} items=${itemsOk} baseSel/borra/audioSep=${baseGestureOk} ⌘⌥G=${galToggleOk} (drag/trim/supr/⌥rango/rango-base/sep-audio/QE/F/vista/galería) consola=${errors.length} errores`;
    if (errors.length) detail += ` :: ${errors.slice(0, 3).join(' | ')}`;
  } catch (e) {
    detail = e.message.split('\n')[0];
  } finally {
    srv.kill();
    await fsp.rm(path.join(projDir, 'fixes.json'), { force: true }); // no ensuciar el demo
    await fsp.rm(path.join(projDir, 'waveform.json'), { force: true });
    await fsp.rm(path.join(projDir, 'publish.json'), { force: true });
    await fsp.rm(path.join(projDir, 'transcripts'), { recursive: true, force: true });
    await fsp.rm(path.join(projDir, 'thumbs'), { recursive: true, force: true });
  }
  report('sfreview humo Playwright (S/D + items drag/trim/supr/⌥rango + marcador + export + waveform + dossier ⌘Y + galería ⌘⌥G, 0 errores)', ok, detail);
}

// ── 7. humo de la GALERÍA sola (`sfreview --gallery`): rejilla real, ficha completa, elegir
//        portada y editar+aprobar el post con PERSISTENCIA verificada en publish.json y tras recargar
{
  const PORT = 3998;
  const srv = spawn('node', [path.join(ROOT, 'bin', 'sfreview.js'), '--gallery', '--port', String(PORT),
    '--roots', galRoot], { stdio: 'ignore' });
  const A = path.join(galRoot, '2026-09-01-lanzamiento-completo');
  let ok = false, detail = '';
  try {
    for (let i = 0; i < 40; i++) {
      try { if ((await fetch(`http://127.0.0.1:${PORT}/api/gallery`)).ok) break; } catch { /* aún no */ }
      await new Promise((r) => setTimeout(r, 250));
    }
    const { chromium } = await import('playwright');
    const browser = await chromium.launch({ headless: true });
    const bctx = await browser.newContext({ viewport: { width: 1600, height: 1000 } });
    const page = await bctx.newPage();
    const errors = [];
    page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });
    page.on('pageerror', (e) => errors.push(String(e)));
    await page.goto(`http://127.0.0.1:${PORT}/`, { waitUntil: 'load' });

    // la galería arranca SOLA (sin sala) y pinta los dos lanzamientos con su estado honesto
    await page.waitForSelector('.galCard', { timeout: 10000 });
    const nCards = await page.$$eval('.galCard', (els) => els.length);
    const chips = await page.$$eval('.galChip', (els) => els.map((e) => e.textContent).join(' | '));
    const gridOk = nCards === 2 && /programado/.test(chips) && /en edición/.test(chips) && /sin post/.test(chips);
    // buscador: filtra la rejilla
    await page.fill('#galSearch', 'medias');
    const filtOk = (await page.$$('.galCard')).length === 1;
    await page.fill('#galSearch', '');

    // el proyecto A MEDIAS abre sin romper nada ni inventar datos
    await page.click('.galCard[data-id="r0/2026-09-02-a-medias"]');
    await page.waitForSelector('#galDetail:not([hidden])', { timeout: 5000 });
    const vacioTx = await page.$eval('#galDetail', (el) => el.textContent);
    const honestoOk = /sin descripción/i.test(vacioTx) && /sin fecha todavía/i.test(vacioTx)
      && /sin candidatas/i.test(vacioTx) && /sin transcript/i.test(vacioTx);
    await page.click('#galBack');
    await page.waitForSelector('#galGrid:not([hidden])', { timeout: 5000 });

    // la ficha COMPLETA: capítulos, transcript, miniaturas y el post
    await page.click('.galCard[data-id="r0/2026-09-01-lanzamiento-completo"]');
    await page.waitForSelector('#galPostBody', { timeout: 5000 });
    // LAS DOS FASES (el contrato de Daniel, no las 9 etapas internas) + el RAIL de secciones
    const fases = await page.$$eval('.galFase .galFaseCnt', (e) => e.map((x) => x.textContent));
    const faseItems = await page.$$eval('.galFaseItem', (e) => e.length);
    const sinStepper = (await page.$$('#galDetail .ppStep')).length === 0;   // el stepper viejo se fue
    const sinLink = !/Link de atribución/.test(await page.$eval('#galDetail', (e) => e.textContent));
    const cols0 = await page.$eval('.galDetGrid', (e) => e.dataset.cols);
    await page.click('.galRailBtn[data-sec="transcript"]');                  // apagar una sección
    const cols1 = await page.$eval('.galDetGrid', (e) => e.dataset.cols);
    const trOculto = await page.$eval('.galSec[data-sec="transcript"]', (e) => e.style.display === 'none');
    for (const sec of ['portada', 'texto', 'post']) await page.click(`.galRailBtn[data-sec="${sec}"]`);
    const ultimaViva = (await page.$$eval('#galDetail .galSec', (e) =>
      e.filter((x) => x.style.display !== 'none').length)) === 1;            // la última no se apaga
    await page.click('.galRailBtn[data-sec="transcript"]');
    for (const sec of ['portada', 'texto']) await page.click(`.galRailBtn[data-sec="${sec}"]`);
    const railOk = fases.length === 2 && fases[0] === '3/5' && fases[1] === '1/3' && faseItems === 8
      && sinStepper && sinLink && cols0 === '4' && cols1 === '3' && trOculto && ultimaViva;
    const nChaps = await page.$$eval('.galChapter', (els) => els.length);
    const nSegs = await page.$$eval('#galTranscript .ppSeg', (els) => els.length);
    const nThumbs = await page.$$eval('.galThumb', (els) => els.length);
    const coverName = await page.$eval('.galCoverName', (el) => el.textContent);
    const fichaOk = nChaps === 2 && nSegs === 6 && nThumbs === 2 && /ab-01\.png/.test(coverName);
    // transcript navegable: el buscador filtra los segmentos
    await page.fill('#galTrFilter', 'frase 3');
    const trFiltOk = (await page.$$('#galTranscript .ppSeg')).length === 1;
    await page.fill('#galTrFilter', '');

    // PORTADA: click en la 2a candidata la vuelve portada, y queda escrita en publish.json
    await page.click('.galThumb[data-thumb="ab-02.png"]');
    await page.waitForSelector('.galThumb[data-thumb="ab-02.png"].on', { timeout: 5000 });
    const pubTrasPortada = JSON.parse(await fsp.readFile(path.join(A, 'publish.json'), 'utf8'));
    const portadaOk = pubTrasPortada.data.thumbnail.chosen === 'ab-02.png';

    // POST: editar + aprobar → escrito en disco
    await page.fill('#galPostBody', 'Comunidad!\n\nTexto EDITADO desde la galería.');
    const sucioOk = await page.$eval('#galSaveHint', (el) => /sin guardar/.test(el.textContent));
    await page.click('[data-act="approve"]');
    await page.waitForSelector('[data-act="unapprove"]', { timeout: 5000 });
    const pubTrasPost = JSON.parse(await fsp.readFile(path.join(A, 'publish.json'), 'utf8'));
    const guardadoOk = /Texto EDITADO desde la galería/.test(pubTrasPost.data.post_draft.body)
      && !!pubTrasPost.data.post_draft.approved_at;

    // PERSISTENCIA REAL: recargar la página y volver a abrir la ficha
    await page.reload({ waitUntil: 'load' });
    await page.waitForSelector('.galCard', { timeout: 10000 });
    const chipsTras = await page.$$eval('.galChip', (els) => els.map((e) => e.textContent).join(' | '));
    await page.click('.galCard[data-id="r0/2026-09-01-lanzamiento-completo"]');
    await page.waitForSelector('#galPostBody', { timeout: 5000 });
    const bodyTras = await page.$eval('#galPostBody', (el) => el.value);
    const coverTras = await page.$eval('.galCoverName', (el) => el.textContent);
    const persisteOk = /Texto EDITADO desde la galería/.test(bodyTras)
      && /ab-02\.png/.test(coverTras) && /elegida/.test(coverTras)
      && /post aprobado/.test(chipsTras)
      && (await page.$('[data-act="unapprove"]')) !== null;

    // editar DESPUÉS de aprobar revoca la firma (nadie aprueba a ciegas un texto que cambió)
    await page.fill('#galPostBody', 'Comunidad!\n\nOtra cosa distinta.');
    await page.click('[data-act="save"]');
    await page.waitForSelector('[data-act="approve"]', { timeout: 5000 });
    const revocaOk = await page.$eval('#galPostState', (el) => /borrador/.test(el.textContent));

    // sandbox: no se puede salir de las raíces por el id ni por el nombre de archivo
    const t1 = await (await fetch(`http://127.0.0.1:${PORT}/api/gallery/item?id=${encodeURIComponent('r0/../../etc')}`)).status;
    const t2 = (await fetch(`http://127.0.0.1:${PORT}/gallery/thumb?id=r0/2026-09-01-lanzamiento-completo&f=${encodeURIComponent('../publish.json')}`)).status;
    const sandboxOk = t1 === 404 && (await t2) === 404;

    await browser.close();
    ok = gridOk && filtOk && honestoOk && fichaOk && railOk && trFiltOk && portadaOk && sucioOk
      && guardadoOk && persisteOk && revocaOk && sandboxOk && errors.length === 0;
    detail = `rejilla=${gridOk}(${nCards}) buscador=${filtOk} estado-honesto=${honestoOk} ficha=${fichaOk}(${nChaps}cap/${nSegs}seg/${nThumbs}thumb) fases+rail=${railOk}(${fases.join('/')}) buscaTr=${trFiltOk} portada=${portadaOk} guarda=${guardadoOk} PERSISTE=${persisteOk} revoca=${revocaOk} sandbox=${sandboxOk} consola=${errors.length} errores`;
    if (errors.length) detail += ` :: ${errors.slice(0, 3).join(' | ')}`;
  } catch (e) {
    detail = e.message.split('\n')[0];
  } finally {
    srv.kill();
  }
  report('galería ⌘⌥G humo Playwright (rejilla + ficha + 2 fases + rail + portada + post editable/aprobable con persistencia, 0 errores)', ok, detail);
}

await fsp.rm(tmp, { recursive: true, force: true });
process.stdout.write(`\n${results.filter((r) => r.ok).length}/${results.length} verdes\n`);
process.exit(failed ? 1 : 0);
