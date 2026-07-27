// lib/gallery.js — el modelo de la GALERÍA DE LANZAMIENTOS.
//
// La Sala (`sfreview <proyecto>`) abre UN proyecto. Cuando el video sale, ese proyecto se vuelve
// invisible y su trabajo (transcript, descripción, miniaturas, post, fecha) queda enterrado. La
// Galería es el catálogo: escanea las RAÍCES de proyectos, lee el `publish.json` de cada uno y
// arma la ficha completa del lanzamiento.
//
// Reglas:
//  · `publish.json` es la FUENTE DE VERDAD. Esto lo lee y lo escribe; no crea un modelo paralelo.
//  · Un lanzamiento = una carpeta con publish.json. Sin publish.json no entra (el histórico del
//    canal NO es del pipeline).
//  · Honestidad > relleno: si un dato no está, el estado lo dice; nunca se inventa.
//  · SIN DOM y SIN red — importable por `node --test`.
import path from 'node:path';
import os from 'node:os';
import { promises as fsp } from 'node:fs';
import { loadPublish, savePublish, parseTranscript, segmentTranscript, applyEdl } from './publish.js';

const IMG_RE = /\.(png|jpe?g|webp)$/i;

/** Raíces por default: donde viven los proyectos del pipeline. Override con SFSTUDIO_ROOTS. */
export function defaultRoots(env = process.env, home = os.homedir()) {
  const raw = env.SFSTUDIO_ROOTS;
  if (raw) return raw.split(/[,:]/).map((s) => s.trim()).filter(Boolean).map((p) => path.resolve(p));
  const bos = path.join(home, 'Developer', 'business-os');
  return [
    path.join(bos, 'youtube', 'videos'),
    path.join(bos, 'agent-server', 'workspace', 'generated'),
  ];
}

// ---------- identidad de un proyecto: "r<idx>/<carpeta>" ----------
// Nunca se acepta una ruta cruda del cliente: el id se resuelve CONTRA las raíces, y el nombre no
// puede traer separadores ni `..`. Así un `?id=../../etc` no puede salir del sandbox.
export function makeId(rootIdx, name) { return `r${rootIdx}/${name}`; }

export function resolveId(roots, id) {
  const m = /^r(\d+)\/(.+)$/.exec(String(id || ''));
  if (!m) return null;
  const idx = +m[1];
  const name = m[2];
  if (!roots[idx]) return null;
  if (name.includes('/') || name.includes('\\') || name === '..' || name === '.') return null;
  return { dir: path.join(roots[idx], name), name, rootIdx: idx };
}

/** Carpetas con publish.json bajo las raíces (una pasada, tolerante a raíces inexistentes). */
export async function scanRoots(roots) {
  const found = [];
  for (let i = 0; i < roots.length; i++) {
    let names = [];
    try {
      names = (await fsp.readdir(roots[i], { withFileTypes: true }))
        .filter((d) => d.isDirectory() && !d.name.startsWith('.'))
        .map((d) => d.name)
        .sort();
    } catch { continue; } // raíz que no existe en esta máquina: no es un error
    for (const name of names) {
      const dir = path.join(roots[i], name);
      try {
        await fsp.access(path.join(dir, 'publish.json'));
        found.push({ id: makeId(i, name), dir, name, root: roots[i] });
      } catch { /* sin publish.json = no es un lanzamiento */ }
    }
  }
  return found;
}

// ---------- estado del lanzamiento (lo que se lee de un vistazo) ----------
// Dos ejes independientes: el VIDEO (¿cuándo sale?) y el POST (¿está listo para salir?).
// `tone` mapea a color en la UI: ok=verde · wait=ámbar · live=morado · idle=gris.

export function launchState(pub, now = new Date()) {
  const d = pub?.data || {};
  const L = d.launch;
  if (L?.publish_at) {
    const at = new Date(L.publish_at);
    if (at.getTime() > now.getTime()) {
      return { key: 'programado', label: `programado ${fmtWhen(at)}`, tone: 'wait', at: L.publish_at };
    }
    return { key: 'publicado', label: `publicado ${fmtWhen(at)}`, tone: 'live', at: L.publish_at };
  }
  const st = (s) => pub?.stages?.[s]?.status;
  if (st('upload') === 'done') return { key: 'subido', label: 'subido · sin programar', tone: 'wait' };
  if (st('metadata') === 'done' || st('checklist') === 'done') {
    return { key: 'listo', label: 'editado · sin programar', tone: 'wait' };
  }
  return { key: 'edicion', label: 'en edición', tone: 'idle' };
}

/** `hasFile` = hay un post-comunidad*.md en el proyecto (la Galería lo siembra al abrir la ficha).
 *  Sin él, la tarjeta diría "sin post" mientras la ficha muestra texto: dos verdades distintas. */
export function postState(pub, { hasFile = false } = {}) {
  const d = pub?.data || {};
  if (d.post_published_at) {
    return { key: 'publicado', label: `post publicado ${fmtWhen(new Date(d.post_published_at))}`, tone: 'live' };
  }
  const pd = d.post_draft || {};
  if (pd.approved_at) return { key: 'aprobado', label: 'post aprobado · listo para salir', tone: 'ok' };
  if (pd.body) return { key: 'borrador', label: 'post en borrador', tone: 'wait' };
  if (hasFile) return { key: 'borrador', label: 'post en borrador (del archivo)', tone: 'wait' };
  return { key: 'sin-post', label: 'sin post', tone: 'idle' };
}

function fmtWhen(d) {
  if (!(d instanceof Date) || isNaN(d.getTime())) return '';
  return d.toLocaleString('es-MX', {
    day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit', timeZone: 'America/Mexico_City',
  });
}

// ---------- miniaturas ----------
/** Candidatas del proyecto: thumbs/ y thumbnails/ (el auto-chain escribe en la 2a). `_*` fuera. */
export async function listThumbs(dir) {
  for (const sub of ['thumbs', 'thumbnails']) {
    try {
      const files = (await fsp.readdir(path.join(dir, sub)))
        .filter((f) => IMG_RE.test(f) && !f.startsWith('_'))
        .sort();
      if (files.length) return { dir: sub, files };
    } catch { /* siguiente */ }
  }
  return { dir: null, files: [] };
}

/** La PORTADA: la elegida por Daniel; si no eligió, la primera candidata (y se dice cuál es cuál). */
export function coverThumb(pub, files) {
  const chosen = pub?.data?.thumbnail?.chosen;
  if (chosen && files.includes(chosen)) return { file: chosen, chosen: true };
  if (chosen) return { file: files[0] || null, chosen: false, missing: chosen };
  return { file: files[0] || null, chosen: false };
}

// ---------- transcript ----------
/** `[00:12.34] texto` / `[1:02:03] texto` → segmentos con timestamp. El formato que deja la fábrica. */
export function parseTextTranscript(txt) {
  const segs = [];
  for (const line of String(txt).split('\n')) {
    const m = /^\s*\[(\d{1,2}):(\d{2})(?::(\d{2}))?(?:\.(\d{1,3}))?\]\s*(.+)$/.exec(line);
    if (!m) continue;
    const [, a, b, c, frac, text] = m;
    // [HH:MM:SS] si viene el 3er grupo; si no, [MM:SS.dd]
    const t = c !== undefined
      ? (+a) * 3600 + (+b) * 60 + (+c)
      : (+a) * 60 + (+b) + (frac ? +`0.${frac}` : 0);
    segs.push({ t: Math.round(t * 10) / 10, text: text.trim() });
  }
  return segs;
}

/**
 * Transcript del proyecto, en el mejor formato disponible:
 *  1) word-level JSON (edit/transcripts/*.json…) remapeado al CORTE FINAL si hay EDL — el canónico
 *  2) el .txt con timestamps que deja la fábrica (TRANSCRIPT-*.txt) — legible, sin word-level
 * Devuelve {found, source, cut, segments, words?, duration?}.
 */
export async function computeTranscriptFor(dirs) {
  const list = Array.isArray(dirs) ? dirs : [dirs];
  for (const dir of list) {
    for (const sub of ['edit/transcripts', 'transcripts', 'edit', '.']) {
      let files = [];
      const d = path.join(dir, sub);
      try { files = (await fsp.readdir(d)).filter((x) => x.endsWith('.json')).sort(); } catch { continue; }
      for (const f of files) {
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
          return {
            found: true, source: 'word-level', file: f, cut,
            words: tr.words.length, duration: tr.duration, segments: segmentTranscript(tr.words),
          };
        } catch { /* no es transcript */ }
      }
    }
  }
  // fallback: el .txt con timestamps (el que deja la fábrica al imprimir el máster)
  for (const dir of list) {
    for (const sub of ['transcripts', '.']) {
      let files = [];
      const d = path.join(dir, sub);
      try {
        files = (await fsp.readdir(d)).filter((x) => /^TRANSCRIPT.*\.txt$/i.test(x)).sort();
      } catch { continue; }
      for (const f of files) {
        const segs = parseTextTranscript(await fsp.readFile(path.join(d, f), 'utf8'));
        if (segs.length > 3) {
          const words = segs.reduce((n, s) => n + s.text.split(/\s+/).length, 0);
          return {
            found: true, source: 'texto', file: f, cut: 'final',
            words, duration: segs[segs.length - 1].t, segments: segs,
          };
        }
      }
    }
  }
  return { found: false, segments: [] };
}

// ---------- descripción ----------
/** Capítulos de una descripción de YouTube: las líneas `MM:SS titulo`. */
export function parseChapters(desc) {
  const out = [];
  for (const line of String(desc || '').split('\n')) {
    const m = /^\s*(?:(\d{1,2}):)?(\d{1,2}):(\d{2})\s+(.+)$/.exec(line);
    if (!m) continue;
    const t = (m[1] ? +m[1] * 3600 : 0) + (+m[2]) * 60 + (+m[3]);
    out.push({ t, label: m[4].trim() });
  }
  return out;
}

/** El bloque publicable de un DESCRIPCION-*.txt de trabajo (título + fences + notas alrededor). */
export function extractDescription(txt) {
  const s = String(txt);
  // convención de la fábrica: "DESCRIPCIÓN (pegar tal cual…)" entre líneas de ===
  const m = /DESCRIPCI[ÓO]N[^\n]*\n=+\n([\s\S]*?)(?:\n=+\n|$)/i.exec(s);
  return (m ? m[1] : s).trim();
}

/** El más RECIENTE de los archivos que matchean (v2 le gana a v1, y `-final` a lo que sea:
 *  ordenar por nombre elegía mal — "post-comunidad.md" ordena después de "post-comunidad-v2.md"). */
async function newestMatching(dir, re) {
  let names = [];
  try { names = await fsp.readdir(dir); } catch { return null; }
  const cand = names.filter((f) => re.test(f));
  if (!cand.length) return null;
  const stat = await Promise.all(cand.map(async (f) => {
    try { return { f, m: (await fsp.stat(path.join(dir, f))).mtimeMs }; } catch { return { f, m: 0 }; }
  }));
  stat.sort((a, b) => b.m - a.m || a.f.localeCompare(b.f));
  return stat[0].f;
}

async function readDescriptionFile(dir) {
  const file = await newestMatching(dir, /^DESCRIPCION.*\.txt$/i);
  if (!file) return null;
  const txt = await fsp.readFile(path.join(dir, file), 'utf8');
  return { text: extractDescription(txt), file };
}

// ---------- el post de comunidad ----------
/**
 * Cuerpo publicable de un post-comunidad*.md de trabajo: la sección "## El post", hasta el
 * siguiente separador de sección (`---` + `##`), sin las notas en blockquote (son para Levy).
 *
 * Se hace por índices y no con un solo regex a propósito: la versión anterior cerraba el
 * lookahead con `\Z`, que en JS NO es "fin de cadena" sino una `Z` literal — un .md sin sección
 * posterior no matcheaba y se publicaba el archivo ENTERO, encabezados y checklist incluidos.
 */
export function extractPostBody(md) {
  const head = /^##\s+El post\s*$/m.exec(md);
  let body = md;
  if (head) {
    body = md.slice(head.index + head[0].length);
    const end = /^---\s*$\n+^##\s/m.exec(body);
    if (end) body = body.slice(0, end.index);
  }
  return body.split('\n').filter((l) => !/^>\s/.test(l)).join('\n').trim();
}

/** El .md de trabajo del post: la versión más RECIENTE (post-comunidad-v2.md > v1). */
async function findPostFile(dir) {
  return newestMatching(dir, /^post-comunidad.*\.md$/i);
}

async function readPostFile(dir) {
  const file = await findPostFile(dir);
  if (!file) return null;
  const raw = await fsp.readFile(path.join(dir, file), 'utf8');
  return { body: extractPostBody(raw), file };
}

// ---------- tarjeta (rejilla) y ficha (expediente) ----------
export async function readCard(entry, now = new Date()) {
  const pub = await loadPublish(entry.dir);
  const { dir: thumbsDir, files } = await listThumbs(entry.dir);
  const cover = coverThumb(pub, files);
  const md = pub?.data?.metadata || {};
  const titulo = pub?.video?.titulo || pub?.data?.launch?.title || md.titles?.[0] || '';
  const hasFile = !pub?.data?.post_draft?.body && !!(await findPostFile(entry.dir));
  return {
    id: entry.id,
    name: entry.name,
    dir: entry.dir,
    slug: pub?.video?.slug || '',
    titulo,
    cover: cover.file,
    cover_chosen: !!cover.chosen,
    thumbs_dir: thumbsDir,
    thumbs_count: files.length,
    launch: launchState(pub, now),
    post: postState(pub, { hasFile }),
    video_id: pub?.data?.launch?.video_id || ytIdFrom(pub) || null,
    updated_at: lastTouch(pub),
  };
}

function ytIdFrom(pub) {
  const url = pub?.data?.post_draft?.video_url || pub?.video?.youtube_url || '';
  return /(?:v=|youtu\.be\/|shorts\/|embed\/)([a-zA-Z0-9_-]{11})/.exec(url)?.[1] || null;
}

function lastTouch(pub) {
  const ts = [
    ...(pub?.log || []).map((l) => l.ts),
    ...Object.values(pub?.stages || {}).map((s) => s.updated_at),
    pub?.data?.post_draft?.updated_at,
  ].filter(Boolean).sort();
  return ts.length ? ts[ts.length - 1] : null;
}

/** El expediente completo de un lanzamiento (lo que pinta la ficha). */
export async function readDossier(entry, now = new Date()) {
  const card = await readCard(entry, now);
  const pub = (await loadPublish(entry.dir)) || {};
  const md = pub.data?.metadata || {};

  // descripción: la de publish.json manda; si no hay, el archivo del proyecto (con su procedencia)
  let description = md.description || '';
  let descSource = description ? 'publish.json (etapa metadata)' : null;
  if (!description) {
    const f = await readDescriptionFile(entry.dir);
    if (f) { description = f.text; descSource = `${f.file} (archivo del proyecto, sin correr metadata)`; }
  }

  // post: publish.json manda; si nunca se editó, se SIEMBRA del .md de trabajo
  const pd = pub.data?.post_draft || {};
  let post = { body: pd.body || '', source: pd.source || null, seeded: false };
  if (!post.body) {
    const f = await readPostFile(entry.dir);
    if (f) post = { body: f.body, source: f.file, seeded: true };
  }

  const tr = await computeTranscriptFor([entry.dir, path.join(entry.dir, 'sfreview_project')]);
  const { files } = await listThumbs(entry.dir);

  return {
    ...card,
    stages: pub.stages || {},
    log: (pub.log || []).slice(-12).reverse(),
    titles: md.titles || [],
    keywords: md.keywords || [],
    summary: md.summary || '',
    link: pub.data?.link || null,
    mentions: pub.data?.mentions || null,
    launch_data: pub.data?.launch || null,
    post_published_at: pub.data?.post_published_at || null,
    post_delay_min: pub.data?.launch?.post_delay_min ?? 5,
    post: { ...card.post, ...post, approved_at: pd.approved_at || null, title: pd.title || card.titulo },
    description,
    description_source: descSource,
    chapters: parseChapters(description),
    thumbs: files,
    transcript: tr,
  };
}

// ---------- escritura (la Galería es la única superficie que edita el post) ----------
/**
 * Aplica un patch de la Galería sobre publish.json. Solo campos conocidos (nada de merge ciego
 * de lo que mande el cliente) y con `savePublish` (tmp+rename: el panel ⌘Y pollea el mismo archivo).
 */
export async function applyGalleryPatch(dir, patch, now = new Date()) {
  const pub = (await loadPublish(dir)) || null;
  if (!pub) throw new Error('este proyecto no tiene publish.json');
  pub.data = pub.data || {};
  const iso = now.toISOString();
  const changed = [];

  if (typeof patch.post_body === 'string') {
    const pd = pub.data.post_draft || {};
    if (pd.body !== patch.post_body) {
      pd.body = patch.post_body;
      pd.updated_at = iso;
      pd.source = pd.source || patch.post_source || 'galería';
      // editar el texto REVOCA la aprobación: nadie aprueba a ciegas un texto que cambió
      if (pd.approved_at) { pd.approved_at = null; changed.push('aprobación revocada (el texto cambió)'); }
      pub.data.post_draft = pd;
      changed.push('post editado');
    }
  }
  if (patch.post_approved !== undefined) {
    const pd = pub.data.post_draft || {};
    if (!pd.body) throw new Error('no hay texto del post que aprobar');
    pd.approved_at = patch.post_approved ? iso : null;
    pub.data.post_draft = pd;
    changed.push(patch.post_approved ? 'post APROBADO' : 'aprobación retirada');
  }
  if (typeof patch.cover === 'string' && patch.cover) {
    const { files } = await listThumbs(dir);
    if (!files.includes(patch.cover)) throw new Error(`la miniatura "${patch.cover}" no está en el proyecto`);
    pub.data.thumbnail = { ...(pub.data.thumbnail || {}), chosen: patch.cover, chosen_at: iso };
    changed.push(`portada → ${patch.cover}`);
  }
  if (typeof patch.titulo === 'string' && patch.titulo.trim()) {
    pub.video = pub.video || {};
    pub.video.titulo = patch.titulo.trim();
    changed.push('título elegido');
  }
  if (changed.length) {
    pub.log = pub.log || [];
    pub.log.push({ ts: iso, stage: 'galeria', status: 'done', msg: changed.join(' · ') });
    await savePublish(dir, pub);
  }
  return { changed, pub };
}
