/**
 * community-draft.js — el brazo que publica el post del video en la comunidad SaaS Factory.
 *
 * ⚠️ CAMBIO DE DISEÑO (26 jul 2026, decisión de Daniel). Antes esto escribía el post como
 * BORRADOR en `posts` (is_draft=true) y Daniel lo aceptaba desde el feed. Ya NO:
 *
 *   · El borrador vive en el PROYECTO (`publish.json` → `data.post_draft.body`) y se ve/edita/
 *     aprueba desde la GALERÍA de SFStudio (⌘⌥G). La BD del producto no se toca hasta publicar.
 *   · Publicar = un INSERT normal (`is_draft: false`). El trigger `notify_admin_post` avisa a la
 *     comunidad, que es justo lo que queremos EN ESE momento.
 *
 * Por qué: escribir borradores en `posts` disparó 1,702 notificaciones push el 26 jul (el trigger
 * solo chequeaba is_draft para el EMAIL; el push salía igual). Ya hay guarda en la BD, pero la
 * lección de fondo es otra: un borrador no tiene por qué existir en producción. Menos superficie,
 * menos formas de equivocarse. (Por eso también murió aquí `assertDraftsAreSilent`: cuidaba un
 * camino que ya no existe.)
 *
 * ⚠️ Requiere SF_SUPABASE_KEY con role service_role (salta RLS para insertar).
 */

// Daniel Carreón (owner). Es el author_id real; la UI puede mostrar un agente
// encima vía agent_author_id, pero el FK debe apuntar a un profile real.
export const DANIEL_AUTHOR_ID = '723add38-9ece-4257-a054-5f006adf108f';
export const CATEGORY_ANUNCIOS = 'fd8709b6-9e06-4ee2-9621-b0dffbc0f6b7';

const COMMUNITY_URL = 'https://www.saasfactory.so/community';

/**
 * Markdown → HTML del feed de la comunidad.
 *
 * Emite EXACTAMENTE las etiquetas que `PostCardContent` ya sabe pintar (y que `sanitizeHtml` deja
 * pasar): p · strong · em · a · img · ul/ol/li · h2/h3 · blockquote · pre>code · code · br.
 * Nada más — una etiqueta que la plataforma no estilice sale como texto plano y se ve peor que
 * el markdown crudo.
 *
 * Antes esto solo hacía negritas y links: un post con `##`, listas o `código` salía con los
 * caracteres a la vista (27 jul 2026). Cero dependencias a propósito: el output está acotado al
 * vocabulario del renderer, y eso un parser genérico no lo garantiza.
 */
export function mdToTiptapHtml(md) {
  const esc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

  // el inline se aplica DESPUÉS de escapar; el orden importa: primero el código (su contenido
  // no se re-interpreta), luego imágenes, links, negrita, cursiva y por último las URLs sueltas.
  const inline = (s) => {
    const codigos = [];
    let out = esc(s).replace(/`([^`]+)`/g, (_, c) => `\u0000C${codigos.push(c) - 1}\u0000`);
    out = out
      .replace(/!\[([^\]]*)\]\(([^)\s]+)\)/g, (_, alt, u) => `<img src="${u}" alt="${alt}">`)
      .replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, (_, tx, u) => `<a href="${u}" target="_blank" rel="noopener">${tx}</a>`)
      .replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>')
      .replace(/(^|[\s(])\*([^*\n]+)\*(?=[\s.,;:!?)]|$)/g, '$1<em>$2</em>')
      .replace(/(^|[\s(])_([^_\n]+)_(?=[\s.,;:!?)]|$)/g, '$1<em>$2</em>')
      // URLs sueltas: no dentro de un href/src ya escrito
      // el punto final de la frase NO es parte del link (`…/abc.` se llevaba el punto)
      .replace(/(?<!["=>])\bhttps?:\/\/[^\s<)]+/g, (u) => {
        const m = /[.,;:!?]+$/.exec(u);
        const cola = m ? m[0] : '';
        const url = cola ? u.slice(0, -cola.length) : u;
        return `<a href="${url}" target="_blank" rel="noopener">${url}</a>${cola}`;
      });
    return out.replace(/\u0000C(\d+)\u0000/g, (_, i) => `<code>${codigos[+i]}</code>`);
  };

  const lineas = String(md).replace(/\r\n/g, '\n').split('\n');
  const html = [];
  let parrafo = [];      // líneas sueltas acumuladas
  let lista = null;      // {tag:'ul'|'ol', items:[]}
  let cita = [];         // líneas de blockquote
  let fence = null;      // {lang, lineas}

  const cerrarParrafo = () => {
    if (!parrafo.length) return;
    html.push(`<p>${parrafo.map(inline).join('<br>')}</p>`);
    parrafo = [];
  };
  const cerrarLista = () => {
    if (!lista) return;
    html.push(`<${lista.tag}>${lista.items.map((i) => `<li>${inline(i)}</li>`).join('')}</${lista.tag}>`);
    lista = null;
  };
  const cerrarCita = () => {
    if (!cita.length) return;
    html.push(`<blockquote><p>${cita.map(inline).join('<br>')}</p></blockquote>`);
    cita = [];
  };
  const cerrarTodo = () => { cerrarParrafo(); cerrarLista(); cerrarCita(); };

  for (const cruda of lineas) {
    const l = cruda.trim();

    if (fence) {                                   // dentro de un bloque de código: literal
      if (/^```/.test(l)) {
        html.push(`<pre><code>${esc(fence.lineas.join('\n'))}</code></pre>`);
        fence = null;
      } else fence.lineas.push(cruda);
      continue;
    }
    if (/^```/.test(l)) { cerrarTodo(); fence = { lineas: [] }; continue; }

    if (!l) { cerrarTodo(); continue; }             // línea en blanco = corta el bloque

    const h = /^(#{2,3})\s+(.+)$/.exec(l);         // ## y ### (h1 no: el post ya tiene título)
    if (h) { cerrarTodo(); html.push(`<h${h[1].length}>${inline(h[2])}</h${h[1].length}>`); continue; }

    if (/^(---|\*\*\*|___)$/.test(l)) { cerrarTodo(); continue; }   // separadores: no hay <hr> estilizado

    const q = /^>\s?(.*)$/.exec(l);
    if (q) { cerrarParrafo(); cerrarLista(); cita.push(q[1]); continue; }
    cerrarCita();

    const ul = /^[-*+]\s+(.+)$/.exec(l);
    const ol = /^\d+[.)]\s+(.+)$/.exec(l);
    if (ul || ol) {
      const tag = ul ? 'ul' : 'ol';
      cerrarParrafo();
      if (lista && lista.tag !== tag) cerrarLista();
      lista = lista || { tag, items: [] };
      lista.items.push((ul || ol)[1]);
      continue;
    }
    cerrarLista();

    parrafo.push(l);                                // lo demás (incluidos los bullets 🔹) es texto
  }
  if (fence) html.push(`<pre><code>${esc(fence.lineas.join('\n'))}</code></pre>`);
  cerrarTodo();
  return html.join('');
}

export function tiptapHtmlToMd(html) {
  return String(html)
    .replace(/<br\s*\/?>/gi, '\n')
    .replace(/<\/p>\s*<p[^>]*>/gi, '\n\n')
    .replace(/<\/?p[^>]*>/gi, '')
    .replace(/<strong>(.*?)<\/strong>/gi, '**$1**')
    .replace(/<a [^>]*href="([^"]+)"[^>]*>.*?<\/a>/gi, '$1')
    .replace(/<[^>]+>/g, '')
    .replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"').replace(/&#39;/g, "'")
    .split('\n').map((l) => l.trimEnd()).join('\n')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
}

/** Rellena los placeholders del cuerpo con los datos reales de la publicación. */
export function fillPlaceholders(md, { videoUrl, trackedLink }) {
  let out = md;
  if (videoUrl) out = out.replace(/\[LINK[_ ]VIDEO\]|\[LINK DEL VIDEO\]/gi, videoUrl);
  if (trackedLink) out = out.replace(/\[LINK[_ ]COMUNIDAD\]|\[TRACKED[_ ]LINK\]/gi, trackedLink);
  return out;
}

/**
 * Sube la miniatura elegida al bucket público `media` y devuelve su URL.
 * Pedido de Daniel (26 jul): "el draft del video sube la miniatura de youtube al mismo post".
 * Así el post de la comunidad se ve con la misma cara que el video en el feed de YouTube.
 *
 * ⚠️ posts.media_urls es JSONB (no text[]): se manda como array JSON, no como literal de Postgres.
 */
export async function uploadThumbToMedia(env, filePath, videoId = 'video') {
  const { readFile } = await import('node:fs/promises');
  const path = await import('node:path');
  const buf = await readFile(filePath);
  const ext = (path.extname(filePath) || '.png').toLowerCase();
  const type = ext === '.jpg' || ext === '.jpeg' ? 'image/jpeg' : 'image/png';
  // nombre estable por video: re-subir sobrescribe en vez de acumular basura en el bucket
  const key = `video-thumbs/${videoId}${ext}`;

  const r = await fetch(`${env.SF_SUPABASE_URL}/storage/v1/object/media/${key}`, {
    method: 'POST',
    headers: {
      apikey: env.SF_SUPABASE_KEY,
      Authorization: `Bearer ${env.SF_SUPABASE_KEY}`,
      'Content-Type': type,
      'x-upsert': 'true',
    },
    body: buf,
  });
  if (!r.ok) throw new Error(`subir miniatura al bucket media → ${r.status}: ${(await r.text()).slice(0, 200)}`);
  return `${env.SF_SUPABASE_URL}/storage/v1/object/public/media/${key}`;
}

/** Primera línea no vacía como título, si no se dio uno explícito. */
function deriveTitle(md) {
  const first = md.split('\n').map((l) => l.trim()).find(Boolean) || 'Nuevo video';
  return first.replace(/[*_#>]/g, '').slice(0, 120);
}

/**
 * PUBLICA el post en la comunidad. Un INSERT normal (is_draft: false) — el trigger notifica.
 * Lo dispara `sfpublish watch` cuando YouTube confirma que el video ya es público, NUNCA antes.
 *
 * Idempotencia: la lleva el llamador (publish.json guarda `post_published_at` + el id y deja de
 * mirar el proyecto). Aquí no se adivina: si te llaman dos veces, insertas dos veces.
 */
export async function publishCommunityPost(env, {
  bodyMarkdown,
  title,
  videoUrl = null,
  trackedLink = null,
  categoryId = CATEGORY_ANUNCIOS,
  authorId = DANIEL_AUTHOR_ID,
  agentAuthorId = null,
  mediaUrls = [],
  dryRun = false,
}) {
  if (!env.SF_SUPABASE_URL || !env.SF_SUPABASE_KEY) {
    throw new Error('faltan SF_SUPABASE_URL / SF_SUPABASE_KEY en el .env');
  }
  const filled = fillPlaceholders(bodyMarkdown, { videoUrl, trackedLink });

  // Un placeholder sin rellenar en un post que sale SOLO a toda la comunidad es un bug caro:
  // se aborta antes de escribir.
  const leftover = filled.match(/\[LINK[_ ][A-Z]+\]|\[TRACKED[_ ]LINK\]/gi);
  if (leftover) throw new Error(`placeholder sin rellenar en el post: ${leftover.join(', ')}`);

  const postTitle = title || deriveTitle(filled);
  const content = mdToTiptapHtml(filled);
  const payload = {
    author_id: authorId,
    agent_author_id: agentAuthorId,
    title: postTitle,
    content,
    category_id: categoryId,
    media_urls: mediaUrls,
    is_draft: false,
  };

  if (dryRun) {
    return { id: null, dryRun: true, title: postTitle, chars: content.length, payload, url: null };
  }

  const res = await fetch(`${env.SF_SUPABASE_URL}/rest/v1/posts`, {
    method: 'POST',
    headers: {
      apikey: env.SF_SUPABASE_KEY,
      Authorization: `Bearer ${env.SF_SUPABASE_KEY}`,
      'Content-Type': 'application/json',
      Prefer: 'return=representation',
    },
    body: JSON.stringify(payload),
  });
  if (!res.ok) throw new Error(`publicar post → ${res.status}: ${(await res.text()).slice(0, 300)}`);
  const post = (await res.json())[0];
  return { id: post.id, title: postTitle, url: `${COMMUNITY_URL}?post=${post.id}`, chars: content.length };
}
