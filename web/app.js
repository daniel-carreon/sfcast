// SFStudio — Sala de Revisión. AI-first: la sala es para VER, RECORTAR fino (S/A/D), ANOTAR,
// y ahora también EDITAR overlays a mano (arrastrar/trim de bordes/eliminar items);
// todo vuelve a la fábrica como fixes.json (trims + item_edits). Nada se re-renderiza aquí.
import {
  newState, cloneState, mergeRanges, addSplit, trimLeft, trimRight,
  prevBoundary, nextBoundary, setTrimRange,
  skipTarget, totalTrimmed, toFixes, fromFixes,
  editItem, effItem, resolveItems, clampItem, pruneItemEdits,
  effAll, effByKey, baseOfKey, patchByKey, removeByKey,
  splitItemAt, trimItemTo, removeItemsInsideRange,
  keptSegments, outDuration, rawToOut, outToRaw,
} from './model.js';

const $ = (id) => document.getElementById(id);
const base = $('base');
const SPEEDS = [1, 1.25, 1.5, 2];

// ---------- iconos de la barra: Lucide (lucide.dev, ISC), SVG inline · cero dependencias ----------
const LU = (paths) => `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">${paths}</svg>`;
const LUF = (paths) => `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="currentColor" stroke="none">${paths}</svg>`; // relleno (play/pausa)
const IC = {
  magnet: LU('<path d="m6 15-4-4 6.75-6.77a7.79 7.79 0 0 1 11 11L13 22l-4-4 6.39-6.36a2.14 2.14 0 0 0-3-3L6 15"/><path d="m5 8 4 4"/><path d="m12 15 4 4"/>'),
  link: LU('<path d="M9 17H7A5 5 0 0 1 7 7h2"/><path d="M15 7h2a5 5 0 1 1 0 10h-2"/><line x1="8" x2="16" y1="12" y2="12"/>'),
  scissors: LU('<circle cx="6" cy="6" r="3"/><path d="M8.12 8.12 12 12"/><path d="M20 4 8.12 15.88"/><circle cx="6" cy="18" r="3"/><path d="M14.8 14.8 20 20"/>'),
  zoomOut: LU('<circle cx="11" cy="11" r="8"/><line x1="21" x2="16.65" y1="21" y2="16.65"/><line x1="8" x2="14" y1="11" y2="11"/>'),
  zoomIn: LU('<circle cx="11" cy="11" r="8"/><line x1="21" x2="16.65" y1="21" y2="16.65"/><line x1="11" x2="11" y1="8" y2="14"/><line x1="8" x2="14" y1="11" y2="11"/>'),
  fit: LU('<path d="M8 3H5a2 2 0 0 0-2 2v3"/><path d="M21 8V5a2 2 0 0 0-2-2h-3"/><path d="M3 16v3a2 2 0 0 0 2 2h3"/><path d="M16 21h3a2 2 0 0 0 2-2v-3"/>'),
  gear: LU('<path d="M12.22 2h-.44a2 2 0 0 0-2 2v.18a2 2 0 0 1-1 1.73l-.43.25a2 2 0 0 1-2 0l-.15-.08a2 2 0 0 0-2.73.73l-.22.38a2 2 0 0 0 .73 2.73l.15.1a2 2 0 0 1 1 1.72v.51a2 2 0 0 1-1 1.74l-.15.09a2 2 0 0 0-.73 2.73l.22.38a2 2 0 0 0 2.73.73l.15-.08a2 2 0 0 1 2 0l.43.25a2 2 0 0 1 1 1.73V20a2 2 0 0 0 2 2h.44a2 2 0 0 0 2-2v-.18a2 2 0 0 1 1-1.73l.43-.25a2 2 0 0 1 2 0l.15.08a2 2 0 0 0 2.73-.73l.22-.39a2 2 0 0 0-.73-2.73l-.15-.08a2 2 0 0 1-1-1.74v-.5a2 2 0 0 1 1-1.74l.15-.09a2 2 0 0 0 .73-2.73l-.22-.38a2 2 0 0 0-2.73-.73l-.15.08a2 2 0 0 1-2 0l-.43-.25a2 2 0 0 1-1-1.73V4a2 2 0 0 0-2-2z"/><circle cx="12" cy="12" r="3"/>'),
  play: LUF('<path d="M8 5v14l11-7z"/>'),
  pause: LUF('<path d="M6 4h4v16H6zM14 4h4v16h-4z"/>'),
  keyboard: LU('<rect width="20" height="16" x="2" y="4" rx="2"/><path d="M6 8h.01"/><path d="M10 8h.01"/><path d="M14 8h.01"/><path d="M18 8h.01"/><path d="M8 12h.01"/><path d="M12 12h.01"/><path d="M16 12h.01"/><path d="M7 16h10"/>'),
};
$('magnetBtn').innerHTML = IC.magnet;
$('linkBtn').innerHTML = IC.link;
$('zoomOut').innerHTML = IC.zoomOut;
$('zoomIn').innerHTML = IC.zoomIn;
$('zoomFit').innerHTML = IC.fit;
$('gearBtn').innerHTML = IC.gear;

// ---------- panel de Atajos (engrane top-right) ----------
function toggleHelpPanel(force) {
  const p = $('helpPanel');
  const open = force !== undefined ? force : p.hidden;
  p.hidden = !open;
  $('gearBtn').classList.toggle('on', open);
}
$('gearBtn').addEventListener('click', (e) => { e.stopPropagation(); toggleHelpPanel(); });
$('hpClose').addEventListener('click', () => toggleHelpPanel(false));
// click fuera del panel (y que no sea el engrane) lo cierra
document.addEventListener('pointerdown', (e) => {
  if ($('helpPanel').hidden) return;
  if (!e.target.closest('#helpPanel') && !e.target.closest('#gearBtn')) toggleHelpPanel(false);
});

let project = null;
let state = newState();
const undoStack = [];
const redoStack = [];
let pxPerSec = 1;       // zoom del timeline
let fitPx = 1;
let mounted = new Map(); // _key → {el}
let speed = 1;
let selKey = null;       // item PRIMARIO seleccionado: índice base (número) o 'aN' (pieza añadida)
let multiSel = new Set(); // selección múltiple (Q/E o grupo): keys de items
// modos estilo CapCut, persistidos: imán (snap al arrastrar) y vinculación (el recorte del base
// se lleva los overlays que caen completos adentro)
let magnetOn = localStorage.getItem('sf.magnet') !== '0';
let linkOn = localStorage.getItem('sf.link') !== '0';
// vista del timeline (persistida): 'compact' = CORTE estilo CapCut (solo material conservado,
// los trims colapsan a costuras/líneas de corte — el DEFAULT) · 'raw' = material completo
let viewMode = localStorage.getItem('sf.viewmode') || 'compact';
let segsCache = []; // keptSegments cacheado; se recomputa en cada render (updateMapping)

// ---------- cambio de coordenadas raw ↔ timeline (la vista corte vive aquí) ----------
function updateMapping() { segsCache = keptSegments(state.trims, project.duration); }
function tlDur() { return viewMode === 'compact' ? outDuration(state.trims, project.duration) : project.duration; }
function tlOf(traw) { return viewMode === 'compact' ? rawToOut(segsCache, traw) : traw; }
function tlToRaw(tl) { return viewMode === 'compact' ? outToRaw(segsCache, tl) : tl; }
function XT(traw) { return tlOf(traw) * pxPerSec; }

// ---------- selección (única + múltiple Q/E + la BASE) ----------
// baseSelected = la pista principal (el video) entra en la selección: Q/E la incluyen y arrastrar
// el grupo hace un RIPPLE (corta la base en el playhead y todo lo de ese lado se pule junto).
let baseSelected = false;
function isSel(key) { return key === selKey || multiSel.has(key); }
function clearSel() { selKey = null; multiSel.clear(); baseSelected = false; }
function setSingleSel(key) {
  multiSel.clear();
  baseSelected = false; // seleccionar un asset suelto saca a la base del grupo
  if (key !== null) multiSel.add(key);
  selKey = key;
}

// ---------- carga ----------
async function boot() {
  project = await (await fetch('/api/project')).json();
  $('projname').textContent = project.name || '';
  document.title = `SFStudio — ${project.name || 'Sala de Revisión'}`;

  base.src = '/media/' + project.base.src;
  base.preservesPitch = true; // 2x con TONO NORMAL (nativo; la razón #1 de los parches a HF muere aquí)

  // restaurar sesión previa si hay fixes.json
  try {
    const r = await fetch('/api/fixes');
    if (r.ok) {
      const fx = await r.json();
      if (fx && (fx.trims || fx.markers || fx.item_edits)) {
        state = fromFixes(fx);
        pruneItemEdits(state, project.items); // timeline regenerado → ediciones stale fuera
      }
    }
  } catch { /* sin sesión previa */ }

  buildSpeedButtons();
  initResizers();
  layoutStage();
  fitTimeline();
  renderTimeline();
  renderMarkers();
  loop();

  // waveform: llega async (el server lo computa/cachea con ffmpeg); dibuja cuando esté
  fetch('/api/waveform').then((r) => r.json()).then((w) => {
    if (w && Array.isArray(w.peaks)) { wave = w; queueWave(); }
  }).catch(() => { /* la sala funciona sin waveform */ });
}

// ---------- waveform (canvas sticky: dibuja SOLO el viewport, redibuja en scroll/zoom) ----------
let wave = null;
let waveQueued = false;
function queueWave() {
  if (waveQueued) return;
  waveQueued = true;
  requestAnimationFrame(() => { waveQueued = false; drawWave(); });
}
function drawWave() {
  const c = $('waveCanvas');
  const scroll = $('timelineScroll');
  const H = c.parentElement.clientHeight;
  const W = scroll.clientWidth;
  const dpr = window.devicePixelRatio || 1;
  if (c.width !== Math.floor(W * dpr) || c.height !== Math.floor(H * dpr)) {
    c.width = Math.floor(W * dpr); c.height = Math.floor(H * dpr);
    c.style.width = W + 'px'; c.style.height = H + 'px';
  }
  const ctx = c.getContext('2d');
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.clearRect(0, 0, W, H);
  const mid = H / 2;
  ctx.strokeStyle = 'rgba(255,255,255,.10)';
  ctx.beginPath(); ctx.moveTo(0, mid); ctx.lineTo(W, mid); ctx.stroke();
  if (!wave || !wave.peaks.length) {
    ctx.fillStyle = '#55555f'; ctx.font = '9px system-ui';
    ctx.fillText(wave ? 'sin pista de audio' : 'cargando waveform…', 8, H - 6);
    return;
  }
  const t0 = scroll.scrollLeft / pxPerSec; // tiempo del TIMELINE (out en vista corte)
  // en vista corte cada columna se remapea a tiempo raw (puntero monotónico: barato)
  let segPtr = 0;
  const colRaw = (tl) => {
    if (viewMode !== 'compact') return tl;
    while (segPtr < segsCache.length - 1 && tl > segsCache[segPtr].out + (segsCache[segPtr].b - segsCache[segPtr].a)) segPtr++;
    const s = segsCache[segPtr];
    return s ? s.a + Math.max(0, Math.min(s.b - s.a, tl - s.out)) : tl;
  };
  ctx.fillStyle = 'rgba(255,145,1,.72)';
  for (let x = 0; x < W; x++) {
    const bA = Math.floor(colRaw(t0 + x / pxPerSec) * wave.rate);
    if (bA * 2 >= wave.peaks.length) break;
    const bB = Math.max(bA + 1, Math.floor(colRaw(t0 + (x + 1) / pxPerSec) * wave.rate));
    let mn = 0, mx = 0;
    for (let b = bA; b < bB && b * 2 + 1 < wave.peaks.length; b++) {
      const lo = wave.peaks[b * 2], hi = wave.peaks[b * 2 + 1];
      if (lo < mn) mn = lo;
      if (hi > mx) mx = hi;
    }
    const y1 = mid - (mx / 100) * (mid - 2);
    const y2 = mid - (mn / 100) * (mid - 2);
    ctx.fillRect(x, y1, 1, Math.max(1, y2 - y1));
  }
}

function layoutStage() {
  const wrap = $('stageWrap');
  const stage = $('stage');
  const aw = wrap.clientWidth, ah = wrap.clientHeight;
  const ar = project.width / project.height;
  let w = aw, h = aw / ar;
  if (h > ah) { h = ah; w = ah * ar; }
  stage.style.width = `${Math.floor(w)}px`;
  stage.style.height = `${Math.floor(h)}px`;
}
window.addEventListener('resize', () => { if (project) { layoutStage(); fitTimeline(false); renderTimeline(); } });

// ---------- overlays (mount/unmount por ventana de tiempo: cada webm-alpha cuesta 2 decoders) ----------
const WINDOW = 3;
function unmountOverlay(key) {
  const m = mounted.get(key);
  if (!m) return;
  if (m.el.tagName === 'VIDEO') { try { m.el.pause(); } catch { /* ok */ } m.el.removeAttribute('src'); m.el.load(); }
  m.el.remove();
  mounted.delete(key);
}
function syncOverlays(t, playing) {
  // lista EFECTIVA (base editados + piezas añadidas): mover/trim/split/eliminar se reflejan en vivo
  const items = effAll(state, project.items);
  const present = new Set();
  for (const it of items) {
    present.add(it._key);
    let m = mounted.get(it._key);
    const inWindow = t >= it.start - WINDOW && t < it.start + it.dur + WINDOW;
    // clave = _key estable del modelo, NO it.id: los ids de negocio pueden repetirse y colisionarían
    if (inWindow && !m) {
      const el = it.type === 'video' ? document.createElement('video') : document.createElement('img');
      el.className = 'ov';
      el.style.zIndex = 20 + (it.track || 1) * 10;
      el.style.objectFit = it.fit === 'stretch' ? 'fill' : (it.fit || 'contain');
      if (it.type === 'video') {
        el.muted = true;
        el.playsInline = true;
        el.preload = 'auto';
        el.playbackRate = speed;
      }
      el.src = '/media/' + it.src;
      el.style.display = 'none';
      $('overlays').appendChild(el);
      m = { el };
      mounted.set(it._key, m);
    } else if (!inWindow && m) {
      unmountOverlay(it._key);
      continue;
    }
    if (!m) continue;
    const local = t - it.start + (it.offset || 0); // offset = in-point del media (trim izq. de video)
    const active = t >= it.start && t < it.start + it.dur;
    m.el.style.display = active ? '' : 'none';
    if (m.el.tagName === 'VIDEO') {
      const dur = m.el.duration;
      const target = Math.max(0, Number.isFinite(dur) ? Math.min(local, dur - 0.03) : local);
      if (active) {
        if (Math.abs(m.el.currentTime - target) > 0.12 && m.el.readyState >= 1) m.el.currentTime = target;
        if (playing && m.el.paused) m.el.play().catch(() => {});
        if (!playing && !m.el.paused) m.el.pause();
      } else {
        if (!m.el.paused) m.el.pause();
        if (m.el.readyState >= 1 && Math.abs(m.el.currentTime - target) > 0.3) m.el.currentTime = target;
      }
    }
  }
  // desmontar lo que ya no existe (item eliminado / add deshecho)
  for (const key of [...mounted.keys()]) if (!present.has(key)) unmountOverlay(key);
}

// ---------- salto de trims: rVFC (por-frame), NUNCA timeupdate (250ms = 7 frames visibles) ----------
function armFrameSkip() {
  const cb = () => {
    if (!base.paused) {
      const tgt = skipTarget(state.trims, base.currentTime);
      if (tgt !== null) {
        if (tgt >= project.duration - 0.05) base.pause();
        base.currentTime = Math.min(tgt, project.duration - 0.04);
      }
    }
    base.requestVideoFrameCallback(cb);
  };
  base.requestVideoFrameCallback(cb);
}

// ---------- bucle de UI ----------
function loop() {
  armFrameSkip();
  const tick = () => {
    const t = base.currentTime || 0;
    const playing = !base.paused && !base.ended;
    syncOverlays(t, playing);
    $('playhead').style.transform = `translateX(${XT(t)}px)`;
    // en vista corte el reloj es el del RESULTADO (tiempo final), como CapCut
    $('timecode').textContent = `${fmt(tlOf(t))} / ${fmt(tlDur())}`;
    $('playBtn').textContent = playing ? '⏸' : '▶';
    // controles de pantalla completa (solo cuando aplica): scrub + reloj + icono play/pausa
    if (document.fullscreenElement || document.webkitFullscreenElement) {
      const cur = tlOf(t), dur = tlDur();
      const frac = dur > 0 ? Math.max(0, Math.min(1, cur / dur)) : 0;
      $('fsSeekFill').style.width = `${frac * 100}%`;
      $('fsSeekKnob').style.left = `${frac * 100}%`;
      $('fsTime').textContent = `${fmt(cur)} / ${fmt(dur)}`;
      const want = playing ? 'pause' : 'play';
      if ($('fsPlay').dataset.ic !== want) { $('fsPlay').innerHTML = playing ? IC.pause : IC.play; $('fsPlay').dataset.ic = want; }
    }
    requestAnimationFrame(tick);
  };
  requestAnimationFrame(tick);
}

function fmt(s) {
  const m = Math.floor(s / 60);
  const sec = (s - m * 60).toFixed(1).padStart(4, '0');
  return `${m}:${sec}`;
}

// ---------- timeline ----------
function fitTimeline(reset = true) {
  updateMapping();
  const w = $('timelineScroll').clientWidth - 4;
  fitPx = Math.max(0.01, w / Math.max(1, tlDur()));
  if (reset) pxPerSec = fitPx;
}

function renderTimeline() {
  updateMapping();
  const W = Math.max(tlDur() * pxPerSec, $('timelineScroll').clientWidth - 4);
  $('timeline').style.width = `${W}px`;

  // ruler (en vista corte marca el tiempo FINAL, como CapCut)
  const ruler = $('ruler');
  ruler.innerHTML = '';
  const steps = [0.5, 1, 2, 5, 10, 30, 60, 120, 300, 600];
  const step = steps.find((s) => s * pxPerSec >= 70) || 600;
  for (let t = 0; t <= tlDur(); t += step) {
    const d = document.createElement('div');
    d.className = 'tick';
    d.style.left = `${t * pxPerSec}px`;
    d.textContent = fmt(t);
    ruler.appendChild(d);
  }

  // pins de marcadores
  const lane = $('markerLane');
  lane.innerHTML = '';
  state.markers.forEach((mk, i) => {
    const p = document.createElement('div');
    p.className = 'mpin';
    p.style.left = `${XT(mk.t)}px`;
    p.title = mk.nota;
    p.dataset.idx = i;
    lane.appendChild(p);
  });

  // items por track (efectivos, incl. piezas añadidas por split; editables: arrastrar = mover,
  // bordes = trim, click = seleccionar). En vista corte ambos EXTREMOS se remapean (un item que
  // cruza trims conserva su ancho de salida real).
  const effItems = effAll(state, project.items);
  for (const tr of [1, 2, 3]) {
    const el = $('track' + tr);
    el.innerHTML = '';
    for (const it of effItems.filter((i) => (i.track || 1) === tr)) {
      const edited = typeof it._key === 'string' || !!state.items[it._key];
      const d = document.createElement('div');
      d.className = `clipItem t${tr}` + (isSel(it._key) ? ' sel' : '') + (edited ? ' edited' : '');
      const x0 = XT(it.start);
      const w = Math.max(2, XT(it.start + it.dur) - x0 - 1); // ancho OUT real (colapsa costuras internas)
      d.style.left = `${x0}px`;
      d.style.width = `${w}px`;
      d.title = `${it.id} · ${it.start}s +${it.dur}s — arrastra para mover · bordes = trim · Supr borra`;
      d.dataset.key = String(it._key);
      if (w > 34) d.textContent = it.id; // el label depende del ancho renderizado, no de la dur cruda
      const hl = document.createElement('div'); hl.className = 'hd l';
      const hr = document.createElement('div'); hr.className = 'hd r';
      d.append(hl, hr);
      el.appendChild(d);
    }
  }

  // base según la vista:
  //  · CORTE (default): clips conservados adyacentes + COSTURAS (línea de corte estilo CapCut);
  //    la costura se arrastra (bordes = ajustar el corte, cuerpo = moverlo) y doble-click restaura
  //  · RAW: material completo con los rangos recortados visibles (la vista quirúrgica)
  const bt = $('track0');
  bt.innerHTML = '';
  const merged = mergeRanges(state.trims);
  // ¿la base de este lado del playhead está seleccionada? (Q/E la incluyen para el ripple)
  const phOut = tlOf(base.currentTime || 0);
  const baseSegSel = (outStart, outEnd) => baseSelected &&
    (rippleDir > 0 ? outStart >= phOut - 1e-3 : outEnd <= phOut + 1e-3);
  if (viewMode === 'compact') {
    for (const s of segsCache) {
      const d = document.createElement('div');
      const wOut = s.b - s.a;
      d.className = 'baseSeg' + (baseSegSel(s.out, s.out + wOut) ? ' sel' : '');
      d.style.left = `${s.out * pxPerSec}px`;
      d.style.width = `${Math.max(1, wOut * pxPerSec - 1)}px`;
      bt.appendChild(d);
    }
    merged.forEach((r, i) => {
      const d = document.createElement('div');
      d.className = 'cutSeam';
      d.style.left = `${rawToOut(segsCache, r.start) * pxPerSec}px`;
      d.title = `corte: −${(r.end - r.start).toFixed(1)}s (raw ${fmt(r.start)} → ${fmt(r.end)}) — ` +
        'click = verificar · bordes = ajustar · arrastrar = mover · doble-click restaura';
      d.dataset.tidx = i;
      const hl = document.createElement('div'); hl.className = 'hd l';
      const hr = document.createElement('div'); hr.className = 'hd r';
      d.append(hl, hr);
      bt.appendChild(d);
    });
  } else {
    let cursor = 0;
    const segs = [];
    for (const r of merged) {
      if (r.start > cursor) segs.push([cursor, r.start]);
      cursor = r.end;
    }
    if (cursor < project.duration) segs.push([cursor, project.duration]);
    for (const [a, b] of segs) {
      const d = document.createElement('div');
      d.className = 'baseSeg' + (baseSegSel(a, b) ? ' sel' : ''); // en raw out==raw
      d.style.left = `${a * pxPerSec}px`;
      d.style.width = `${Math.max(1, (b - a) * pxPerSec - 1)}px`;
      bt.appendChild(d);
    }
    merged.forEach((r, i) => {
      const d = document.createElement('div');
      d.className = 'trimRange';
      d.style.left = `${r.start * pxPerSec}px`;
      d.style.width = `${Math.max(2, (r.end - r.start) * pxPerSec - 1)}px`;
      d.title = `recorte ${r.start}s → ${r.end}s — arrastra para mover · bordes = ajustar · doble-click restaura`;
      d.dataset.tidx = i;
      const hl = document.createElement('div'); hl.className = 'hd l';
      const hr = document.createElement('div'); hr.className = 'hd r';
      d.append(hl, hr);
      bt.appendChild(d);
    });
  }
  for (const s of state.splits) {
    const d = document.createElement('div');
    d.className = 'splitLine';
    d.style.left = `${XT(s)}px`;
    bt.appendChild(d);
  }

  const cut = totalTrimmed(state.trims);
  const nEdits = Object.keys(state.items).length;
  $('trimSummary').innerHTML = (state.trims.length
    ? `<b>${cut.toFixed(1)}s</b> recortados en ${mergeRanges(state.trims).length} rango(s) · dur final ${fmt(project.duration - cut)}`
    : 'sin recortes') + (nEdits ? ` · <span class="iedit">${nEdits} asset(s) editado(s)</span>` : '');
  renderItemInfo();
  queueWave();
}

// ---------- inspector del item seleccionado ----------
const TRACK_NAMES = { 1: 'clips', 2: 'alpha', 3: 'caps' };
function renderItemInfo() {
  const box = $('itemInfo');
  // selección múltiple (Q/E) y/o la base: tarjeta de grupo, no de item
  if (multiSel.size > 1 || baseSelected) {
    box.hidden = false;
    const que = baseSelected
      ? `${multiSel.size} asset(s) <b>+ la base</b>`
      : `${multiSel.size} assets seleccionados`;
    const hint = baseSelected
      ? '<b>arrastrar</b> hace RIPPLE en el playhead (corta la base + todo lo de ese lado se pule junto) · <b>Supr</b> borra los assets · <b>Esc</b> deselecciona'
      : '<b>arrastrar</b> mueve el grupo · <b>⌥←/→</b> 1 frame (⇧×10) · <b>Supr</b> borra todos · <b>Esc</b> deselecciona';
    box.innerHTML = `<div class="iiId">${que}</div><div class="iiHint">${hint}</div>`;
    return;
  }
  const only = selKey !== null ? selKey : (multiSel.size === 1 ? [...multiSel][0] : null);
  const it = only !== null ? effByKey(state, project.items, only) : null;
  if (!it) {
    box.innerHTML = '';
    box.hidden = true;
    return;
  }
  box.hidden = false;
  const off = it.offset ? ` · in ${it.offset.toFixed(2)}s` : '';
  const isAdd = typeof it._key === 'string' ? ' · pieza de split' : '';
  box.innerHTML = `<div class="iiId">${it.id}</div>` +
    `<div class="iiMeta">${TRACK_NAMES[it.track || 1]} · ${fmt(it.start)} → ${fmt(it.start + it.dur)} (${it.dur.toFixed(2)}s)${off}${isAdd}</div>` +
    `<div class="iiHint"><b>S</b> parte · <b>A/D</b> trim al playhead · <b>⌥←/→</b> mover 1 frame (⇧×10) · <b>Supr</b> borra · <b>Esc</b> deselecciona</div>`;
}

function renderMarkers() {
  const ol = $('markerList');
  ol.innerHTML = '';
  state.markers.forEach((mk, i) => {
    const li = document.createElement('li');
    const del = document.createElement('button');
    del.className = 'mdel'; del.textContent = '✕'; del.title = 'borrar marcador';
    del.addEventListener('click', (e) => { e.stopPropagation(); pushUndo(); state.markers.splice(i, 1); refresh(); });
    // el tiempo del marcador habla el idioma de la vista (out en corte, raw en raw)
    const t = document.createElement('div'); t.className = 'mt'; t.textContent = fmt(tlOf(mk.t));
    const n = document.createElement('div'); n.className = 'mnota'; n.textContent = mk.nota || '(sin nota)';
    li.append(del, t, n);
    li.addEventListener('click', () => { base.currentTime = mk.t; });
    ol.appendChild(li);
  });
}

function refresh() { renderTimeline(); renderMarkers(); }

// ---------- undo / redo ----------
function pushUndo() {
  undoStack.push(cloneState(state));
  if (undoStack.length > 100) undoStack.shift();
  redoStack.length = 0; // una edición nueva invalida el redo
}
function validateSel() {
  for (const k of [...multiSel]) if (!effByKey(state, project.items, k)) multiSel.delete(k);
  if (selKey !== null && !effByKey(state, project.items, selKey)) selKey = null;
}
function undo() {
  const prev = undoStack.pop();
  if (prev) {
    redoStack.push(cloneState(state));
    state = prev;
    validateSel();
    refresh();
    toast('deshecho · ⌘⇧Z rehace');
  }
}
function redo() {
  const next = redoStack.pop();
  if (next) {
    undoStack.push(cloneState(state));
    if (undoStack.length > 100) undoStack.shift();
    state = next;
    validateSel();
    refresh();
    toast('rehecho');
  }
}

function selectedKeys() {
  if (multiSel.size) return [...multiSel];
  return selKey !== null ? [selKey] : [];
}

// S/A/D con selección (única O de grupo Q/E): aplica `fn` a cada asset seleccionado. Devuelve
// true si HABÍA selección (aunque ningún asset contuviera el playhead), para que el caller NO
// caiga a la operación de BASE — evita que un A/D con 🔗 borre en cascada el grupo recién elegido.
function itemOpOverSelection(fn, okMsg) {
  const keys = selectedKeys();
  if (!keys.length) return false;
  pushUndo();
  let n = 0;
  for (const kk of keys) if (fn(kk)) n++;
  if (n) { refresh(); toast(typeof okMsg === 'function' ? okMsg(n) : okMsg); }
  else { undoStack.pop(); toast('playhead fuera de los assets seleccionados'); }
  return true;
}

function removeSelectedItem() {
  const keys = selectedKeys();
  if (!keys.length) return;
  // adds ('aN') se eliminan con splice → borrar de mayor a menor índice para no invalidar keys
  keys.sort((p, q) => {
    const pa = typeof p === 'string', qa = typeof q === 'string';
    if (pa && qa) return +q.slice(1) - +p.slice(1);
    return pa === qa ? 0 : (pa ? 1 : -1);
  });
  pushUndo();
  let n = 0;
  let lastId = null;
  for (const k of keys) {
    const it = effByKey(state, project.items, k);
    if (it && removeByKey(state, project.items, k)) { n++; lastId = it.id; }
  }
  if (!n) { undoStack.pop(); return; }
  toast(n === 1 ? `${lastId} eliminado · ⌘Z deshace` : `${n} assets eliminados · ⌘Z deshace`);
  clearSel();
  refresh();
}

function nudgeSelectedItem(dt) {
  const keys = selectedKeys();
  if (!keys.length) return false;
  pushUndo();
  let n = 0;
  for (const k of keys) {
    const baseIt = baseOfKey(state, project.items, k);
    const it = effByKey(state, project.items, k);
    if (!it || !baseIt) continue;
    patchByKey(state, project.items, k, clampItem(baseIt, { start: it.start + dt }, project.duration));
    n++;
  }
  if (!n) { undoStack.pop(); return false; }
  refresh();
  return true;
}

// Q/E: seleccionar TODO a un lado del cursor (dir<0 = izquierda, dir>0 = derecha), INCLUIDA LA BASE
// (el video principal). Criterio para overlays: E toma los que EMPIEZAN en/después del playhead; Q
// los que TERMINAN en/antes. La base SIEMPRE entra (es continua) → arrastrar el grupo hace ripple.
function selectSide(dir) {
  const t = base.currentTime || 0;
  const items = effAll(state, project.items);
  const keys = items
    .filter((it) => (dir > 0 ? it.start >= t - 1e-3 : it.start + it.dur <= t + 1e-3))
    .map((it) => it._key);
  multiSel = new Set(keys);
  selKey = keys.length === 1 ? keys[0] : null;
  baseSelected = true; // la base del lado elegido entra: el grupo se arrastra como un todo (ripple)
  rippleDir = dir;     // recordar el lado para el ripple
  renderTimeline();
  toast(`${keys.length} asset(s) + la base a la ${dir > 0 ? 'derecha' : 'izquierda'} · ` +
    'arrastra el grupo para RIPPLE (corta la base y todo lo de ese lado se pule) · Supr borra los assets');
}
let rippleDir = 1; // lado activo del último Q/E (para el ripple)

// ↑ = siguiente bloque, ↓ = anterior (estilo CapCut): recorre los assets por tiempo; ↓ desde el
// primero vuelve al base (sin selección). Seleccionar también lleva el playhead al inicio del bloque.
function navigateBlocks(dir) {
  const items = effAll(state, project.items).sort((a, b) => a.start - b.start || (a.track || 1) - (b.track || 1));
  if (!items.length) { toast('sin assets en el timeline'); return; }
  const cur = selKey !== null ? items.findIndex((i) => i._key === selKey) : -1;
  let next;
  if (cur === -1) {
    const t = base.currentTime || 0;
    next = dir > 0
      ? items.findIndex((i) => i.start >= t - 1e-3)
      : (() => { let p = -1; items.forEach((i, j) => { if (i.start < t - 1e-3) p = j; }); return p; })();
    if (next === -1 && dir > 0) next = items.length - 1;
  } else {
    next = cur + dir;
  }
  if (next < 0 || next >= items.length) {
    clearSel();
    renderTimeline();
    toast('base (sin selección)');
    return;
  }
  setSingleSel(items[next]._key);
  base.currentTime = Math.min(project.duration, items[next].start + 0.001);
  renderTimeline();
  toast(`${items[next].id} · ${fmt(items[next].start)}`);
}

// ---------- interacción ----------
function timeFromEvent(e) {
  // devuelve tiempo RAW (los consumidores — seek, trims — viven en raw); la conversión
  // desde coordenadas de pantalla pasa por el timeline (out en vista corte)
  const rect = $('timeline').getBoundingClientRect();
  const tl = Math.max(0, Math.min(tlDur(), (e.clientX - rect.left) / pxPerSec));
  return Math.max(0, Math.min(project.duration, tlToRaw(tl)));
}
function seekFromEvent(e) {
  base.currentTime = timeFromEvent(e);
}

// snap de bordes: playhead, 0, fin del proyecto y bordes de los demás items.
// El imán es un MODO (🧲, persistido); ⌥ lo invierte por gesto.
function snapCandidates(exceptKey) {
  const c = [0, project.duration, base.currentTime || 0];
  for (const it of effAll(state, project.items)) {
    if (it._key === exceptKey) continue;
    c.push(it.start, it.start + it.dur);
  }
  return c;
}
function snapInfo(t, cands, altKey) {
  const active = magnetOn !== !!altKey; // ⌥ invierte el modo
  if (!active) return { t, hit: null };
  const thr = 8 / pxPerSec; // 8px de imán
  let best = t, dist = thr, hit = null;
  for (const c of cands) {
    const d = Math.abs(t - c);
    if (d < dist) { best = c; dist = d; hit = c; }
  }
  return { t: best, hit };
}
function snapTo(t, cands, altKey) { return snapInfo(t, cands, altKey).t; }

// línea guía del imán: contorno vertical detrás del gesto cuando un borde se alinea (estilo CapCut)
function showSnapGuide(t) {
  let g = $('snapGuide');
  if (!g) {
    g = document.createElement('div');
    g.id = 'snapGuide';
    $('timeline').appendChild(g);
  }
  g.style.left = `${XT(t)}px`;
  g.hidden = false;
}
function hideSnapGuide() {
  const g = $('snapGuide');
  if (g) g.hidden = true;
}

function selectByKey(key) {
  // si el item ya es parte de una selección múltiple, clickearlo NO la rompe (permite
  // agarrar el grupo Q/E y arrastrarlo); clickear uno de fuera sí re-selecciona solo
  if (!multiSel.has(key)) setSingleSel(key);
  else selKey = key;
  renderTimeline();
}

// vinculación (🔗): un rango recortado del base se lleva los overlays que caen COMPLETOS adentro
function applyLinkedRemoval(start, end) {
  if (!linkOn) return 0;
  return removeItemsInsideRange(state, project.items, start, end);
}

// drag de un item: mover (cuerpo) o trim (bordes .hd). Actualiza SOLO el div durante el drag
// (recrear el DOM mataría el gesto); render completo al soltar. El stage refleja en vivo via rAF.
function startItemDrag(e, div, key) {
  e.preventDefault();
  e.stopPropagation();
  const baseIt = baseOfKey(state, project.items, key);
  const it0 = effByKey(state, project.items, key);
  if (!it0 || !baseIt) return;
  const mode = e.target.classList.contains('hd') ? (e.target.classList.contains('l') ? 'l' : 'r') : 'move';
  selectByKey(key); // re-renderiza el timeline → el div original queda detached: re-consultarlo
  div = $('track' + (it0.track || 1)).querySelector(`.clipItem[data-key="${key}"]`) || div;
  const x0 = e.clientX;
  const undo0 = cloneState(state);
  const srcEl = mounted.get(key)?.el;
  const srcDur = (srcEl?.tagName === 'VIDEO' && Number.isFinite(srcEl.duration)) ? srcEl.duration : null;
  const cands = snapCandidates(key);
  let changed = false;
  // arrastre de GRUPO (selección Q/E): el primario mueve a todos con el mismo delta EN TL (out),
  // así el grupo se mantiene visualmente junto aunque cada uno cruce costuras distintas
  const group = (mode === 'move' && multiSel.size > 1 && multiSel.has(key))
    ? [...multiSel].filter((k) => k !== key).map((k) => {
        const it = effByKey(state, project.items, k);
        const b = baseOfKey(state, project.items, k);
        return it && b ? { k, outStart0: tlOf(it.start), base: b } : null;
      }).filter(Boolean)
    : [];
  const placeDiv = (el, eff) => {
    const px0 = XT(eff.start);
    el.style.left = `${px0}px`;
    el.style.width = `${Math.max(2, XT(eff.start + eff.dur) - px0 - 1)}px`;
  };
  // el gesto vive en TL-space (out): en vista corte pxPerSec mide px/seg-OUT, así que el delta de
  // pantalla es un delta OUT — sumarlo a un ancla RAW corrompe la posición al cruzar una costura.
  // Ancla→TL, sumar dx, volver a RAW con tlToRaw (todo esto es identidad en vista raw).
  const A0 = tlOf(it0.start);
  const B0 = tlOf(it0.start + it0.dur);
  const candsTl = cands.map(tlOf);
  div.classList.add('dragging');

  const move = (ev) => {
    const dx = (ev.clientX - x0) / pxPerSec; // delta en segundos OUT (tl-space)
    if (Math.abs(ev.clientX - x0) < 2 && !changed) return;
    let patch = null;
    let hit = null; // el hit de snapInfo vive en TL; a showSnapGuide (que espera raw) va con tlToRaw
    if (mode === 'move') {
      const s1 = snapInfo(A0 + dx, candsTl, ev.altKey);
      let nsTl = s1.t;
      hit = s1.hit;
      const s2 = snapInfo(nsTl + (B0 - A0), candsTl, ev.altKey);
      if (s2.hit !== null && s1.hit === null) { nsTl = s2.t - (B0 - A0); hit = s2.hit; } // imán por el borde derecho
      patch = clampItem(baseIt, { start: tlToRaw(nsTl) }, project.duration, srcDur);
    } else if (mode === 'l') {
      const s1 = snapInfo(A0 + dx, candsTl, ev.altKey);
      hit = s1.hit;
      let ns = tlToRaw(s1.t);
      const end = it0.start + it0.dur;
      const minStart = baseIt.type === 'video' ? it0.start - (it0.offset || 0) : 0; // el media no existe antes de su 0
      ns = Math.max(minStart, Math.min(ns, end - 0.1));
      const delta = ns - it0.start;
      patch = clampItem(baseIt, {
        start: ns,
        dur: it0.dur - delta,
        ...(baseIt.type === 'video' ? { offset: (it0.offset || 0) + delta } : {}),
      }, project.duration, srcDur);
    } else {
      const s1 = snapInfo(B0 + dx, candsTl, ev.altKey);
      hit = s1.hit;
      let ne = Math.max(it0.start + 0.1, Math.min(tlToRaw(s1.t), project.duration));
      patch = clampItem(baseIt, { dur: ne - it0.start }, project.duration, srcDur);
    }
    patchByKey(state, project.items, key, patch);
    changed = true;
    const eff = effByKey(state, project.items, key);
    placeDiv(div, eff);
    // el grupo sigue al primario con su mismo delta EN TL (out)
    if (group.length) {
      const outDelta = tlOf(eff.start) - A0;
      for (const g of group) {
        patchByKey(state, project.items, g.k, clampItem(g.base, { start: tlToRaw(g.outStart0 + outDelta) }, project.duration));
        const ge = effByKey(state, project.items, g.k);
        const gdiv = $('track' + (ge.track || 1)).querySelector(`.clipItem[data-key="${g.k}"]`);
        if (gdiv && ge) placeDiv(gdiv, ge);
      }
    }
    if (hit !== null) showSnapGuide(tlToRaw(hit)); else hideSnapGuide();
    renderItemInfo();
  };
  const up = () => {
    window.removeEventListener('pointermove', move);
    window.removeEventListener('pointerup', up);
    div.classList.remove('dragging');
    hideSnapGuide();
    if (changed) {
      undoStack.push(undo0);
      if (undoStack.length > 100) undoStack.shift();
      redoStack.length = 0;
      const eff = effByKey(state, project.items, key);
      refresh();
      toast(group.length
        ? `${group.length + 1} assets movidos juntos · ⌘Z deshace`
        : `${it0.id} ${mode === 'move' ? '→' : 'trim'} ${fmt(eff.start)} (+${eff.dur.toFixed(2)}s)`);
    }
  };
  window.addEventListener('pointermove', move);
  window.addEventListener('pointerup', up);
}

// drag de un RECORTE del base: mover el rango completo (por si el punto exacto salió mal) o
// ajustar sus bordes. Doble-click lo elimina (restaura el contenido). Fusión al soltar, no en medio.
function trimSnapCandidates(exceptIdx) {
  const c = [0, project.duration, base.currentTime || 0];
  for (const it of effAll(state, project.items)) c.push(it.start, it.start + it.dur);
  state.trims.forEach((r, i) => { if (i !== exceptIdx) c.push(r.start, r.end); });
  return c;
}
function startTrimDrag(e, div, tidx) {
  e.preventDefault();
  const r0 = state.trims[tidx];
  if (!r0) return;
  const mode = e.target.classList.contains('hd') ? (e.target.classList.contains('l') ? 'l' : 'r') : 'move';
  const x0 = e.clientX;
  const undo0 = cloneState(state);
  const cands = trimSnapCandidates(tidx);
  const len = r0.end - r0.start;
  let changed = false;
  div.classList.add('dragging');

  const move = (ev) => {
    const dx = (ev.clientX - x0) / pxPerSec;
    if (Math.abs(ev.clientX - x0) < 2 && !changed) return;
    let hit = null;
    let did = false;
    if (mode === 'move') {
      const s1 = snapInfo(r0.start + dx, cands, ev.altKey);
      let ns = s1.t;
      hit = s1.hit;
      const s2 = snapInfo(ns + len, cands, ev.altKey);
      if (s2.hit !== null && s1.hit === null) { ns = s2.t - len; hit = s2.hit; }
      ns = Math.max(0, Math.min(ns, project.duration - len));
      did = setTrimRange(state, tidx, ns, ns + len, project.duration);
    } else if (mode === 'l') {
      const s1 = snapInfo(r0.start + dx, cands, ev.altKey);
      hit = s1.hit;
      did = setTrimRange(state, tidx, Math.min(s1.t, r0.end - 0.05), r0.end, project.duration);
    } else {
      const s1 = snapInfo(r0.end + dx, cands, ev.altKey);
      hit = s1.hit;
      did = setTrimRange(state, tidx, r0.start, Math.max(s1.t, r0.start + 0.05), project.duration);
    }
    if (!did) return;
    changed = true;
    const r = state.trims[tidx];
    div.style.left = `${r.start * pxPerSec}px`;
    div.style.width = `${Math.max(2, (r.end - r.start) * pxPerSec - 1)}px`;
    div.title = `recorte ${r.start}s → ${r.end}s`;
    if (hit !== null) showSnapGuide(hit); else hideSnapGuide();
  };
  const up = () => {
    window.removeEventListener('pointermove', move);
    window.removeEventListener('pointerup', up);
    div.classList.remove('dragging');
    hideSnapGuide();
    if (changed) {
      const r = state.trims[tidx];
      const a = r.start, b = r.end;
      state.trims = mergeRanges(state.trims);
      undoStack.push(undo0);
      if (undoStack.length > 100) undoStack.shift();
      redoStack.length = 0;
      refresh();
      toast(`recorte ${mode === 'move' ? 'movido' : 'ajustado'} → ${fmt(a)}–${fmt(b)} · ⌘Z deshace`);
    }
  };
  window.addEventListener('pointermove', move);
  window.addEventListener('pointerup', up);
}

// COSTURA (vista corte): el corte es una línea entre dos clips, como CapCut. Bordes = ajustar
// (izq. mueve trim.start, der. mueve trim.end — extender/devolver material), cuerpo = mover el
// corte completo, click = seek a 1.5s antes para VERIFICARLO, doble-click = restaurar.
// El ripple cambia TODA la geometría → re-render completo por frame (rAF).
function startSeamDrag(e, div, tidx) {
  e.preventDefault();
  const r0 = state.trims[tidx];
  if (!r0) return;
  const zone = e.target.classList.contains('hd') ? (e.target.classList.contains('l') ? 'l' : 'r') : 'move';
  const x0 = e.clientX;
  const undo0 = cloneState(state);
  const len0 = r0.end - r0.start;
  let changed = false;
  let raf = 0;
  // dx vive en segundos OUT (pxPerSec = px/seg-OUT en vista corte). El eje out se define por los
  // OTROS trims (el que arrastramos está colapsado): capturamos ese mapping FIJO al inicio del
  // gesto para traducir el delta de pantalla a RAW aun cuando la costura cruza otro corte.
  const segs0 = keptSegments(state.trims.filter((_, i) => i !== tidx), project.duration);
  const outStart0 = rawToOut(segs0, r0.start);
  const outEnd0 = rawToOut(segs0, r0.end);

  const move = (ev) => {
    const dx = (ev.clientX - x0) / pxPerSec; // delta en segundos OUT
    if (Math.abs(ev.clientX - x0) < 2 && !changed) return;
    let did = false;
    if (zone === 'l') {
      const ns = outToRaw(segs0, outStart0 + dx);
      did = setTrimRange(state, tidx, Math.min(ns, r0.end - 0.05), r0.end, project.duration);
    } else if (zone === 'r') {
      const ne = outToRaw(segs0, outEnd0 + dx);
      did = setTrimRange(state, tidx, r0.start, Math.max(ne, r0.start + 0.05), project.duration);
    } else {
      const ns = Math.max(0, Math.min(outToRaw(segs0, outStart0 + dx), project.duration - len0));
      did = setTrimRange(state, tidx, ns, ns + len0, project.duration);
    }
    if (!did) return;
    changed = true;
    if (!raf) raf = requestAnimationFrame(() => { raf = 0; renderTimeline(); });
  };
  const up = () => {
    window.removeEventListener('pointermove', move);
    window.removeEventListener('pointerup', up);
    if (raf) { cancelAnimationFrame(raf); raf = 0; }
    if (changed) {
      const r = state.trims[tidx];
      state.trims = mergeRanges(state.trims);
      undoStack.push(undo0);
      if (undoStack.length > 100) undoStack.shift();
      redoStack.length = 0;
      refresh();
      toast(`corte ${zone === 'move' ? 'movido' : 'ajustado'}: −${(r.end - r.start).toFixed(1)}s (raw ${fmt(r.start)}–${fmt(r.end)}) · ⌘Z deshace`);
    } else {
      // click sin arrastre = VERIFICAR el corte: seek a 1.5s antes de la costura
      base.currentTime = Math.max(0, r0.start - 1.5);
      toast(`corte: −${len0.toFixed(1)}s (raw ${fmt(r0.start)} → ${fmt(r0.end)}) · Espacio para escucharlo · doble-click restaura`);
    }
  };
  window.addEventListener('pointermove', move);
  window.addEventListener('pointerup', up);
}

// ⌥-arrastre sobre el timeline = seleccionar un RANGO y recortarlo del base (el gesto del silencio)
function startRangeTrim(e) {
  e.preventDefault();
  const t0 = timeFromEvent(e);
  const sel = document.createElement('div');
  sel.className = 'rangeSel';
  $('timeline').appendChild(sel);
  let t1 = t0;
  const paint = () => {
    const a = Math.min(t0, t1), b = Math.max(t0, t1);
    sel.style.left = `${XT(a)}px`;
    sel.style.width = `${Math.max(1, XT(b) - XT(a))}px`;
  };
  paint();
  const move = (ev) => { t1 = timeFromEvent(ev); paint(); };
  const up = () => {
    window.removeEventListener('pointermove', move);
    window.removeEventListener('pointerup', up);
    sel.remove();
    const a = Math.min(t0, t1), b = Math.max(t0, t1);
    if (b - a >= 0.05) {
      pushUndo();
      state.trims.push({ start: Math.round(a * 1000) / 1000, end: Math.round(b * 1000) / 1000 });
      state.trims = mergeRanges(state.trims);
      const n = applyLinkedRemoval(a, b);
      validateSel();
      refresh();
      toast(`recorte ${fmt(a)} → ${fmt(b)} (${(b - a).toFixed(1)}s)${n ? ` · ${n} asset(s) adentro eliminados 🔗` : ''} · ⌘Z deshace`);
    }
  };
  window.addEventListener('pointermove', move);
  window.addEventListener('pointerup', up);
}

// RIPPLE: con la base incluida en la selección (Q/E), arrastrar el grupo CORTA la base en el
// playhead y todo lo de ese lado (base + overlays) se pule junto — como agarrar la parte derecha
// del timeline entero y jalarla. Los overlays ripplean SOLOS (sus posiciones out se recomputan por
// los trims). Dirección: a la izquierda = tighten (cortar); el pipeline solo CORTA, no inserta
// relleno, así que arrastrar a la derecha vuelve al punto de partida. El pivote es el playhead.
function startRippleDrag(e) {
  e.preventDefault();
  e.stopPropagation();
  const pivot = base.currentTime || 0;
  const x0 = e.clientX;
  const undo0 = cloneState(state);
  const trims0 = state.trims.map((r) => ({ start: r.start, end: r.end })); // snapshot inmutable
  let changed = false, raf = 0, lastW = 0;
  const r3 = (x) => Math.round(x * 1000) / 1000;
  const move = (ev) => {
    const dOut = (ev.clientX - x0) / pxPerSec; // out-seconds; izquierda (neg) = tighten
    if (Math.abs(ev.clientX - x0) < 2 && !changed) return;
    const w = Math.max(0, -dOut);
    lastW = w;
    const extra = w > 0.02 ? [{ start: r3(pivot), end: r3(Math.min(project.duration, pivot + w)) }] : [];
    state.trims = mergeRanges([...trims0, ...extra]); // reconstruir desde el snapshot = idempotente
    changed = true;
    if (!raf) raf = requestAnimationFrame(() => { raf = 0; renderTimeline(); });
  };
  const up = () => {
    window.removeEventListener('pointermove', move);
    window.removeEventListener('pointerup', up);
    if (raf) { cancelAnimationFrame(raf); raf = 0; }
    if (changed && lastW > 0.02) {
      undoStack.push(undo0); if (undoStack.length > 100) undoStack.shift(); redoStack.length = 0;
      validateSel();
      refresh();
      toast(`ripple −${lastW.toFixed(1)}s en ${fmt(tlOf(pivot))} · base + todo a la derecha pulido · ⌘Z deshace`);
    } else {
      state.trims = trims0; // sin corte neto: dejar el snapshot intacto
      renderTimeline();
      if (changed) toast('el ripple solo CORTA hacia la izquierda (el pipeline no inserta relleno)');
    }
  };
  window.addEventListener('pointermove', move);
  window.addEventListener('pointerup', up);
}

// costura MÁS CERCANA al clic (no la topmost por z-order): con cientos de cortes densos las
// hit-zones de 14px se solapan y el orden de DOM sesgaría el clic a la costura más tardía.
function nearestSeam(clientX) {
  let best = null, bestD = 10; // umbral de 10px
  for (const s of $('track0').querySelectorAll('.cutSeam')) {
    const r = s.getBoundingClientRect();
    const d = Math.abs(clientX - (r.left + r.width / 2));
    if (d < bestD) { bestD = d; best = s; }
  }
  return best;
}

for (const id of ['ruler', 'markerLane', 'waveRow', 'track0', 'track1', 'track2', 'track3']) {
  $(id).addEventListener('pointerdown', (e) => {
    if (e.target.classList.contains('mpin')) {
      const mk = state.markers[+e.target.dataset.idx];
      if (mk) base.currentTime = mk.t;
      return;
    }
    const clip = e.target.closest('.clipItem');
    if (clip) {
      const k = clip.dataset.key;
      const key = k.startsWith('a') ? k : +k;
      // con la base incluida (Q/E): agarrar un asset del grupo por el cuerpo = RIPPLE del todo
      if (baseSelected && isSel(key) && !e.target.classList.contains('hd')) { startRippleDrag(e); return; }
      startItemDrag(e, clip, key);
      return;
    }
    const tr = e.target.closest('.trimRange');
    if (tr) { startTrimDrag(e, tr, +tr.dataset.tidx); return; }
    // con la base seleccionada, arrastrar la pista base = RIPPLE (agarra el lado entero y púlelo)
    if (e.currentTarget.id === 'track0' && baseSelected) { startRippleDrag(e); return; }
    // en vista corte, elegir la costura más cercana al clic (no la topmost) — track0 solamente
    if (e.currentTarget.id === 'track0' && viewMode === 'compact') {
      const seam = nearestSeam(e.clientX);
      if (seam) { startSeamDrag(e, seam, +seam.dataset.tidx); return; }
    }
    if (e.altKey) { startRangeTrim(e); return; }
    if (selKey !== null || multiSel.size || baseSelected) { clearSel(); renderTimeline(); } // click en vacío deselecciona
    seekFromEvent(e);
    const move = (ev) => seekFromEvent(ev);
    const up = () => { window.removeEventListener('pointermove', move); window.removeEventListener('pointerup', up); };
    window.addEventListener('pointermove', move);
    window.addEventListener('pointerup', up);
  });
}

// doble-click en un recorte (raw) o en una costura (corte, la más cercana) = eliminarlo (restaura)
$('track0').addEventListener('dblclick', (e) => {
  const tr = e.target.closest('.trimRange') || (viewMode === 'compact' ? nearestSeam(e.clientX) : null);
  if (!tr) return;
  pushUndo();
  state.trims.splice(+tr.dataset.tidx, 1);
  refresh();
  toast('corte eliminado: contenido restaurado · ⌘Z deshace');
});

$('playBtn').addEventListener('click', togglePlay);
function togglePlay() {
  if (base.paused) base.play().catch(() => {});
  else base.pause();
}

function buildSpeedButtons() {
  const box = $('speeds');
  for (const s of SPEEDS) {
    const b = document.createElement('button');
    b.textContent = s + 'x';
    b.dataset.speed = s;
    if (s === 1) b.classList.add('active');
    b.addEventListener('click', () => setSpeed(s));
    box.appendChild(b);
  }
}
function setSpeed(s) {
  speed = s;
  base.preservesPitch = true;
  base.playbackRate = s;
  for (const m of mounted.values()) if (m.el.tagName === 'VIDEO') m.el.playbackRate = s;
  $('speedBadge').textContent = s + 'x';
  for (const b of $('speeds').children) b.classList.toggle('active', +b.dataset.speed === s);
  for (const b of $('fsSpeeds').children) b.classList.toggle('active', +b.dataset.speed === s);
}
function cycleSpeed(dir) {
  const i = SPEEDS.indexOf(speed);
  setSpeed(SPEEDS[Math.max(0, Math.min(SPEEDS.length - 1, i + dir))]);
}

function setZoom(px, anchorT = null, anchorScreenX = null) {
  const scroll = $('timelineScroll');
  let anchor, screenX;
  if (anchorScreenX !== null) {
    // ancla en el CURSOR (pinch / ⌘+scroll): el tiempo bajo el mouse no se mueve al hacer zoom
    screenX = anchorScreenX;
    anchor = (scroll.scrollLeft + screenX) / pxPerSec;
  } else {
    // anchor vive en coordenadas del TIMELINE (out en vista corte)
    anchor = anchorT ?? tlOf(base.currentTime || 0);
    screenX = anchor * pxPerSec - scroll.scrollLeft;
  }
  // techo que ESCALA con fitPx: un techo fijo menor que fitPx dejaba el zoom inerte en proyectos cortos
  const maxPx = Math.max(120, fitPx * 8);
  pxPerSec = Math.max(fitPx, Math.min(maxPx, px));
  renderTimeline();
  scroll.scrollLeft = Math.max(0, anchor * pxPerSec - screenX);
}
$('zoomIn').addEventListener('click', () => setZoom(pxPerSec * 1.6));
$('zoomOut').addEventListener('click', () => setZoom(pxPerSec / 1.6));
$('zoomFit').addEventListener('click', () => { fitTimeline(); renderTimeline(); });

// ---------- toggle de HUECOS EN ROJO (persistido; oculto = corte compacto por default) ----------
// 'compact' = costuras (sin rojo, default) · 'raw' = los cortes se muestran como HUECOS ROJOS con
// su duración real (el "espacio vacío en rojo" que Daniel quiere ver a pedido).
function applyViewMode() {
  const compact = viewMode === 'compact';
  $('viewBtn').innerHTML = IC.scissors; // icon-only; el estado se comunica con el color (.on = rojo)
  $('viewBtn').classList.toggle('on', !compact);
  $('viewBtn').title = compact
    ? 'Mostrar los cortes como HUECOS ROJOS (el material recortado, con su hueco real). Ahora ves el corte compacto: costuras, sin rojo.'
    : 'Ocultar los huecos: volver al corte compacto (costuras, sin espacio rojo).';
}
$('viewBtn').addEventListener('click', () => {
  viewMode = viewMode === 'compact' ? 'raw' : 'compact';
  localStorage.setItem('sf.viewmode', viewMode);
  applyViewMode();
  fitTimeline();
  refresh(); // timeline + lista de marcadores (sus tiempos cambian de idioma con la vista)
  toast(viewMode === 'compact'
    ? 'huecos ocultos: corte compacto (costuras, sin rojo)'
    : 'huecos en ROJO: cada corte se ve como espacio vacío recortado');
});
applyViewMode();

// ---------- F: pantalla completa ----------
// F = el VIDEO a pantalla completa REAL (edge-to-edge), no la app entera con timeline. Fullscreen
// del #stageWrap: el navegador lo lleva a tamaño de pantalla, layoutStage recalcula el #stage a esas
// dimensiones y el <video> (object-fit: contain) llena la pantalla lo más grande posible.
function toggleFullscreen() {
  if (document.fullscreenElement || document.webkitFullscreenElement) {
    (document.exitFullscreen || document.webkitExitFullscreen).call(document);
    return;
  }
  const el = $('stageWrap');
  const req = el.requestFullscreen || el.webkitRequestFullscreen;
  if (req) {
    const p = req.call(el);
    if (p && p.catch) p.catch(() => toast('pantalla completa bloqueada por el navegador'));
  }
}
// ---------- barra de controles en pantalla completa (tipo reproductor, auto-oculta) ----------
$('fsPlay').innerHTML = IC.play;
$('fsKeys').innerHTML = IC.keyboard;
(function buildFsSpeeds() {
  const box = $('fsSpeeds');
  for (const s of SPEEDS) {
    const b = document.createElement('button');
    b.className = 'fsSpeed'; b.textContent = s + 'x'; b.dataset.speed = s;
    if (s === speed) b.classList.add('active');
    b.addEventListener('click', (e) => { e.stopPropagation(); setSpeed(s); fsShowBar(); });
    box.appendChild(b);
  }
})();
$('fsPlay').addEventListener('click', (e) => { e.stopPropagation(); togglePlay(); fsShowBar(); });
$('fsKeys').addEventListener('click', (e) => { e.stopPropagation(); $('fsHelp').hidden = !$('fsHelp').hidden; fsShowBar(); });

// scrub: la barra representa el TIMELINE (out en vista corte); click/arrastre = seek
function fsSeekTo(e) {
  const r = $('fsSeek').getBoundingClientRect();
  const frac = Math.max(0, Math.min(1, (e.clientX - r.left) / r.width));
  base.currentTime = Math.max(0, Math.min(project.duration, tlToRaw(frac * tlDur())));
}
$('fsSeek').addEventListener('pointerdown', (e) => {
  e.stopPropagation();
  fsSeekTo(e);
  const move = (ev) => { fsSeekTo(ev); fsShowBar(); };
  const up = () => { window.removeEventListener('pointermove', move); window.removeEventListener('pointerup', up); };
  window.addEventListener('pointermove', move);
  window.addEventListener('pointerup', up);
});

// auto-ocultar: la barra desaparece (con el cursor) tras inactividad si está reproduciendo
let fsHideTimer = null;
function fsShowBar() {
  if (!(document.fullscreenElement || document.webkitFullscreenElement)) return;
  const bar = $('fsBar');
  bar.hidden = false;
  bar.classList.remove('fsHidden');
  $('stageWrap').style.cursor = '';
  clearTimeout(fsHideTimer);
  fsHideTimer = setTimeout(() => {
    if ((document.fullscreenElement || document.webkitFullscreenElement) && !base.paused && $('fsHelp').hidden) {
      bar.classList.add('fsHidden');
      $('stageWrap').style.cursor = 'none';
    }
  }, 2600);
}
// click en el video (no en la barra) = play/pausa, como un reproductor
$('stageWrap').addEventListener('click', (e) => {
  if (!(document.fullscreenElement || document.webkitFullscreenElement)) return;
  if (e.target.closest('#fsBar') || e.target.closest('#fsHelp')) return;
  togglePlay(); fsShowBar();
});

// al entrar/salir de fullscreen: recomputar el escenario y prender/apagar la barra + su auto-hide
const onFsChange = () => {
  const fs = !!(document.fullscreenElement || document.webkitFullscreenElement);
  if (project) requestAnimationFrame(layoutStage);
  if (fs) {
    fsShowBar();
    $('stageWrap').addEventListener('pointermove', fsShowBar);
  } else {
    $('fsBar').hidden = true;
    $('fsHelp').hidden = true;
    $('stageWrap').style.cursor = '';
    $('stageWrap').removeEventListener('pointermove', fsShowBar);
    clearTimeout(fsHideTimer);
  }
};
document.addEventListener('fullscreenchange', onFsChange);
document.addEventListener('webkitfullscreenchange', onFsChange);

// ---------- modos estilo CapCut: 🧲 imán · 🔗 vinculación (persistidos) ----------
function renderModes() {
  $('magnetBtn').classList.toggle('active', magnetOn);
  $('linkBtn').classList.toggle('active', linkOn);
}
$('magnetBtn').addEventListener('click', () => {
  magnetOn = !magnetOn;
  localStorage.setItem('sf.magnet', magnetOn ? '1' : '0');
  renderModes();
  toast(`imán ${magnetOn ? 'ON' : 'OFF'} · ⌥ lo invierte por gesto`);
});
$('linkBtn').addEventListener('click', () => {
  linkOn = !linkOn;
  localStorage.setItem('sf.link', linkOn ? '1' : '0');
  renderModes();
  toast(linkOn ? 'vinculación ON: el recorte del base se lleva los assets adentro' : 'vinculación OFF: los recortes no tocan los assets');
});
renderModes();

// pinch de trackpad (wheel con ctrlKey en macOS) o ⌘+scroll de mouse = zoom anclado al cursor;
// rueda vertical sin modificador = pan horizontal del timeline
$('timelineScroll').addEventListener('wheel', (e) => {
  const scroll = $('timelineScroll');
  if (e.ctrlKey || e.metaKey) {
    e.preventDefault();
    const cx = e.clientX - scroll.getBoundingClientRect().left;
    setZoom(pxPerSec * Math.exp(-e.deltaY * 0.008), null, cx);
  } else if (Math.abs(e.deltaY) > Math.abs(e.deltaX)) {
    e.preventDefault();
    scroll.scrollLeft += e.deltaY;
  }
}, { passive: false });
$('timelineScroll').addEventListener('scroll', queueWave);

// ---------- resizers (sidebar + timeline), persistidos en localStorage ----------
function makeDrag(el, handlers) {
  el.addEventListener('pointerdown', (e) => {
    e.preventDefault();
    try { el.setPointerCapture(e.pointerId); } catch { /* el drag funciona igual sin captura */ }
    el.classList.add('active');
    const ctx = handlers.start(e);
    const move = (ev) => handlers.move(ev.clientX, ev.clientY, ctx);
    const up = () => {
      el.classList.remove('active');
      el.removeEventListener('pointermove', move);
      el.removeEventListener('pointerup', up);
      if (handlers.end) handlers.end(ctx);
    };
    el.addEventListener('pointermove', move);
    el.addEventListener('pointerup', up);
  });
}
function cssVarPx(name, fallback) {
  const v = parseFloat(getComputedStyle(document.documentElement).getPropertyValue(name));
  return Number.isFinite(v) ? v : fallback;
}
function initResizers() {
  const root = document.documentElement;
  const sw = parseFloat(localStorage.getItem('sf.sidebarW'));
  if (Number.isFinite(sw)) $('sidebar').style.width = Math.min(520, Math.max(180, sw)) + 'px';
  const wh = parseFloat(localStorage.getItem('sf.waveH'));
  if (Number.isFinite(wh)) root.style.setProperty('--waveH', Math.min(160, Math.max(28, wh)) + 'px');
  const bh = parseFloat(localStorage.getItem('sf.baseH'));
  if (Number.isFinite(bh)) root.style.setProperty('--baseH', Math.min(100, Math.max(40, bh)) + 'px');

  makeDrag($('dragSidebar'), {
    start: (e) => ({ x0: e.clientX, w0: $('sidebar').getBoundingClientRect().width }),
    move: (x, _y, c) => {
      $('sidebar').style.width = Math.min(520, Math.max(180, c.w0 - (x - c.x0))) + 'px';
      layoutStage();
    },
    end: () => {
      localStorage.setItem('sf.sidebarW', parseFloat($('sidebar').style.width));
      fitTimeline(false); renderTimeline();
    },
  });
  makeDrag($('dragTimeline'), {
    start: (e) => ({ y0: e.clientY, w0: cssVarPx('--waveH', 44), b0: cssVarPx('--baseH', 46) }),
    move: (_x, y, c) => {
      const d = c.y0 - y; // arrastrar hacia arriba agranda el timeline
      root.style.setProperty('--waveH', Math.min(160, Math.max(28, c.w0 + d * 0.6)) + 'px');
      root.style.setProperty('--baseH', Math.min(100, Math.max(40, c.b0 + d * 0.4)) + 'px');
      layoutStage(); queueWave();
    },
    end: () => {
      localStorage.setItem('sf.waveH', cssVarPx('--waveH', 44));
      localStorage.setItem('sf.baseH', cssVarPx('--baseH', 46));
      renderTimeline();
    },
  });
}

// ---------- marcadores ----------
function openMarkerPopover(t) {
  base.pause();
  const pop = $('popover');
  const input = $('popInput');
  pop.hidden = false;
  const x = Math.min(window.innerWidth - 320, Math.max(8, XT(t) - $('timelineScroll').scrollLeft));
  pop.style.left = `${x}px`;
  pop.style.bottom = '210px';
  input.value = '';
  input.focus();
  const done = (save) => {
    pop.hidden = true;
    input.onkeydown = null;
    input.blur(); // sin esto el foco queda en el input oculto y el teclado global se ignora
    if (save) {
      pushUndo();
      state.markers.push({ t: Math.round(t * 1000) / 1000, nota: input.value.trim() });
      state.markers.sort((a, b) => a.t - b.t);
      refresh();
      toast(`marcador @ ${fmt(t)}`);
    }
  };
  input.onkeydown = (e) => {
    e.stopPropagation();
    if (e.key === 'Enter') done(true);
    if (e.key === 'Escape') done(false);
  };
}

// ---------- export ----------
async function exportFixes() {
  const fixes = toFixes(state, project.base.src, { project: project.name, duration: project.duration });
  let savedPath = '(no guardado en disco)';
  try {
    const r = await fetch('/api/fixes', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(fixes) });
    const j = await r.json();
    if (j.ok) savedPath = j.path;
  } catch { /* modal igual muestra el JSON */ }
  $('modalBody').textContent = JSON.stringify(fixes, null, 2);
  $('modalPath').textContent = savedPath;
  $('modal').hidden = false;
}
$('exportBtn').addEventListener('click', exportFixes);
$('modalClose').addEventListener('click', () => { $('modal').hidden = true; });
$('modal').addEventListener('pointerdown', (e) => { if (e.target === $('modal')) $('modal').hidden = true; });

// ---------- panel ⌘Y: el DOSSIER del lanzamiento (SFPublish) ----------
// Pantalla completa. Espejo AI-first del TRABAJO, no solo del estado: transcript con timestamps,
// descripción/títulos/keywords, miniaturas A/B, menciones, horario y upload. Lo escriben los
// comandos sfpublish (los corre el agente); las decisiones se toman CONVERSANDO. CERO forms.
let ppTimer = null;
let ppTranscriptOk = false; // solo el ÉXITO se cachea; un "sin transcript" se reintenta al reabrir
let ppLastPub = null;       // último publish.json pintado (fuente de los botones de copiar)
let ppLastTr = null;        // último transcript pintado

// --- rail de secciones: prender/apagar columnas, layout responsivo 1-2-3, persistido
const PP_COLS = ['tr', 'meta', 'launch'];
const PP_W = { tr: 1.05, meta: 1.1, launch: 0.95 };
let ppView = (() => {
  try { return { tr: true, meta: true, launch: true, ...JSON.parse(localStorage.getItem('sf.pp.view') || '{}') }; }
  catch { return { tr: true, meta: true, launch: true }; }
})();
function applyPpView() {
  const on = PP_COLS.filter((c) => ppView[c]);
  for (const col of document.querySelectorAll('#ppGrid .ppCol')) {
    const visible = !!ppView[col.dataset.col];
    col.style.display = visible ? '' : 'none';
    col.classList.toggle('solo', visible && on.length === 1);
  }
  $('ppGrid').style.gridTemplateColumns = on.map((c) => PP_W[c] + 'fr').join(' ');
  for (const b of document.querySelectorAll('.ppRailBtn')) b.classList.toggle('on', !!ppView[b.dataset.col]);
  localStorage.setItem('sf.pp.view', JSON.stringify(ppView));
}
for (const b of document.querySelectorAll('.ppRailBtn')) {
  b.addEventListener('click', () => {
    const c = b.dataset.col;
    if (ppView[c] && PP_COLS.filter((x) => ppView[x]).length === 1) {
      toast('al menos una sección prendida');
      return;
    }
    ppView[c] = !ppView[c];
    applyPpView();
  });
}
applyPpView();

// --- copiar: el dossier es espejo, pero lo que muestra se LLEVA (a YouTube, a Skool, a donde sea)
// Iconos: Lucide (lucide.dev, ISC) — SVG inline oficial de `copy` y `check`; cero dependencias.
const ICON_COPY = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect width="14" height="14" x="8" y="8" rx="2" ry="2"/><path d="M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2"/></svg>';
const ICON_CHECK = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M20 6 9 17l-5-5"/></svg>';
for (const b of document.querySelectorAll('.ppCopy')) b.innerHTML = ICON_COPY;

async function ppCopy(text, what, btn = null) {
  if (!text) { toast(`nada que copiar aún en ${what}`); return; }
  try {
    await navigator.clipboard.writeText(text);
    toast(`${what} copiado ✓`);
    if (btn) {
      btn.innerHTML = ICON_CHECK;
      btn.classList.add('ok');
      setTimeout(() => { btn.innerHTML = ICON_COPY; btn.classList.remove('ok'); }, 1400);
    }
  } catch { toast('no pude copiar (permiso del navegador)'); }
}
$('copyTranscript').addEventListener('click', (e) =>
  ppCopy(ppLastTr?.segments?.map((s) => s.text).join('\n\n'), 'transcript', e.currentTarget));
$('copyTitles').addEventListener('click', (e) =>
  ppCopy((ppLastPub?.data?.metadata?.titles || []).join('\n'), 'títulos', e.currentTarget));
$('copyDesc').addEventListener('click', (e) =>
  ppCopy(ppLastPub?.data?.metadata?.description, 'descripción', e.currentTarget));
$('copyKeywords').addEventListener('click', (e) =>
  ppCopy((ppLastPub?.data?.metadata?.keywords || []).join(', '), 'keywords', e.currentTarget));
$('copyPost').addEventListener('click', (e) =>
  ppCopy(ppLastPub?.data?.post, 'post', e.currentTarget));
$('ppTitles').addEventListener('click', (e) => {
  const btn = e.target.closest('.ppTitleCopy');
  if (btn) ppCopy(ppLastPub?.data?.metadata?.titles?.[+btn.dataset.idx], 'título', btn);
});
function togglePublishPanel() {
  const panel = $('publishPanel');
  if (panel.hidden) {
    panel.hidden = false;
    refreshPublish();
    loadTranscript();
    ppTimer = setInterval(refreshPublish, 2000); // el agente escribe, el dossier refleja
  } else {
    panel.hidden = true;
    clearInterval(ppTimer);
    ppTimer = null;
  }
}
async function refreshPublish() {
  try {
    renderPublish(await (await fetch('/api/publish')).json());
    loadThumbs(); // la galería también refleja en vivo (el agente genera candidatas mientras miras)
  } catch { /* server fuera: el panel conserva lo último pintado */ }
}
async function loadTranscript() {
  if (ppTranscriptOk) return; // el corte final no cambia; los fallos SÍ se reintentan
  try {
    const tr = await (await fetch('/api/transcript')).json();
    ppTranscriptOk = !!tr.found;
    renderTranscript(tr);
  } catch { renderTranscript({ found: false }); }
}
async function loadThumbs() {
  try {
    renderThumbs(await (await fetch('/api/thumbs')).json());
  } catch { /* mantiene lo pintado */ }
}
function ppAgo(iso) {
  if (!iso) return '';
  const s = (Date.now() - new Date(iso).getTime()) / 1000;
  if (s < 90) return 'hace un momento';
  if (s < 3600) return `hace ${Math.round(s / 60)} min`;
  if (s < 86400) return `hace ${Math.round(s / 3600)} h`;
  return new Date(iso).toLocaleString('es-MX', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' });
}
function escapeHtml(s) {
  // comillas incluidas: hay usos en contexto de ATRIBUTO (alt de thumbs) — sin esto, un filename
  // con comilla inyecta atributos arbitrarios (hallazgo de la revisión adversarial 19 jul)
  return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

// --- transcript: párrafos con timestamp clickeable (seek del video de la sala, que vive detrás)
function renderTranscript(tr) {
  ppLastTr = tr;
  const box = $('ppTranscript');
  box.innerHTML = '';
  if (!tr.found || !tr.segments?.length) {
    box.innerHTML = '<div class="ppEmptyBlock">sin transcript word-level en el proyecto.<br>Pídele a Levy que lo transcriba (MLX Whisper → <code>edit/transcripts/*.json</code>) — al reabrir el dossier aparece.</div>';
    $('ppTrMeta').textContent = '';
    return;
  }
  const drift = Math.round(Math.abs(tr.duration - project.duration));
  $('ppTrMeta').textContent = `${tr.words.toLocaleString('es-MX')} palabras · ${Math.round(tr.duration / 60)} min · ` +
    (tr.cut === 'final'
      ? `CORTE FINAL${drift > 5 ? ` (deriva ≈${drift}s vs máster: hubo fix passes post-EDL)` : ''}`
      : '⚠ RAW (sin EDL: los tiempos pueden no coincidir con el corte)');
  const frag = document.createDocumentFragment();
  for (const s of tr.segments) {
    const d = document.createElement('div');
    d.className = 'ppSeg';
    d.innerHTML = `<span class="ppSegT" data-t="${s.t}">${fmt(s.t)}</span><span class="ppSegTx">${escapeHtml(s.text)}</span>`;
    frag.appendChild(d);
  }
  box.appendChild(frag);
}
$('ppTranscript').addEventListener('click', (e) => {
  const t = e.target.closest('.ppSegT')?.dataset.t;
  if (t !== undefined) {
    base.currentTime = Math.min(project.duration, +t);
    // ⇧click = "ver este momento": seek + cerrar el dossier (el video vive detrás, a pantalla llena)
    if (e.shiftKey) togglePublishPanel();
    else toast(`video → ${fmt(+t)} · ⇧click para verlo`);
  }
});

// --- miniaturas candidatas (A/B): <proyecto>/thumbs/*.png|jpg — las genera el agente
function renderThumbs(j) {
  const box = $('ppThumbs');
  box.innerHTML = '';
  if (!j.found || !j.files?.length) {
    box.innerHTML = '<div class="ppEmptyBlock">sin candidatas aún.<br>Pídele a Levy 2-3 miniaturas (skill <b>youtube-thumbnails</b>) → van a <code>&lt;proyecto&gt;/thumbs/</code> y aparecen aquí para el A/B de YouTube.</div>';
    return;
  }
  for (const f of j.files) {
    const d = document.createElement('figure');
    d.className = 'ppThumb';
    d.innerHTML = `<img src="/thumbs/${encodeURIComponent(f)}" alt="${escapeHtml(f)}" loading="lazy"><figcaption>${escapeHtml(f)}</figcaption>`;
    box.appendChild(d);
  }
}

// --- el resto del dossier (se repinta con cada poll; el transcript NO se toca)
function renderPublish(j) {
  const stages = j.stages || [];
  const proj = j.project || '<proyecto>';
  const stepper = $('ppStepper');
  if (!j.found) {
    $('ppSlug').textContent = 'sin publish.json';
    stepper.innerHTML = '';
    $('ppTitles').innerHTML = `<div class="ppEmptyBlock">este proyecto aún no arranca la etapa 2.<br>Pídele a Levy que la arranque, o:<br><code>node bin/sfpublish.js ${escapeHtml(proj)} init</code></div>`;
    for (const id of ['ppDesc', 'ppKeywords', 'ppPost', 'ppMentions', 'ppSchedule', 'ppGate', 'ppUpload']) $(id).innerHTML = '';
    $('ppLinkState').textContent = '';
    return;
  }
  const pub = j.publish;
  ppLastPub = pub;
  const md = pub.data?.metadata || {};
  $('ppSlug').textContent = pub.video?.slug || '';

  // stepper de etapas (hover = evidencia + hace cuánto)
  stepper.innerHTML = '';
  for (const s of stages) {
    const st = pub.stages?.[s] || { status: 'pending' };
    const chip = document.createElement('span');
    chip.className = `ppStep ${st.status}`;
    chip.textContent = s;
    chip.title = `${st.status}${st.evidence ? ` — ${st.evidence}` : ''}${st.updated_at ? ` (${ppAgo(st.updated_at)})` : ''}`;
    stepper.appendChild(chip);
  }

  // títulos: el elegido (video.titulo) lleva badge
  const tbox = $('ppTitles');
  tbox.innerHTML = '';
  const titles = md.titles || [];
  if (!titles.length) tbox.innerHTML = '<div class="ppEmptyBlock">sin títulos aún — corre la etapa <b>metadata</b>.</div>';
  titles.forEach((t, i) => {
    const el = document.createElement('div');
    const chosen = t === pub.video?.titulo;
    el.className = 'ppTitle' + (chosen ? ' chosen' : '');
    el.innerHTML = `<span class="ppTitleTx">${escapeHtml(t)}</span><span class="ppTitleMeta">${chosen ? 'ELEGIDO · ' : ''}${t.length}/60</span>` +
      `<button class="ppCopy ppTitleCopy" data-idx="${i}" title="copiar este título">${ICON_COPY}</button>`;
    tbox.appendChild(el);
  });

  // descripción completa, con el /go/ resaltado; estado del link junto al header
  const desc = md.description || '';
  $('ppDesc').innerHTML = desc
    ? escapeHtml(desc).replace(/(https?:\/\/\S*\/go\/[a-z0-9-]+)/g, '<span class="ppGo">$1</span>')
    : '<div class="ppEmptyBlock">sin descripción aún.</div>';
  const link = pub.data?.link;
  $('ppLinkState').textContent = link ? (link.verified ? `/go/ verificado ✓ ${link.status} + cookies` : `/go/ SIN verificar (${link.status})`) : '';
  $('ppLinkState').className = 'ppHmeta ' + (link?.verified ? 'ok' : link ? 'bad' : '');

  // keywords + post
  $('ppKeywords').innerHTML = (md.keywords || []).map((k) => `<span class="ppChip">${escapeHtml(k)}</span>`).join('') ||
    '<div class="ppEmptyBlock">sin keywords aún.</div>';
  $('ppPost').innerHTML = pub.data?.post ? escapeHtml(pub.data.post) : '<div class="ppEmptyBlock">sin post aún — etapa <b>post</b>.</div>';

  // menciones → tarjetas (t clickeable, mismo seek que el transcript)
  const ment = pub.data?.mentions;
  const mbox = $('ppMentions');
  if (!ment) mbox.innerHTML = '<div class="ppEmptyBlock">sin correr aún — etapa <b>mentions</b>.</div>';
  else if (!ment.length) {
    mbox.innerHTML = `<div class="ppEmptyBlock">0 menciones textuales (0 falsos positivos &gt; cobertura).${pub.data?.endScreen ? `<br>end screen sugerida: <b>${escapeHtml(pub.data.endScreen.titulo)}</b>` : ''}</div>`;
  } else {
    mbox.innerHTML = ment.map((m) => `<div class="ppMention"><span class="ppSegT" data-t="${m.t}">${fmt(m.t)}</span>` +
      `<span class="ppMentionTx"><b>${escapeHtml(m.titulo)}</b><br><i>"${escapeHtml(m.frase_detectada)}"</i></span></div>`).join('') +
      (pub.data?.endScreen ? `<div class="ppEmptyBlock">end screen: <b>${escapeHtml(pub.data.endScreen.titulo)}</b></div>` : '');
  }

  // horario sugerido
  const sch = pub.data?.schedule;
  $('ppSchedule').innerHTML = sch?.candidates
    ? sch.candidates.map((c) => `<div class="ppSlot${c.lunes ? ' lunes' : ''}">${c.lunes ? '★' : '·'} ${escapeHtml(c.local)}${c.lunes ? ' — LUNES' : ''}</div>`).join('')
    : '<div class="ppEmptyBlock">sin correr aún — etapa <b>schedule</b>.</div>';

  // gate + upload (estado vivo con evidencia)
  const gate = pub.stages?.checklist;
  $('ppGate').innerHTML = gate?.updated_at
    ? `<div class="ppState ${gate.status}">${escapeHtml(gate.evidence || gate.status)}</div>`
    : '<div class="ppEmptyBlock">sin correr aún — etapa <b>checklist</b>.</div>';
  const up = pub.stages?.upload;
  $('ppUpload').innerHTML = up?.updated_at
    ? `<div class="ppState ${up.status}">${escapeHtml(up.evidence || up.status)}</div>`
    : '<div class="ppEmptyBlock">todavía nada — etapa <b>upload</b> (siempre queda en PRIVADO).</div>';
}
$('ppMentions').addEventListener('click', (e) => {
  const t = e.target.closest('.ppSegT')?.dataset.t;
  if (t !== undefined) {
    base.currentTime = Math.min(project.duration, +t);
    if (e.shiftKey) togglePublishPanel();
    else toast(`video → ${fmt(+t)} · ⇧click para verlo`);
  }
});
$('ppClose').addEventListener('click', togglePublishPanel);

let toastTimer = null;
function toast(msg) {
  const t = $('toast');
  t.textContent = msg;
  t.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { t.hidden = true; }, 1800);
}

// ---------- teclado ----------
// S/A/D operan sobre el COMPONENTE SELECCIONADO; sin selección, el default es la línea base.
window.addEventListener('keydown', (e) => {
  if (!project) return;
  if (document.activeElement && document.activeElement.tagName === 'INPUT') return;
  const t = base.currentTime || 0;
  const frame = 1 / (project.fps || 30);
  const k = e.key.toLowerCase();

  // dossier (⌘Y) / modal de export (⌘E) abiertos = ESPEJO a pantalla completa: bloquear TODAS
  // las teclas del timeline (incl. ⌘Z) menos las que los cierran, para no mutar el proyecto detrás
  if (!$('modal').hidden) { if (k === 'escape') $('modal').hidden = true; return; }
  if (!$('publishPanel').hidden) { if (k === 'escape' || k === 'y') { e.preventDefault(); togglePublishPanel(); } return; }
  // el panel de atajos NO bloquea teclas (es referencia); solo Esc lo cierra
  if (!$('helpPanel').hidden && k === 'escape') { toggleHelpPanel(false); return; }

  if ((e.metaKey || e.ctrlKey) && k === 'z') {
    e.preventDefault();
    if (e.shiftKey) redo(); else undo();
    return;
  }
  if ((e.metaKey || e.ctrlKey) && k === 'y') { e.preventDefault(); togglePublishPanel(); return; }
  if ((e.metaKey || e.ctrlKey) && k === 'e') { e.preventDefault(); exportFixes(); return; }
  // ⌥←/⌥→ = mover el item seleccionado 1 frame (⇧×10); las flechas solas SIEMPRE son playhead
  if (e.altKey && !e.metaKey && !e.ctrlKey && (k === 'arrowleft' || k === 'arrowright')) {
    e.preventDefault();
    nudgeSelectedItem((k === 'arrowright' ? 1 : -1) * frame * (e.shiftKey ? 10 : 1));
    return;
  }
  if (e.metaKey || e.ctrlKey || e.altKey) return;

  switch (k) {
    case ' ': e.preventDefault(); togglePlay(); break;
    case 's':
      // con selección (única o grupo): parte cada asset en el playhead; sin selección: split del base
      if (!itemOpOverSelection((kk) => splitItemAt(state, project.items, kk, t), (n) => `${n} asset(s) partido(s) @ ${fmt(t)}`)) {
        pushUndo();
        if (addSplit(state, t, project.duration)) { refresh(); toast(`split @ ${fmt(t)}`); } else undoStack.pop();
      }
      break;
    case 'a':
      if (!itemOpOverSelection((kk) => trimItemTo(state, project.items, kk, t, 'l'), (n) => `${n} asset(s): trim ← al playhead`)) {
        const p = prevBoundary(state, t, project.duration);
        pushUndo();
        if (trimLeft(state, t, project.duration)) {
          const n = applyLinkedRemoval(p, t);
          validateSel();
          refresh();
          toast(`recorte ←${n ? ` · ${n} asset(s) adentro eliminados 🔗` : ''}`);
        } else undoStack.pop();
      }
      break;
    case 'd':
      if (!itemOpOverSelection((kk) => trimItemTo(state, project.items, kk, t, 'r'), (n) => `${n} asset(s): trim → al playhead`)) {
        const n2 = nextBoundary(state, t, project.duration);
        pushUndo();
        if (trimRight(state, t, project.duration)) {
          const n = applyLinkedRemoval(t, n2);
          validateSel();
          refresh();
          toast(`recorte →${n ? ` · ${n} asset(s) adentro eliminados 🔗` : ''}`);
        } else undoStack.pop();
      }
      break;
    case 'm': openMarkerPopover(t); break;
    case 'q': selectSide(-1); break; // seleccionar TODO a la izquierda del cursor
    case 'e': selectSide(1); break;  // seleccionar TODO a la derecha del cursor
    case 'f': toggleFullscreen(); break;
    case 'y': togglePublishPanel(); break;
    case ',': case '<': cycleSpeed(-1); break;
    case '.': case '>': cycleSpeed(1); break;
    case 'backspace': case 'delete': if (selectedKeys().length) { e.preventDefault(); removeSelectedItem(); } break;
    case 'escape': if (selKey !== null || multiSel.size || baseSelected) { clearSel(); renderTimeline(); } break;
    case 'arrowup': e.preventDefault(); navigateBlocks(1); break;    // siguiente bloque (CapCut)
    case 'arrowdown': e.preventDefault(); navigateBlocks(-1); break; // bloque anterior
    // ←/→ avanzan en el tiempo del TIMELINE: en vista corte el paso SALTA los trims
    case 'arrowleft': e.preventDefault(); base.currentTime = Math.max(0, tlToRaw(Math.max(0, tlOf(t) - frame * (e.shiftKey ? 10 : 1)))); break;
    case 'arrowright': e.preventDefault(); base.currentTime = Math.min(project.duration, tlToRaw(Math.min(tlDur(), tlOf(t) + frame * (e.shiftKey ? 10 : 1)))); break;
    default: break;
  }
});

boot();
