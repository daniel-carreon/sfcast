#!/usr/bin/env node
// sfpublish <proyecto-dir> <etapa> — la SEGUNDA ETAPA de la línea: del máster aprobado al publicado.
// AI-first: estos comandos los corre el AGENTE (Levy); el panel ⌘Y de la sala solo REFLEJA publish.json.
//
// Etapas: init | metadata | mentions | checklist | schedule | post | launch | watch | upload | connect | status
// Reglas duras: la BD del negocio es SOLO lectura salvo (a) insert idempotente en tracked_links y
// (b) `watch`, que INSERTA el anuncio ya publicado cuando el video se hizo público, el post estaba
// APROBADO en la galería y pasaron los minutos pactados · upload jamás publica público.
// El borrador del post NO vive en la BD: vive en publish.json y se aprueba en la galería (⌘⌥G).
import path from 'node:path';
import os from 'node:os';
import { promises as fsp } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import {
  STAGES, newPublish, setStage, loadPublish, savePublish,
  slugFromYoutubeId, slugFromProjectName, trackedUrl, parseTranscript, findMentions,
  checklistGate, nextSlots, communityPost, applyEdl,
} from '../lib/publish.js';
import { listThumbs, extractPostBody, resolveThumb, computeTranscriptFor } from '../lib/gallery.js';

const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');

function usage(code = 1) {
  process.stderr.write(`uso: sfpublish <proyecto-dir> <etapa> [opciones]
etapas:
  init        crea publish.json (esqueleto de etapas)
  metadata    descripción/títulos/keywords + link corto verificado (saasfactory.so/<slug>).
              DEFAULT del flujo: el AGENTE la escribe leyendo el transcript y la entrega con
              --from <json> ({description,titles,keywords,summary}). Sin --from usa la
              Description Machine del producto (Gemini via OpenRouter) — camino automático/cron.
  thumbs      escanea <proyecto>/thumbs/*.png|jpg (candidatas A/B) y marca la etapa
  mentions    transcript ↔ youtube_videos → plan de tarjetas + end screen
  checklist   gate de publicación (exit≠0 si falla algo duro)
  schedule    sugiere slot según peak hours del canal
  post        anuncio de comunidad. Sin flags: solo texto.
              --draft [--body <post.md>] → arma el borrador EN EL PROYECTO (publish.json).
              Se ve, se edita y se APRUEBA en la galeria de SFStudio (⌘⌥G). La BD del
              producto no se toca hasta publicar.
  launch      INTERVENCION 2: sube miniatura (la portada elegida en la galeria) + fija
              metadata + PROGRAMA el video (Data API v3). --at "YYYY-MM-DD HH:MM" (hora MX)
  watch       lazo de cierre: si el video YA es publico, pasaron N min y el post esta
              APROBADO, lo publica en la comunidad (INSERT). Sensor = estado real en
              YouTube, no un temporizador ciego. Idempotente. --dry-run para ensayar
  upload      subida agéntica a YouTube Studio (perfil persistente; draft PRIVADO)
  connect     abre el navegador del perfil para loguear Google (ritual de 1 vez)
  status      imprime el estado de publish.json
opciones:
  --youtube-url <url>   URL de YouTube ya existente (el slug = los ULTIMOS 6 de su id)
  --slug <slug>         fuerza el slug del tracked link
  --transcript <path>   transcript word-level JSON (default: autodetecta edit/transcripts/*.json)
  --from <path>         (metadata) JSON escrito por el agente — se salta la generación con Gemini
  --title <string>      (metadata) fija el título ELEGIDO (la decisión de Daniel, dictada al agente)
  --draft               (post) arma el borrador en publish.json (se aprueba en la galeria)
  --body <path.md>      (post --draft) archivo del cuerpo (default: el post-comunidad*.md mas nuevo)
  --at <fecha>          (launch) "2026-07-27 11:00" hora MX, o ISO con offset
  --thumb <path>        (launch) miniatura a subir (default: la 1a de thumbs/)
  --post-delay <min>    (launch) minutos tras publicarse el video para el post (default 5)
  --dry-run             (watch) ensaya la publicacion sin escribir nada en la comunidad
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
  else if (a === '--from') flags.from = argv[++i];
  else if (a === '--title') flags.title = argv[++i];
  else if (a === '--file') flags.file = argv[++i];
  else if (a === '--test') flags.test = true;
  else if (a === '--dry-run') flags.dryRun = true;
  else if (a === '--draft') flags.draft = true;
  else if (a === '--body') flags.body = argv[++i];
  else if (a === '--at') flags.at = argv[++i];
  else if (a === '--thumb') flags.thumb = argv[++i];
  else if (a === '--post-delay') flags.postDelay = argv[++i];
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
// OJO: el apex saasfactory.so → www es un 308 de Vercel SIN cookies; el resolver vive en www,
// así que se verifica contra www directo (el CTA público sigue siendo saasfactory.so/<slug>).
function verifyGoLink(slug) {
  const url = `https://www.saasfactory.so/${slug}`;
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

// transcript del proyecto, remapeado al CORTE FINAL si hay EDL (los tiempos del raw mienten
// contra el video publicado: capítulos y menciones deben vivir en tiempo final)
async function loadTranscriptCut(dir) {
  const tPath = await findTranscript(dir);
  let tr = parseTranscript(await fsp.readFile(tPath, 'utf8'));
  let cut = 'raw';
  for (const edlName of ['edl_breathed.json', 'edl.json']) {
    try {
      const edl = JSON.parse(await fsp.readFile(path.join(dir, 'edit', edlName), 'utf8'));
      if (Array.isArray(edl.ranges) && edl.ranges.length) {
        const mapped = applyEdl(tr.words, edl.ranges);
        tr = { words: mapped.words, duration: mapped.duration, text: mapped.words.map((w) => w.text).join(' ') };
        cut = 'final';
        break;
      }
    } catch { /* sin edl */ }
  }
  return { ...tr, path: tPath, cut };
}

/**
 * Transcript TOLERANTE para las etapas que solo necesitan LEER el texto (metadata).
 * `loadTranscriptCut` exige word-level JSON porque `mentions` necesita timestamps por palabra;
 * pero un proyecto puede traer solo el TRANSCRIPT-*.txt con timestamps que deja la imprenta, y
 * ahí morir con "no encontré transcript" es falso: el texto SÍ está. Cae a ese .txt, y solo si
 * tampoco hay nada devuelve null (el llamador decide si eso es fatal).
 */
async function loadTranscriptLoose(dir) {
  try { return await loadTranscriptCut(dir); } catch { /* sin word-level: seguimos buscando */ }
  const tr = await computeTranscriptFor([dir]);
  if (!tr.found) return null;
  return {
    words: [], text: tr.segments.map((s) => s.text).join(' '),
    duration: tr.duration, path: tr.file, cut: `texto (${tr.file})`,
  };
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

/** El post-comunidad*.md más RECIENTE del proyecto (v2 le gana a v1). Misma regla que la galería. */
async function newestPostFile(dir) {
  let names = [];
  try { names = await fsp.readdir(dir); } catch { return null; }
  const cand = names.filter((f) => /^post-comunidad.*\.md$/i.test(f));
  if (!cand.length) return null;
  const st = await Promise.all(cand.map(async (f) => ({ f, m: (await fsp.stat(path.join(dir, f))).mtimeMs })));
  st.sort((a, b) => b.m - a.m || a.f.localeCompare(b.f));
  return path.join(dir, st[0].f);
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
      const slug = pub.video.slug;
      const trackedLinkUrl = trackedUrl(slug);

      // 0) si viene --from (el DEFAULT del flujo: la escribe el AGENTE), VALIDAR ANTES de
      //    cualquier efecto — un JSON malformado no debe dejar link creado ni etapa corrupta
      let md = null, autor;
      if (flags.from) {
        md = JSON.parse(await fsp.readFile(path.resolve(flags.from), 'utf8'));
        if (!md.description || !Array.isArray(md.titles) || !md.titles.length) {
          throw new Error(`--from ${flags.from}: se espera {description, titles[≥1], keywords[], summary}`);
        }
        if (!Array.isArray(md.keywords)) {
          throw new Error(`--from: keywords debe ser un ARRAY (llegó ${typeof md.keywords}) — ej. ["ia","saas"]`);
        }
        if (md.description.length > 5000) {
          throw new Error(`--from: descripción ${md.description.length} chars — YouTube corta en 5000`);
        }
        if (!md.description.includes(trackedLinkUrl)) {
          throw new Error(`--from: la descripción NO trae el tracked link ${trackedLinkUrl} — agrégalo al CTA`);
        }
        autor = 'escrita por el agente (transcript leído directo)';
      }
      setStage(pub, 'metadata', 'running', flags.from ? 'metadata del agente en validación…' : 'generando con el system prompt del producto…');
      await savePublish(projectDir, pub);

      const tr = await loadTranscriptLoose(projectDir);
      if (!tr && !md) {
        throw new Error(`no encontré transcript en ${projectDir} y no me diste --from: sin texto no hay metadata. ` +
          'Pásalo con --transcript, o escribe la metadata tú y entrégala con --from.');
      }
      if (tr) {
        const n = tr.words.length || tr.text.split(/\s+/).length;
        out(`transcript: ${tr.path} (${n} palabras, ${Math.round(tr.duration / 60)} min, corte ${tr.cut})`);
      } else {
        out('sin transcript en el proyecto — no importa: la metadata la escribiste tú (--from)');
      }

      // 1) tracked link idempotente (el CTA de la descripción usa el link real)
      const campaign = flags.youtubeUrl ? ytId(flags.youtubeUrl) : path.basename(projectDir);
      const linkTitle = `YT: ${(pub.video.titulo || path.basename(projectDir)).substring(0, 80)}`;
      const link = await ensureTrackedLink(env, slug, linkTitle, campaign);
      out(`tracked link: ${trackedLinkUrl} (${link.created ? 'CREADO' : 'ya existía — reusado'})`);

      // 2) sin --from: Description Machine del producto (Gemini) — camino automático/cron
      if (!md) {
        md = await generateMetadata(env, tr.text, trackedLinkUrl, pub.video.titulo || null);
        autor = 'Description Machine (Gemini, paridad producto)';
      }
      pub.data.metadata = md;
      // título elegido: JAMÁS pisar en silencio una elección previa (revisión adversarial 19 jul).
      // --title = decisión explícita (Daniel dicta conversando) · sin título previo = 1ª opción ·
      // título previo huérfano de la lista nueva = se CONSERVA con aviso.
      if (flags.title) pub.video.titulo = flags.title;
      else if (!pub.video.titulo) pub.video.titulo = md.titles[0];
      else if (!md.titles.includes(pub.video.titulo)) {
        out(`⚠ el título elegido "${pub.video.titulo}" no está en la lista nueva — se CONSERVA (usa --title para cambiarlo)`);
      }
      setStage(pub, 'metadata', 'done',
        `descripción ${md.description?.length || 0} chars · ${md.titles?.length || 0} títulos · ${(md.keywords || []).length} keywords · ${autor}`);

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
      const trackedLinkUrl = trackedUrl(slug);
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
      const tr = await loadTranscriptCut(projectDir);
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

    case 'thumbs': {
      // candidatas A/B: las genera el auto-chain de `edicion-de-video` (Etapa 7, 3+3).
      // Acepta thumbs/ Y thumbnails/: la skill escribe en thumbnails/ y sfpublish nació con
      // thumbs/. Mirar las dos evita el "sin candidatas aún" con la carpeta llena al lado.
      const { dir: sub, files } = await listThumbs(projectDir);
      const dir = path.join(projectDir, sub || 'thumbs');
      pub.data.thumbs = files;
      pub.data.thumbs_dir = path.basename(dir);
      setStage(pub, 'thumbnail', files.length ? 'done' : 'pending',
        files.length ? `${files.length} candidata(s) en ${path.basename(dir)}/ — A/B en YouTube (Test & compare admite 3)` : 'sin candidatas en thumbs/ ni thumbnails/ aún');
      await savePublish(projectDir, pub);
      out(files.length ? `✓ ${files.length} candidata(s) en ${path.basename(dir)}/: ${files.join(', ')}` : `sin candidatas: genera 2-3 en ${dir}`);
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
      // Sin --draft: comportamiento histórico (texto en pantalla, cero escritura).
      if (!flags.draft) {
        const text = communityPost(pub);
        pub.data.post = text;
        setStage(pub, 'post', 'done', `anuncio listo (${text.length} chars) — SOLO texto, publícalo tú en la comunidad`);
        await savePublish(projectDir, pub);
        out('=== POST DE COMUNIDAD (texto) ===\n');
        out(text);
        out('\n(usa --draft --body <post.md> para dejarlo como BORRADOR en la comunidad)');
        break;
      }

      // Con --draft: deja el post ARMADO en el PROYECTO (publish.json), no en la BD.
      // Daniel lo ve, edita y aprueba en la GALERÍA de SFStudio (⌘⌥G). La comunidad no se toca
      // hasta que `watch` lo publique — un borrador no tiene por qué existir en producción
      // (lección de las 1,702 notificaciones, 26 jul).
      const bodyPath = flags.body ||
        (await newestPostFile(projectDir)) || path.join(projectDir, 'post-comunidad.md');
      let raw;
      try { raw = await fsp.readFile(path.resolve(bodyPath), 'utf8'); }
      catch (e) { throw new Error(`no pude leer el cuerpo del post (${bodyPath}): ${e.message}`); }

      const videoUrl = flags.youtubeUrl || pub.video?.youtube_url ||
        (pub.video?.youtube_id ? `https://youtu.be/${pub.video.youtube_id}` : null) ||
        pub.data?.post_draft?.video_url || null;
      const body = extractPostBody(raw);
      const prev = pub.data.post_draft || {};
      pub.data.post_draft = {
        ...prev,
        title: flags.title || pub.video?.titulo || prev.title || null,
        body,
        source: path.basename(bodyPath),
        video_url: videoUrl,
        updated_at: new Date().toISOString(),
        // el texto cambió → la aprobación previa ya no aplica (nadie aprueba a ciegas)
        approved_at: prev.body === body ? (prev.approved_at || null) : null,
      };
      setStage(pub, 'post', 'done',
        `borrador ARMADO en el proyecto (${body.length} chars, de ${path.basename(bodyPath)}) — apruébalo en la galería (⌘⌥G)`);
      await savePublish(projectDir, pub);
      out(`✓ borrador armado en el proyecto (${body.length} chars, de ${path.basename(bodyPath)})`);
      out(`  título: ${pub.data.post_draft.title || '(se deriva de la 1a línea)'}`);
      out(`  video:  ${videoUrl || '⚠ sin URL todavía (se rellena en launch)'}`);
      out('  lo ves y lo apruebas en la GALERÍA: sfreview --gallery  (o ⌘⌥G desde la sala)');
      out('  la comunidad NO tiene nada todavía: se publica sola cuando el video se haga público.');
      break;
    }

    case 'launch': {
      // La INTERVENCIÓN 2 de Daniel: "te doy la fecha y lo programas para X día a Y hora;
      // 5 minutos después de la publicación mi post a la comunidad se sube".
      // Aquí se deja TODO armado: miniatura + metadata + programación en YouTube, y el post
      // queda ARMADO esperando que el video se vuelva público (lo dispara `watch`).
      const env = await loadEnv();
      const { getAccessToken, setThumbnail, scheduleVideo, verifyScheduled } = await import('../lib/youtube-api.js');

      // SIN --at = VESTIR sin programar: título, descripción, tags y miniatura quedan puestos y el
      // video sigue privado sin fecha. Programar es una acción hacia afuera y la fecha solo la da
      // Daniel; que falte no puede impedir dejar el video listo.
      const at = flags.at;
      // "2026-07-27 11:00" → ISO con offset de México; con offset explícito se respeta tal cual
      const iso = at
        ? (/[zZ]|[+-]\d{2}:?\d{2}$/.test(at) ? at : `${at.replace(' ', 'T')}:00-06:00`.replace(/:00:00-06:00$/, ':00-06:00'))
        : null;

      const videoUrl = flags.youtubeUrl || pub.video?.youtube_url ||
        (pub.video?.youtube_id ? `https://youtu.be/${pub.video.youtube_id}` : null) ||
        pub.data?.launch?.video_id && `https://youtu.be/${pub.data.launch.video_id}` ||
        pub.data?.post_draft?.video_url || null;
      if (!videoUrl) throw new Error('no hay video: pasa --youtube-url o corre upload antes');
      const videoId = ytId(videoUrl);

      const token = await getAccessToken(env);

      // 1) miniatura: --thumb, la PORTADA elegida en la galería, o la primera candidata.
      // `data.thumbnail.chosen` es el nombre de archivo que escribe la galería (⌘⌥G): se
      // resuelve contra thumbs/ y thumbnails/ — antes se asumía ruta y no encontraba nada.
      let thumbPath = flags.thumb ? path.resolve(flags.thumb) : null;
      const { dir: tsub, files: tfiles } = await listThumbs(projectDir);
      const chosen = pub.data?.thumbnail?.chosen;
      if (!thumbPath && chosen) {
        // mira thumbs/ Y thumbnails/: la portada pudo quedar en la carpeta que no es la de
        // las candidatas mostradas. Un nombre con `/` = ruta explícita (uso avanzado).
        thumbPath = chosen.includes('/') ? path.resolve(chosen) : await resolveThumb(projectDir, chosen);
        if (!thumbPath) out(`⚠ la portada elegida "${chosen}" ya no está en el proyecto`);
      }
      if (!thumbPath && tfiles.length) thumbPath = path.join(projectDir, tsub, tfiles[0]);
      if (thumbPath) {
        await setThumbnail(env, videoId, thumbPath, token);
        out(`✓ miniatura subida a YouTube: ${path.basename(thumbPath)}${chosen ? '' : ' (automática: no elegiste portada en la galería)'}`);
      } else {
        out('⚠ sin miniatura (no encontré candidatas en thumbs/ ni --thumb)');
      }

      // 2) metadata final + programación
      const md = pub.data?.metadata || {};
      const sched = await scheduleVideo(env, videoId, {
        publishAt: iso,
        title: flags.title || pub.video?.titulo || md.title || null,
        description: md.description || null,
        tags: md.keywords || null,
      }, token);

      // 3) verificar contra YouTube (evidencia, no fe)
      if (iso) {
        const v = await verifyScheduled(env, videoId, iso, token);
        if (!v.ok) throw new Error(`YouTube no confirmó la programación (publishAt=${v.publishAt})`);
      } else {
        const { getVideo } = await import('../lib/youtube-api.js');
        const v = await getVideo(env, videoId, token);
        if (v.snippet?.title !== sched.title) throw new Error(`YouTube no confirmó el título (quedó "${v.snippet?.title}")`);
        out(`✓ vestido y PRIVADO sin fecha: "${v.snippet.title}" · ${(v.snippet.description || '').length} chars de descripción · ${(v.snippet.tags || []).length} tags`);
        out('  falta SOLO tu hora:  sfpublish <proyecto> launch --at "2026-07-28 11:00"');
      }

      // el post ya sabe a qué video apunta (el [LINK_VIDEO] se rellena al publicarlo)
      if (pub.data.post_draft && !pub.data.post_draft.video_url) {
        pub.data.post_draft.video_url = `https://youtu.be/${videoId}`;
      }
      const pd = pub.data?.post_draft;
      pub.data.launch = {
        video_id: videoId,
        publish_at: sched.publishAt || null,
        title: sched.title,
        thumbnail: thumbPath ? path.basename(thumbPath) : null,
        post_delay_min: Number(flags.postDelay || 5),
        post_status: pd?.approved_at ? 'aprobado' : pd?.body ? 'sin-aprobar' : 'sin-draft',
      };
      setStage(pub, 'schedule', iso ? 'done' : 'running',
        iso ? `programado ${sched.publishAt} · miniatura ${thumbPath ? 'OK' : 'FALTA'}`
            : `vestido y privado SIN fecha · miniatura ${thumbPath ? 'OK' : 'FALTA'} · falta el --at de Daniel`);
      await savePublish(projectDir, pub);

      if (iso) {
        out(`✓ programado: ${sched.publishAt}`);
        out(`  título: ${sched.title}`);
        out(`  privacidad: ${sched.privacyStatus} (YouTube lo publica solo a esa hora)`);
      }
      out({
        aprobado: `  post de comunidad: APROBADO, sale ${pub.data.launch.post_delay_min} min después de que el video esté público`,
        'sin-aprobar': '  ⚠ el post está armado pero SIN APROBAR: apruébalo en la galería (⌘⌥G) o no sale',
        'sin-draft': '  ⚠ no hay post armado: corre `post --draft` y apruébalo en la galería (⌘⌥G)',
      }[pub.data.launch.post_status]);
      break;
    }

    case 'watch': {
      // El LAZO de cierre: sensor = estado real del video en YouTube (no un temporizador ciego).
      // Si YouTube se retrasa procesando, el post NO sale antes que el video.
      // El texto sale del PROYECTO (publish.json), no de un borrador en la BD del producto.
      const env = await loadEnv();
      const { getVideo } = await import('../lib/youtube-api.js');
      const L = pub.data?.launch;
      if (!L?.video_id) throw new Error('este proyecto no tiene launch: corre `launch --at ...` antes');
      if (pub.data?.post_published_at) { out(`ya publicado el ${pub.data.post_published_at}`); break; }
      const draft = pub.data?.post_draft;
      if (!draft?.body) throw new Error('no hay post armado: corre `post --draft` antes');
      // TRES condiciones, no dos: video público + tiempo cumplido + APROBADO por Daniel.
      // Un post sin aprobar es un texto que nadie firmó: no sale solo, por definición.
      if (!draft.approved_at) {
        out('· el post está armado pero SIN APROBAR (galería ⌘⌥G) — no publico nada');
        break;
      }

      const v = await getVideo(env, L.video_id);
      if (v.status.privacyStatus !== 'public') {
        out(`· video aún ${v.status.privacyStatus} (programado ${v.status.publishAt || '—'}) — no toco el post`);
        break;
      }
      const publicSince = new Date(v.snippet.publishedAt).getTime();
      const waitMs = (L.post_delay_min ?? 5) * 60_000;
      const faltan = publicSince + waitMs - Date.now();
      if (faltan > 0) { out(`· video público; faltan ${Math.ceil(faltan / 60000)} min para el post`); break; }

      const { publishCommunityPost, uploadThumbToMedia } = await import('../lib/community-draft.js');
      const videoUrl = draft.video_url || `https://youtu.be/${L.video_id}`;
      const trackedLink = pub.data?.link?.url ||
        (pub.video?.slug ? trackedUrl(pub.video.slug) : null);

      // la MISMA cara que el video: la portada elegida en la galería va al post (pedido de Daniel).
      // En dry-run NO se sube (subir al bucket ya es escribir; un ensayo no escribe nada).
      let mediaUrls = [];
      const { files: tfiles } = await listThumbs(projectDir);
      const cover = pub.data?.thumbnail?.chosen || L.thumbnail || tfiles[0];
      const coverPath = cover ? await resolveThumb(projectDir, cover) : null;
      // ...y detrás, lo que haya en post-media/ (por nombre): contar lo que construiste no es lo
      // mismo que MOSTRARLO. Convención simple: imagen que cae ahí, imagen que va al post.
      const extras = [];
      try {
        const dir = path.join(projectDir, 'post-media');
        for (const f of (await fsp.readdir(dir)).sort()) {
          if (/\.(png|jpe?g|webp|gif)$/i.test(f)) extras.push(path.join(dir, f));
        }
      } catch { /* sin post-media/: el post va solo con la portada */ }
      // ⚠️ la PORTADA no va en media_urls: el embed del video ya la pinta. Duplicarla se ve
      // como error. En media_urls van solo los frames del proceso (post-media/).
      if (!flags.dryRun) {
        for (const f of extras.filter(Boolean)) {
          try {
            mediaUrls.push(await uploadThumbToMedia(env, f, L.video_id));
          } catch (e) { out(`⚠ imagen no subida al post (${path.basename(f)}): ${e.message}`); }
        }
      } else {
        mediaUrls = extras;   // ensayo: solo para contarlas, no se sube nada
      }

      const post = await publishCommunityPost(env, {
        bodyMarkdown: draft.body,
        title: draft.title || pub.video?.titulo || null,
        videoUrl, trackedLink, mediaUrls,
        videoEmbedUrl: videoUrl,   // se reproduce dentro del post, no manda a YouTube
        dryRun: !!flags.dryRun,
      });
      if (flags.dryRun) {
        out(`(dry-run) NO se escribió nada. Saldría: "${post.title}" · ${post.chars} chars de HTML · ` +
            `miniatura ${mediaUrls.length ? 'sí' : 'no'} · video ${videoUrl}`);
        break;
      }

      if (post.alreadyPublished) {
        // otro watcher (o el cron de la otra máquina) ya lo publicó: se adopta su id y se sale.
        pub.data.post_published_at = post.publishedAt;
        pub.data.post_published_id = post.id;
        setStage(pub, 'post', 'done', `ya estaba publicado (${post.id}) — otro proceso ganó la carrera`);
        setStage(pub, 'published', 'done', `video público + post fuera (${post.id})`);
        await savePublish(projectDir, pub);
        out(`· el post YA estaba en la comunidad (${post.id}) — no publiqué un duplicado`);
        break;
      }

      pub.data.post_published_at = new Date().toISOString();
      pub.data.post_published_id = post.id;
      setStage(pub, 'post', 'done', `publicado en la comunidad ${pub.data.post_published_at}`);
      setStage(pub, 'published', 'done', `video público + post fuera (${post.id})`);
      await savePublish(projectDir, pub);
      out(`✓ post publicado en la comunidad (${post.id}) — la comunidad ya fue notificada`);
      out(`  ${post.url}`);
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
