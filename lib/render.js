// sfrender core: card HTML/GSAP → secuencia PNG determinista → mux ffmpeg.
// Contrato de cards (invariante de la fábrica):
//   <div id="root" data-composition-id data-duration data-width data-height> + assets relativos
//   + UNA gsap.timeline({paused:true}) registrada en window.__timelines[id].
// Técnica (verificada estado-del-arte 18 jul 2026): seek de la timeline pausada frame a frame
// + screenshot plano (beginFrame fue removido de Chromium 147) + mux ffmpeg.
import { chromium } from 'playwright';
import { spawn } from 'node:child_process';
import { promises as fsp } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { startStatic } from './static-server.js';

const CHROME_ARGS = [
  '--force-color-profile=srgb', // mismo color en cualquier máquina (bug wide-gamut de Chromium)
  '--font-render-hinting=none',
  '--hide-scrollbars',
];

export class RenderError extends Error {}

function runFfmpeg(args, { quiet = true } = {}) {
  return new Promise((resolve, reject) => {
    const p = spawn('ffmpeg', ['-nostdin', '-y', '-loglevel', quiet ? 'error' : 'info', ...args], {
      stdio: ['ignore', 'inherit', 'pipe'],
    });
    let err = '';
    p.stderr.on('data', (d) => (err += d));
    p.on('close', (code) => (code === 0 ? resolve() : reject(new RenderError(`ffmpeg exit ${code}\n${err.slice(-2000)}`))));
    p.on('error', reject);
  });
}

async function muxFrames(framesDir, outPath, { format, fps, quiet }) {
  const input = ['-framerate', String(fps), '-i', path.join(framesDir, 'f_%05d.png')];
  if (format === 'mp4') {
    // h264_videotoolbox (HW, rápido) con fallback libx264. yuv420p como los renders HF de referencia.
    const common = ['-pix_fmt', 'yuv420p', '-colorspace', 'bt709', '-color_primaries', 'bt709', '-color_trc', 'bt709', '-movflags', '+faststart', outPath];
    try {
      await runFfmpeg([...input, '-c:v', 'h264_videotoolbox', '-b:v', '8M', ...common], { quiet });
    } catch {
      await runFfmpeg([...input, '-c:v', 'libx264', '-crf', '18', '-preset', 'medium', ...common], { quiet });
    }
  } else if (format === 'webm') {
    // Receta alpha verificada (Remotion + Chrome devs): libvpx-vp9 + yuva420p, UNA pasada continua
    // (el alpha VP9 driftea si se renderiza en chunks). auto-alt-ref=0 obligatorio con alpha.
    await runFfmpeg([...input, '-c:v', 'libvpx-vp9', '-pix_fmt', 'yuva420p', '-b:v', '0', '-crf', '26', '-row-mt', '1', '-auto-alt-ref', '0', outPath], { quiet });
  } else if (format === 'prores') {
    await runFfmpeg([...input, '-c:v', 'prores_ks', '-profile:v', '4444', '-pix_fmt', 'yuva444p10le', outPath], { quiet });
  } else {
    throw new RenderError(`formato desconocido: ${format}`);
  }
}

/**
 * Renderiza una card. cardPath = dir con index.html (o ruta a un .html).
 * opts: { out, format: 'mp4'|'webm'|'prores', fps=30, quiet=false, keepFrames=false }
 */
export async function renderCard(cardPath, opts = {}) {
  const t0 = Date.now();
  const format = opts.format || (opts.out?.endsWith('.webm') ? 'webm' : opts.out?.endsWith('.mov') ? 'prores' : 'mp4');
  const fps = opts.fps ?? 30; // ?? y no ||: un --fps 0 explícito debe FALLAR, no caer al default en silencio
  if (!Number.isFinite(fps) || fps <= 0) throw new RenderError(`fps inválido: ${fps}`);
  const quiet = opts.quiet ?? false;

  let cardDir = cardPath;
  let entry = 'index.html';
  const st = await fsp.stat(cardPath);
  if (!st.isDirectory()) {
    cardDir = path.dirname(cardPath);
    entry = path.basename(cardPath);
  }
  await fsp.access(path.join(cardDir, entry)).catch(() => {
    throw new RenderError(`no existe ${entry} en ${cardDir}`);
  });

  const srv = await startStatic(cardDir);
  const browser = await chromium.launch({ headless: true, args: CHROME_ARGS });
  const framesDir = await fsp.mkdtemp(path.join(os.tmpdir(), 'sfrender-'));
  try {
    const page = await browser.newPage({ viewport: { width: 1280, height: 720 }, deviceScaleFactor: 1 });
    const consoleErrors = [];
    page.on('console', (m) => { if (m.type() === 'error') consoleErrors.push(m.text()); });
    page.on('pageerror', (e) => consoleErrors.push(String(e)));

    await page.goto(`${srv.url}/${entry}`, { waitUntil: 'load', timeout: 30000 });

    // Contrato: leer metadata del root.
    const meta = await page.evaluate(() => {
      const root = document.getElementById('root');
      if (!root) return null;
      return {
        id: root.dataset.compositionId,
        duration: parseFloat(root.dataset.duration),
        width: parseInt(root.dataset.width, 10),
        height: parseInt(root.dataset.height, 10),
        videos: document.querySelectorAll('video').length,
      };
    });
    if (!meta || !meta.id || !Number.isFinite(meta.duration) || !meta.width || !meta.height) {
      throw new RenderError(`card no cumple el contrato (#root con data-composition-id/duration/width/height) en ${cardDir}`);
    }
    if (meta.videos > 0 && !opts.allowVideo) {
      throw new RenderError(
        `la card contiene ${meta.videos} <video>: los decoders headless NO obedecen el seek (hallazgo verificado). ` +
        `Pre-extrae el video a secuencia de imágenes e inyecta <img> por frame, o corre con --allow-video bajo tu riesgo.`
      );
    }

    await page.setViewportSize({ width: meta.width, height: meta.height });

    // Timeline registrada + fonts listas + settle inicial.
    // polling por intervalo, NO 'raf': en headless una página ociosa no produce frames y rAF se cuelga.
    // OJO: el predicado DEBE devolver booleano — devolver la timeline de GSAP (objeto con
    // referencias circulares) rompe la transferencia del handle y waitForFunction espera para siempre.
    await page.waitForFunction(
      (id) => !!(window.__timelines && window.__timelines[id]), meta.id, { timeout: 15000, polling: 100 }
    );
    await page.evaluate(() => document.fonts.ready.then(() => undefined));
    await page.evaluate((id) => { const tl = window.__timelines[id]; tl.pause(); tl.seek(0); }, meta.id);
    const omitBackground = format !== 'mp4';
    await page.screenshot({ type: 'png', omitBackground }); // warmup descartable (gotcha fonts/first-paint)

    const nFrames = Math.round(meta.duration * fps);
    if (nFrames <= 0) throw new RenderError(`duración inválida: ${meta.duration}`);

    for (let f = 0; f < nFrames; f++) {
      await page.evaluate(
        ([id, t]) => {
          const tl = window.__timelines[id];
          tl.seek(t); // suppressEvents=true por default en GSAP; aplica estilos SÍNCRONO
          // settle acotado: doble-rAF si el compositor está vivo, timeout 50ms si no (headless ocioso)
          return new Promise((r) => {
            let done = false;
            requestAnimationFrame(() => requestAnimationFrame(() => { done = true; r(); }));
            setTimeout(() => { if (!done) r(); }, 50);
          });
        },
        [meta.id, f / fps]
      );
      await page.screenshot({
        type: 'png',
        omitBackground,
        clip: { x: 0, y: 0, width: meta.width, height: meta.height },
        path: path.join(framesDir, `f_${String(f).padStart(5, '0')}.png`),
      });
      if (!quiet && nFrames > 20 && f % Math.floor(nFrames / 4) === 0 && f > 0) {
        process.stderr.write(`  frame ${f}/${nFrames}\n`);
      }
    }

    const out = opts.out || path.join(process.cwd(), `${meta.id}.${format === 'prores' ? 'mov' : format}`);
    await muxFrames(framesDir, out, { format, fps, quiet: true });

    const secs = ((Date.now() - t0) / 1000).toFixed(1);
    if (!quiet) {
      process.stderr.write(`sfrender: ${meta.id} → ${out} (${nFrames}f @${fps}fps ${meta.width}x${meta.height} ${format}) en ${secs}s\n`);
      if (consoleErrors.length) process.stderr.write(`  ⚠️ ${consoleErrors.length} errores de consola en la card:\n  ${consoleErrors.slice(0, 5).join('\n  ')}\n`);
    }
    return { out, frames: nFrames, fps, width: meta.width, height: meta.height, id: meta.id, seconds: parseFloat(secs), consoleErrors };
  } finally {
    await browser.close();
    await srv.close();
    if (!opts.keepFrames) await fsp.rm(framesDir, { recursive: true, force: true });
  }
}
