// Modelo puro de la Sala de Revisión: splits, trims no destructivos, marcadores,
// y ediciones de items (mover / trim de bordes / eliminar overlays del timeline).
// SIN DOM — importable por node --test y por el browser (ESM).
const EPS = 1e-4;
const MIN_ITEM_DUR = 0.1;

export function newState() {
  // items = ediciones por índice del timeline base · adds = piezas NUEVAS (nacen al partir un
  // asset con S), clonan el media de un item base (`from`) con su propio placement.
  // comments = FEEDBACK DE DANIEL (tecla C). Canal distinto de markers: markers son la fábrica
  // explicándole a Daniel; comments son Daniel dictándole a la fábrica. Nunca se mezclan.
  return { splits: [], trims: [], markers: [], comments: [], items: {}, adds: [], audioLinked: true };
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

/** Mueve/redimensiona UN rango de recorte del base (índice en la lista ya fusionada).
 *  NO fusiona: el caller fusiona al soltar el gesto (fusionar en medio del drag cambia índices). */
export function setTrimRange(state, idx, start, end, duration) {
  if (!state.trims[idx]) return false;
  const a = Math.max(0, Math.min(start, duration));
  const b = Math.max(0, Math.min(end, duration));
  if (b - a < 0.05) return false;
  state.trims[idx] = { start: round3(a), end: round3(b) };
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

// ---------- vista CORTE (estilo CapCut): mapeo raw ↔ out sobre los trims ----------
// El timeline muestra SOLO el material conservado (duración final); cada trim colapsa a una
// COSTURA (línea de corte). Estas funciones son el cambio de coordenadas.

/** Segmentos conservados del base en tiempo raw, con su inicio acumulado en tiempo out. */
export function keptSegments(trims, duration) {
  const segs = [];
  let cursor = 0, out = 0;
  for (const r of mergeRanges(trims)) {
    if (r.start > cursor + EPS) {
      segs.push({ a: cursor, b: r.start, out });
      out += r.start - cursor;
    }
    cursor = Math.max(cursor, r.end);
  }
  if (cursor < duration - EPS) segs.push({ a: cursor, b: duration, out });
  return segs;
}

/** Duración del corte (out). */
export function outDuration(trims, duration) {
  return Math.max(0, duration - totalTrimmed(trims));
}

/** raw → out. Dentro de un trim colapsa a la costura. */
export function rawToOut(segs, t) {
  let out = 0;
  for (const s of segs) {
    if (t < s.a) return s.out;
    if (t <= s.b + EPS) return s.out + (t - s.a);
    out = s.out + (s.b - s.a);
  }
  return out;
}

/** out → raw (inversa). Una costura exacta resuelve HACIA ADELANTE (inicio del material
 *  que sigue): así el seek en la costura muestra contenido conservado, no el trim. */
export function outToRaw(segs, o) {
  for (const s of segs) {
    if (o < s.out + (s.b - s.a) - EPS) return s.a + Math.max(0, o - s.out);
  }
  return segs.length ? segs[segs.length - 1].b : 0;
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
  state.adds = (state.adds || []).filter((a) => {
    const base = baseItems[a.from];
    return base && (a.id == null || base.id == null || a.id === base.id);
  });
}

// ---------- direccionamiento unificado: base items (key numérico) + adds (key 'aN') ----------

/** Lista efectiva COMPLETA [{...item, _key}] — base editados (sin removed) + piezas añadidas. */
export function effAll(state, baseItems) {
  const out = resolveItems(state, baseItems).map((it) => ({ ...it, _key: it._idx }));
  (state.adds || []).forEach((a, i) => {
    const tpl = baseItems[a.from];
    if (!tpl) return;
    out.push({
      ...tpl, id: a.id ?? tpl.id, start: a.start, dur: a.dur,
      ...(a.offset !== undefined ? { offset: a.offset } : {}),
      _key: 'a' + i, _from: a.from,
    });
  });
  return out;
}

/** Item efectivo por key ('aN' o índice numérico). null si no existe / removed. */
export function effByKey(state, baseItems, key) {
  if (typeof key === 'string' && key.startsWith('a')) {
    return effAll(state, baseItems).find((it) => it._key === key) || null;
  }
  const it = effItem(state, +key, baseItems[+key]);
  return it ? { ...it, _key: +key } : null;
}

/** Item base plantilla del key (para clamp por tipo/media). */
export function baseOfKey(state, baseItems, key) {
  if (typeof key === 'string' && key.startsWith('a')) {
    const a = (state.adds || [])[+key.slice(1)];
    return a ? baseItems[a.from] : null;
  }
  return baseItems[+key] || null;
}

/** Aplica un patch de placement al item `key` (base → items{}, add → in place). */
export function patchByKey(state, baseItems, key, patch) {
  if (typeof key === 'string' && key.startsWith('a')) {
    const a = state.adds[+key.slice(1)];
    if (!a) return false;
    for (const k of ['start', 'dur', 'offset']) if (patch[k] !== undefined) a[k] = round3(patch[k]);
    return true;
  }
  const base = baseItems[+key];
  if (!base) return false;
  editItem(state, +key, base.id, patch);
  return true;
}

/** Elimina el item `key` (base → flag removed, add → sale de la lista). */
export function removeByKey(state, baseItems, key) {
  if (typeof key === 'string' && key.startsWith('a')) {
    const i = +key.slice(1);
    if (!state.adds[i]) return false;
    state.adds.splice(i, 1);
    return true;
  }
  const base = baseItems[+key];
  if (!base) return false;
  editItem(state, +key, base.id, { removed: true });
  return true;
}

/** S sobre un item: lo parte en dos en `t`. La pieza derecha nace como add (offset compensado). */
export function splitItemAt(state, baseItems, key, t) {
  const it = effByKey(state, baseItems, key);
  if (!it) return false;
  const end = it.start + it.dur;
  if (t < it.start + 0.05 || t > end - 0.05) return false; // playhead fuera (o al ras) del asset
  const from = typeof key === 'string' ? state.adds[+key.slice(1)].from : +key;
  const isVideo = (baseItems[from] || {}).type === 'video';
  patchByKey(state, baseItems, key, { dur: t - it.start });
  state.adds.push({
    from, id: it.id, start: round3(t), dur: round3(end - t),
    ...(isVideo ? { offset: round3((it.offset || 0) + (t - it.start)) } : {}),
  });
  return true;
}

/** A/D sobre un item: recorta su borde hasta el playhead (A = izquierdo, D = derecho). */
export function trimItemTo(state, baseItems, key, t, side) {
  const it = effByKey(state, baseItems, key);
  if (!it) return false;
  const end = it.start + it.dur;
  if (t < it.start + 0.05 || t > end - 0.05) return false;
  const isVideo = (baseOfKey(state, baseItems, key) || {}).type === 'video';
  if (side === 'l') {
    return patchByKey(state, baseItems, key, {
      start: t, dur: end - t,
      ...(isVideo ? { offset: (it.offset || 0) + (t - it.start) } : {}),
    });
  }
  return patchByKey(state, baseItems, key, { dur: t - it.start });
}

/** Vinculación: al recortar un rango del base, elimina los overlays que caen COMPLETOS adentro. */
export function removeItemsInsideRange(state, baseItems, start, end) {
  let n = 0;
  // adds primero (de atrás hacia adelante: splice no invalida índices previos)
  for (let i = (state.adds || []).length - 1; i >= 0; i--) {
    const a = state.adds[i];
    if (a.start >= start - EPS && a.start + a.dur <= end + EPS) { state.adds.splice(i, 1); n++; }
  }
  for (let idx = 0; idx < baseItems.length; idx++) {
    const it = effItem(state, idx, baseItems[idx]);
    if (it && it.start >= start - EPS && it.start + it.dur <= end + EPS) {
      editItem(state, idx, baseItems[idx].id, { removed: true });
      n++;
    }
  }
  return n;
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
  const itemAdds = (state.adds || []).map((a) => {
    const out = { from: a.from, id: a.id, start: a.start, dur: a.dur };
    if (a.offset !== undefined) out.offset = a.offset;
    return out;
  });
  return {
    video: videoSrc,
    exported_at: new Date().toISOString(),
    trims: mergeRanges(state.trims).map((r) => ({ start: round3(r.start), end: round3(r.end) })),
    markers: state.markers.map((m) => ({ t: round3(m.t), nota: m.nota })),
    // feedback de Daniel (tecla C). Aditivo: print_master / sfstudio-apply lo ignoran.
    comments: (state.comments || []).map((c) => ({ t: round3(c.t), texto: c.texto, creado: c.creado })),
    splits: [...state.splits],
    // audio pegado al video por default (un solo mp4); false = Daniel lo separó (clic derecho) →
    // señal para la fábrica de tratar el audio como pista independiente. Solo se emite si es false.
    ...(state.audioLinked === false ? { audio_linked: false } : {}),
    ...(itemEdits.length ? { item_edits: itemEdits } : {}),
    ...(itemAdds.length ? { item_adds: itemAdds } : {}),
    ...extra,
  };
}

export function fromFixes(fixes) {
  const s = newState();
  if (Array.isArray(fixes?.trims)) s.trims = mergeRanges(fixes.trims.map((r) => ({ start: +r.start, end: +r.end })));
  if (Array.isArray(fixes?.markers)) s.markers = fixes.markers.map((m) => ({ t: +m.t, nota: String(m.nota ?? '') }));
  if (Array.isArray(fixes?.comments)) {
    s.comments = fixes.comments
      .filter((c) => Number.isFinite(+c?.t))
      .map((c) => ({ t: +c.t, texto: String(c.texto ?? ''), creado: c.creado || null }))
      .sort((a, b) => a.t - b.t);
  }
  if (Array.isArray(fixes?.splits)) s.splits = fixes.splits.map(Number).sort((a, b) => a - b);
  s.audioLinked = fixes?.audio_linked !== false; // default true salvo que se haya separado explícito
  if (Array.isArray(fixes?.item_edits)) {
    for (const e of fixes.item_edits) {
      if (!Number.isInteger(e?.index) || e.index < 0) continue;
      const ed = { id: e.id };
      for (const k of ['start', 'dur', 'offset']) if (typeof e[k] === 'number') ed[k] = round3(e[k]);
      if (e.removed) ed.removed = true;
      s.items[e.index] = ed;
    }
  }
  if (Array.isArray(fixes?.item_adds)) {
    for (const a of fixes.item_adds) {
      if (!Number.isInteger(a?.from) || a.from < 0 || typeof a.start !== 'number' || typeof a.dur !== 'number') continue;
      const add = { from: a.from, id: a.id, start: round3(a.start), dur: round3(a.dur) };
      if (typeof a.offset === 'number') add.offset = round3(a.offset);
      s.adds.push(add);
    }
  }
  return s;
}

function round3(x) {
  return Math.round(x * 1000) / 1000;
}
