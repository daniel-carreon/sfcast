#!/usr/bin/env node
// sfstudio-apply <fixes.json> <master.mp4> [-o out.mp4] [--dry-run] [--force]
// El puente AI-first: Daniel recorta/anota en la sala → la fábrica aplica los cortes al máster.
// Frame-accurate: trim/atrim + concat re-encodeado (mismo método del máster de la fábrica).
// Endurecido tras la revisión adversarial del 18 jul: audio opcional, guard de duración
// proxy↔máster, trims descartados SIEMPRE reportados, errores limpios + cleanup de parciales.
import { promises as fsp } from 'node:fs';
import { spawn } from 'node:child_process';

function usage(code = 1) {
  process.stderr.write('uso: sfstudio-apply <fixes.json> <master.mp4> [-o out.mp4] [--dry-run] [--force]\n');
  process.exit(code);
}

const args = process.argv.slice(2);
if (args.length < 2 || args.includes('-h') || args.includes('--help')) usage(args.includes('-h') || args.includes('--help') ? 0 : 1);

let fixesPath = null, masterPath = null, outPath = null, dryRun = false, force = false;
for (let i = 0; i < args.length; i++) {
  const a = args[i];
  if (a === '-o' || a === '--out') outPath = args[++i];
  else if (a === '--dry-run') dryRun = true;
  else if (a === '--force') force = true;
  else if (!fixesPath) fixesPath = a;
  else if (!masterPath) masterPath = a;
  else usage();
}
if (!fixesPath || !masterPath) usage();
outPath = outPath || masterPath.replace(/\.mp4$/, '') + '.fixed.mp4';

function ffprobe(argv) {
  return new Promise((resolve, reject) => {
    const pr = spawn('ffprobe', ['-v', 'error', ...argv]);
    let out = '';
    pr.stdout.on('data', (d) => (out += d));
    pr.on('close', (c) => (c === 0 ? resolve(out.trim()) : reject(new Error(`ffprobe falló sobre el archivo (¿es un video válido?)`))));
    pr.on('error', reject);
  });
}
const probeDuration = async (p) => parseFloat(await ffprobe(['-show_entries', 'format=duration', '-of', 'default=nk=1:nw=1', p]));
const probeHasAudio = async (p) => (await ffprobe(['-select_streams', 'a', '-show_entries', 'stream=codec_type', '-of', 'default=nk=1:nw=1', p])) !== '';

async function main() {
  const fixes = JSON.parse(await fsp.readFile(fixesPath, 'utf8').catch(() => { throw new Error(`no pude leer ${fixesPath}`); }));
  await fsp.access(masterPath).catch(() => { throw new Error(`no existe el máster: ${masterPath}`); });

  const masterDur = await probeDuration(masterPath);
  const hasAudio = await probeHasAudio(masterPath);

  // GUARD: el fixes.json registra la duración del PROXY donde Daniel recortó. Si el máster
  // difiere de forma grosera, casi seguro es el archivo equivocado — abortar salvo --force.
  if (Number.isFinite(+fixes.duration) && Math.abs(+fixes.duration - masterDur) > 1.0) {
    const msg = `el máster mide ${masterDur.toFixed(3)}s pero el fixes.json se exportó sobre un timeline de ${(+fixes.duration).toFixed(3)}s — ¿máster equivocado o de otra versión?`;
    if (!force) throw new Error(`${msg}\nSi ESTÁS SEGURO de que corresponde, repite con --force.`);
    process.stdout.write(`⚠️ ${msg} (continuando por --force)\n`);
  }

  const rawTrims = Array.isArray(fixes.trims) ? fixes.trims : [];
  const clamped = rawTrims.map((r) => ({
    orig: r,
    start: Math.max(0, +r.start),
    end: Math.min(masterDur, +r.end),
  }));
  const dropped = clamped.filter((r) => !(r.end - r.start > 1e-4));
  const trims = clamped
    .filter((r) => r.end - r.start > 1e-4)
    .map(({ start, end }) => ({ start, end }))
    .sort((a, b) => a.start - b.start)
    .reduce((acc, r) => {
      const last = acc[acc.length - 1];
      if (last && r.start <= last.end + 1e-4) last.end = Math.max(last.end, r.end);
      else acc.push({ ...r });
      return acc;
    }, []);

  // los descartes NUNCA son silenciosos (hallazgo revisión: parecían "sin ediciones")
  for (const d of dropped) {
    process.stdout.write(`⚠️ trim DESCARTADO por caer fuera del máster: ${JSON.stringify(d.orig)} (máster ${masterDur.toFixed(3)}s)\n`);
  }

  if (!trims.length) {
    process.stdout.write(rawTrims.length
      ? `los ${rawTrims.length} trim(s) del fixes.json quedaron fuera de rango — nada aplicable (¿máster correcto?).\n`
      : 'fixes.json sin trims — nada que aplicar al máster.\n');
    if (fixes.markers?.length) {
      process.stdout.write('marcadores (notas para la fábrica):\n');
      for (const m of fixes.markers) process.stdout.write(`  @${m.t}s  ${m.nota}\n`);
    }
    process.exit(rawTrims.length && !force ? 1 : 0);
  }

  // keep = complemento de los trims
  const keeps = [];
  let cursor = 0;
  for (const r of trims) {
    if (r.start - cursor > 0.02) keeps.push({ start: cursor, end: r.start });
    cursor = r.end;
  }
  if (masterDur - cursor > 0.02) keeps.push({ start: cursor, end: masterDur });
  if (!keeps.length) throw new Error('los trims cubren TODO el máster — nada quedaría. Aborto.');

  const N = keeps.length; // programático, jamás a mano (gotcha #32)
  const parts = [];
  const pairs = [];
  keeps.forEach((k, i) => {
    parts.push(`[0:v]trim=start=${k.start.toFixed(3)}:end=${k.end.toFixed(3)},setpts=PTS-STARTPTS[v${i}]`);
    if (hasAudio) parts.push(`[0:a]atrim=start=${k.start.toFixed(3)}:end=${k.end.toFixed(3)},asetpts=PTS-STARTPTS[a${i}]`);
    pairs.push(hasAudio ? `[v${i}][a${i}]` : `[v${i}]`);
  });
  const graph = `${parts.join(';')};${pairs.join('')}concat=n=${N}:v=1:a=${hasAudio ? 1 : 0}[v]${hasAudio ? '[a]' : ''}`;

  // assert de labels vs N (gotcha #32) ANTES de invocar ffmpeg: cada [vN] (y [aN] si hay
  // audio) debe aparecer EXACTAMENTE 2 veces — como salida del trim y como entrada del concat
  const vLabels = (graph.match(/\[v\d+\]/g) || []).length;
  const aLabels = (graph.match(/\[a\d+\]/g) || []).length;
  if (vLabels !== N * 2 || (hasAudio ? aLabels !== N * 2 : aLabels !== 0)) {
    throw new Error(`ASSERT FALLÓ: v=${vLabels}/a=${aLabels} labels vs concat n=${N} — filtergraph malformado, no invoco ffmpeg.`);
  }

  const cutTotal = trims.reduce((s, r) => s + (r.end - r.start), 0);
  const enc = ['-map', '[v]', ...(hasAudio ? ['-map', '[a]', '-c:a', 'aac', '-b:a', '192k', '-ar', '48000'] : []),
    '-c:v', 'h264_videotoolbox', '-b:v', '12M', '-movflags', '+faststart'];
  const cmd = ['ffmpeg', '-nostdin', '-y', '-loglevel', 'error', '-i', masterPath, '-filter_complex', graph, ...enc, outPath];

  process.stdout.write(`máster:  ${masterPath} (${masterDur.toFixed(3)}s${hasAudio ? '' : ', SIN pista de audio'})\n`);
  process.stdout.write(`cortes:  ${trims.length} rango(s), ${cutTotal.toFixed(3)}s eliminados → duración final ${(masterDur - cutTotal).toFixed(3)}s\n`);
  trims.forEach((r, i) => process.stdout.write(`  corte ${i + 1}: ${r.start.toFixed(3)}s → ${r.end.toFixed(3)}s (${(r.end - r.start).toFixed(3)}s)\n`));
  process.stdout.write(`conservo ${N} segmento(s):\n`);
  keeps.forEach((k, i) => process.stdout.write(`  seg ${i + 1}: ${k.start.toFixed(3)}s → ${k.end.toFixed(3)}s\n`));
  if (fixes.markers?.length) {
    process.stdout.write('marcadores (notas, NO se aplican solos):\n');
    for (const m of fixes.markers) process.stdout.write(`  @${m.t}s  ${m.nota}\n`);
  }
  process.stdout.write(`\ncomando ffmpeg:\n  ${cmd.map((c) => (/[ ;\[\]]/.test(c) ? `'${c}'` : c)).join(' ')}\n`);

  if (dryRun) {
    process.stdout.write('\n--dry-run: no ejecuté nada.\n');
    return;
  }

  const t0 = Date.now();
  const run = (argv) => new Promise((resolve, reject) => {
    const p = spawn(argv[0], argv.slice(1), { stdio: ['ignore', 'inherit', 'inherit'] });
    p.on('close', (c) => (c === 0 ? resolve() : reject(new Error(`ffmpeg exit ${c}`))));
    p.on('error', reject);
  });
  try {
    await run(cmd);
  } catch (e) {
    process.stderr.write(`${e.message} — reintento con libx264…\n`);
    const cmd2 = [...cmd];
    const vt = cmd2.indexOf('h264_videotoolbox');
    cmd2.splice(vt, 1, 'libx264');
    const bIdx = cmd2.indexOf('-b:v');
    if (bIdx > -1) cmd2.splice(bIdx, 2, '-crf', '18');
    await run(cmd2); // si también falla, el catch de tope limpia el parcial
  }
  const outDur = await probeDuration(outPath);
  process.stdout.write(`\n✓ ${outPath} (${outDur.toFixed(3)}s) en ${((Date.now() - t0) / 1000).toFixed(1)}s\n`);
  const expected = masterDur - cutTotal;
  if (Math.abs(outDur - expected) > 0.5) {
    throw new Error(`duración final ${outDur.toFixed(3)}s difiere de la esperada ${expected.toFixed(3)}s — revisar.`);
  }
}

try {
  await main();
} catch (e) {
  process.stderr.write(`sfstudio-apply ERROR: ${e.message}\n`);
  // no dejar un output parcial/0-bytes como basura engañosa
  try {
    const st = await fsp.stat(outPath);
    if (st.size === 0) await fsp.rm(outPath, { force: true });
  } catch { /* no existe, ok */ }
  process.exit(1);
}
