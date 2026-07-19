// Servidor estático mínimo compartido por sfrender (cards) y sfreview (sala).
// Soporta HTTP Range (seek de mp4 largos) y manda no-cache SIEMPRE (mata el gotcha #34).
import http from 'node:http';
import { createReadStream, promises as fsp } from 'node:fs';
import path from 'node:path';

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.svg': 'image/svg+xml',
  '.webp': 'image/webp',
  '.mp4': 'video/mp4',
  '.mov': 'video/quicktime',
  '.webm': 'video/webm',
  '.ttf': 'font/ttf',
  '.otf': 'font/otf',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.ico': 'image/x-icon',
};

function safeJoin(root, urlPath) {
  const decoded = decodeURIComponent(urlPath.split('?')[0]);
  const resolved = path.normalize(path.join(root, decoded));
  if (!resolved.startsWith(path.normalize(root))) return null; // path traversal
  return resolved;
}

export async function serveFile(req, res, filePath) {
  let st;
  try {
    st = await fsp.stat(filePath);
    if (st.isDirectory()) {
      filePath = path.join(filePath, 'index.html');
      st = await fsp.stat(filePath);
    }
  } catch {
    res.writeHead(404, { 'Content-Type': 'text/plain' });
    res.end('404');
    return;
  }
  const mime = MIME[path.extname(filePath).toLowerCase()] || 'application/octet-stream';
  const headers = {
    'Content-Type': mime,
    'Cache-Control': 'no-store, no-cache, must-revalidate',
    'Accept-Ranges': 'bytes',
    'Access-Control-Allow-Origin': '*',
  };
  const range = req.headers.range;
  if (range) {
    const m = /^bytes=(\d*)-(\d*)$/.exec(range);
    if (m) {
      let start = m[1] === '' ? null : parseInt(m[1], 10);
      let end = m[2] === '' ? null : parseInt(m[2], 10);
      if (start === null) { start = st.size - end; end = st.size - 1; }
      else if (end === null || end >= st.size) end = st.size - 1;
      if (start >= 0 && start <= end && start < st.size) {
        res.writeHead(206, {
          ...headers,
          'Content-Range': `bytes ${start}-${end}/${st.size}`,
          'Content-Length': end - start + 1,
        });
        createReadStream(filePath, { start, end }).pipe(res);
        return;
      }
      res.writeHead(416, { 'Content-Range': `bytes */${st.size}` });
      res.end();
      return;
    }
  }
  res.writeHead(200, { ...headers, 'Content-Length': st.size });
  createReadStream(filePath).pipe(res);
}

/**
 * Sirve `root` en 127.0.0.1. port 0 = efímero. `routes` opcional: {'/api/x': (req,res)=>bool-handled}.
 * Devuelve { server, port, url, close() }.
 */
export async function startStatic(root, { port = 0, routes = null } = {}) {
  const server = http.createServer(async (req, res) => {
    try {
      if (routes) {
        for (const [prefix, handler] of Object.entries(routes)) {
          if (req.url.split('?')[0] === prefix || req.url.startsWith(prefix + '/') || req.url.startsWith(prefix + '?')) {
            const handled = await handler(req, res);
            if (handled !== false) return;
          }
        }
      }
      const fp = safeJoin(root, req.url === '/' ? '/index.html' : req.url);
      if (!fp) {
        res.writeHead(403); res.end('403');
        return;
      }
      await serveFile(req, res, fp);
    } catch (e) {
      if (!res.headersSent) res.writeHead(500, { 'Content-Type': 'text/plain' });
      res.end('500 ' + e.message);
    }
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(port, '127.0.0.1', resolve);
  });
  const actual = server.address().port;
  return {
    server,
    port: actual,
    url: `http://127.0.0.1:${actual}`,
    close: () => new Promise((r) => server.close(r)),
  };
}
