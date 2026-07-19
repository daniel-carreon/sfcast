// Modelo puro de la Sala de Revisión: splits, trims no destructivos, marcadores.
// SIN DOM — importable por node --test y por el browser (ESM).
const EPS = 1e-4;

export function newState() {
  return { splits: [], trims: [], markers: [] };
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

/** fixes.json (contrato con sfstudio-apply). */
export function toFixes(state, videoSrc, extra = {}) {
  return {
    video: videoSrc,
    exported_at: new Date().toISOString(),
    trims: mergeRanges(state.trims).map((r) => ({ start: round3(r.start), end: round3(r.end) })),
    markers: state.markers.map((m) => ({ t: round3(m.t), nota: m.nota })),
    splits: [...state.splits],
    ...extra,
  };
}

export function fromFixes(fixes) {
  const s = newState();
  if (Array.isArray(fixes?.trims)) s.trims = mergeRanges(fixes.trims.map((r) => ({ start: +r.start, end: +r.end })));
  if (Array.isArray(fixes?.markers)) s.markers = fixes.markers.map((m) => ({ t: +m.t, nota: String(m.nota ?? '') }));
  if (Array.isArray(fixes?.splits)) s.splits = fixes.splits.map(Number).sort((a, b) => a - b);
  return s;
}

function round3(x) {
  return Math.round(x * 1000) / 1000;
}
