import test from 'node:test';
import assert from 'node:assert/strict';
import {
  newState, mergeRanges, boundaries, addSplit, trimLeft, trimRight,
  skipTarget, totalTrimmed, toFixes, fromFixes, setTrimRange,
  editItem, effItem, resolveItems, clampItem, pruneItemEdits,
  effAll, effByKey, patchByKey, removeByKey, splitItemAt, trimItemTo, removeItemsInsideRange,
} from '../web/model.js';

const DUR = 100;

test('mergeRanges fusiona solapes y adyacentes', () => {
  assert.deepEqual(
    mergeRanges([{ start: 5, end: 8 }, { start: 7, end: 10 }, { start: 20, end: 21 }]),
    [{ start: 5, end: 10 }, { start: 20, end: 21 }]
  );
});

test('S+D: split y trim a la derecha hasta la frontera', () => {
  const s = newState();
  addSplit(s, 50, DUR);
  assert.ok(trimRight(s, 42, DUR));
  assert.deepEqual(s.trims, [{ start: 42, end: 50 }]); // corta hasta el split, no hasta el final
});

test('S+A: trim a la izquierda hasta la frontera previa', () => {
  const s = newState();
  addSplit(s, 30, DUR);
  assert.ok(trimLeft(s, 37.5, DUR));
  assert.deepEqual(s.trims, [{ start: 30, end: 37.5 }]);
});

test('A sin splits recorta desde 0', () => {
  const s = newState();
  assert.ok(trimLeft(s, 3.2, DUR));
  assert.deepEqual(s.trims, [{ start: 0, end: 3.2 }]);
});

test('D sin splits recorta hasta el final', () => {
  const s = newState();
  assert.ok(trimRight(s, 95, DUR));
  assert.deepEqual(s.trims, [{ start: 95, end: 100 }]);
});

test('trims consecutivos se fusionan y las fronteras los respetan', () => {
  const s = newState();
  addSplit(s, 10, DUR); addSplit(s, 20, DUR);
  trimRight(s, 10, DUR);           // 10-20
  trimRight(s, 20, DUR);           // 20-100 → fusiona 10-100
  assert.deepEqual(s.trims, [{ start: 10, end: 100 }]);
  // el split 20 queda dentro del trim: sigue siendo frontera (inofensivo, se fusiona igual)
  assert.deepEqual(boundaries(s, DUR), [0, 10, 20, 100]);
});

test('skipTarget salta el rango completo fusionado', () => {
  const trims = [{ start: 10, end: 15 }, { start: 15, end: 22 }];
  assert.equal(skipTarget(trims, 12), 22);
  assert.equal(skipTarget(trims, 9.5), null);
  assert.equal(skipTarget(trims, 22.01), null);
});

test('totalTrimmed suma fusionado', () => {
  assert.equal(totalTrimmed([{ start: 0, end: 5 }, { start: 4, end: 10 }]), 10);
});

test('round-trip fixes.json', () => {
  const s = newState();
  addSplit(s, 40, DUR);
  trimRight(s, 33.333, DUR);
  s.markers.push({ t: 12.5, nota: 'este corte luce weird' });
  const fx = toFixes(s, 'assets/base.mp4');
  assert.equal(fx.video, 'assets/base.mp4');
  assert.deepEqual(fx.trims, [{ start: 33.333, end: 40 }]);
  assert.equal(fx.markers[0].nota, 'este corte luce weird');
  const s2 = fromFixes(fx);
  assert.deepEqual(s2.trims, s.trims);
  assert.deepEqual(s2.splits, [40]);
});

test('guardas: no split en 0/fin, no trims microscopicos', () => {
  const s = newState();
  assert.equal(addSplit(s, 0, DUR), false);
  assert.equal(addSplit(s, 100, DUR), false);
  assert.equal(trimLeft(s, 0.01, DUR), false);
  assert.equal(trimRight(s, 99.99, DUR), false);
});

test('setTrimRange: mueve/redimensiona un recorte con clamps y sin fusionar en medio', () => {
  const s = newState();
  trimRight(s, 95, DUR);            // [95, 100]
  trimLeft(s, 3, DUR);              // [0, 3] — queda ordenado: [0,3], [95,100]
  // mover el primero completo +2s
  assert.ok(setTrimRange(s, 0, 2, 5, DUR));
  assert.deepEqual(s.trims[0], { start: 2, end: 5 });
  // clamp a los límites del proyecto
  assert.ok(setTrimRange(s, 1, 97, 130, DUR));
  assert.deepEqual(s.trims[1], { start: 97, end: 100 });
  // rechaza rangos microscópicos e índices fantasma
  assert.equal(setTrimRange(s, 0, 4, 4.01, DUR), false);
  assert.equal(setTrimRange(s, 9, 1, 2, DUR), false);
  // el caller fusiona al soltar: mover uno encima del otro colapsa a un solo rango
  assert.ok(setTrimRange(s, 0, 94, 98, DUR));
  s.trims = mergeRanges(s.trims);
  assert.deepEqual(s.trims, [{ start: 94, end: 100 }]);
});

// ---------- ediciones de items (mover / trim / eliminar overlays) ----------
const ITEMS = [
  { id: 'cap-5x', type: 'image', src: 'a.png', start: 4, dur: 2, track: 3, fit: 'stretch' },
  { id: 'logo-anthropic', type: 'video', src: 'b.webm', start: 3, dur: 2.4, track: 2, fit: 'contain', alpha: true },
];

test('editItem + effItem: mover un item cambia solo su placement', () => {
  const s = newState();
  editItem(s, 0, 'cap-5x', { start: 6.5 });
  const it = effItem(s, 0, ITEMS[0]);
  assert.equal(it.start, 6.5);
  assert.equal(it.dur, 2);            // sin tocar
  assert.equal(ITEMS[0].start, 4);    // el base queda intacto
});

test('effItem: removed devuelve null y resolveItems lo excluye', () => {
  const s = newState();
  editItem(s, 0, 'cap-5x', { removed: true });
  assert.equal(effItem(s, 0, ITEMS[0]), null);
  const res = resolveItems(s, ITEMS);
  assert.equal(res.length, 1);
  assert.equal(res[0]._idx, 1);
});

test('clampItem: respeta MIN_DUR, límites del proyecto y duración del media', () => {
  // no se sale del proyecto
  const c1 = clampItem(ITEMS[0], { start: 99.5 }, DUR);
  assert.ok(c1.start + (c1.dur ?? ITEMS[0].dur) <= DUR + 1e-4);
  // dur mínima
  assert.ok(clampItem(ITEMS[0], { dur: 0.01 }, DUR).dur >= 0.1);
  // offset nunca negativo
  assert.equal(clampItem(ITEMS[1], { offset: -3 }, DUR).offset, 0);
  // un video no puede durar más que su media restante (srcDur 2.4, offset 1 → máx 1.4)
  const c2 = clampItem(ITEMS[1], { offset: 1, dur: 5 }, DUR, 2.4);
  assert.ok(Math.abs(c2.dur - 1.4) < 1e-3);
});

test('trim izquierdo de video: start avanza y offset compensa (in-point)', () => {
  const s = newState();
  // simular el gesto: +0.5s por la izquierda → start 3.5, dur 1.9, offset 0.5
  editItem(s, 1, 'logo-anthropic', { start: 3.5, dur: 1.9, offset: 0.5 });
  const it = effItem(s, 1, ITEMS[1]);
  assert.equal(it.start, 3.5);
  assert.equal(it.dur, 1.9);
  assert.equal(it.offset, 0.5);
});

test('round-trip item_edits en fixes.json', () => {
  const s = newState();
  editItem(s, 0, 'cap-5x', { start: 7, dur: 1.5 });
  editItem(s, 1, 'logo-anthropic', { removed: true });
  const fx = toFixes(s, 'assets/base.mp4');
  assert.equal(fx.item_edits.length, 2);
  assert.deepEqual(fx.item_edits[0], { index: 0, id: 'cap-5x', start: 7, dur: 1.5 });
  assert.deepEqual(fx.item_edits[1], { index: 1, id: 'logo-anthropic', removed: true });
  const s2 = fromFixes(fx);
  assert.equal(effItem(s2, 0, ITEMS[0]).start, 7);
  assert.equal(effItem(s2, 1, ITEMS[1]), null);
});

test('fixes.json sin item_edits (sesiones viejas) sigue funcionando', () => {
  const s = fromFixes({ trims: [{ start: 1, end: 2 }] });
  assert.deepEqual(s.items, {});
  assert.equal(resolveItems(s, ITEMS).length, 2);
});

test('pruneItemEdits tira ediciones stale (id distinto o índice fuera de rango)', () => {
  const s = newState();
  editItem(s, 0, 'cap-5x', { start: 9 });          // válida
  editItem(s, 1, 'OTRO-id', { start: 9 });          // id no coincide → stale
  editItem(s, 7, 'fantasma', { removed: true });    // índice fuera → stale
  s.adds.push({ from: 1, id: 'logo-anthropic', start: 8, dur: 1 });  // válida
  s.adds.push({ from: 9, id: 'nadie', start: 8, dur: 1 });           // from fuera → stale
  pruneItemEdits(s, ITEMS);
  assert.deepEqual(Object.keys(s.items), ['0']);
  assert.equal(s.adds.length, 1);
});

// ---------- splits de items, trims al playhead, vinculación ----------

test('splitItemAt: parte un asset en dos; la pieza derecha nace como add con offset compensado', () => {
  const s = newState();
  assert.ok(splitItemAt(s, ITEMS, 1, 4.0)); // video [3, 5.4] → [3,4] + add [4, 5.4]
  const all = effAll(s, ITEMS);
  assert.equal(all.length, 3);
  const left = effByKey(s, ITEMS, 1);
  assert.equal(left.dur, 1);
  const right = all.find((i) => i._key === 'a0');
  assert.equal(right.start, 4);
  assert.ok(Math.abs(right.dur - 1.4) < 1e-3);
  assert.equal(right.offset, 1); // in-point compensado: el video sigue donde iba
  // la pieza añadida también se puede partir, mover y borrar
  assert.ok(splitItemAt(s, ITEMS, 'a0', 4.5));
  assert.equal(effAll(s, ITEMS).length, 4);
  assert.ok(patchByKey(s, ITEMS, 'a1', { start: 9 }));
  assert.ok(removeByKey(s, ITEMS, 'a1'));
  assert.equal(effAll(s, ITEMS).length, 3);
});

test('splitItemAt: rechaza playhead fuera (o al ras) del asset', () => {
  const s = newState();
  assert.equal(splitItemAt(s, ITEMS, 0, 3.9), false);  // antes del start (4)
  assert.equal(splitItemAt(s, ITEMS, 0, 4.01), false); // al ras del borde
  assert.equal(splitItemAt(s, ITEMS, 0, 6.5), false);  // después del end (6)
});

test('trimItemTo: A/D recortan el borde del asset hasta el playhead', () => {
  const s = newState();
  assert.ok(trimItemTo(s, ITEMS, 1, 3.5, 'l')); // video [3, 5.4] → [3.5, 5.4] con offset 0.5
  let it = effByKey(s, ITEMS, 1);
  assert.equal(it.start, 3.5);
  assert.equal(it.offset, 0.5);
  assert.ok(trimItemTo(s, ITEMS, 1, 5.0, 'r')); // → [3.5, 5.0]
  it = effByKey(s, ITEMS, 1);
  assert.equal(it.dur, 1.5);
  assert.equal(trimItemTo(s, ITEMS, 1, 9, 'r'), false); // fuera del asset
});

test('removeItemsInsideRange (vinculación): solo lo que cae COMPLETO adentro', () => {
  const s = newState();
  s.adds.push({ from: 0, id: 'cap-5x', start: 10, dur: 1 });
  // rango [9.5, 12]: el add [10,11] cae completo · base [4,6] y [3,5.4] no
  const n = removeItemsInsideRange(s, ITEMS, 9.5, 12);
  assert.equal(n, 1);
  assert.equal(s.adds.length, 0);
  assert.equal(effAll(s, ITEMS).length, 2);
  // rango que traga el cap [4,6] completo
  assert.equal(removeItemsInsideRange(s, ITEMS, 3.9, 6.1), 1);
  assert.equal(effByKey(s, ITEMS, 0), null);
});

test('round-trip item_adds en fixes.json', () => {
  const s = newState();
  splitItemAt(s, ITEMS, 1, 4.0);
  const fx = toFixes(s, 'assets/base.mp4');
  assert.equal(fx.item_adds.length, 1);
  assert.equal(fx.item_adds[0].from, 1);
  assert.equal(fx.item_adds[0].offset, 1);
  const s2 = fromFixes(fx);
  assert.equal(s2.adds.length, 1);
  assert.equal(effAll(s2, ITEMS).length, 3);
});

// ---------- vista corte: mapeo raw ↔ out ----------
import { keptSegments, outDuration, rawToOut, outToRaw } from '../web/model.js';

test('keptSegments: complemento de los trims con out acumulado', () => {
  const trims = [{ start: 10, end: 20 }, { start: 50, end: 55 }];
  assert.deepEqual(keptSegments(trims, DUR), [
    { a: 0, b: 10, out: 0 },
    { a: 20, b: 50, out: 10 },
    { a: 55, b: 100, out: 40 },
  ]);
  assert.equal(outDuration(trims, DUR), 85);
});

test('keptSegments: trim al inicio y al final', () => {
  const trims = [{ start: 0, end: 5 }, { start: 95, end: 100 }];
  assert.deepEqual(keptSegments(trims, DUR), [{ a: 5, b: 95, out: 0 }]);
  assert.equal(outDuration(trims, DUR), 90);
});

test('rawToOut: dentro de un trim colapsa a la costura', () => {
  const segs = keptSegments([{ start: 10, end: 20 }], DUR);
  assert.equal(rawToOut(segs, 5), 5);
  assert.equal(rawToOut(segs, 15), 10);  // adentro del trim → costura
  assert.equal(rawToOut(segs, 20), 10);
  assert.equal(rawToOut(segs, 30), 20);
  assert.equal(rawToOut(segs, 100), 90);
});

test('outToRaw es la inversa de rawToOut fuera de los trims', () => {
  const segs = keptSegments([{ start: 10, end: 20 }, { start: 50, end: 55 }], DUR);
  for (const t of [0, 5, 9.9, 20.1, 33, 49.9, 55.1, 80, 100]) {
    assert.ok(Math.abs(outToRaw(segs, rawToOut(segs, t)) - t) < 1e-3, `round-trip ${t}`);
  }
  assert.equal(outToRaw(segs, 10), 20);  // la costura resuelve al inicio del material que sigue
  assert.equal(outToRaw(segs, 85), 100);
  assert.equal(outToRaw(segs, 999), 100); // clamp al final
});

test('sin trims el mapeo es identidad', () => {
  const segs = keptSegments([], DUR);
  assert.deepEqual(segs, [{ a: 0, b: 100, out: 0 }]);
  assert.equal(rawToOut(segs, 42), 42);
  assert.equal(outToRaw(segs, 42), 42);
});

// ---------- regresiones de los blockers de coordenadas (workflow 21 jul) ----------
test('mover un punto por un delta OUT que cruza un trim (fix blocker startItemDrag)', () => {
  const segs = keptSegments([{ start: 20, end: 30 }], DUR); // 10s cortados
  // item en raw 15 (antes del corte), arrastrado +20s OUT: el correcto es 45 (salta los 10s), NO 35
  assert.equal(outToRaw(segs, rawToOut(segs, 15) + 20), 45);
  // arrastre que NO cruza el corte: delta OUT == delta RAW
  assert.equal(outToRaw(segs, rawToOut(segs, 5) + 10), 15);
});

test('arrastrar costura izquierda cruzando OTRO trim (fix blocker startSeamDrag)', () => {
  const segs0 = keptSegments([{ start: 10, end: 15 }], DUR); // el otro trim, que NO se arrastra
  // borde izq del trim [50,60] arrastrado -40 OUT: el correcto es 5, NO 10 (la suma ingenua)
  assert.equal(outToRaw(segs0, rawToOut(segs0, 50) - 40), 5);
});

test('ripple: cortar w en el pivote adelanta todo lo de la derecha w seg (out); la izquierda no se mueve', () => {
  const pivot = 30, w = 5;
  const before = keptSegments([], DUR);
  const after = keptSegments([{ start: pivot, end: pivot + w }], DUR);
  assert.equal(rawToOut(before, 50), 50);
  assert.equal(rawToOut(after, 50), 45);   // overlay a la derecha se pule w seg
  assert.equal(rawToOut(after, 20), 20);   // a la izquierda del pivote, intacto
  assert.equal(outDuration([{ start: pivot, end: pivot + w }], DUR), 95);
});

test('audioLinked: default true (audio pegado al video), se persiste SOLO cuando se separa', () => {
  const s = newState();
  assert.equal(s.audioLinked, true);
  // default true → toFixes NO emite el campo (fixes lean)
  assert.equal('audio_linked' in toFixes(s, 'v.mp4'), false);
  // separado (clic derecho) → se emite false y fromFixes lo lee de vuelta
  s.audioLinked = false;
  const fx = toFixes(s, 'v.mp4');
  assert.equal(fx.audio_linked, false);
  assert.equal(fromFixes(fx).audioLinked, false);
  // un fixes viejo sin el campo → default true (retrocompatible)
  assert.equal(fromFixes({ trims: [] }).audioLinked, true);
});
