// web/gallery.js — LA GALERÍA DE LANZAMIENTOS (⌘⌥G).
//
// La Sala mira UN video. La Galería mira TODOS: rejilla con la portada de cada lanzamiento y, a un
// clic, el expediente entero (metadata con capítulos, transcript navegable, miniaturas candidatas y
// el post de comunidad editable/aprobable).
//
// AI-first, como el resto del panel: aquí se MIRA y se APRUEBA. Lo único que se escribe desde la
// pantalla es lo que EXIGE criterio humano y no se puede dictar bien conversando —
//   · cuál miniatura es la portada (es una decisión visual: se ve o no se ve)
//   · el texto final del post y su aprobación (lleva la firma de Daniel)
// — y las tres cosas caen en el MISMO publish.json que escribe `sfpublish`. Cero modelo paralelo.
//
// Aprobar ≠ publicar: aprobar deja el post listo; quien lo publica es `sfpublish watch` cuando
// YouTube confirma que el video ya es público.
//
// Vanilla, cero dependencias, cero build step — el espíritu del resto de web/.

const $ = (id) => document.getElementById(id);

let deps = { toast: () => {}, escapeHtml: (s) => s, fmt: (s) => String(s) };
let items = [];          // tarjetas de la rejilla
let current = null;      // ficha abierta (dossier completo)
let filter = '';
let dirty = false;       // el textarea del post tiene cambios sin guardar
let booted = false;

export function initGallery(d) {
  deps = { ...deps, ...d };
  if (booted) return api;
  booted = true;

  $('galClose').addEventListener('click', () => toggleGallery(false));
  $('galBack').addEventListener('click', () => showGrid());
  $('galSearch').addEventListener('input', (e) => { filter = e.target.value.trim().toLowerCase(); renderGrid(); });
  $('galGrid').addEventListener('click', (e) => {
    const card = e.target.closest('.galCard');
    if (card) openItem(card.dataset.id);
  });
  // las tarjetas son focusables (tabindex): Enter/Espacio las abre, como un enlace
  $('galGrid').addEventListener('keydown', (e) => {
    const card = e.target.closest('.galCard');
    if (card && (e.key === 'Enter' || e.key === ' ')) { e.preventDefault(); openItem(card.dataset.id); }
  });
  // delegación de la ficha: un solo listener para todo lo interactivo del expediente
  $('galDetail').addEventListener('click', onDetailClick);
  $('galDetail').addEventListener('input', (e) => {
    if (e.target.id === 'galPostBody') { dirty = true; markPostDirty(); }
    if (e.target.id === 'galTrFilter') renderTranscript(e.target.value.trim().toLowerCase());
  });
  return api;
}

const api = { toggle: toggleGallery, isOpen: () => !$('galleryPanel').hidden, hasFocus };

/** ¿el foco está en un campo de texto de la galería? (el teclado global no debe robarle teclas) */
function hasFocus() {
  const a = document.activeElement;
  return !!a && (a.tagName === 'TEXTAREA' || a.tagName === 'INPUT') && !!a.closest('#galleryPanel');
}

export function toggleGallery(force) {
  const panel = $('galleryPanel');
  const open = force !== undefined ? force : panel.hidden;
  if (!open && dirty && !confirm('El post tiene cambios sin guardar. ¿Cerrar de todos modos?')) return;
  panel.hidden = !open;
  if (open) {
    load();
  } else {
    dirty = false;
    document.activeElement?.blur?.();
  }
}

// ---------- datos ----------
async function load() {
  try {
    const j = await (await fetch('/api/gallery')).json();
    items = j.items || [];
    $('galCount').textContent = `${items.length} lanzamiento${items.length === 1 ? '' : 's'}`;
    $('galWhere').textContent = (j.roots || []).map(shortPath).join('  ·  ');
    if (current) {
      // refrescar la ficha abierta sin sacar a Daniel de ella
      await openItem(current.id, { keepScroll: true });
    } else {
      renderGrid();
    }
  } catch (e) {
    $('galGrid').innerHTML = `<div class="galEmpty">no pude leer el catálogo: ${deps.escapeHtml(e.message)}</div>`;
  }
}

function shortPath(p) {
  return String(p).replace(/^\/Users\/[^/]+\//, '~/').replace(/^~\/Developer\/business-os\//, '');
}

// ---------- rejilla ----------
function showGrid() {
  if (dirty && !confirm('El post tiene cambios sin guardar. ¿Volver de todos modos?')) return;
  dirty = false;
  current = null;
  $('galDetail').hidden = true;
  $('galGrid').hidden = false;
  $('galBack').hidden = true;
  $('galSearch').hidden = false;
  renderGrid();
}

function renderGrid() {
  const box = $('galGrid');
  const list = filter
    ? items.filter((it) => `${it.name} ${it.titulo} ${it.slug}`.toLowerCase().includes(filter))
    : items;
  if (!list.length) {
    box.innerHTML = `<div class="galEmpty">${items.length
      ? 'ningún lanzamiento coincide con la búsqueda.'
      : 'sin lanzamientos todavía.<br>Un lanzamiento es una carpeta con <code>publish.json</code> bajo las raíces de arriba — lo crea <code>sfpublish &lt;proyecto&gt; init</code>.'}</div>`;
    return;
  }
  const esc = deps.escapeHtml;
  box.innerHTML = list.map((it) => {
    const cover = it.cover
      ? `<img src="/gallery/thumb?id=${encodeURIComponent(it.id)}&f=${encodeURIComponent(it.cover)}" alt="${esc(it.cover)}" loading="lazy">`
      : '<div class="galNoCover">sin miniatura</div>';
    return `<article class="galCard" data-id="${esc(it.id)}" tabindex="0">
      <div class="galCover">${cover}${it.cover && !it.cover_chosen ? '<span class="galAuto" title="portada automática: aún no eliges la definitiva">auto</span>' : ''}</div>
      <div class="galCardBody">
        <h4>${esc(it.titulo || it.name)}</h4>
        <div class="galCardSub">${esc(it.name)}${it.slug ? ` · ${esc(it.slug)}` : ''}</div>
        <div class="galChips">
          <span class="galChip ${it.launch?.tone || 'idle'}">${esc(it.launch?.label || '—')}</span>
          <span class="galChip ${it.post?.tone || 'idle'}">${esc(it.post?.label || '—')}</span>
        </div>
      </div>
    </article>`;
  }).join('');
}

// ---------- ficha ----------
async function openItem(id, opts = {}) {
  if (!opts.keepScroll && dirty && !confirm('El post tiene cambios sin guardar. ¿Salir de todos modos?')) return;
  const scroll = opts.keepScroll ? $('galDetail').scrollTop : 0;
  try {
    const j = await (await fetch(`/api/gallery/item?id=${encodeURIComponent(id)}`)).json();
    if (j.error) throw new Error(j.error);
    current = j;
    dirty = false;
    $('galGrid').hidden = true;
    $('galDetail').hidden = false;
    $('galBack').hidden = false;
    $('galSearch').hidden = true;
    renderDetail(j);
    $('galDetail').scrollTop = scroll;
  } catch (e) {
    deps.toast(`no pude abrir la ficha: ${e.message}`);
  }
}

function renderDetail(it) {
  const esc = deps.escapeHtml;
  const cover = it.cover
    ? `<img id="galCoverImg" src="/gallery/thumb?id=${encodeURIComponent(it.id)}&f=${encodeURIComponent(it.cover)}" alt="${esc(it.cover)}">`
    : '<div class="galNoCover big">sin miniatura en el proyecto</div>';

  const thumbs = it.thumbs.length
    ? it.thumbs.map((f) => `<figure class="galThumb${f === it.cover ? ' on' : ''}" data-thumb="${esc(f)}" title="click = usar como portada (va a YouTube y al post)">
         <img src="/gallery/thumb?id=${encodeURIComponent(it.id)}&f=${encodeURIComponent(f)}" alt="${esc(f)}" loading="lazy">
         <figcaption>${esc(f)}</figcaption></figure>`).join('')
    : '<div class="galEmptyBlock">sin candidatas. Pídele a Levy 2-3 miniaturas (skill <b>youtube-thumbnails</b>).</div>';

  const L = it.launch_data;
  const cuando = L?.publish_at
    ? `<div class="galWhenBig">${esc(new Date(L.publish_at).toLocaleString('es-MX', { weekday: 'long', day: 'numeric', month: 'long', hour: '2-digit', minute: '2-digit' }))}</div>
       <div class="galWhenSub">video · YouTube lo hace público solo a esa hora</div>
       <div class="galWhenSub">post de comunidad · <b>${L.post_delay_min ?? 5} min después</b> de que el video esté público${it.post_published_at ? ` — ya salió ${esc(new Date(it.post_published_at).toLocaleString('es-MX'))}` : ''}</div>
       ${L.video_id ? `<a class="galLink" href="https://youtu.be/${esc(L.video_id)}" target="_blank" rel="noopener">youtu.be/${esc(L.video_id)}</a>` : ''}`
    : `<div class="galEmptyBlock">sin fecha todavía. La programa el agente:<br><code>sfpublish &lt;proyecto&gt; launch --at "2026-07-27 11:00"</code></div>`;

  const chapters = it.chapters.length
    ? `<div class="galChapters">${it.chapters.map((c) => `<div class="galChapter"><span class="galT">${deps.fmt(c.t)}</span><span>${esc(c.label)}</span></div>`).join('')}</div>`
    : '';

  const gate = Object.entries(it.stages || {}).map(([k, v]) =>
    `<span class="ppStep ${v.status}" title="${esc(v.evidence || v.status)}">${esc(k)}</span>`).join('');

  const post = it.post || {};
  const approved = !!post.approved_at;
  const published = !!it.post_published_at;

  $('galDetail').innerHTML = `
    <div class="galDetTop">
      <div>
        <h2>${esc(it.titulo || it.name)}</h2>
        <div class="galDetSub">${esc(it.name)}${it.slug ? ` · ${esc(it.slug)}` : ''} · <span class="galPath">${esc(shortPath(it.dir))}</span></div>
      </div>
      <div class="galChips">
        <span class="galChip ${it.launch?.tone}">${esc(it.launch?.label)}</span>
        <span class="galChip ${post.tone}">${esc(post.label)}</span>
      </div>
    </div>
    <div class="galStepper">${gate}</div>

    <div class="galDetGrid">
      <section class="galSec">
        <h3>Portada</h3>
        <div class="galCoverBig">${cover}</div>
        <div class="galCoverName">${it.cover ? esc(it.cover) + (it.cover_chosen ? ' · elegida' : ' · automática (elige una abajo)') : ''}</div>
        <h3>Cuándo sale</h3>
        ${cuando}
        <h3>Miniaturas candidatas <span class="galHmeta">${it.thumbs.length}</span></h3>
        <div class="galThumbs">${thumbs}</div>
      </section>

      <section class="galSec">
        <h3>Descripción ${it.description_source ? `<span class="galHmeta">${esc(it.description_source)}</span>` : ''}
          <button class="galMini" data-copy="desc" title="copiar la descripción">copiar</button></h3>
        ${it.description
          ? `${chapters}<pre class="galDesc">${esc(it.description)}</pre>`
          : '<div class="galEmptyBlock">sin descripción. La escribe el agente: <code>sfpublish &lt;proyecto&gt; metadata</code>.</div>'}
        <h3>Títulos</h3>
        ${it.titles.length
          ? it.titles.map((t) => `<div class="galTitle${t === it.titulo ? ' chosen' : ''}">${esc(t)}<span class="galHmeta">${t.length}/60</span></div>`).join('')
          : '<div class="galEmptyBlock">sin títulos generados.</div>'}
        <h3>Keywords</h3>
        ${it.keywords.length
          ? `<div class="ppChips">${it.keywords.map((k) => `<span class="ppChip">${esc(k)}</span>`).join('')}</div>`
          : '<div class="galEmptyBlock">sin keywords.</div>'}
        ${it.link ? `<h3>Link de atribución</h3><div class="galLinkState ${it.link.verified ? 'ok' : 'bad'}">${esc(it.link.url)} — ${it.link.verified ? `verificado ✓ ${it.link.status}` : `SIN verificar (${it.link.status})`}</div>` : ''}
      </section>

      <section class="galSec">
        <h3>Transcript ${it.transcript.found ? `<span class="galHmeta">${it.transcript.words.toLocaleString('es-MX')} palabras · ${Math.round(it.transcript.duration / 60)} min · ${esc(it.transcript.source)}${it.transcript.cut === 'raw' ? ' · ⚠ RAW' : ''}</span>` : ''}</h3>
        ${it.transcript.found
          ? `<input id="galTrFilter" type="search" placeholder="buscar en el transcript…" autocomplete="off">
             <div id="galTranscript" class="galScroll"></div>`
          : '<div class="galEmptyBlock">sin transcript en el proyecto.</div>'}
      </section>

      <section class="galSec">
        <h3>Post de comunidad
          <span class="galHmeta">${post.source ? esc(post.source) : ''}${post.seeded ? ' · sembrado del archivo' : ''}</span>
        </h3>
        <div class="galPostState ${approved ? 'ok' : 'wait'}" id="galPostState">${
          published ? `publicado en la comunidad ${esc(new Date(it.post_published_at).toLocaleString('es-MX'))}`
          : approved ? `APROBADO ${esc(new Date(post.approved_at).toLocaleString('es-MX'))} · sale solo cuando el video se haga público`
          : 'borrador · nadie lo ve todavía'}</div>
        <textarea id="galPostBody" spellcheck="false" ${published ? 'readonly' : ''} placeholder="el post que sale a la comunidad cuando el video se publique…">${esc(post.body || '')}</textarea>
        <div class="galPostBar">
          <button class="galBtn" data-act="save" ${published ? 'disabled' : ''}>Guardar</button>
          <button class="galBtn ${approved ? 'off' : 'primary'}" data-act="${approved ? 'unapprove' : 'approve'}" ${published ? 'disabled' : ''}>${approved ? 'Retirar aprobación' : 'Aprobar'}</button>
          <button class="galMini" data-copy="post">copiar</button>
          <span class="galSaveHint" id="galSaveHint"></span>
        </div>
        <div class="galNote">aprobar <b>no publica</b>: deja el post listo. Lo publica <code>sfpublish watch</code> cuando YouTube confirma que el video ya es público (+${it.post_delay_min} min).</div>
      </section>
    </div>`;

  if (it.transcript.found) renderTranscript('');
}

function renderTranscript(q) {
  if (!current?.transcript?.segments) return;
  const box = $('galTranscript');
  if (!box) return;
  const esc = deps.escapeHtml;
  const segs = q ? current.transcript.segments.filter((s) => s.text.toLowerCase().includes(q)) : current.transcript.segments;
  box.innerHTML = segs.length
    ? segs.map((s) => `<div class="ppSeg"><span class="galT">${deps.fmt(s.t)}</span><span class="ppSegTx">${esc(s.text)}</span></div>`).join('')
    : '<div class="galEmptyBlock">nada coincide.</div>';
}

function markPostDirty() {
  const h = $('galSaveHint');
  if (h) { h.textContent = 'sin guardar'; h.className = 'galSaveHint warn'; }
}

async function onDetailClick(e) {
  const copy = e.target.closest('[data-copy]');
  if (copy) {
    const what = copy.dataset.copy;
    const text = what === 'desc' ? current?.description : $('galPostBody')?.value;
    try {
      await navigator.clipboard.writeText(text || '');
      deps.toast(`${what === 'desc' ? 'descripción' : 'post'} copiado ✓`);
    } catch { deps.toast('no pude copiar (permiso del navegador)'); }
    return;
  }
  const thumb = e.target.closest('[data-thumb]');
  if (thumb) { await save({ cover: thumb.dataset.thumb }); return; }
  const btn = e.target.closest('[data-act]');
  if (!btn || btn.disabled) return;
  if (btn.dataset.act === 'save') await save({ post_body: $('galPostBody').value });
  if (btn.dataset.act === 'approve') await save({ post_body: $('galPostBody').value, post_approved: true });
  if (btn.dataset.act === 'unapprove') await save({ post_approved: false });
}

/** Escribe el patch en publish.json del proyecto y repinta con lo que el server devolvió. */
async function save(patch) {
  if (!current) return;
  try {
    const r = await fetch(`/api/gallery/item?id=${encodeURIComponent(current.id)}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(patch),
    });
    const j = await r.json();
    if (!r.ok || j.ok === false) throw new Error(j.error || `HTTP ${r.status}`);
    dirty = false;
    current = j.item;
    const scroll = $('galDetail').scrollTop;
    renderDetail(j.item);
    $('galDetail').scrollTop = scroll;
    const h = $('galSaveHint');
    if (h) { h.textContent = j.changed.length ? `guardado · ${j.changed.join(' · ')}` : 'sin cambios'; h.className = 'galSaveHint ok'; }
    // la tarjeta de la rejilla ya no refleja la verdad: refrescar el catálogo en segundo plano
    fetch('/api/gallery').then((x) => x.json()).then((g) => { items = g.items || items; }).catch(() => {});
  } catch (err) {
    deps.toast(`no se guardó: ${err.message}`);
    const h = $('galSaveHint');
    if (h) { h.textContent = `error: ${err.message}`; h.className = 'galSaveHint bad'; }
  }
}

/** Teclas propias de la galería. Devuelve true si la consumió (el teclado global se detiene). */
export function galleryKey(e) {
  const k = e.key.toLowerCase();
  if (hasFocus()) {
    // dentro del textarea: solo ⌘S guarda y Esc suelta el foco; el resto se escribe normal
    if ((e.metaKey || e.ctrlKey) && k === 's') {
      e.preventDefault();
      save({ post_body: $('galPostBody')?.value ?? '' });
      return true;
    }
    if (k === 'escape') { document.activeElement.blur(); return true; }
    return true;
  }
  if (k === 'escape') {
    e.preventDefault();
    // en modo galería-sola no hay sala detrás: cerrar dejaría una pantalla en blanco
    if (!$('galDetail').hidden) showGrid();
    else if (!document.body.classList.contains('galleryOnly')) toggleGallery(false);
    return true;
  }
  if (k === '/' && !$('galSearch').hidden) { e.preventDefault(); $('galSearch').focus(); return true; }
  return true; // la galería es un espejo a pantalla completa: nada llega al timeline de atrás
}
