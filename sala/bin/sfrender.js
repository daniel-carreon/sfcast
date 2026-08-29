#!/usr/bin/env node
// sfrender <card-dir> [-o out] [--format mp4|webm|prores] [--fps N] [--quiet] [--allow-video]
import { renderCard, RenderError } from '../lib/render.js';

function usage(code = 1) {
  process.stderr.write(
    `uso: sfrender <card-dir|index.html> [-o out.(mp4|webm|mov)] [--format mp4|webm|prores] [--fps N] [--quiet] [--allow-video]\n`
  );
  process.exit(code);
}

const args = process.argv.slice(2);
if (!args.length || args.includes('-h') || args.includes('--help')) usage(args.length ? 0 : 1);

let cardPath = null;
const opts = {};
for (let i = 0; i < args.length; i++) {
  const a = args[i];
  if (a === '-o' || a === '--out') opts.out = args[++i];
  else if (a === '--format') opts.format = args[++i];
  else if (a === '--fps') opts.fps = parseFloat(args[++i]);
  else if (a === '--quiet') opts.quiet = true;
  else if (a === '--allow-video') opts.allowVideo = true;
  else if (a === '--keep-frames') opts.keepFrames = true;
  else if (!a.startsWith('-') && !cardPath) cardPath = a;
  else usage();
}
if (!cardPath) usage();

try {
  await renderCard(cardPath, opts);
  process.exit(0);
} catch (e) {
  process.stderr.write(`sfrender ERROR: ${e instanceof RenderError ? e.message : e.stack}\n`);
  process.exit(1);
}
