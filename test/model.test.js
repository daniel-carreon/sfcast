import test from 'node:test';
import assert from 'node:assert/strict';
import {
  newState, mergeRanges, boundaries, addSplit, trimLeft, trimRight,
  skipTarget, totalTrimmed, toFixes, fromFixes,
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
