import test from 'node:test';
import assert from 'node:assert/strict';
import {
  newState, mergeRanges, boundaries, addSplit, trimLeft, trimRight,
  skipTarget, totalTrimmed, toFixes, fromFixes,
  editItem, effItem, resolveItems, clampItem, pruneItemEdits,
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
  pruneItemEdits(s, ITEMS);
  assert.deepEqual(Object.keys(s.items), ['0']);
});
