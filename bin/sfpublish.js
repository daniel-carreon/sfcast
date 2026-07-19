#!/usr/bin/env node
// sfpublish <proyecto-dir> <etapa> — la SEGUNDA ETAPA de la línea: del máster aprobado al publicado.
// AI-first: estos comandos los corre el AGENTE (Levy); el panel ⌘Y de la sala solo REFLEJA publish.json.
//
// Etapas: init | metadata | mentions | checklist | schedule | post | upload | connect | status
// Reglas duras: BD del negocio SOLO lectura salvo insert idempotente en tracked_links ·
// posts = SOLO texto (jamás insert en la BD del producto) · upload jamás publica público.
import path from 'node:path';
import os from 'node:os';
import { promises as fsp } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import {
  STAGES, newPublish, setStage, loadPublish, savePublish,
  slugFromYoutubeId, slugFromProjectName, parseTranscript, findMentions,
  checklistGate, nextSlots, communityPost,
} from '../lib/publish.js';

const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');

function usage(code = 1) {
  process.stderr.write(`uso: sfpublish <proyecto-dir> <etapa> [opciones]
etapas:
  init        crea publish.json (esqueleto de etapas)
  metadata    transcript → descripción/títulos/keywords (system prompt del producto) + link /go/ verificado
  mentions    transcript ↔ youtube_videos → plan de tarjetas + end screen
  checklist   gate de publicación (exit≠0 si falla algo duro)
  schedule    sugiere slot según peak hours del canal
  post        texto del anuncio de comunidad (SOLO texto)
  upload      subida agéntica a YouTube Studio (perfil persistente; draft PRIVADO)
  connect     abre el navegador del perfil para loguear Google (ritual de 1 vez)
  status      imprime el estado de publish.json
opciones:
  --youtube-url <url>   URL de YouTube ya existente (slug vid-<id> como el producto)
  --slug <slug>         fuerza el slug del tracked link
  --transcript <path>   transcript word-level JSON (default: autodetecta edit/transcripts/*.json)
  --test                (upload) prueba E2E con demo/out/card-916.mp4, draft privado + BORRADO
  --env <path>          .env alterno (default: ~/Developer/business-os/agent-server/.env)
`);
  process.exit(code);
}

// ---------- args ----------
const argv = process.argv.slice(2);
if (!argv.length || argv.includes('-h') || argv.includes('--help')) usage(argv.length ? 0 : 1);
const flags = {};
const pos = [];
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a === '--youtube-url') flags.youtubeUrl = argv[++i];
  else if (a === '--slug') flags.slug = argv[++i];
  else if (a === '--transcript') flags.transcript = argv[++i];
  else if (a === '--env') flags.env = argv[++i];
  else if (a === '--file') flags.file = argv[++i];
  else if (a === '--test') flags.test = true;
  else if (a.startsWith('-')) usage();
  else pos.push(a);
}
const [projArg, stage] = pos;
if (!stage && projArg !== 'connect') usage();
const projectDir = projArg === 'connect' ? null : path.resolve(projArg);
const cmd = projArg === 'connect' ? 'connect' : stage;

// ---------- env (agent-server/.env es el path canónico de credenciales) ----------
async function loadEnv() {
  const envPath = flags.env || process.env.SFPUBLISH_ENV ||
    path.join(os.homedir(), 'Developer', 'business-os', 'agent-server', '.env');
  const env = {};
  try {
    for (const line of (await fsp.readFile(envPath, 'utf8')).split('\n')) {
      const m = /^([A-Z0-9_]+)=(.*)$/.exec(line.trim());
      if (m) env[m[1]] = m[2].replace(/^["']|["']$/g, '');
    }
  } catch (e) {
    throw new Error(`no pude leer el .env de credenciales (${envPath}): ${e.message}`);
  }
  return env;
}

// ---------- Supabase REST (SF project). SOLO lectura + insert idempotente en tracked_links ----------
function sbHeaders(env) {
  return { apikey: env.SF_SUPABASE_KEY, Authorization: `Bearer ${env.SF_SUPABASE_KEY}` };
}
async function sbGet(env, pathq) {
  const r = await fetch(`${env.SF_SUPABASE_URL}/rest/v1/${pathq}`, { headers: sbHeaders(env) });
  if (!r.ok) throw new Error(`Supabase GET ${pathq} → ${r.status}: ${(await r.text()).slice(0, 200)}`);
  return r.json();
}
async function ensureTrackedLink(env, slug, title, campaign) {
  const existing = await sbGet(env, `tracked_links?slug=eq.${encodeURIComponent(slug)}&select=id,slug,is_active`);
  if (existing.length) return { id: existing[0].id, slug, created: false, active: existing[0].is_active };
  const r = await fetch(`${env.SF_SUPABASE_URL}/rest/v1/tracked_links`, {
    method: 'POST',
    headers: { ...sbHeaders(env), 'Content-Type': 'application/json', Prefer: 'return=representation' },
    body: JSON.stringify({
      // mismo shape que el admin API del producto (youtube-descriptions/route.ts)
      slug, title, destination_url: 'https://saasfactory.so/about', source: 'youtube', campaign,
    }),
  });
  if (!r.ok) throw new Error(`insert tracked_links → ${r.status}: ${(await r.text()).slice(0, 300)}`);
  const rows = await r.json();
  return { id: rows[0].id, slug, created: true, active: true };
}

// verificación EN VIVO del redirect limpio + cookies de atribución (curl real = la evidencia).
// OJO: el apex saasfactory.so → www es un 308 de Vercel SIN cookies; el route /go/ vive en www,
// así que se verifica contra www directo (el CTA público sigue siendo saasfactory.so/go/<slug>).
function verifyGoLink(slug) {
  const url = `https://www.saasfactory.so/go/${slug}`;
  const r = spawnSync('curl', ['-sI', '-o', '/dev/null', '-w', '%{http_code} %{redirect_url}', url], { encoding: 'utf8', timeout: 20000 });
  const head = spawnSync('curl', ['-sI', url], { encoding: 'utf8', timeout: 20000 });
  const status = parseInt((r.stdout || '').split(' ')[0], 10);
  const cookies = (head.stdout || '').split('\n').filter((l) => /^set-cookie:/i.test(l)).map((l) => l.trim());
  const hasAttribution = cookies.some((c) => /link_source/.test(c)) && cookies.some((c) => /utm_params/.test(c));
  return { url, status, redirect: (r.stdout || '').split(' ').slice(1).join(' ').trim(), cookies, hasAttribution, raw: (head.stdout || '').trim() };
}

// ---------- transcript ----------
async function findTranscript(dir) {
  if (flags.transcript) return path.resolve(flags.transcript);
  for (const sub of ['edit/transcripts', 'transcripts', 'edit', '.']) {
    try {
      const d = path.join(dir, sub);
      const files = (await fsp.readdir(d)).filter((f) => f.endsWith('.json'));
      for (const f of files) {
        const txt = await fsp.readFile(path.join(d, f), 'utf8');
        try {
          const j = JSON.parse(txt);
          if (Array.isArray(j.words) || Array.isArray(j.segments)) return path.join(d, f);
        } catch { /* no es transcript */ }
      }
    } catch { /* dir no existe */ }
  }
  throw new Error(`no encontré transcript word-level en ${dir} (edit/transcripts/*.json). ` +
    'Genera uno con MLX Whisper (~/.whisper-mlx-venv) o pásalo con --transcript.');
}

async function getPub() {
  let pub = await loadPublish(projectDir);
  if (!pub) {
    const slug = flags.slug || (flags.youtubeUrl ? slugFromYoutubeId(ytId(flags.youtubeUrl)) : slugFromProjectName(path.basename(projectDir)));
    pub = newPublish(slug);
  }
  if (flags.slug) pub.video.slug = flags.slug;
  return pub;
}
function ytId(url) {
  const m = /(?:v=|youtu\.be\/|shorts\/|embed\/)([a-zA-Z0-9_-]{11})/.exec(url || '');
  if (!m) throw new Error(`URL de YouTube inválida: ${url}`);
  return m[1];
}

// SYSTEM_PROMPT del producto, VERBATIM (fuente: saas-factory-community/src/app/api/admin/
// youtube-descriptions/route.ts — la Description Machine). NO editar aquí: si el producto
// cambia su prompt, copiarlo de nuevo citando la fuente.
const SYSTEM_PROMPT = `Eres un experto en YouTube SEO para el canal de Daniel Carreon (@danielcarreonai).
El canal es sobre construir software con IA, SaaS, y emprendimiento tech.
La comunidad se llama SaaS Factory (saasfactory.so).

REGLAS ESTRICTAS:
- Responde SOLO en formato JSON valido, sin markdown ni backticks
- Descripcion en espanol
- Titulos en espanol
- Timestamps en formato MM:SS o HH:MM:SS
- TIMESTAMPS DENSOS: Maximo 5-7 timestamps por video. Cada timestamp debe cubrir un bloque grande de contenido (3-5 minutos minimo). Piensa en capitulos, no en cada frase. Agrupa temas relacionados bajo un solo timestamp con un titulo que genere curiosidad. NO pongas timestamps cada 30 segundos o cada minuto.
- Maximo 5000 caracteres en la descripcion
- Cada titulo maximo 60 caracteres
- Usa emojis con moderacion (1-2 por seccion)
- El CTA siempre usa el tracked link proporcionado
- Si el transcript tiene timestamps, usalos. Si no, genera timestamps aproximados basados en el flujo del contenido.
- thumbnail_suggestion: 1-2 oraciones describiendo una miniatura llamativa (texto grande, expresion, colores)

FORMATO JSON DE RESPUESTA:
{
  "description": "La descripcion completa lista para copiar a YouTube",
  "titles": ["Titulo 1", "Titulo 2", "Titulo 3"],
  "keywords": ["keyword1", "keyword2", "keyword3"],
  "summary": "Resumen de 1 linea del video",
  "thumbnail_suggestion": "Descripcion de miniatura sugerida"
}

ESTRUCTURA DE LA DESCRIPCION:
1. CTA a SaaS Factory con el tracked link (PRIMERO, una linea)
2. Linea vacia
3. Gancho (2 lineas que enganchen, con keyword principal)
4. Linea vacia
5. TIMESTAMPS con emoji de reloj
6. Linea vacia
7. RECURSOS MENCIONADOS (si aplica)
8. Linea vacia
9. Hashtags (5-8 relevantes)`;

async function generateMetadata(env, transcriptText, trackedLinkUrl, videoTitle) {
  const userPrompt = `Transcript del video:
${transcriptText.substring(0, 30000)}

Tracked Link URL para el CTA: ${trackedLinkUrl}
${videoTitle ? `Titulo actual del video: ${videoTitle}` : ''}

Genera la descripcion optimizada, 3 titulos, keywords y summary.`;

  const r = await fetch('https://openrouter.ai/api/v1/chat/completions', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${env.OPENROUTER_API_KEY}`,
      'Content-Type': 'application/json',
      'HTTP-Referer': 'https://saasfactory.so',
      'X-Title': 'SFPublish',
    },
    body: JSON.stringify({
      model: 'google/gemini-3.1-flash-lite-preview', // mismo modelo que la Description Machine del producto
      messages: [
        { role: 'system', content: SYSTEM_PROMPT },
        { role: 'user', content: userPrompt },
      ],
      max_tokens: 4000,
      temperature: 0.7,
    }),
  });
  if (!r.ok) throw new Error(`OpenRouter → ${r.status}: ${(await r.text()).slice(0, 300)}`);
  const data = await r.json();
  const raw = data.choices?.[0]?.message?.content || '';
  const clean = raw.replace(/```json\n?/g, '').replace(/```\n?/g, '').trim();
  try {
    return JSON.parse(clean);
  } catch {
    throw new Error(`la respuesta del modelo no es JSON válido: ${raw.slice(0, 300)}`);
  }
}

// ---------- etapas ----------
const out = (s) => process.stdout.write(s + '\n');

async function run() {
  if (cmd === 'connect') {
    const { connectRitual } = await import('../lib/upload-youtube.js');
    await connectRitual();
    return;
  }

  const st = await fsp.stat(projectDir).catch(() => null);
  if (!st?.isDirectory()) throw new Error(`el proyecto no existe: ${projectDir}`);
  const pub = await getPub();

  switch (cmd) {
    case 'init': {
      await savePublish(projectDir, pub);
      out(`publish.json creado en ${projectDir} (slug: ${pub.video.slug})`);
      out(`etapas: ${STAGES.join(' → ')}`);
      break;
    }

    case 'metadata': {
      const env = await loadEnv();
      setStage(pub, 'metadata', 'running', 'generando con el system prompt del producto…');
      await savePublish(projectDir, pub);

      const tPath = await findTranscript(projectDir);
      const tr = parseTranscript(await fsp.readFile(tPath, 'utf8'));
      out(`transcript: ${tPath} (${tr.words.length} palabras, ${Math.round(tr.duration / 60)} min)`);

      // 1) tracked link idempotente PRIMERO (el CTA de la descripción usa el link real)
      const slug = pub.video.slug;
      const campaign = flags.youtubeUrl ? ytId(flags.youtubeUrl) : path.basename(projectDir);
      const linkTitle = `YT: ${(pub.video.titulo || path.basename(projectDir)).substring(0, 80)}`;
      const link = await ensureTrackedLink(env, slug, linkTitle, campaign);
      const trackedLinkUrl = `https://saasfactory.so/go/${slug}`;
      out(`tracked link: ${trackedLinkUrl} (${link.created ? 'CREADO' : 'ya existía — reusado'})`);

      // 2) metadata con IA (SYSTEM_PROMPT verbatim del producto)
      const md = await generateMetadata(env, tr.text, trackedLinkUrl, pub.video.titulo || null);
      pub.data.metadata = md;
      if (!pub.video.titulo && md.titles?.[0]) pub.video.titulo = md.titles[0];
      setStage(pub, 'metadata', 'done',
        `descripción ${md.description?.length || 0} chars · ${md.titles?.length || 0} títulos · ${md.keywords?.length || 0} keywords`);

      // 3) verificación EN VIVO del /go/ (redirect + Set-Cookie de atribución)
      const v = verifyGoLink(slug);
      const linkOk = v.status >= 300 && v.status < 400 && v.hasAttribution;
      setStage(pub, 'link', linkOk ? 'done' : 'error',
        linkOk ? `${trackedLinkUrl} ✓ ${v.status} → ${v.redirect} · cookies: link_source+utm_params`
          : `${trackedLinkUrl} → ${v.status} (¿cookie de atribución? ${v.hasAttribution})`);
      pub.data.link = { url: trackedLinkUrl, verified: linkOk, status: v.status, redirect: v.redirect, cookies: v.cookies };
      await savePublish(projectDir, pub);

      out('\n=== TÍTULOS ===');
      (md.titles || []).forEach((t, i) => out(`  ${i + 1}. ${t} (${t.length} chars)`));
      out('\n=== DESCRIPCIÓN ===\n' + md.description);
      out('\n=== KEYWORDS ===\n' + (md.keywords || []).join(', '));
      out('\n=== CURL -I DEL LINK ===\n' + v.raw.split('\n').slice(0, 12).join('\n'));
      if (!linkOk) process.exit(1);
      break;
    }

    case 'link': {
      // (re)verifica el /go/ sin re-generar metadata (idempotente y barato)
      const env = await loadEnv();
      const slug = pub.video.slug;
      const campaign = flags.youtubeUrl ? ytId(flags.youtubeUrl) : path.basename(projectDir);
      const link = await ensureTrackedLink(env, slug, `YT: ${(pub.video.titulo || path.basename(projectDir)).substring(0, 80)}`, campaign);
      const trackedLinkUrl = `https://saasfactory.so/go/${slug}`;
      const v = verifyGoLink(slug);
      const linkOk = v.status >= 300 && v.status < 400 && v.hasAttribution;
      setStage(pub, 'link', linkOk ? 'done' : 'error',
        linkOk ? `${trackedLinkUrl} ✓ ${v.status} → ${v.redirect} · cookies: link_source+utm_params`
          : `${trackedLinkUrl} → ${v.status} (¿cookie de atribución? ${v.hasAttribution})`);
      pub.data.link = { url: trackedLinkUrl, verified: linkOk, status: v.status, redirect: v.redirect, cookies: v.cookies };
      await savePublish(projectDir, pub);
      out(`tracked link: ${trackedLinkUrl} (${link.created ? 'CREADO' : 'ya existía — reusado'})`);
      out(v.raw);
      out(linkOk ? '\n✓ redirect limpio + cookies de atribución vivos' : '\n✗ el link no está sirviendo la atribución');
      if (!linkOk) process.exit(1);
      break;
    }

    case 'mentions': {
      const env = await loadEnv();
      setStage(pub, 'mentions', 'running', 'buscando menciones en el transcript…');
      await savePublish(projectDir, pub);
      const tPath = await findTranscript(projectDir);
      const tr = parseTranscript(await fsp.readFile(tPath, 'utf8'));
      const videos = await sbGet(env, 'youtube_videos?select=video_id,title&order=published_at.desc&limit=200');
      const own = flags.youtubeUrl ? ytId(flags.youtubeUrl) : null;
      const found = findMentions(tr.words, videos.filter((v) => v.video_id !== own));
      pub.data.mentions = found;
      // candidato a pantalla final: la última mención; si no hay, el video más reciente del canal
      pub.data.endScreen = found.length
        ? { video_id: found[found.length - 1].video_id, titulo: found[found.length - 1].titulo, motivo: 'última mención del video' }
        : videos[0] ? { video_id: videos[0].video_id, titulo: videos[0].title, motivo: 'video más reciente (sin menciones detectadas)' } : null;
      setStage(pub, 'mentions', 'done',
        found.length ? `${found.length} mención(es) → plan de tarjetas listo` : '0 menciones (umbral conservador: 0 falsos positivos > cobertura)');
      await savePublish(projectDir, pub);
      if (found.length) {
        out('t\tvideo_id\ttítulo\tfrase detectada');
        for (const m of found) out(`${m.t}s\t${m.video_id}\t${m.titulo}\t"${m.frase_detectada}"`);
      } else {
        out(`0 menciones contra ${videos.length} títulos del canal (umbral: racha ≥4 tokens, ≥3 contenido, ≥2 distintivos).`);
      }
      if (pub.data.endScreen) out(`end screen sugerida: ${pub.data.endScreen.titulo} (${pub.data.endScreen.motivo})`);
      break;
    }

    case 'checklist': {
      let defaults = {};
      try { defaults = JSON.parse(await fsp.readFile(path.join(ROOT, 'channel-defaults.json'), 'utf8')); } catch { /* gate lo reporta */ }
      const { checks, pass } = checklistGate(pub, defaults);
      for (const c of checks) out(`${c.ok ? '✓' : c.level === 'WARN' ? '⚠' : '✗'} [${c.level}] ${c.id}: ${c.detail}`);
      setStage(pub, 'checklist', pass ? 'done' : 'error',
        `${checks.filter((c) => c.ok).length}/${checks.length} checks · ${pass ? 'GATE ABIERTO' : 'GATE CERRADO (falla dura)'}`);
      await savePublish(projectDir, pub);
      out(pass ? '\nGATE ABIERTO: listo para upload.' : '\nGATE CERRADO: corrige lo duro antes de subir.');
      if (!pass) process.exit(1);
      break;
    }

    case 'schedule': {
      const s = nextSlots(new Date());
      pub.data.schedule = s;
      setStage(pub, 'schedule', 'done', `sugerido: ${s.preferred?.local}${s.preferred?.lunes ? ' (LUNES, día más activo)' : ''}`);
      await savePublish(projectDir, pub);
      out('slots sugeridos (peak hours 11AM/4PM/9PM MX, lunes más activo):');
      for (const c of s.candidates) out(`  ${c.lunes ? '★' : '·'} ${c.local}`);
      break;
    }

    case 'post': {
      const text = communityPost(pub);
      pub.data.post = text;
      setStage(pub, 'post', 'done', `anuncio listo (${text.length} chars) — SOLO texto, publícalo tú en la comunidad`);
      await savePublish(projectDir, pub);
      out('=== POST DE COMUNIDAD (texto, NUNCA insert en BD) ===\n');
      out(text);
      break;
    }

    case 'upload': {
      const { uploadFlow } = await import('../lib/upload-youtube.js');
      await uploadFlow(projectDir, pub, { test: flags.test, root: ROOT, file: flags.file || null });
      break;
    }

    case 'status': {
      out(`proyecto: ${projectDir}`);
      out(`video: ${pub.video.slug}${pub.video.titulo ? ` · "${pub.video.titulo}"` : ''}`);
      for (const s of STAGES) {
        const st2 = pub.stages[s] || { status: 'pending' };
        const icon = { done: '✓', running: '…', error: '✗', partial: '◐', pending: '·' }[st2.status] || '·';
        out(`  ${icon} ${s.padEnd(10)} ${st2.status.padEnd(8)} ${st2.evidence || ''}`);
      }
      break;
    }

    default:
      usage();
  }
}

run().catch((e) => {
  process.stderr.write(`sfpublish ERROR: ${e.message}\n`);
  process.exit(1);
});
