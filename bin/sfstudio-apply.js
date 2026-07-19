#!/usr/bin/env node
// sfstudio-apply <fixes.json> <master.mp4> [-o out.mp4] [--dry-run]
// El puente AI-first: Daniel recorta/anota en la sala → la fábrica aplica los cortes al máster.
// Frame-accurate: trim/atrim + concat re-encodeado (mismo método del máster de la fábrica).
// El N del concat se calcula PROGRAMÁTICAMENTE y se asserta contra los pares del filtergraph
// antes de invocar ffmpeg (gotcha #32 de la skill).
import { promises as fsp } from 'node:fs';
import { spawn } from 'node:child_process';

function usage(code = 1) {
  process.stderr.write('uso: sfstudio-apply <fixes.json> <master.mp4> [-o out.mp4] [--dry-run]\n');
  process.exit(code);
}

const args = process.argv.slice(2);
if (args.length < 2 || args.includes('-h') || args.includes('--help')) usage(args.includes('-h') || args.includes('--help') ? 0 : 1);

let fixesPath = null, masterPath = null, outPath = null, dryRun = false;
for (let i = 0; i < args.length; i++) {
  const a = args[i];
  if (a === '-o' || a === '--out') outPath = args[++i];
  else if (a === '--dry-run') dryRun = true;
  else if (!fixesPath) fixesPath = a;
  else if (!masterPath) masterPath = a;
  else usage();
}
if (!fixesPath || !masterPath) usage();
outPath = outPath || masterPath.replace(/\.mp4$/, '') + '.fixed.mp4';

const fixes = JSON.parse(await fsp.readFile(fixesPath, 'utf8'));
await fsp.access(masterPath).catch(() => { process.stderr.write(`no existe el máster: ${masterPath}\n`); process.exit(1); });

function probeDuration(p) {
  return new Promise((resolve, reject) => {
    const pr = spawn('ffprobe', ['-v', 'error', '-show_entries', 'format=duration', '-of', 'default=nk=1:nw=1', p]);
    let out = '';
    pr.stdout.on('data', (d) => (out += d));
    pr.on('close', (c) => (c === 0 ? resolve(parseFloat(out.trim())) : reject(new Error('ffprobe falló'))));
  });
}
const masterDur = await probeDuration(masterPath);

// merge de trims (mismo criterio que la sala)
const trims = (fixes.trims || [])
  .map((r) => ({ start: Math.max(0, +r.start), end: Math.min(masterDur, +r.end) }))
  .filter((r) => r.end - r.start > 1e-4)
  .sort((a, b) => a.start - b.start)
  .reduce((acc, r) => {
    const last = acc[acc.length - 1];
    if (last && r.start <= last.end + 1e-4) last.end = Math.max(last.end, r.end);
    else acc.push({ ...r });
    return acc;
  }, []);

if (!trims.length) {
  process.stdout.write('fixes.json sin trims — nada que aplicar al máster.\n');
  if (fixes.markers?.length) {
    process.stdout.write(`marcadores (notas para la fábrica):\n`);
    for (const m of fixes.markers) process.stdout.write(`  @${m.t}s  ${m.nota}\n`);
  }
  process.exit(0);
}

// keep = complemento de los trims
const keeps = [];
let cursor = 0;
for (const r of trims) {
  if (r.start - cursor > 0.02) keeps.push({ start: cursor, end: r.start });
  cursor = r.end;
}
if (masterDur - cursor > 0.02) keeps.push({ start: cursor, end: masterDur });
if (!keeps.length) { process.stderr.write('los trims cubren TODO el máster — nada quedaría. Aborto.\n'); process.exit(1); }

const N = keeps.length; // programático, jamás a mano (gotcha #32)
const parts = [];
const pairs = [];
keeps.forEach((k, i) => {
  parts.push(`[0:v]trim=start=${k.start.toFixed(3)}:end=${k.end.toFixed(3)},setpts=PTS-STARTPTS[v${i}]`);
  parts.push(`[0:a]atrim=start=${k.start.toFixed(3)}:end=${k.end.toFixed(3)},asetpts=PTS-STARTPTS[a${i}]`);
  pairs.push(`[v${i}][a${i}]`);
});
const graph = `${parts.join(';')};${pairs.join('')}concat=n=${N}:v=1:a=1[v][a]`;

// assert de pares vs N (gotcha #32) ANTES de invocar ffmpeg
const pairCount = (graph.match(/\[v\d+\]\[a\d+\]/g) || []).length;
if (pairCount !== N) {
  process.stderr.write(`ASSERT FALLÓ: ${pairCount} pares vs concat n=${N} — filtergraph malformado, no invoco ffmpeg.\n`);
  process.exit(1);
}

const cutTotal = trims.reduce((s, r) => s + (r.end - r.start), 0);
const enc = ['-map', '[v]', '-map', '[a]', '-c:v', 'h264_videotoolbox', '-b:v', '12M',
  '-c:a', 'aac', '-b:a', '192k', '-ar', '48000', '-movflags', '+faststart'];
const cmd = ['ffmpeg', '-nostdin', '-y', '-loglevel', 'error', '-i', masterPath, '-filter_complex', graph, ...enc, outPath];

process.stdout.write(`máster:  ${masterPath} (${masterDur.toFixed(3)}s)\n`);
process.stdout.write(`cortes:  ${trims.length} rango(s), ${cutTotal.toFixed(3)}s eliminados → duración final ${(masterDur - cutTotal).toFixed(3)}s\n`);
trims.forEach((r, i) => process.stdout.write(`  corte ${i + 1}: ${r.start.toFixed(3)}s → ${r.end.toFixed(3)}s (${(r.end - r.start).toFixed(3)}s)\n`));
process.stdout.write(`conservo ${N} segmento(s):\n`);
keeps.forEach((k, i) => process.stdout.write(`  seg ${i + 1}: ${k.start.toFixed(3)}s → ${k.end.toFixed(3)}s\n`));
if (fixes.markers?.length) {
  process.stdout.write(`marcadores (notas, NO se aplican solos):\n`);
  for (const m of fixes.markers) process.stdout.write(`  @${m.t}s  ${m.nota}\n`);
}
process.stdout.write(`\ncomando ffmpeg:\n  ${cmd.map((c) => (/[ ;\[\]]/.test(c) ? `'${c}'` : c)).join(' ')}\n`);

if (dryRun) {
  process.stdout.write('\n--dry-run: no ejecuté nada.\n');
  process.exit(0);
}

const t0 = Date.now();
await new Promise((resolve, reject) => {
  const p = spawn(cmd[0], cmd.slice(1), { stdio: ['ignore', 'inherit', 'inherit'] });
  p.on('close', (c) => (c === 0 ? resolve() : reject(new Error(`ffmpeg exit ${c}`))));
}).catch(async (e) => {
  // fallback a libx264 si videotoolbox no está
  process.stderr.write(`${e.message} — reintento con libx264…\n`);
  const cmd2 = cmd.map((c) => (c === 'h264_videotoolbox' ? 'libx264' : c === '12M' ? '18' : c));
  const bIdx = cmd2.indexOf('-b:v');
  if (bIdx > -1) cmd2.splice(bIdx, 2, '-crf', '18');
  await new Promise((resolve, reject2) => {
    const p2 = spawn(cmd2[0], cmd2.slice(1), { stdio: ['ignore', 'inherit', 'inherit'] });
    p2.on('close', (c) => (c === 0 ? resolve() : reject2(new Error(`ffmpeg exit ${c}`))));
  });
});
const outDur = await probeDuration(outPath);
process.stdout.write(`\n✓ ${outPath} (${outDur.toFixed(3)}s) en ${((Date.now() - t0) / 1000).toFixed(1)}s\n`);
const expected = masterDur - cutTotal;
if (Math.abs(outDur - expected) > 0.5) {
  process.stderr.write(`⚠️ duración final ${outDur.toFixed(3)}s difiere de la esperada ${expected.toFixed(3)}s — revisar.\n`);
  process.exit(1);
}
