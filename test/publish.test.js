// Unit tests de SFPublish: gate del checklist + matcher de menciones (fixture sintético,
// incluyendo el caso que NO debe matchear) + slots + slugs + parser de transcript.
import test from 'node:test';
import assert from 'node:assert/strict';
import {
  STAGES, newPublish, setStage, slugFromYoutubeId, slugFromProjectName,
  parseTranscript, findMentions, checklistGate, nextSlots, communityPost,
} from '../lib/publish.js';

// helper: frase → words con timestamps sintéticos (1 palabra = 0.4s)
function words(frase, t0 = 0) {
  return frase.split(/\s+/).map((w, i) => ({ text: w, start: t0 + i * 0.4, end: t0 + (i + 1) * 0.4 }));
}

const DEFAULTS = { madeForKids: false };

function goodPub() {
  const pub = newPublish('vid-test');
  pub.video.titulo = 'Claude Code cambió mi forma de construir SaaS';
  pub.data.metadata = {
    description: '🚀 Únete: https://saasfactory.so/go/vid-test\n\nEn este video que aprende como los agentes para tu SaaS con IA.\n\n🕒 TIMESTAMPS:\n00:00 Intro\n05:30 El sistema\n12:00 Cierre\n\n#SaaS',
    titles: ['Claude Code cambió mi forma de construir SaaS'],
    keywords: ['claude code', 'saas', 'ia', 'agentes', 'automatizacion'],
    summary: 'resumen',
  };
  return pub;
}

test('checklist: gate ABIERTO con metadata completa', () => {
  const { checks, pass } = checklistGate(goodPub(), DEFAULTS);
  assert.equal(pass, true);
  assert.equal(checks.find((c) => c.id === 'thumbnail').ok, false); // WARN no bloquea
});

test('checklist: gate CERRADO — título >60, sin /go/ arriba, pocas keywords', () => {
  const pub = goodPub();
  pub.video.titulo = 'x'.repeat(61);
  pub.data.metadata.description = 'linea uno\nlinea dos\nhttps://saasfactory.so/go/vid-test\n00:00 a\n01:00 b y este video que aprende como para los';
  pub.data.metadata.keywords = ['a', 'b'];
  const { checks, pass } = checklistGate(pub, DEFAULTS);
  assert.equal(pass, false);
  assert.equal(checks.find((c) => c.id === 'titulo').ok, false);
  assert.equal(checks.find((c) => c.id === 'descripcion_go').ok, false);
  assert.equal(checks.find((c) => c.id === 'keywords').ok, false);
});

test('checklist: thumbnail done cuando la etapa se marca', () => {
  const pub = goodPub();
  setStage(pub, 'thumbnail', 'done', 'miniatura lista');
  const { checks } = checklistGate(pub, DEFAULTS);
  assert.equal(checks.find((c) => c.id === 'thumbnail').ok, true);
});

const VIDEOS = [
  { video_id: 'AAA', title: '32 Trucos Para Volverte un Experto con Claude Code en 19 Minutos' },
  { video_id: 'BBB', title: 'Claude Code Acaba de lanzar /goal, Ahora Tenemos Agentes Infinitos' },
  { video_id: 'CCC', title: 'DeepSeek + Claude Code = 100x más BARATO' },
];

test('mentions: racha textual del título → match con t correcto', () => {
  const tw = words('hola banda bienvenidos al canal en el video de treinta y dos trucos para volverte un experto les enseñe la base hoy vamos mas alla', 0);
  const found = findMentions(tw, VIDEOS);
  assert.equal(found.length, 1);
  assert.equal(found[0].video_id, 'AAA');
  assert.match(found[0].frase_detectada, /trucos para volverte un experto/);
  assert.ok(found[0].t > 3 && found[0].t < 8, `t=${found[0].t} fuera de rango`);
});

test('mentions: "claude code" suelto JAMÁS matchea (guardia anti falso positivo)', () => {
  const tw = words('hoy vamos a usar claude code para construir un saas con claude code y mas claude code todo el dia', 0);
  assert.equal(findMentions(tw, VIDEOS).length, 0);
});

test('mentions: hablar del tema sin citar el título NO matchea', () => {
  const tw = words('deepseek es un modelo barato que me gusta mucho y claude code lo usa de maravilla', 0);
  assert.equal(findMentions(tw, VIDEOS).length, 0);
});

test('mentions: dos menciones se ordenan por t', () => {
  const tw = [
    ...words('primero recuerden agentes infinitos con goal ahora tenemos agentes infinitos como vimos', 0),
    ...words('y despues trucos para volverte un experto ya saben', 60),
  ];
  const found = findMentions(tw, VIDEOS);
  assert.equal(found.length, 2);
  assert.ok(found[0].t < found[1].t);
  assert.equal(found[0].video_id, 'BBB');
  assert.equal(found[1].video_id, 'AAA');
});

test('slugs: youtube id con underscore y nombre de proyecto', () => {
  assert.equal(slugFromYoutubeId('AbC_dEf1234'), 'vid-abc-def1234');
  assert.equal(slugFromProjectName('video-final-5-practica'), 'vid-final-5-practica');
  assert.equal(slugFromProjectName('Mi Video Ñoño!!'), 'vid-mi-video-nono');
});

test('parseTranscript: formato word-level filtra spacing y calcula duración', () => {
  const j = { words: [
    { type: 'word', text: 'Hola', start: 1, end: 1.5 },
    { type: 'spacing', text: ' ', start: 1.5, end: 1.6 },
    { type: 'word', text: 'mundo', start: 1.6, end: 2.2 },
  ] };
  const tr = parseTranscript(j);
  assert.equal(tr.words.length, 2);
  assert.equal(tr.text, 'Hola mundo');
  assert.equal(tr.duration, 2.2);
});

test('schedule: desde miércoles, preferido es lunes y el más cercano es hoy 4PM', () => {
  const wed = new Date(2026, 6, 15, 12, 0, 0); // miércoles 15 jul 2026, mediodía
  const s = nextSlots(wed);
  assert.equal(s.preferred.lunes, true);
  assert.equal(new Date(s.soonest.iso).getHours(), 16);
  assert.equal(new Date(s.soonest.iso).getDate(), 15);
});

test('publish.json: esqueleto con todas las etapas y log acumulativo', () => {
  const pub = newPublish('vid-x', 'Título');
  assert.deepEqual(Object.keys(pub.stages), STAGES);
  setStage(pub, 'metadata', 'done', 'ok');
  assert.equal(pub.stages.metadata.status, 'done');
  assert.equal(pub.log.length, 1);
});

test('post de comunidad: SOLO texto, con título y sin markup raro', () => {
  const txt = communityPost(goodPub());
  assert.match(txt, /Claude Code cambió mi forma/);
  assert.equal(typeof txt, 'string');
});
