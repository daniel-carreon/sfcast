// SFPublish — subida agéntica a YouTube Studio por NAVEGADOR (no API: tarjetas/end screens no
// existen en la Data API v3 y los uploads de apps no verificadas quedan bloqueados en privado).
// Perfil persistente PROPIO (~/.sfstudio/browser-profile) — JAMÁS el Chrome personal de Daniel.
//
// REGLAS DURAS: nunca publicar público · nunca tocar videos existentes del canal ·
// el único video que se sube en modo --test es el draft PRIVADO "[TEST SFPublish] borrar"
// y se BORRA al final. Sin sesión de Google → rama B: documentar el ritual de conexión.
import path from 'node:path';
import os from 'node:os';
import { promises as fsp } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { setStage, savePublish } from './publish.js';

const PROFILE = path.join(os.homedir(), '.sfstudio', 'browser-profile');
const TEST_TITLE = '[TEST SFPublish] borrar';
const STUDIO = 'https://studio.youtube.com';

async function launch(headless = false) {
  const { chromium } = await import('playwright');
  await fsp.mkdir(PROFILE, { recursive: true });
  const ctx = await chromium.launchPersistentContext(PROFILE, {
    headless,
    viewport: { width: 1440, height: 900 },
    locale: 'es-MX',
    args: ['--disable-blink-features=AutomationControlled'],
  });
  const page = ctx.pages()[0] || await ctx.newPage();
  return { ctx, page };
}

async function shot(page, dir, name) {
  await fsp.mkdir(dir, { recursive: true });
  const p = path.join(dir, name);
  await page.screenshot({ path: p, fullPage: false }).catch(() => {});
  process.stdout.write(`  📸 ${p}\n`);
  return p;
}

// ¿hay sesión de Google con acceso a Studio?
async function hasSession(page) {
  await page.goto(STUDIO, { waitUntil: 'domcontentloaded', timeout: 45000 }).catch(() => {});
  await page.waitForTimeout(4000);
  const url = page.url();
  if (/accounts\.google\.com|ServiceLogin|signin/i.test(url)) return false;
  // el shell de Studio montado = sesión viva
  return await page.locator('ytcp-navigation-drawer, #create-icon, ytcp-button#create-icon').first()
    .isVisible({ timeout: 8000 }).catch(() => false);
}

const RITUAL = `
=== RITUAL DE CONEXIÓN (una sola vez) ===
1. Corre:  node bin/sfpublish.js connect
   (abre un Chromium con el perfil persistente de SFStudio — NO tu Chrome personal)
2. Loguea tu cuenta de Google del canal (@danielcarreonai) en la ventana que se abre.
   Pasa el 2FA normal. Las cookies quedan guardadas en ~/.sfstudio/browser-profile.
3. Cuando veas el dashboard de YouTube Studio, cierra la ventana.
4. Desde ahí, todos los uploads agénticos reusan esa sesión (dura meses).
   Re-correr el ritual solo si Google la expira.
`;

export async function connectRitual() {
  process.stdout.write('abriendo el perfil persistente de SFStudio para loguear Google…\n');
  const { ctx, page } = await launch(false);
  await page.goto(STUDIO, { waitUntil: 'domcontentloaded', timeout: 45000 }).catch(() => {});
  process.stdout.write('loguea tu cuenta en la ventana. Espero hasta 5 min a que Studio cargue…\n');
  const deadline = Date.now() + 5 * 60 * 1000;
  let ok = false;
  while (Date.now() < deadline) {
    if (await page.locator('ytcp-navigation-drawer, #create-icon').first().isVisible({ timeout: 1000 }).catch(() => false)) {
      ok = true;
      break;
    }
    await page.waitForTimeout(2000);
    if (page.isClosed()) break;
  }
  process.stdout.write(ok ? '✓ sesión conectada: el perfil ya puede subir videos.\n'
    : '⚠ no vi Studio cargado; si ya logueaste, corre `sfpublish <proyecto> upload --test` para verificar.\n');
  await ctx.close().catch(() => {});
}

// primer elemento visible entre varios selectores candidatos (Studio cambia sus nodos seguido)
async function firstVisible(page, selectors, timeout = 10000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    for (const sel of selectors) {
      const loc = page.locator(sel).first();
      if (await loc.isVisible({ timeout: 200 }).catch(() => false)) return loc;
    }
    await page.waitForTimeout(300);
  }
  throw new Error(`ningún selector visible: ${selectors.join(' | ')}`);
}

function channelIdFrom(page) {
  const m = page.url().match(/\/channel\/(UC[\w-]+)/);
  return m ? m[1] : null;
}

// abre el diálogo de subida: deep-link ?d=ud primero (inmune a cambios de DOM de Studio),
// cascada de clicks Crear→Subir videos como fallback
async function openUploadDialog(page) {
  const cid = channelIdFrom(page);
  if (cid) {
    await page.goto(`${STUDIO}/channel/${cid}?d=ud`, { waitUntil: 'domcontentloaded' }).catch(() => {});
    // el diálogo de subida = hay un input[type=file] en el DOM (el tag del dialog cambia seguido)
    const ok = await page.locator('input[type="file"]').first()
      .waitFor({ state: 'attached', timeout: 20000 }).then(() => true).catch(() => false);
    if (ok) return;
  }
  const create = await firstVisible(page, [
    'ytcp-button#create-icon', '#create-icon',
    'ytcp-button:has-text("Crear")', 'ytcp-button:has-text("Create")',
    'button[aria-label*="rear"]', 'ytcp-icon-button[aria-label*="ubir video"]', 'ytcp-icon-button[aria-label*="pload video"]',
  ], 20000);
  await create.click();
  const uploadItem = await firstVisible(page, [
    'tp-yt-paper-item[test-id="upload-beta"]', 'tp-yt-paper-item:has-text("Subir videos")', 'tp-yt-paper-item:has-text("Upload videos")',
  ]);
  await uploadItem.click();
}

async function fillTextbox(page, containerSel, text) {
  const box = await firstVisible(page, [`${containerSel} #textbox`, containerSel]);
  await box.click();
  await page.keyboard.press(process.platform === 'darwin' ? 'Meta+a' : 'Control+a');
  await page.keyboard.press('Backspace');
  await box.type(text, { delay: 10 });
}

// flujo completo de llenado del diálogo de subida (config repetible desde channel-defaults.json)
async function fillUploadDialog(page, shotsDir, { title, description, defaults }) {
  await firstVisible(page, ['#title-textarea', 'ytcp-video-metadata-editor', 'ytcp-uploads-dialog'], 120000);
  await page.waitForTimeout(3000);
  await shot(page, shotsDir, '03-dialogo-abierto.png');

  await fillTextbox(page, '#title-textarea', title);
  if (description) await fillTextbox(page, '#description-textarea', description);
  await shot(page, shotsDir, '04-titulo-descripcion.png');

  // made for kids — SIEMPRE "No es contenido para niños" (channel-defaults.json)
  if (defaults.madeForKids === false) {
    const radio = await firstVisible(page, [
      'tp-yt-paper-radio-button[name="VIDEO_MADE_FOR_KIDS_NOT_MFK"]',
      '#audience tp-yt-paper-radio-button:nth-of-type(2)',
    ]);
    await radio.click();
  }
  await shot(page, shotsDir, '05-audiencia.png');

  // Siguiente ×3: detalles → elementos → comprobaciones → visibilidad
  for (let i = 0; i < 3; i++) {
    const next = await firstVisible(page, ['#next-button', 'ytcp-button#next-button']);
    await next.click();
    await page.waitForTimeout(1500);
  }
  await shot(page, shotsDir, '06-visibilidad.png');

  // visibilidad SIEMPRE privado (regla dura: jamás público desde el agente)
  const priv = await firstVisible(page, [
    'tp-yt-paper-radio-button[name="PRIVATE"]',
    '#privacy-radios tp-yt-paper-radio-button:first-of-type',
  ]);
  await priv.click();
  await shot(page, shotsDir, '07-privado.png');

  const done = await firstVisible(page, ['#done-button', 'ytcp-button#done-button']);
  await done.click();
  await page.waitForTimeout(4000);
  await shot(page, shotsDir, '08-guardado.png');
  // cerrar el diálogo de confirmación si aparece
  const close = page.locator('ytcp-button#close-button, #close-button').first();
  if (await close.isVisible({ timeout: 3000 }).catch(() => false)) await close.click();
}

async function deleteTestVideo(page, shotsDir) {
  const cid = channelIdFrom(page);
  const rowSel = `ytcp-video-row:has-text("${TEST_TITLE}")`;
  // card-916.mp4 es 9:16 → YouTube lo clasifica como SHORT (otra pestaña); barremos ambas.
  const lists = cid
    ? [`${STUDIO}/channel/${cid}/videos/short`, `${STUDIO}/channel/${cid}/videos/upload`]
    : [STUDIO];

  const gotoList = async (url) => {
    await page.keyboard.press('Escape').catch(() => {});   // cierra overlay/backdrop pegado entre borrados
    if (cid) {
      await page.goto(url, { waitUntil: 'domcontentloaded' }).catch(() => {});
    } else {
      await page.goto(`${STUDIO}`, { waitUntil: 'domcontentloaded' });
      const content = await firstVisible(page, [
        'a#menu-item-1', 'tp-yt-paper-icon-item:has-text("Contenido")', 'tp-yt-paper-icon-item:has-text("Content")',
      ], 20000);
      await content.click();
    }
    await page.waitForTimeout(4000);
  };

  // encuentra la pestaña donde vive el draft (poll: el recién subido tarda en indexarse)
  let listUrl = null;
  const deadline = Date.now() + 120000;
  while (Date.now() < deadline && !listUrl) {
    for (const url of lists) {
      await gotoList(url);
      if (await page.locator(rowSel).first().isVisible({ timeout: 4000 }).catch(() => false)) { listUrl = url; break; }
    }
  }
  await shot(page, shotsDir, '09-lista-contenido.png');
  if (!listUrl) throw new Error('no encontré el draft de prueba en Videos ni Shorts (ni con 120s de reloads)');

  // borra una fila del test; devuelve false si ya no quedan, lanza en error transitorio (se reintenta)
  const deleteOne = async () => {
    const row = page.locator(rowSel).first();
    if (!await row.isVisible({ timeout: 5000 }).catch(() => false)) return false;
    await row.scrollIntoViewIfNeeded().catch(() => {});
    await row.hover();
    await page.waitForTimeout(400);
    const menu = await firstVisible(page, [
      `${rowSel} ytcp-icon-button[aria-label="Opciones"]`,
      `${rowSel} ytcp-icon-button[aria-label*="pciones"]`,
      `${rowSel} ytcp-icon-button[aria-label*="ptions"]`,
      `${rowSel} #hover-items ytcp-icon-button:last-of-type`,
    ]);
    await menu.click();
    const del = await firstVisible(page, [
      'tp-yt-paper-item:has-text("Borrar definitivamente")', 'tp-yt-paper-item:has-text("Eliminar definitivamente")',
      'tp-yt-paper-item:has-text("Delete forever")',
    ], 8000);
    await del.click();
    await page.waitForTimeout(1200);
    // marcar "comprendo que es permanente" → habilita #confirm-button.
    // clickear el HOST del checkbox (el #checkbox interno lo intercepta su contenedor).
    const chk = await firstVisible(page, [
      'ytcp-confirmation-dialog ytcp-checkbox-lit', 'tp-yt-paper-dialog ytcp-checkbox-lit',
      'ytcp-checkbox-lit', 'tp-yt-paper-checkbox',
    ]);
    await chk.click();
    const confirm = await firstVisible(page, [
      'ytcp-confirmation-dialog #confirm-button', 'tp-yt-paper-dialog #confirm-button', '#confirm-button',
    ]);
    for (let w = 0; w < 25; w++) {
      if (await confirm.getAttribute('aria-disabled').catch(() => null) !== 'true') break;
      await page.waitForTimeout(300);
    }
    await confirm.click();
    await page.waitForTimeout(4500);
    return true;
  };

  // idempotente: limpia también huérfanos de corridas previas; reintenta ante flake transitorio
  for (let guard = 0; guard < 10; guard++) {
    const r = await deleteOne().catch(() => null);   // null = flake → reintenta desde lista fresca
    if (r === false) break;
    await gotoList(listUrl);
  }
  await shot(page, shotsDir, '10-borrado.png');

  const still = await page.locator(rowSel).first().isVisible({ timeout: 4000 }).catch(() => false);
  if (still) throw new Error('el draft de prueba SIGUE en la lista tras el borrado');
}

export async function uploadFlow(projectDir, pub, { test = false, root, file = null } = {}) {
  const shotsDir = path.join(projectDir, 'upload-shots');
  let videoFile = file;

  if (test) {
    videoFile = path.join(root, 'demo', 'out', 'card-916.mp4');
    const exists = await fsp.stat(videoFile).catch(() => null);
    if (!exists) {
      process.stdout.write('renderizando el video de prueba (demo/card-916 → mp4)…\n');
      await fsp.mkdir(path.dirname(videoFile), { recursive: true });
      const r = spawnSync('node', [path.join(root, 'bin', 'sfrender.js'), path.join(root, 'demo', 'card-916'), '-o', videoFile, '--quiet'],
        { encoding: 'utf8', timeout: 180000 });
      if (r.status !== 0) throw new Error(`sfrender del video de prueba falló: ${(r.stderr || '').slice(0, 300)}`);
    }
  } else if (!videoFile) {
    throw new Error('modo real: pásame el máster con --file <path> (o usa --test para la prueba E2E segura)');
  }

  setStage(pub, 'upload', 'running', test ? 'prueba E2E con draft privado…' : `subiendo ${path.basename(videoFile)}…`);
  await savePublish(projectDir, pub);

  let defaults = {};
  try { defaults = JSON.parse(await fsp.readFile(path.join(root, 'channel-defaults.json'), 'utf8')); } catch { /* sin defaults */ }

  const { ctx, page } = await launch(false);
  try {
    process.stdout.write('checando sesión de Google en el perfil persistente…\n');
    const session = await hasSession(page);
    await shot(page, shotsDir, session ? '01-studio-con-sesion.png' : '01-sin-sesion-login.png');

    if (!session) {
      // ── RAMA B: sin sesión. Honesto: no se puede subir; el flujo queda listo y el ritual documentado.
      setStage(pub, 'upload', 'pending',
        'RAMA B: sin sesión Google en ~/.sfstudio/browser-profile — corre el ritual: node bin/sfpublish.js connect');
      await savePublish(projectDir, pub);
      process.stdout.write('\nRAMA B — el perfil no tiene sesión de Google (esperado en el primer uso).\n');
      process.stdout.write(RITUAL);
      return { branch: 'B', shotsDir };
    }

    // ── RAMA A: hay sesión → flujo completo
    await openUploadDialog(page);
    await shot(page, shotsDir, '02-dialogo-subida.png');

    const input = page.locator('input[type="file"]').first();
    await input.setInputFiles(videoFile, { timeout: 20000 });

    const md = pub.data?.metadata || {};
    await fillUploadDialog(page, shotsDir, {
      title: test ? TEST_TITLE : (pub.video?.titulo || md.titles?.[0] || path.basename(videoFile)),
      description: test ? 'Video de prueba del pipeline SFPublish. Se borra automáticamente.' : (md.description || ''),
      defaults,
    });

    if (test) {
      process.stdout.write('verificando el draft en la lista de contenido y BORRÁNDOLO…\n');
      await deleteTestVideo(page, shotsDir);
      setStage(pub, 'upload', 'done', 'RAMA A: E2E completo — draft privado subido, verificado y BORRADO (canal limpio)');
      await savePublish(projectDir, pub);
      process.stdout.write('✓ RAMA A completa: draft privado subido y borrado. Screenshots en ' + shotsDir + '\n');
      return { branch: 'A', shotsDir };
    }

    setStage(pub, 'upload', 'done', `subido como PRIVADO: ${path.basename(videoFile)} — la visibilidad la decide Daniel`);
    await savePublish(projectDir, pub);
    process.stdout.write('✓ subido como PRIVADO. Tarjetas/end screen: siguiente iteración (editor de draft).\n');
    return { branch: 'A', shotsDir };
  } catch (e) {
    await shot(page, shotsDir, '99-error.png');
    setStage(pub, 'upload', 'error', `falló: ${e.message.slice(0, 160)}`);
    await savePublish(projectDir, pub);
    throw e;
  } finally {
    await ctx.close().catch(() => {});
  }
}
