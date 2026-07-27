// Unit tests del modelo de la GALERÍA: identidad/sandbox de proyectos, estado del lanzamiento,
// portada, transcript de texto, capítulos, y el patch sobre publish.json (con sus invariantes).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { promises as fsp } from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import {
  defaultRoots, makeId, resolveId, scanRoots, launchState, postState, coverThumb,
  parseTextTranscript, parseChapters, extractDescription, extractPostBody,
  listThumbs, resolveThumb, readCard, readDossier, applyGalleryPatch,
} from '../lib/gallery.js';

// ---------- raíces e identidad ----------
test('defaultRoots: default bajo business-os, override por SFSTUDIO_ROOTS', () => {
  const d = defaultRoots({}, '/Users/x');
  assert.equal(d.length, 2);
  assert.ok(d[0].endsWith('/Developer/business-os/youtube/videos'));
  assert.deepEqual(defaultRoots({ SFSTUDIO_ROOTS: '/a,/b' }, '/Users/x'), ['/a', '/b']);
});

test('resolveId: resuelve dentro de la raíz y RECHAZA traversal', () => {
  const roots = ['/r0', '/r1'];
  assert.deepEqual(resolveId(roots, makeId(0, 'proj')), { dir: '/r0/proj', name: 'proj', rootIdx: 0 });
  assert.equal(resolveId(roots, 'r1/otro').dir, '/r1/otro');
  for (const malo of ['r0/../../etc', 'r0/a/b', 'r9/x', 'proj', '', null, 'r0/..', 'r0/.', 'r0/a\\b']) {
    assert.equal(resolveId(roots, malo), null, `debió rechazar: ${malo}`);
  }
});

// ---------- estado ----------
test('launchState: programado vs publicado vs sin fecha', () => {
  const now = new Date('2026-07-26T20:00:00Z');
  const futuro = { data: { launch: { publish_at: '2026-07-27T17:00:00Z' } } };
  const pasado = { data: { launch: { publish_at: '2026-07-20T17:00:00Z' } } };
  assert.equal(launchState(futuro, now).key, 'programado');
  assert.equal(launchState(futuro, now).tone, 'wait');
  assert.equal(launchState(pasado, now).key, 'publicado');
  assert.equal(launchState({ stages: { upload: { status: 'done' } } }, now).key, 'subido');
  assert.equal(launchState({ stages: { metadata: { status: 'done' } } }, now).key, 'listo');
  assert.equal(launchState({}, now).key, 'edicion');
  assert.equal(launchState(null, now).key, 'edicion'); // publish.json ilegible: no revienta
});

test('postState: sin post → borrador → aprobado → publicado (y el archivo cuenta como borrador)', () => {
  assert.equal(postState({}).key, 'sin-post');
  assert.equal(postState({}, { hasFile: true }).key, 'borrador');
  assert.equal(postState({ data: { post_draft: { body: 'x' } } }).key, 'borrador');
  assert.equal(postState({ data: { post_draft: { body: 'x', approved_at: 'ayer' } } }).key, 'aprobado');
  const pubd = { data: { post_published_at: '2026-07-27T18:05:00Z', post_draft: { body: 'x', approved_at: 'a' } } };
  assert.equal(postState(pubd).key, 'publicado');
});

test('coverThumb: la elegida gana; sin elección, la primera; elección fantasma se reporta', () => {
  const files = ['a.png', 'b.png'];
  assert.deepEqual(coverThumb({ data: { thumbnail: { chosen: 'b.png' } } }, files), { file: 'b.png', chosen: true });
  assert.deepEqual(coverThumb({}, files), { file: 'a.png', chosen: false });
  assert.deepEqual(coverThumb({ data: { thumbnail: { chosen: 'z.png' } } }, files),
    { file: 'a.png', chosen: false, missing: 'z.png' });
  assert.equal(coverThumb({}, []).file, null);
});

// ---------- parsers ----------
test('parseTextTranscript: [MM:SS.dd] y [HH:MM:SS]', () => {
  const segs = parseTextTranscript([
    'TRANSCRIPT DEL VIDEO (encabezado que se ignora)',
    '[00:00.26] Acabo de reemplazar todo.',
    '[01:12.48] práctica es casi veinte tokens.',
    '[1:02:03] una hora después.',
    'línea suelta sin timestamp',
  ].join('\n'));
  assert.equal(segs.length, 3);
  assert.equal(segs[0].t, 0.3);
  assert.equal(segs[1].t, 72.5);
  assert.equal(segs[2].t, 3723);
  assert.equal(segs[0].text, 'Acabo de reemplazar todo.');
});

test('parseChapters: solo las líneas de capítulo de la descripción', () => {
  const ch = parseChapters('bla bla\n00:00 Intro\n01:19 El examen sorpresa\n1:02:03 Cierre\nno soy capítulo');
  assert.deepEqual(ch.map((c) => c.t), [0, 79, 3723]);
  assert.equal(ch[1].label, 'El examen sorpresa');
});

test('extractDescription: saca el bloque publicable de un DESCRIPCION-*.txt de trabajo', () => {
  const txt = 'TÍTULO:\nAlgo\n\n====\nDESCRIPCIÓN (pegar tal cual en YouTube):\n====\nHola 👉 link\n00:00 Intro\n====\nNOTAS internas\n';
  const d = extractDescription(txt);
  assert.ok(d.startsWith('Hola'));
  assert.ok(!d.includes('NOTAS internas'));
  // sin fences: devuelve el texto completo, no vacío
  assert.equal(extractDescription('solo texto'), 'solo texto');
});

test('extractPostBody: toma "## El post" y tira las notas de blockquote', () => {
  const md = '# Post\n\n> nota para Levy\n\n---\n\n## El post\n\nComunidad!\n\n> otra nota\nTexto real\n\n---\n\n## Checklist\n\n- [x] algo\n';
  const b = extractPostBody(md);
  assert.ok(b.startsWith('Comunidad!'));
  assert.ok(b.includes('Texto real'));
  assert.ok(!b.includes('Checklist'));
  assert.ok(!b.includes('otra nota'));
});

// ---------- disco: escaneo, tarjeta, ficha y patch ----------
async function fixture() {
  const tmp = await fsp.mkdtemp(path.join(os.tmpdir(), 'sfgal-'));
  const root = path.join(tmp, 'videos');
  const A = path.join(root, '2026-01-01-con-lanzamiento');
  const B = path.join(root, 'sin-publish-json');
  await fsp.mkdir(path.join(A, 'thumbs'), { recursive: true });
  await fsp.mkdir(B, { recursive: true });
  await fsp.writeFile(path.join(A, 'publish.json'), JSON.stringify({
    video: { slug: 'vid-humo', titulo: 'Título elegido' },
    stages: { metadata: { status: 'done', evidence: 'ok' } },
    log: [],
    data: { metadata: { description: 'CTA\n\n00:00 Intro\n02:30 Cierre', titles: ['Título elegido'], keywords: ['ia'] } },
  }));
  for (const f of ['a.png', 'b.png', '_privada.png']) await fsp.writeFile(path.join(A, 'thumbs', f), 'x');
  await fsp.writeFile(path.join(A, 'post-comunidad.md'), '## El post\n\nComunidad!\n\nMira esto.\n');
  await fsp.writeFile(path.join(A, 'TRANSCRIPT-master.txt'), Array.from({ length: 8 },
    (_, i) => `[00:0${i}.00] frase número ${i} del video`).join('\n'));
  return { tmp, root, A, B };
}

test('scanRoots: solo carpetas con publish.json, y aguanta una raíz inexistente', async () => {
  const { tmp, root, A } = await fixture();
  const found = await scanRoots([root, path.join(tmp, 'no-existe')]);
  assert.equal(found.length, 1);
  assert.equal(found[0].dir, A);
  assert.equal(found[0].id, 'r0/2026-01-01-con-lanzamiento');
  await fsp.rm(tmp, { recursive: true, force: true });
});

test('listThumbs: ignora las `_*` (fuentes de trabajo, no candidatas)', async () => {
  const { tmp, A } = await fixture();
  const { dir, files } = await listThumbs(A);
  assert.equal(dir, 'thumbs');
  assert.deepEqual(files, ['a.png', 'b.png']);
  await fsp.rm(tmp, { recursive: true, force: true });
});

test('resolveThumb: encuentra la portada en thumbs/ O thumbnails/, y rechaza traversal', async () => {
  const { tmp, A } = await fixture();
  // el proyecto tiene thumbs/; simulamos uno que además usa thumbnails/ (lo escribe el auto-chain)
  await fsp.mkdir(path.join(A, 'thumbnails'), { recursive: true });
  await fsp.writeFile(path.join(A, 'thumbnails', 'portada.png'), 'x');
  assert.equal(await resolveThumb(A, 'a.png'), path.join(A, 'thumbs', 'a.png'));
  assert.equal(await resolveThumb(A, 'portada.png'), path.join(A, 'thumbnails', 'portada.png'));
  assert.equal(await resolveThumb(A, 'no-existe.png'), null);
  for (const malo of ['../publish.json', 'sub/a.png', '..', '', null]) {
    assert.equal(await resolveThumb(A, malo), null, `debió rechazar: ${malo}`);
  }
  await fsp.rm(tmp, { recursive: true, force: true });
});

test('readCard / readDossier: la ficha arma capítulos, transcript de texto y siembra el post', async () => {
  const { tmp, root } = await fixture();
  const [entry] = await scanRoots([root]);
  const card = await readCard(entry);
  assert.equal(card.titulo, 'Título elegido');
  assert.equal(card.cover, 'a.png');
  assert.equal(card.cover_chosen, false);
  assert.equal(card.launch.key, 'listo');
  assert.equal(card.post.key, 'borrador'); // hay post-comunidad.md aunque publish.json no traiga body

  const d = await readDossier(entry);
  assert.deepEqual(d.chapters.map((c) => c.t), [0, 150]);
  assert.equal(d.transcript.found, true);
  assert.equal(d.transcript.source, 'texto');
  assert.equal(d.transcript.segments.length, 8);
  assert.ok(d.post.body.startsWith('Comunidad!'));
  assert.equal(d.post.seeded, true);
  await fsp.rm(tmp, { recursive: true, force: true });
});

test('applyGalleryPatch: guarda post, aprueba, y EDITAR revoca la aprobación', async () => {
  const { tmp, root, A } = await fixture();
  const [entry] = await scanRoots([root]);

  await applyGalleryPatch(A, { post_body: 'Comunidad!\n\nTexto nuevo.' });
  await applyGalleryPatch(A, { post_approved: true });
  let d = await readDossier(entry);
  assert.equal(d.post.key, 'aprobado');
  assert.ok(d.post.approved_at);
  assert.equal(d.post.seeded, false); // ya no viene del archivo: vive en publish.json

  const r = await applyGalleryPatch(A, { post_body: 'Comunidad!\n\nOtra cosa.' });
  assert.ok(r.changed.some((c) => /revocada/.test(c)));
  d = await readDossier(entry);
  assert.equal(d.post.key, 'borrador');
  assert.equal(d.post.approved_at, null);
  await fsp.rm(tmp, { recursive: true, force: true });
});

test('applyGalleryPatch: la portada debe existir; aprobar sin texto falla; persiste en disco', async () => {
  const { tmp, root, A } = await fixture();
  const [entry] = await scanRoots([root]);

  await assert.rejects(() => applyGalleryPatch(A, { cover: 'fantasma.png' }), /no está en el proyecto/);
  await assert.rejects(() => applyGalleryPatch(A, { post_approved: true }), /no hay texto/);

  await applyGalleryPatch(A, { cover: 'b.png' });
  const raw = JSON.parse(await fsp.readFile(path.join(A, 'publish.json'), 'utf8'));
  assert.equal(raw.data.thumbnail.chosen, 'b.png');           // quedó ESCRITO en publish.json
  assert.ok(raw.log.some((l) => l.stage === 'galeria'));      // y dejó rastro en el log
  const card = await readCard(entry);
  assert.equal(card.cover, 'b.png');
  assert.equal(card.cover_chosen, true);

  await assert.rejects(() => applyGalleryPatch(path.join(tmp, 'nada'), { cover: 'b.png' }), /publish\.json/);
  await fsp.rm(tmp, { recursive: true, force: true });
});
