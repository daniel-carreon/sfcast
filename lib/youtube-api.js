/**
 * youtube-api.js — el eslabón que cierra la intervención 2 de Daniel.
 *
 * "Cuando valide todo, te doy la fecha de publicación y lo programas para X día a Y hora."
 *
 * El upload por navegador (upload-youtube.js) deja el video como BORRADOR PRIVADO y ahí para.
 * Lo que faltaba —miniatura y programación— NO necesita Playwright: el refresh token del canal
 * tiene scope `youtube.force-ssl` (verificado 26 jul 2026), así que se hace por Data API v3:
 *
 *   thumbnails.set   → sube la miniatura elegida
 *   videos.update    → título/descripción/tags + status.publishAt (la programación real)
 *
 * Por qué API y no Studio por navegador: el diálogo de Studio cambia de selectores cada tanto y
 * un canal monetizado mete pasos extra que traban el flujo. La API es contrato estable.
 *
 * Credenciales (agent-server/.env): YT_OAUTH_CLIENT_ID · YT_OAUTH_CLIENT_SECRET · YT_REFRESH_TOKEN
 */

const API = 'https://www.googleapis.com/youtube/v3';
const UPLOAD_API = 'https://www.googleapis.com/upload/youtube/v3';

export async function getAccessToken(env) {
  const { YT_OAUTH_CLIENT_ID: id, YT_OAUTH_CLIENT_SECRET: secret, YT_REFRESH_TOKEN: refresh } = env;
  if (!id || !secret || !refresh) {
    throw new Error('faltan YT_OAUTH_CLIENT_ID / YT_OAUTH_CLIENT_SECRET / YT_REFRESH_TOKEN en el .env');
  }
  const r = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ client_id: id, client_secret: secret, refresh_token: refresh, grant_type: 'refresh_token' }),
  });
  const j = await r.json();
  if (!r.ok || !j.access_token) throw new Error(`OAuth YouTube falló: ${JSON.stringify(j).slice(0, 200)}`);
  return j.access_token;
}

export async function getVideo(env, videoId, token = null) {
  const t = token || await getAccessToken(env);
  const r = await fetch(`${API}/videos?part=snippet,status,processingDetails&id=${videoId}`, {
    headers: { Authorization: `Bearer ${t}` },
  });
  const j = await r.json();
  if (!r.ok) throw new Error(`videos.list → ${r.status}: ${JSON.stringify(j).slice(0, 200)}`);
  if (!j.items?.length) throw new Error(`el video ${videoId} no existe o la cuenta no tiene acceso`);
  return j.items[0];
}

/** Sube la miniatura elegida. El canal debe estar verificado (el de Daniel lo está). */
export async function setThumbnail(env, videoId, filePath, token = null) {
  const t = token || await getAccessToken(env);
  const { readFile } = await import('node:fs/promises');
  const buf = await readFile(filePath);
  if (buf.length > 2 * 1024 * 1024) {
    throw new Error(`la miniatura pesa ${(buf.length / 1048576).toFixed(2)} MB — YouTube corta en 2 MB`);
  }
  const type = /\.png$/i.test(filePath) ? 'image/png' : 'image/jpeg';
  const r = await fetch(`${UPLOAD_API}/thumbnails/set?videoId=${videoId}&uploadType=media`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${t}`, 'Content-Type': type, 'Content-Length': String(buf.length) },
    body: buf,
  });
  const j = await r.json();
  if (!r.ok) throw new Error(`thumbnails.set → ${r.status}: ${JSON.stringify(j).slice(0, 300)}`);
  return j.items?.[0] || j;
}

/**
 * Programa el video y, de paso, fija la metadata final.
 *
 * OJO (regla de YouTube): para que `publishAt` sea válido el video debe estar en `private`.
 * Al llegar la hora, YouTube lo pasa a público solo. Si se mandara `public` con publishAt,
 * la API lo rechaza. Por eso privacyStatus va SIEMPRE 'private' aquí.
 */
export async function scheduleVideo(env, videoId, { publishAt, title, description, tags, categoryId }, token = null) {
  const t = token || await getAccessToken(env);
  const when = new Date(publishAt);
  if (isNaN(when.getTime())) throw new Error(`fecha inválida: ${publishAt}`);
  if (when.getTime() < Date.now() + 60_000) {
    throw new Error(`la fecha ${when.toISOString()} ya pasó (o es en menos de 1 min) — YouTube la rechaza`);
  }

  const current = await getVideo(env, videoId, t);
  const parts = ['status'];
  const body = {
    id: videoId,
    status: {
      privacyStatus: 'private',            // requisito de publishAt (YouTube lo publica solo a la hora)
      publishAt: when.toISOString(),
      selfDeclaredMadeForKids: false,
      embeddable: true,
      license: 'youtube',
    },
  };

  if (title || description || tags || categoryId) {
    parts.push('snippet');
    body.snippet = {
      title: title ?? current.snippet.title,
      description: description ?? current.snippet.description,
      categoryId: categoryId ?? current.snippet.categoryId,
      ...(tags ? { tags } : current.snippet.tags ? { tags: current.snippet.tags } : {}),
      defaultLanguage: current.snippet.defaultLanguage || 'es',
    };
  }

  const r = await fetch(`${API}/videos?part=${parts.join(',')}`, {
    method: 'PUT',
    headers: { Authorization: `Bearer ${t}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  const j = await r.json();
  if (!r.ok) throw new Error(`videos.update → ${r.status}: ${JSON.stringify(j).slice(0, 400)}`);
  return { id: j.id, privacyStatus: j.status?.privacyStatus, publishAt: j.status?.publishAt, title: j.snippet?.title };
}

/** Verificación post-hoc: lo que YouTube dice que quedó (evidencia, no fe). */
export async function verifyScheduled(env, videoId, expectedIso, token = null) {
  const v = await getVideo(env, videoId, token);
  const got = v.status?.publishAt || null;
  const ok = !!got && Math.abs(new Date(got) - new Date(expectedIso)) < 60_000;
  return {
    ok,
    privacyStatus: v.status.privacyStatus,
    publishAt: got,
    title: v.snippet.title,
    hasCustomThumb: !!v.snippet.thumbnails?.maxres || !!v.snippet.thumbnails?.standard,
  };
}
