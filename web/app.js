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

// ---------- panel ⌘Y (SFPublish) ----------
// Espejo AI-first del pipeline post-edición: LEE publish.json (lo escriben los comandos sfpublish
// que corre el agente) y lo pinta. CERO forms: si una etapa pide decisión humana, se decide
// CONVERSANDO con Levy, no clickeando aquí.
const PP_ICON = { done: '●', running: '◐', error: '●', partial: '◐', pending: '○' };
let ppTimer = null;
function togglePublishPanel() {
  const panel = $('publishPanel');
  if (panel.hidden) {
    panel.hidden = false;
    refreshPublish();
    ppTimer = setInterval(refreshPublish, 2000); // poll: el agente escribe, el panel refleja
  } else {
    panel.hidden = true;
    clearInterval(ppTimer);
    ppTimer = null;
  }
}
async function refreshPublish() {
  try {
    renderPublish(await (await fetch('/api/publish')).json());
  } catch { /* server fuera: el panel conserva lo último pintado */ }
}
function ppAgo(iso) {
  if (!iso) return '';
  const s = (Date.now() - new Date(iso).getTime()) / 1000;
  if (s < 90) return 'hace un momento';
  if (s < 3600) return `hace ${Math.round(s / 60)} min`;
  if (s < 86400) return `hace ${Math.round(s / 3600)} h`;
  return new Date(iso).toLocaleString('es-MX', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' });
}
function renderPublish(j) {
  const box = $('ppStages');
  const stages = j.stages || [];
  const cmds = j.commands || {};
  const proj = j.project || '<proyecto>';
  if (!j.found) {
    $('ppSlug').textContent = '';
    box.innerHTML = '';
    const d = document.createElement('div');
    d.className = 'ppEmpty';
    d.innerHTML = `sin <b>publish.json</b> en este proyecto.<br>Pídele a Levy que arranque la etapa 2, o corre:<br><code>node bin/sfpublish.js ${proj} init</code>`;
    box.appendChild(d);
    return;
  }
  const pub = j.publish;
  $('ppSlug').textContent = `${pub.video?.slug || ''}${pub.video?.titulo ? ` · ${pub.video.titulo}` : ''}`;
  box.innerHTML = '';
  for (const s of stages) {
    const st = pub.stages?.[s] || { status: 'pending', evidence: '', updated_at: null };
    const card = document.createElement('div');
    card.className = `ppStage ${st.status}`;
    const cmd = (cmds[s] || '').replace('<proyecto>', proj);
    card.innerHTML = `
      <span class="ppDot">${PP_ICON[st.status] || '○'}</span>
      <div class="ppBody">
        <div class="ppRow"><span class="ppName">${s}</span><span class="ppTime">${ppAgo(st.updated_at)}</span></div>
        <div class="ppEv">${st.evidence ? escapeHtml(st.evidence) : '<i>pendiente</i>'}</div>
        <code class="ppCmd" title="el comando que corre el agente para esta etapa">${escapeHtml(cmd)}</code>
      </div>`;
    box.appendChild(card);
  }
}
function escapeHtml(s) {
  return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}
$('ppClose').addEventListener('click', togglePublishPanel);
$('publishPanel').addEventListener('pointerdown', (e) => { if (e.target === $('publishPanel')) togglePublishPanel(); });

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
