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

import { paintCopy, flashCopied } from './icons.js';

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
  $('galLightbox').addEventListener('click', onLightboxClick);
  $('galDetail').addEventListener('input', (e) => {
    if (e.target.id === 'galPostBody') { dirty = true; markDirty('galSaveHint'); }
    if (e.target.id === 'galDescBody') { dirty = true; markDirty('galDescHint'); }
    if (e.target.id === 'galTrFilter') renderTranscript(e.target.value.trim().toLowerCase());
  });
  return api;
}

const api = {
  toggle: toggleGallery,
  isOpen: () => !$('galleryPanel').hidden,
  hasFocus,
  isDirty: () => dirty,
};

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
    closeLightbox();
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
  closeLightbox();
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
  const scroll = opts.keepScroll ? (document.querySelector('#galDetail .galDetGrid')?.scrollTop || 0) : 0;
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
    const g = document.querySelector('#galDetail .galDetGrid');
    if (g) g.scrollTop = scroll;
  } catch (e) {
    deps.toast(`no pude abrir la ficha: ${e.message}`);
  }
}

// --- barra HORIZONTAL de secciones (26→27 jul: era un rail vertical con el texto rotado; Daniel
// la quiso acostada). Un chip por sección: prende/apaga y, si está prendida, la trae a la vista.
// Es preferencia de VISTA, no cabina. Persistida, y nunca se apagan todas.
const GAL_SECS = [
  { id: 'portada', label: 'Portada' },
  { id: 'texto', label: 'Texto' },
  { id: 'transcript', label: 'Transcript' },
  { id: 'post', label: 'Post' },
];
let galView = (() => {
  const def = { portada: true, texto: true, transcript: true, post: true };
  try { return { ...def, ...JSON.parse(localStorage.getItem('sf.gal.view') || '{}') }; } catch { return def; }
})();
function applyGalView() {
  const on = GAL_SECS.filter((s) => galView[s.id]);
  for (const sec of document.querySelectorAll('#galDetail .galSec')) {
    sec.style.display = galView[sec.dataset.sec] ? '' : 'none';
  }
  const grid = document.querySelector('#galDetail .galDetGrid');
  if (grid) grid.dataset.cols = String(on.length);
  for (const b of document.querySelectorAll('.galSecBtn')) b.classList.toggle('on', !!galView[b.dataset.sec]);
  localStorage.setItem('sf.gal.view', JSON.stringify(galView));
}
function toggleSec(id) {
  const on = GAL_SECS.filter((s) => galView[s.id]);
  if (galView[id] && on.length === 1) { deps.toast('al menos una sección prendida'); return; }
  // si ya está prendida pero NO cabe en la vista, el chip NAVEGA en vez de apagar
  // (en pantallas anchas todas caben y el chip es puro toggle; en angostas es el navegador)
  if (galView[id]) {
    const sec = document.querySelector(`#galDetail .galSec[data-sec="${id}"]`);
    const grid = document.querySelector('#galDetail .galDetGrid');
    if (sec && grid) {
      const s = sec.getBoundingClientRect(), g = grid.getBoundingClientRect();
      if (s.right > g.right + 2 || s.left < g.left - 2 || s.top > g.bottom - 40 || s.bottom < g.top + 40) {
        sec.scrollIntoView({ behavior: 'smooth', block: 'start', inline: 'start' });
        return;
      }
    }
  }
  galView[id] = !galView[id];
  applyGalView();
}

// --- lightbox: la miniatura a TAMAÑO REAL ---------------------------------------------------
// Una miniatura de 200px de ancho no se puede juzgar: lo que decide si un título se lee en el feed
// móvil es verla grande. La rejilla es para navegar; esto es para decidir.
// El post se escribe en markdown pero la comunidad lo ve RENDERIZADO. Este toggle enseña
// exactamente lo que van a ver — con el MISMO converter del publicador (viene en post.html),
// no con una segunda implementación que mentiría.
let postPreview = false;

let lbList = [];   // archivos navegables (portada primero si no está entre las candidatas)
let lbIdx = -1;

const lbOpen = () => !$('galLightbox').hidden;

function openLightbox(file) {
  if (!current) return;
  lbList = current.thumbs.slice();
  if (current.cover && !lbList.includes(current.cover)) lbList.unshift(current.cover);
  lbIdx = Math.max(0, lbList.indexOf(file));
  $('galLightbox').hidden = false;
  renderLightbox();
}

function closeLightbox() {
  $('galLightbox').hidden = true;
  $('glbImg').src = '';   // suelta la imagen grande de memoria
  lbList = []; lbIdx = -1;
}

function lbStep(d) {
  if (lbList.length < 2) return;
  lbIdx = (lbIdx + d + lbList.length) % lbList.length;
  renderLightbox();
}

function renderLightbox() {
  const f = lbList[lbIdx];
  if (!f) { closeLightbox(); return; }
  const esPortada = f === current?.cover;
  $('glbImg').src = `/gallery/thumb?id=${encodeURIComponent(current.id)}&f=${encodeURIComponent(f)}`;
  $('glbImg').alt = f;
  $('glbName').textContent = f;
  $('glbCount').textContent = lbList.length > 1 ? `${lbIdx + 1} / ${lbList.length}` : '';
  const btn = $('galLightbox').querySelector('[data-glb="cover"]');
  btn.textContent = esPortada ? '✓ es la portada' : 'usar como portada';
  btn.disabled = esPortada;
  for (const n of $('galLightbox').querySelectorAll('.glbNav')) n.hidden = lbList.length < 2;
}

async function onLightboxClick(e) {
  const act = e.target.closest('[data-glb]')?.dataset.glb;
  if (act === 'close' || e.target.id === 'galLightbox') { closeLightbox(); return; }
  if (act === 'prev') { lbStep(-1); return; }
  if (act === 'next') { lbStep(1); return; }
  if (act === 'cover') { const f = lbList[lbIdx]; await save({ cover: f }); renderLightbox(); }
}

/** Las dos fases en el header: qué falta y de quién es la pelota. */
function renderFases(it) {
  const esc = deps.escapeHtml;
  return `<div class="galFases">${it.fases.map((f) => {
    const hechos = f.items.filter((i) => i.ok).length;
    const completa = hechos === f.items.length;
    return `<section class="galFase${completa ? ' completa' : ''}">
      <header><span class="galFaseN">${f.n}</span>
        <span class="galFaseT">${esc(f.titulo)}</span>
        <span class="galFaseDe">${esc(f.de)}</span>
        <span class="galFaseCnt">${hechos}/${f.items.length}</span></header>
      <div class="galFaseItems">${f.items.map((i) => `
        <span class="galFaseItem ${i.ok ? 'ok' : 'falta'}" title="${esc(i.ok ? (i.detalle || 'listo') : i.falta)}">
          ${i.ok ? '✓' : '·'} ${esc(i.label)}${i.detalle && i.ok ? `<b>${esc(i.detalle)}</b>` : ''}
        </span>`).join('')}</div>
    </section>`;
  }).join('<span class="galFaseFlecha">→</span>')}</div>`;
}

function renderDetail(it) {
  const esc = deps.escapeHtml;
  const cover = it.cover
    ? `<img id="galCoverImg" src="/gallery/thumb?id=${encodeURIComponent(it.id)}&f=${encodeURIComponent(it.cover)}" alt="${esc(it.cover)}">`
    : '<div class="galNoCover big">sin miniatura en el proyecto</div>';

  const thumbs = it.thumbs.length
    ? it.thumbs.map((f) => `<figure class="galThumb${f === it.cover ? ' on' : ''}" data-thumb="${esc(f)}" title="click = usar como portada (va a YouTube y al post)">
         <img src="/gallery/thumb?id=${encodeURIComponent(it.id)}&f=${encodeURIComponent(f)}" alt="${esc(f)}" loading="lazy">
         <button class="galZoom" data-big="${esc(f)}" title="verla a tamaño real">⤢</button>
         <figcaption>${esc(f)}</figcaption></figure>`).join('')
    : '<div class="galEmptyBlock">sin candidatas. Pídele a Levy 2-3 miniaturas (skill <b>youtube-thumbnails</b>).</div>';

  const L = it.launch_data;
  const cuando = L?.publish_at
    ? `<div class="galWhenBig">${esc(new Date(L.publish_at).toLocaleString('es-MX', { weekday: 'long', day: 'numeric', month: 'long', hour: '2-digit', minute: '2-digit' }))}</div>
       <div class="galWhenSub">video · YouTube lo hace público solo a esa hora</div>
       <div class="galWhenSub">post de comunidad · <b>${L.post_delay_min ?? 5} min después</b> de que el video esté público${it.post_published_at ? ` — ya salió ${esc(new Date(it.post_published_at).toLocaleString('es-MX'))}` : ''}</div>
       ${L.video_id ? `<a class="galLink" href="https://youtu.be/${esc(L.video_id)}" target="_blank" rel="noopener">youtu.be/${esc(L.video_id)}</a>` : ''}`
    : `<div class="galEmptyBlock">sin fecha todavía. La programa el agente:<br><code>sfpublish &lt;proyecto&gt; launch --at "2026-07-27 11:00"</code></div>`;

  // (los capítulos NO se pintan aparte: ya viven dentro del texto de la descripción, que es lo
  //  que de verdad se pega en YouTube. Pintarlos arriba era la misma lista dos veces.)

  const post = it.post || {};
  const approved = !!post.approved_at;
  const published = !!it.post_published_at;

  $('galDetail').innerHTML = `
    <div class="galDetHead">
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
      ${renderFases(it)}
    </div>

    <div class="galDetBody">
    <nav class="galSecBar" aria-label="secciones del expediente">
      ${GAL_SECS.map((s) => `<button class="galSecBtn" data-sec="${s.id}" title="prende/apaga ${s.label} (si ya está, la trae a la vista)"><span class="galLed"></span>${s.label}</button>`).join('')}
    </nav>
    <div class="galDetGrid">
      <section class="galSec" data-sec="portada">
        <h3>Portada${it.cover ? `<button class="galMini" data-big="${esc(it.cover)}" title="verla a tamaño real (F)">⤢ ver grande</button>` : ''}</h3>
        <div class="galCoverBig"${it.cover ? ` data-big="${esc(it.cover)}" title="click = verla a tamaño real"` : ''}>${cover}</div>
        <div class="galCoverName">${it.cover ? esc(it.cover) + (it.cover_chosen ? ' · elegida' : ' · automática (elige una abajo)') : ''}</div>
        <h3>Cuándo sale</h3>
        ${cuando}
        <h3>Miniaturas candidatas <span class="galHmeta">${it.thumbs.length}</span></h3>
        <div class="galThumbs">${thumbs}</div>
      </section>

      <section class="galSec" data-sec="texto">
        <h3>Descripción ${it.description_source ? `<span class="galHmeta">${esc(it.description_source)}</span>` : ''}
          ${it.description ? '<button class="galCopy" data-copy="desc" title="copiar la descripción"></button>' : ''}</h3>
        ${it.description
          ? `<textarea id="galDescBody" spellcheck="false">${esc(it.description)}</textarea>
             <div class="galPostBar">
               <button class="galBtn" data-act="save-desc">Guardar</button>
               <span class="galSaveHint" id="galDescHint"></span>
             </div>`
          : '<div class="galEmptyBlock">sin descripción. La escribe el agente: <code>sfpublish &lt;proyecto&gt; metadata</code>.</div>'}
        <h3>Títulos <span class="galHmeta">click = ese sale a YouTube</span></h3>
        ${it.titles.length
          ? it.titles.map((t, i) => `<div class="galTitle${t === it.titulo ? ' chosen' : ''}" data-titulo="${esc(t)}" title="elegir este título"><span class="galRadio"></span><span class="galTitleTx">${esc(t)}</span><span class="galHmeta">${t.length}/60</span><button class="galCopy" data-copy="title" data-idx="${i}" title="copiar este título"></button></div>`).join('')
          : '<div class="galEmptyBlock">sin títulos generados.</div>'}
        <h3>Keywords${it.keywords.length ? '<button class="galCopy" data-copy="keywords" title="copiar las keywords"></button>' : ''}</h3>
        ${it.keywords.length
          ? `<div class="ppChips">${it.keywords.map((k) => `<span class="ppChip">${esc(k)}</span>`).join('')}</div>`
          : '<div class="galEmptyBlock">sin keywords.</div>'}
      </section>

      <section class="galSec" data-sec="transcript">
        <h3>Transcript ${it.transcript.found ? `<span class="galHmeta">${it.transcript.words.toLocaleString('es-MX')} palabras · ${Math.round(it.transcript.duration / 60)} min · ${esc(it.transcript.source)}${it.transcript.cut === 'raw' ? ' · ⚠ RAW' : ''}</span><button class="galCopy" data-copy="transcript" title="copiar el transcript"></button>` : ''}</h3>
        ${it.transcript.found
          ? `<input id="galTrFilter" type="search" placeholder="buscar en el transcript…" autocomplete="off">
             <div id="galTranscript" class="galScroll"></div>`
          : '<div class="galEmptyBlock">sin transcript en el proyecto.</div>'}
      </section>

      <section class="galSec" data-sec="post">
        <h3>Post de comunidad
          <span class="galHmeta">${post.source ? esc(post.source) : ''}${post.seeded ? ' · sembrado del archivo' : ''}</span>
          <button class="galMini" data-act="preview" title="ver el post como lo verá la comunidad (P)">${postPreview ? 'editar' : 'ver render'}</button>
          <button class="galCopy" data-copy="post" title="copiar el post"></button>
        </h3>
        <div class="galPostState ${approved ? 'ok' : 'wait'}" id="galPostState">${
          published ? `publicado en la comunidad ${esc(new Date(it.post_published_at).toLocaleString('es-MX'))}`
          : approved ? `APROBADO ${esc(new Date(post.approved_at).toLocaleString('es-MX'))} · sale solo cuando el video se haga público`
          : 'borrador · nadie lo ve todavía'}</div>
        ${postPreview
          ? `<div class="galPostRender">${post.html || '<i>sin texto</i>'}</div>`
          : `<textarea id="galPostBody" spellcheck="false" ${published ? 'readonly' : ''} placeholder="el post que sale a la comunidad cuando el video se publique…">${esc(post.body || '')}</textarea>`}
        <div class="galPostBar">
          <button class="galBtn" data-act="save" ${published || postPreview ? 'disabled' : ''}>Guardar</button>
          <button class="galBtn ${approved ? 'off' : 'primary'}" data-act="${approved ? 'unapprove' : 'approve'}" ${published ? 'disabled' : ''}>${approved ? 'Retirar aprobación' : 'Aprobar'}</button>
          <span class="galSaveHint" id="galSaveHint"></span>
        </div>
        <div class="galNote">aprobar <b>no publica</b>: deja el post listo. Lo publica <code>sfpublish watch</code> cuando YouTube confirma que el video ya es público (+${it.post_delay_min} min).</div>
      </section>
    </div>
    </div>`;

  for (const b of $('galDetail').querySelectorAll('.galCopy')) paintCopy(b);
  applyGalView();
  if (it.transcript.found) renderTranscript('');
}

/** Lo que se lleva cada botón de copiar. El expediente es espejo, pero su contenido SE LLEVA. */
function copyText(what, idx) {
  if (what === 'desc') return current?.description || '';
  if (what === 'keywords') return (current?.keywords || []).join(', ');
  if (what === 'title') return current?.titles?.[idx] || '';
  if (what === 'post') return $('galPostBody')?.value || '';
  if (what === 'transcript') {
    return (current?.transcript?.segments || []).map((s) => `${deps.fmt(s.t)}  ${s.text}`).join('\n');
  }
  return '';
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

function markDirty(hintId) {
  const h = $(hintId);
  if (h) { h.textContent = 'sin guardar'; h.className = 'galSaveHint warn'; }
}

async function onDetailClick(e) {
  const secBtn = e.target.closest('.galSecBtn');
  if (secBtn) { toggleSec(secBtn.dataset.sec); return; }
  // ⤢ (o la portada) abre a tamaño real — antes que [data-thumb], que sí cambia la portada
  const big = e.target.closest('[data-big]');
  if (big) { e.stopPropagation(); openLightbox(big.dataset.big); return; }
  const copy = e.target.closest('[data-copy]');
  if (copy) {
    const what = copy.dataset.copy;
    const text = copyText(what, +copy.dataset.idx);
    if (!text) { deps.toast(`nada que copiar aún en ${what}`); return; }
    try {
      await navigator.clipboard.writeText(text);
      deps.toast(`${what} copiado ✓`);
      flashCopied(copy);
    } catch { deps.toast('no pude copiar (permiso del navegador)'); }
    return;
  }
  const thumb = e.target.closest('[data-thumb]');
  if (thumb) { await save({ cover: thumb.dataset.thumb }); return; }
  const titulo = e.target.closest('[data-titulo]');
  if (titulo) { await save({ titulo: titulo.dataset.titulo }); return; }
  const btn = e.target.closest('[data-act]');
  if (!btn || btn.disabled) return;
  if (btn.dataset.act === 'preview') {
    // al salir del preview NO se pierde lo escrito: se guarda antes de cambiar de vista
    if (!postPreview && dirty && $('galPostBody')) await save({ post_body: $('galPostBody').value });
    postPreview = !postPreview;
    renderDetail(current);
    return;
  }
  if (btn.dataset.act === 'save-desc') await save({ description: $('galDescBody').value });
  if (btn.dataset.act === 'save') await save({ post_body: $('galPostBody').value });
  if (btn.dataset.act === 'approve') await save({ post_body: $('galPostBody')?.value ?? current?.post?.body ?? '', post_approved: true });
  if (btn.dataset.act === 'unapprove') await save({ post_approved: false });
}

/** Escribe el patch en publish.json del proyecto y repinta con lo que el server devolvió. */
async function save(patch, hintId = 'galSaveHint') {
  if (!current) return;
  if (patch.description !== undefined) hintId = 'galDescHint';
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
    const scroll = document.querySelector('#galDetail .galDetGrid')?.scrollTop || 0;
    // guardar UNA cosa repinta la ficha entera; lo que Daniel esté escribiendo en OTRO campo no
    // se puede perder en el repintado (elegir un título borraba la descripción a medio editar)
    const enVuelo = [];
    for (const [id, campo] of [['galDescBody', 'description'], ['galPostBody', 'post_body']]) {
      const el = $(id);
      if (el && patch[campo] === undefined && el.value !== (id === 'galDescBody' ? j.item.description : j.item.post?.body)) {
        enVuelo.push([id, el.value, el === document.activeElement, el.selectionStart, el.selectionEnd]);
      }
    }
    renderDetail(j.item);
    for (const [id, val, teníaFoco, a, b2] of enVuelo) {
      const el = $(id);
      if (!el) continue;
      el.value = val;
      dirty = true;
      markDirty(id === 'galDescBody' ? 'galDescHint' : 'galSaveHint');
      if (teníaFoco) { el.focus(); el.setSelectionRange(a, b2); }
    }
    const g = document.querySelector('#galDetail .galDetGrid');
    if (g) g.scrollTop = scroll;   // guardar no debe brincar la vista al inicio

    const h = $(hintId);
    if (h) { h.textContent = j.changed.length ? `guardado · ${j.changed.join(' · ')}` : 'sin cambios'; h.className = 'galSaveHint ok'; }
    // la tarjeta de la rejilla ya no refleja la verdad: refrescar el catálogo en segundo plano
    fetch('/api/gallery').then((x) => x.json()).then((g) => { items = g.items || items; }).catch(() => {});
  } catch (err) {
    deps.toast(`no se guardó: ${err.message}`);
    const h = $(hintId);
    if (h) { h.textContent = `error: ${err.message}`; h.className = 'galSaveHint bad'; }
  }
}

/** Teclas propias de la galería. Devuelve true si la consumió (el teclado global se detiene). */
export function galleryKey(e) {
  const k = e.key.toLowerCase();
  // el lightbox está ENCIMA de todo: se lleva las teclas primero
  if (lbOpen()) {
    e.preventDefault();
    if (k === 'escape' || k === 'f') closeLightbox();
    else if (e.key === 'ArrowLeft') lbStep(-1);
    else if (e.key === 'ArrowRight') lbStep(1);
    else if (e.key === 'Enter') save({ cover: lbList[lbIdx] }).then(renderLightbox);
    return true;
  }
  if (hasFocus()) {
    // dentro del textarea: solo ⌘S guarda y Esc suelta el foco; el resto se escribe normal
    if ((e.metaKey || e.ctrlKey) && k === 's') {
      e.preventDefault();
      if (document.activeElement.id === 'galDescBody') save({ description: document.activeElement.value });
      else save({ post_body: $('galPostBody')?.value ?? '' });
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
  if (k === 'f' && current?.cover) { e.preventDefault(); openLightbox(current.cover); return true; }
  if (k === '/' && !$('galSearch').hidden) { e.preventDefault(); $('galSearch').focus(); return true; }
  return true; // la galería es un espejo a pantalla completa: nada llega al timeline de atrás
}
