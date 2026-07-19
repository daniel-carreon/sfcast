// SFPublish — lógica pura de la etapa 2 (máster aprobado → publicado).
// Todo lo testeable vive aquí sin red ni disco: el CLI (bin/sfpublish.js) orquesta.
import { promises as fsp } from 'node:fs';
import path from 'node:path';

// Orden canónico del pipeline post-edición. El panel ⌘Y pinta estas etapas en este orden.
export const STAGES = ['metadata', 'link', 'mentions', 'thumbnail', 'checklist', 'schedule', 'post', 'upload', 'published'];

export const STAGE_COMMANDS = {
  metadata: 'node bin/sfpublish.js <proyecto> metadata',
  link: 'node bin/sfpublish.js <proyecto> metadata', // el link se crea+verifica dentro de metadata
  mentions: 'node bin/sfpublish.js <proyecto> mentions',
  thumbnail: 'conversacional: pídele la miniatura a Levy (skill youtube-thumbnails)',
  checklist: 'node bin/sfpublish.js <proyecto> checklist',
  schedule: 'node bin/sfpublish.js <proyecto> schedule',
  post: 'node bin/sfpublish.js <proyecto> post',
  upload: 'node bin/sfpublish.js <proyecto> upload',
  published: 'node bin/sfpublish.js <proyecto> upload (visibilidad la decide Daniel conversando)',
};

// ---------- publish.json ----------
export function newPublish(slug, titulo = '') {
  const stages = {};
  for (const s of STAGES) stages[s] = { status: 'pending', evidence: '', updated_at: null };
  return { video: { slug, titulo }, stages, log: [], data: {} };
}

export function setStage(pub, stage, status, evidence = '') {
  if (!pub.stages[stage]) pub.stages[stage] = { status: 'pending', evidence: '', updated_at: null };
  const ts = new Date().toISOString();
  pub.stages[stage].status = status;
  pub.stages[stage].evidence = evidence;
  pub.stages[stage].updated_at = ts;
  pub.log.push({ ts, stage, status, msg: evidence });
  return pub;
}

export function publishPath(projectDir) {
  return path.join(projectDir, 'publish.json');
}

export async function loadPublish(projectDir) {
  try {
    return JSON.parse(await fsp.readFile(publishPath(projectDir), 'utf8'));
  } catch {
    return null;
  }
}

export async function savePublish(projectDir, pub) {
  // atómico (tmp + rename): el panel ⌘Y pollea cada 2s y no debe leer un JSON a medias
  const p = publishPath(projectDir);
  await fsp.writeFile(p + '.tmp', JSON.stringify(pub, null, 1));
  await fsp.rename(p + '.tmp', p);
}

// ---------- slugs (misma regla que el admin API del producto: constraint slug_format [a-z0-9-]) ----------
export function slugFromYoutubeId(ytid) {
  return `vid-${ytid.toLowerCase().replace(/_/g, '-')}`;
}

export function slugFromProjectName(name) {
  const clean = name.toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '')
    .replace(/[^a-z0-9-]+/g, '-').replace(/-+/g, '-').replace(/^-|-$/g, '')
    .replace(/^video-/, '');
  return clean.startsWith('vid-') ? clean : `vid-${clean}`;
}

// ---------- transcript (formato word-level tipo ElevenLabs/Whisper: {words:[{type,text,start,end}]}) ----------
export function parseTranscript(json) {
  const raw = typeof json === 'string' ? JSON.parse(json) : json;
  let words = [];
  if (Array.isArray(raw.words)) {
    words = raw.words
      .filter((w) => (w.type === 'word' || w.type === undefined) && w.text && w.text.trim())
      .map((w) => ({ text: w.text.trim(), start: +w.start || 0, end: +w.end || 0 }));
  } else if (Array.isArray(raw.segments)) {
    // formato whisper por segmentos → aproximar palabra a palabra dentro del segmento
    for (const seg of raw.segments) {
      const toks = String(seg.text || '').trim().split(/\s+/).filter(Boolean);
      const dur = (seg.end - seg.start) / Math.max(1, toks.length);
      toks.forEach((t, i) => words.push({ text: t, start: seg.start + i * dur, end: seg.start + (i + 1) * dur }));
    }
  }
  const text = words.map((w) => w.text).join(' ');
  const duration = words.length ? words[words.length - 1].end : 0;
  return { words, text, duration };
}

// ---------- normalización ----------
export function norm(s) {
  return String(s).toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '')
    .replace(/[^a-z0-9ñ\s]/g, ' ').replace(/\s+/g, ' ').trim();
}

const STOPWORDS = new Set(('de la el en y a los las un una que es con para por se su al lo como mas pero sus le ya o ' +
  'este si porque esta entre cuando muy sin sobre tambien me hasta hay donde quien desde todo nos durante todos uno ' +
  'les ni contra otros ese eso ante ellos e esto mi antes algunos unos yo otro otras otra tanto esa estos mucho ' +
  'quienes nada muchos cual poco ella estar estas algunas algo nosotros tu te ti ustedes del ha he va voy vas han ' +
  'ser son era fue solo asi mas menos cada vez aqui ahi alla ahora').split(' '));

// palabras-contenido tan omnipresentes en ESTE canal que solas no identifican un video
const CHANNEL_COMMON = new Set(['claude', 'code', 'ia', 'ai', 'agente', 'agentes', 'video', 'videos', 'saas',
  'factory', 'gpt', 'chatgpt', 'cursor', 'negocio', 'automatizar', 'gratis', 'curso', 'modelo', 'modelos',
  'openai', 'anthropic', 'gemini', 'deepseek', 'software', 'nuevo', 'nueva', 'mejor', 'experto', 'minutos', 'tutorial']);

export function isContent(tok) {
  return !STOPWORDS.has(tok) && (tok.length >= 2 || /^\d+$/.test(tok));
}

export function isDistinctive(tok) {
  return isContent(tok) && !CHANNEL_COMMON.has(tok);
}

// ---------- menciones: transcript ↔ títulos de youtube_videos ----------
// Filosofía: 0 falsos positivos > cobertura. Solo matchea una RACHA CONSECUTIVA de tokens del
// título dicha textual en el transcript: ≥4 tokens seguidos con ≥3 de contenido y ≥2 distintivos
// (o el título completo si es corto). "claude code" suelto JAMÁS matchea.
export function findMentions(transcriptWords, videos, opts = {}) {
  const minRun = opts.minRun ?? 4;
  const minContent = opts.minContent ?? 3;
  const minDistinct = opts.minDistinct ?? 2;

  const tWords = [];
  for (const w of transcriptWords) {
    for (const tok of norm(w.text).split(' ')) {
      if (tok) tWords.push({ tok, start: w.start });
    }
  }
  const tToks = tWords.map((w) => w.tok);
  const tJoined = ' ' + tToks.join(' ') + ' ';

  const mentions = [];
  for (const v of videos) {
    const titleToks = norm(v.title).split(' ').filter(Boolean);
    if (!titleToks.length) continue;
    const fullOk = titleToks.length < minRun; // título muy corto: exigir el título COMPLETO
    let best = null;

    const runs = [];
    if (fullOk) {
      if (titleToks.filter(isContent).length >= 2) runs.push(titleToks);
    } else {
      // todas las ventanas contiguas del título, de la más larga a la más corta:
      // la primera que matchee gana (= la racha más larga dicha textual)
      for (let len = titleToks.length; len >= minRun; len--) {
        for (let i = 0; i + len <= titleToks.length; i++) {
          const run = titleToks.slice(i, i + len);
          if (run.filter(isContent).length >= minContent && run.filter(isDistinctive).length >= minDistinct) {
            runs.push(run);
          }
        }
      }
    }

    for (const run of runs) {
      const needle = ' ' + run.join(' ') + ' ';
      const at = tJoined.indexOf(needle);
      if (at === -1) continue;
      // posición → índice de token (contando espacios previos)
      const tokIdx = tJoined.slice(0, at + 1).split(' ').filter(Boolean).length;
      const t = tWords[Math.min(tokIdx, tWords.length - 1)]?.start ?? 0;
      if (!best || run.length > best.run.length) best = { run, t };
      break; // la racha más larga que matchea gana (iteramos de larga a corta)
    }

    if (best) {
      mentions.push({
        t: Math.round(best.t * 10) / 10,
        video_id: v.video_id,
        titulo: v.title,
        frase_detectada: best.run.join(' '),
      });
    }
  }
  return mentions.sort((a, b) => a.t - b.t);
}

// ---------- checklist gate ----------
export function checklistGate(pub, defaults = {}) {
  const md = pub.data?.metadata || {};
  const desc = md.description || '';
  const titulo = pub.video?.titulo || md.titles?.[0] || '';
  const firstTwoLines = desc.split('\n').slice(0, 2).join('\n');
  const chapterLines = desc.split('\n').filter((l) => /(^|\s)\d{1,2}:\d{2}(:\d{2})?(\s|$)/.test(l));
  const esHits = (norm(desc).match(/\b(que|para|los|las|con|este|esta|como|del|una|más|mas|aprende|video)\b/g) || []).length;

  const checks = [
    { id: 'titulo', level: 'HARD', ok: !!titulo && titulo.length <= 60, detail: titulo ? `"${titulo}" (${titulo.length}/60 chars)` : 'sin título elegido' },
    { id: 'descripcion_go', level: 'HARD', ok: /\/go\//.test(firstTwoLines), detail: /\/go\//.test(firstTwoLines) ? 'link /go/ en las primeras 2 líneas' : 'el /go/ NO está en las primeras 2 líneas' },
    { id: 'keywords', level: 'HARD', ok: (md.keywords || []).length >= 5, detail: `${(md.keywords || []).length} keywords (mínimo 5)` },
    { id: 'capitulos', level: 'HARD', ok: chapterLines.length >= 2, detail: `${chapterLines.length} líneas con timestamp (mínimo 2)` },
    { id: 'idioma_es', level: 'HARD', ok: esHits >= 5, detail: `heurística español: ${esHits} señales (mínimo 5)` },
    { id: 'no_kids', level: 'HARD', ok: defaults.madeForKids === false, detail: defaults.madeForKids === false ? 'made-for-kids = NO (channel-defaults.json)' : 'channel-defaults.json sin madeForKids:false' },
    { id: 'thumbnail', level: 'WARN', ok: pub.stages?.thumbnail?.status === 'done', detail: pub.stages?.thumbnail?.status === 'done' ? 'miniatura marcada' : 'miniatura pendiente (WARN, no bloquea)' },
    { id: 'descripcion_len', level: 'HARD', ok: desc.length > 0 && desc.length <= 5000, detail: `descripción ${desc.length}/5000 chars` },
  ];
  const pass = checks.every((c) => c.ok || c.level === 'WARN');
  return { checks, pass };
}

// ---------- schedule: peak hours reales del canal (11AM, 4-5PM, 9PM MX; lunes más activo) ----------
export function nextSlots(now, count = 3) {
  const PEAKS = [11, 16, 21];
  const out = [];
  const d = new Date(now);
  // ventana COMPLETA de 8 días (cortar antes dejaba fuera al lunes si hoy es mié/jue — bug cazado por test)
  for (let day = 0; day < 8; day++) {
    for (const h of PEAKS) {
      const slot = new Date(d.getFullYear(), d.getMonth(), d.getDate() + day, h, 0, 0);
      if (slot.getTime() > now.getTime() + 30 * 60 * 1000) {
        out.push({ iso: slot.toISOString(), local: slot.toString().slice(0, 21), lunes: slot.getDay() === 1 });
      }
    }
  }
  // lunes primero si hay uno en la ventana; luego por cercanía
  out.sort((a, b) => (b.lunes - a.lunes) || (new Date(a.iso) - new Date(b.iso)));
  const preferred = out[0];
  const soonest = out.slice().sort((a, b) => new Date(a.iso) - new Date(b.iso))[0];
  return { preferred, soonest, candidates: out.slice(0, count) };
}

// ---------- post de comunidad (SOLO texto — regla dura feedback/youtube-posts.md) ----------
export function communityPost(pub) {
  const md = pub.data?.metadata || {};
  const titulo = pub.video?.titulo || md.titles?.[0] || 'nuevo video';
  const resumen = md.summary || '';
  return [
    `🎬 Video nuevo: ${titulo}`,
    '',
    resumen,
    '',
    'Ya está arriba en el canal. Si construyes con IA, este te toca directo.',
    '👉 Véanlo y me dicen en los comentarios qué parte les voló la cabeza.',
  ].join('\n');
}
