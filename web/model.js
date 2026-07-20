// Modelo puro de la Sala de Revisión: splits, trims no destructivos, marcadores,
// y ediciones de items (mover / trim de bordes / eliminar overlays del timeline).
// SIN DOM — importable por node --test y por el browser (ESM).
const EPS = 1e-4;
const MIN_ITEM_DUR = 0.1;

export function newState() {
  return { splits: [], trims: [], markers: [], items: {} };
}

export function cloneState(s) {
  return JSON.parse(JSON.stringify(s));
}

/** Ordena y fusiona rangos solapados/adyacentes. */
export function mergeRanges(ranges) {
  const sorted = [...ranges]
    .filter((r) => r.end - r.start > EPS)
    .sort((a, b) => a.start - b.start);
  const out = [];
  for (const r of sorted) {
    const last = out[out.length - 1];
    if (last && r.start <= last.end + EPS) last.end = Math.max(last.end, r.end);
    else out.push({ start: r.start, end: r.end });
  }
  return out;
}

/** Fronteras de segmento del base: 0, splits, bordes de trims, duración. */
export function boundaries(state, duration) {
  const b = new Set([0, duration]);
  for (const s of state.splits) if (s > EPS && s < duration - EPS) b.add(s);
  for (const t of mergeRanges(state.trims)) {
    if (t.start > EPS) b.add(t.start);
    if (t.end < duration - EPS) b.add(t.end);
  }
  return [...b].sort((x, y) => x - y);
}

export function prevBoundary(state, t, duration) {
  const bs = boundaries(state, duration);
  let p = 0;
  for (const b of bs) if (b < t - EPS) p = b;
  return p;
}

export function nextBoundary(state, t, duration) {
  const bs = boundaries(state, duration);
  for (const b of bs) if (b > t + EPS) return b;
  return duration;
}

export function addSplit(state, t, duration) {
  if (t < EPS || t > duration - EPS) return false;
  if (state.splits.some((s) => Math.abs(s - t) < 0.01)) return false;
  state.splits.push(round3(t));
  state.splits.sort((a, b) => a - b);
  return true;
}

/** A: recorta desde la frontera anterior hasta el playhead. */
export function trimLeft(state, t, duration) {
  if (t < 0.05) return false;
  const p = prevBoundary(state, t, duration);
  if (t - p < 0.02) return false;
  state.trims.push({ start: round3(p), end: round3(t) });
  state.trims = mergeRanges(state.trims);
  return true;
}

/** D: recorta desde el playhead hasta la frontera siguiente. */
export function trimRight(state, t, duration) {
  if (t > duration - 0.05) return false;
  const n = nextBoundary(state, t, duration);
  if (n - t < 0.02) return false;
  state.trims.push({ start: round3(t), end: round3(n) });
  state.trims = mergeRanges(state.trims);
  return true;
}

export function addMarker(state, t, nota) {
  state.markers.push({ t: round3(t), nota: String(nota || '') });
  state.markers.sort((a, b) => a.t - b.t);
}

/** Si t cae dentro de un trim (fusionado) devuelve el fin del rango; si no, null. */
export function skipTarget(trims, t) {
  for (const r of mergeRanges(trims)) {
    if (t >= r.start - EPS && t < r.end - EPS) return r.end;
  }
  return null;
}

export function totalTrimmed(trims) {
  return mergeRanges(trims).reduce((acc, r) => acc + (r.end - r.start), 0);
}

// ---------- ediciones de items (overlays del timeline: mover / trim / eliminar) ----------
// state.items = { [index]: {id, start?, dur?, offset?, removed?} } — SOLO los que cambiaron.
// `offset` = in-point del media (segundos dentro del webm/mp4 del overlay); solo aplica a video.

/** Registra/mezcla una edición del item `idx`. `id` es sanity-check para restaurar sesiones. */
export function editItem(state, idx, id, patch) {
  const prev = state.items[idx] || { id };
  const next = { ...prev, id };
  for (const k of ['start', 'dur', 'offset']) {
    if (patch[k] !== undefined) next[k] = round3(patch[k]);
  }
  if (patch.removed !== undefined) next.removed = !!patch.removed;
  state.items[idx] = next;
}

/** Item efectivo (base + edición). Devuelve null si está eliminado. */
export function effItem(state, idx, baseItem) {
  if (!baseItem) return null;
  const ed = state.items[idx];
  if (!ed) return baseItem;
  if (ed.removed) return null;
  const out = { ...baseItem };
  for (const k of ['start', 'dur', 'offset']) if (ed[k] !== undefined) out[k] = ed[k];
  return out;
}

/** Lista efectiva [{...item, _idx}] excluyendo eliminados. */
export function resolveItems(state, baseItems) {
  const out = [];
  for (let i = 0; i < baseItems.length; i++) {
    const it = effItem(state, i, baseItems[i]);
    if (it) out.push({ ...it, _idx: i });
  }
  return out;
}

/** Clampa una edición de placement contra los límites del proyecto y del media. */
export function clampItem(baseItem, edit, duration, srcDur = null) {
  const out = { ...edit };
  if (out.dur !== undefined) out.dur = Math.max(MIN_ITEM_DUR, out.dur);
  if (out.offset !== undefined) out.offset = Math.max(0, out.offset);
  if (out.start !== undefined) {
    const dur = out.dur ?? baseItem.dur;
    out.start = Math.max(0, Math.min(out.start, duration - MIN_ITEM_DUR));
    if (out.start + dur > duration) out.dur = round3(duration - out.start);
  }
  if (srcDur && baseItem.type === 'video') {
    const off = out.offset ?? baseItem.offset ?? 0;
    const dur = out.dur ?? baseItem.dur;
    if (off + dur > srcDur + EPS) out.dur = round3(Math.max(MIN_ITEM_DUR, srcDur - off));
  }
  for (const k of ['start', 'dur', 'offset']) if (out[k] !== undefined) out[k] = round3(out[k]);
  return out;
}

/** Poda ediciones stale al restaurar sesión (timeline regenerado: index/id ya no coinciden). */
export function pruneItemEdits(state, baseItems) {
  for (const key of Object.keys(state.items)) {
    const idx = +key;
    const base = baseItems[idx];
    const ed = state.items[key];
    if (!base || (ed.id != null && base.id != null && ed.id !== base.id)) delete state.items[key];
  }
}

/** fixes.json (contrato con sfstudio-apply + la fábrica). */
export function toFixes(state, videoSrc, extra = {}) {
  const itemEdits = Object.keys(state.items)
    .map(Number)
    .sort((a, b) => a - b)
    .map((idx) => {
      const ed = state.items[idx];
      const out = { index: idx, id: ed.id };
      for (const k of ['start', 'dur', 'offset']) if (ed[k] !== undefined) out[k] = ed[k];
      if (ed.removed) out.removed = true;
      return out;
    });
  return {
    video: videoSrc,
    exported_at: new Date().toISOString(),
    trims: mergeRanges(state.trims).map((r) => ({ start: round3(r.start), end: round3(r.end) })),
    markers: state.markers.map((m) => ({ t: round3(m.t), nota: m.nota })),
    splits: [...state.splits],
    ...(itemEdits.length ? { item_edits: itemEdits } : {}),
    ...extra,
  };
}

export function fromFixes(fixes) {
  const s = newState();
  if (Array.isArray(fixes?.trims)) s.trims = mergeRanges(fixes.trims.map((r) => ({ start: +r.start, end: +r.end })));
  if (Array.isArray(fixes?.markers)) s.markers = fixes.markers.map((m) => ({ t: +m.t, nota: String(m.nota ?? '') }));
  if (Array.isArray(fixes?.splits)) s.splits = fixes.splits.map(Number).sort((a, b) => a - b);
  if (Array.isArray(fixes?.item_edits)) {
    for (const e of fixes.item_edits) {
      if (!Number.isInteger(e?.index) || e.index < 0) continue;
      const ed = { id: e.id };
      for (const k of ['start', 'dur', 'offset']) if (typeof e[k] === 'number') ed[k] = round3(e[k]);
      if (e.removed) ed.removed = true;
      s.items[e.index] = ed;
    }
  }
  return s;
}

function round3(x) {
  return Math.round(x * 1000) / 1000;
}
