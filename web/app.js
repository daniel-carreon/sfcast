// SFStudio — Sala de Revisión. AI-first: la sala es para VER, RECORTAR fino (S/A/D) y ANOTAR;
// los recortes/notas vuelven a la fábrica como fixes.json. Nada se re-renderiza aquí.
import {
  newState, cloneState, mergeRanges, addSplit, trimLeft, trimRight,
  skipTarget, totalTrimmed, toFixes, fromFixes,
} from './model.js';

const $ = (id) => document.getElementById(id);
const base = $('base');
const SPEEDS = [1, 1.25, 1.5, 2];

let project = null;
let state = newState();
const undoStack = [];
let pxPerSec = 1;       // zoom del timeline
let fitPx = 1;
let mounted = new Map(); // id → {el, item}
let speed = 1;

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
      if (fx && (fx.trims || fx.markers)) state = fromFixes(fx);
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
  const t0 = scroll.scrollLeft / pxPerSec;
  ctx.fillStyle = 'rgba(255,145,1,.72)';
  for (let x = 0; x < W; x++) {
    const bA = Math.floor((t0 + x / pxPerSec) * wave.rate);
    if (bA * 2 >= wave.peaks.length) break;
    const bB = Math.max(bA + 1, Math.floor((t0 + (x + 1) / pxPerSec) * wave.rate));
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
function syncOverlays(t, playing) {
  for (let idx = 0; idx < project.items.length; idx++) {
    const it = project.items[idx];
    const inWindow = t >= it.start - WINDOW && t < it.start + it.dur + WINDOW;
    // clave = índice del array, NO it.id: los ids de negocio pueden repetirse y colisionarían
    let m = mounted.get(idx);
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
      m = { el, item: it };
      mounted.set(idx, m);
    } else if (!inWindow && m) {
      if (m.el.tagName === 'VIDEO') { try { m.el.pause(); } catch { /* ok */ } m.el.removeAttribute('src'); m.el.load(); }
      m.el.remove();
      mounted.delete(idx);
      continue;
    }
    if (!m) continue;
    const local = t - it.start;
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
    $('playhead').style.transform = `translateX(${t * pxPerSec}px)`;
    $('timecode').textContent = `${fmt(t)} / ${fmt(project.duration)}`;
    $('playBtn').textContent = playing ? '⏸' : '▶';
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
  const w = $('timelineScroll').clientWidth - 4;
  fitPx = Math.max(0.01, w / project.duration);
  if (reset) pxPerSec = fitPx;
}

function renderTimeline() {
  const W = Math.max(project.duration * pxPerSec, $('timelineScroll').clientWidth - 4);
  $('timeline').style.width = `${W}px`;
  const X = (t) => t * pxPerSec;

  // ruler
  const ruler = $('ruler');
  ruler.innerHTML = '';
  const steps = [0.5, 1, 2, 5, 10, 30, 60, 120, 300, 600];
  const step = steps.find((s) => s * pxPerSec >= 70) || 600;
  for (let t = 0; t <= project.duration; t += step) {
    const d = document.createElement('div');
    d.className = 'tick';
    d.style.left = `${X(t)}px`;
    d.textContent = fmt(t);
    ruler.appendChild(d);
  }

  // pins de marcadores
  const lane = $('markerLane');
  lane.innerHTML = '';
  state.markers.forEach((mk, i) => {
    const p = document.createElement('div');
    p.className = 'mpin';
    p.style.left = `${X(mk.t)}px`;
    p.title = mk.nota;
    p.dataset.idx = i;
    lane.appendChild(p);
  });

  // items por track
  for (const tr of [1, 2, 3]) {
    const el = $('track' + tr);
    el.innerHTML = '';
    for (const it of project.items.filter((i) => (i.track || 1) === tr)) {
      const d = document.createElement('div');
      d.className = `clipItem t${tr}`;
      d.style.left = `${X(it.start)}px`;
      d.style.width = `${Math.max(2, (it.dur * pxPerSec) - 1)}px`;
      d.title = `${it.id} · ${it.start}s +${it.dur}s`;
      if (it.dur * pxPerSec > 34) d.textContent = it.id;
      el.appendChild(d);
    }
  }

  // base: segmentos + trims tachados + splits
  const bt = $('track0');
  bt.innerHTML = '';
  const merged = mergeRanges(state.trims);
  let cursor = 0;
  const segs = [];
  for (const r of merged) {
    if (r.start > cursor) segs.push([cursor, r.start]);
    cursor = r.end;
  }
  if (cursor < project.duration) segs.push([cursor, project.duration]);
  for (const [a, b] of segs) {
    const d = document.createElement('div');
    d.className = 'baseSeg';
    d.style.left = `${X(a)}px`;
    d.style.width = `${Math.max(1, (b - a) * pxPerSec - 1)}px`;
    bt.appendChild(d);
  }
  for (const r of merged) {
    const d = document.createElement('div');
    d.className = 'trimRange';
    d.style.left = `${X(r.start)}px`;
    d.style.width = `${Math.max(2, (r.end - r.start) * pxPerSec - 1)}px`;
    d.title = `recorte ${r.start}s → ${r.end}s (⌘Z deshace)`;
    bt.appendChild(d);
  }
  for (const s of state.splits) {
    const d = document.createElement('div');
    d.className = 'splitLine';
    d.style.left = `${X(s)}px`;
    bt.appendChild(d);
  }

  const cut = totalTrimmed(state.trims);
  $('trimSummary').innerHTML = state.trims.length
    ? `<b>${cut.toFixed(1)}s</b> recortados en ${mergeRanges(state.trims).length} rango(s) · dur final ${fmt(project.duration - cut)}`
    : 'sin recortes';
  queueWave();
}

function renderMarkers() {
  const ol = $('markerList');
  ol.innerHTML = '';
  state.markers.forEach((mk, i) => {
    const li = document.createElement('li');
    const del = document.createElement('button');
    del.className = 'mdel'; del.textContent = '✕'; del.title = 'borrar marcador';
    del.addEventListener('click', (e) => { e.stopPropagation(); pushUndo(); state.markers.splice(i, 1); refresh(); });
    const t = document.createElement('div'); t.className = 'mt'; t.textContent = fmt(mk.t);
    const n = document.createElement('div'); n.className = 'mnota'; n.textContent = mk.nota || '(sin nota)';
    li.append(del, t, n);
    li.addEventListener('click', () => { base.currentTime = mk.t; });
    ol.appendChild(li);
  });
}

function refresh() { renderTimeline(); renderMarkers(); }

// ---------- undo ----------
function pushUndo() {
  undoStack.push(cloneState(state));
  if (undoStack.length > 100) undoStack.shift();
}
function undo() {
  const prev = undoStack.pop();
  if (prev) { state = prev; refresh(); toast('deshecho'); }
}

// ---------- interacción ----------
function seekFromEvent(e) {
  const rect = $('timeline').getBoundingClientRect();
  const t = Math.max(0, Math.min(project.duration, (e.clientX - rect.left) / pxPerSec));
  base.currentTime = t;
}
for (const id of ['ruler', 'markerLane', 'waveRow', 'track0', 'track1', 'track2', 'track3']) {
  $(id).addEventListener('pointerdown', (e) => {
    if (e.target.classList.contains('mpin')) {
      const mk = state.markers[+e.target.dataset.idx];
      if (mk) base.currentTime = mk.t;
      return;
    }
    seekFromEvent(e);
    const move = (ev) => seekFromEvent(ev);
    const up = () => { window.removeEventListener('pointermove', move); window.removeEventListener('pointerup', up); };
    window.addEventListener('pointermove', move);
    window.addEventListener('pointerup', up);
  });
}

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
    anchor = anchorT ?? (base.currentTime || 0);
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
  const x = Math.min(window.innerWidth - 320, Math.max(8, t * pxPerSec - $('timelineScroll').scrollLeft));
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
window.addEventListener('keydown', (e) => {
  if (!project) return;
  if (document.activeElement && document.activeElement.tagName === 'INPUT') return;
  const t = base.currentTime || 0;
  const frame = 1 / (project.fps || 30);
  const k = e.key.toLowerCase();

  if ((e.metaKey || e.ctrlKey) && k === 'z') { e.preventDefault(); undo(); return; }
  if ((e.metaKey || e.ctrlKey) && k === 'y') { e.preventDefault(); togglePublishPanel(); return; }
  if (e.metaKey || e.ctrlKey || e.altKey) return;

  switch (k) {
    case ' ': e.preventDefault(); togglePlay(); break;
    case 's': pushUndo(); if (addSplit(state, t, project.duration)) { refresh(); toast(`split @ ${fmt(t)}`); } else undoStack.pop(); break;
    case 'a': pushUndo(); if (trimLeft(state, t, project.duration)) { refresh(); toast('recorte ←'); } else undoStack.pop(); break;
    case 'd': pushUndo(); if (trimRight(state, t, project.duration)) { refresh(); toast('recorte →'); } else undoStack.pop(); break;
    case 'm': openMarkerPopover(t); break;
    case 'e': exportFixes(); break;
    case 'y': togglePublishPanel(); break;
    case ',': case '<': cycleSpeed(-1); break;
    case '.': case '>': cycleSpeed(1); break;
    case 'arrowleft': e.preventDefault(); base.currentTime = Math.max(0, t - frame * (e.shiftKey ? 10 : 1)); break;
    case 'arrowright': e.preventDefault(); base.currentTime = Math.min(project.duration, t + frame * (e.shiftKey ? 10 : 1)); break;
    default: break;
  }
});

boot();
