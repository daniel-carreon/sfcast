#!/usr/bin/env python3
"""SFCast pipeline worker — el backend soberano del Loom de SaaS Factory.

Corre en el VPS (systemd sfcast-pipeline, cores 5-7, Nice 15 — SIEMPRE por
debajo de meet-pipeline). Flujo por sesión subida a /opt/sfcast/incoming/{id}:

  UPLOAD_DONE → concat segmentos (stream copy + faststart) → thumbnail →
  transcript faster-whisper (español) → OpenRouter: título + resumen +
  capítulos → genera viewer/embed HTML estáticos → actualiza biblioteca.

Además sirve en 127.0.0.1:9096: GET /health, POST /api/cast/view/{id} (vistas).
"""
import asyncio
import json
import os
import re
import shutil
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path

from aiohttp import web, ClientSession

BASE = Path("/opt/sfcast")
INCOMING = BASE / "incoming"
WWW = BASE / "www"
ENV_FILE = BASE / "pipeline" / ".env"
VIEWS_FILE = WWW / "views.json"
LIBRARY_FILE = WWW / "library.json"
PORT = 9096
POLL_S = 8

# ── env ──────────────────────────────────────────────────────────────────────
ENV = {}
if ENV_FILE.exists():
    for line in ENV_FILE.read_text().splitlines():
        if "=" in line and not line.startswith("#"):
            k, v = line.split("=", 1)
            ENV[k.strip()] = v.strip()

BASE_URL = ENV.get("SFCAST_BASE_URL", "https://livekit.saasfactory.so")
OPENROUTER_KEY = ENV.get("OPENROUTER_API_KEY", "")
LLM_MODEL = ENV.get("SFCAST_LLM_MODEL", "google/gemini-2.5-flash")

_whisper_model = None
_views_lock = asyncio.Lock()
_processing = set()


def log(msg: str):
    print(f"[{datetime.now().strftime('%H:%M:%S')}] {msg}", flush=True)


def run(cmd: list, timeout=1800) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


# ── transcripción ────────────────────────────────────────────────────────────
def get_model():
    global _whisper_model
    if _whisper_model is None:
        from faster_whisper import WhisperModel
        for name in ("large-v3-turbo", "turbo", "medium"):
            try:
                log(f"cargando modelo whisper '{name}' (int8, cpu)…")
                _whisper_model = WhisperModel(name, device="cpu", compute_type="int8", cpu_threads=3)
                log(f"modelo '{name}' listo")
                break
            except Exception as e:  # noqa: BLE001
                log(f"modelo '{name}' falló: {e}")
        if _whisper_model is None:
            raise RuntimeError("ningún modelo whisper disponible")
    return _whisper_model


def transcribe(video: Path) -> dict:
    t0 = time.time()
    model = get_model()
    segments, info = model.transcribe(
        str(video), language="es", vad_filter=True,
        condition_on_previous_text=False, beam_size=5)
    segs = [{"s": round(s.start, 2), "e": round(s.end, 2), "text": s.text.strip()}
            for s in segments if s.text.strip()]
    text = " ".join(s["text"] for s in segs)
    log(f"transcript: {len(segs)} segmentos, {len(text)} chars en {time.time()-t0:.0f}s")
    return {"segments": segs, "text": text, "language": info.language,
            "processing_s": round(time.time() - t0, 1)}


# ── LLM: título + resumen + capítulos ────────────────────────────────────────
async def enrich(transcript_text: str, duration_s: float) -> dict:
    fallback = {
        "titulo": f"Grabación {datetime.now().strftime('%d %b %Y %H:%M')}",
        "resumen": "", "resumen_corto": "", "capitulos": [],
    }
    if not OPENROUTER_KEY or len(transcript_text.strip()) < 40:
        return fallback
    n_caps = 3 if duration_s < 240 else (5 if duration_s < 900 else 8)
    prompt = f"""Eres el editor de video de SaaS Factory. Este es el transcript (español) de una grabación de pantalla de {duration_s:.0f} segundos.

TRANSCRIPT:
{transcript_text[:14000]}

Devuelve SOLO un JSON válido (sin markdown, sin explicación) con:
{{"titulo": "título corto y específico (máx 60 chars, sin comillas internas)",
 "resumen": "resumen útil en 2-4 frases en español",
 "resumen_corto": "una sola frase (máx 120 chars)",
 "capitulos": [{{"t": <segundos desde inicio, número>, "titulo": "..."}}] (entre 2 y {n_caps}, el primero en t=0)}}"""
    try:
        async with ClientSession() as http:
            async with http.post(
                "https://openrouter.ai/api/v1/chat/completions",
                headers={"Authorization": f"Bearer {OPENROUTER_KEY}"},
                json={"model": LLM_MODEL, "temperature": 0.3,
                      "messages": [{"role": "user", "content": prompt}]},
                timeout=90,
            ) as resp:
                data = await resp.json()
        raw = data["choices"][0]["message"]["content"]
        raw = re.sub(r"^```(json)?|```$", "", raw.strip(), flags=re.M).strip()
        out = json.loads(raw)
        caps = [c for c in out.get("capitulos", [])
                if isinstance(c.get("t"), (int, float)) and 0 <= c["t"] < duration_s]
        return {
            "titulo": str(out.get("titulo") or fallback["titulo"])[:80],
            "resumen": str(out.get("resumen", "")),
            "resumen_corto": str(out.get("resumen_corto", ""))[:160],
            "capitulos": caps[:10],
        }
    except Exception as e:  # noqa: BLE001
        log(f"LLM enrich falló ({e}) — uso fallback")
        return fallback


# ── media ────────────────────────────────────────────────────────────────────
def concat_segments(session_dir: Path, out: Path) -> None:
    segs = sorted(list(session_dir.glob("seg-*.mp4")) + list(session_dir.glob("seg-*.mov")))
    if not segs:
        raise RuntimeError("sin segmentos seg-*")
    if len(segs) == 1:
        r = run(["ffmpeg", "-y", "-i", str(segs[0]), "-c", "copy",
                 "-movflags", "+faststart", str(out)])
    else:
        lst = session_dir / "concat.txt"
        lst.write_text("".join(f"file '{s}'\n" for s in segs))
        r = run(["ffmpeg", "-y", "-f", "concat", "-safe", "0", "-i", str(lst),
                 "-c", "copy", "-movflags", "+faststart", str(out)])
    if r.returncode != 0 or not out.exists():
        raise RuntimeError(f"concat falló: {r.stderr[-400:]}")


def probe_duration(video: Path) -> float:
    r = run(["ffprobe", "-v", "error", "-show_entries", "format=duration",
             "-of", "csv=p=0", str(video)])
    return float(r.stdout.strip() or 0)


def make_thumb(video: Path, out: Path, duration: float) -> None:
    ts = max(1.0, min(duration * 0.15, 30.0))
    run(["ffmpeg", "-y", "-ss", str(ts), "-i", str(video),
         "-frames:v", "1", "-vf", "scale=1280:-2", str(out)])


# ── html ─────────────────────────────────────────────────────────────────────
def esc(s: str) -> str:
    return (s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
            .replace('"', "&quot;"))


CSS = """
:root{--bg:#0b0c0e;--card:#141619;--line:#26292e;--txt:#e8e8e6;--dim:#9a9a94;--acc:#ff9101}
*{margin:0;padding:0;box-sizing:border-box}
body{background:var(--bg);color:var(--txt);font:16px/1.6 -apple-system,'SF Pro Text',Segoe UI,Roboto,sans-serif}
.wrap{max-width:960px;margin:0 auto;padding:24px 20px 80px}
.brand{display:flex;align-items:center;gap:10px;padding:14px 0 22px;color:var(--dim);font-size:13px;letter-spacing:.08em;text-transform:uppercase}
.brand b{color:var(--acc);letter-spacing:.02em}
h1{font-size:26px;line-height:1.25;margin-bottom:6px;font-weight:700}
.meta{color:var(--dim);font-size:13px;margin-bottom:18px}
video{width:100%;border-radius:14px;background:#000;display:block;border:1px solid var(--line)}
.controls{display:flex;flex-wrap:wrap;gap:8px;align-items:center;margin:14px 0 6px}
.chip{border:1px solid var(--line);background:var(--card);color:var(--txt);border-radius:999px;padding:5px 13px;font-size:13px;cursor:pointer}
.chip.on{background:var(--acc);color:#111;border-color:var(--acc);font-weight:600}
.chip:hover{border-color:var(--acc)}
.spacer{flex:1}
section{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:18px 20px;margin-top:18px}
section h2{font-size:13px;letter-spacing:.1em;text-transform:uppercase;color:var(--acc);margin-bottom:10px}
.caps a{display:flex;gap:12px;padding:7px 4px;color:var(--txt);text-decoration:none;border-radius:8px}
.caps a:hover{background:#1c1f24}
.caps .t{color:var(--acc);font-variant-numeric:tabular-nums;min-width:52px;font-size:14px}
.tr span{cursor:pointer;border-radius:4px;padding:1px 2px}
.tr span:hover{background:#22252b}
.tr span.on{background:rgba(255,145,1,.18);color:#ffd9a1}
.foot{margin-top:26px;color:var(--dim);font-size:12.5px;text-align:center}
.foot a{color:var(--acc);text-decoration:none}
"""


def viewer_html(d: dict) -> str:
    data_json = json.dumps({"id": d["id"], "segments": d["transcript"]["segments"],
                            "capitulos": d["capitulos"]}, ensure_ascii=False)
    caps_html = "".join(
        f'<a href="#" data-t="{c["t"]}"><span class="t">{int(c["t"])//60:02d}:{int(c["t"])%60:02d}</span>'
        f'<span>{esc(c["titulo"])}</span></a>' for c in d["capitulos"])
    dur = int(d["duration"])
    fecha = d["created"][:10]
    return f"""<!doctype html><html lang="es"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow"><link rel="icon" href="data:,">
<title>{esc(d["titulo"])} — SFCast</title>
<meta property="og:title" content="{esc(d["titulo"])}">
<meta property="og:description" content="{esc(d["resumen_corto"] or "Video de SaaS Factory")}">
<meta property="og:image" content="{BASE_URL}/media/{d["id"]}/thumb.jpg">
<meta property="og:type" content="video.other">
<meta name="twitter:card" content="summary_large_image">
<style>{CSS}</style></head><body><div class="wrap">
<div class="brand"><b>SFCast</b> · SaaS Factory</div>
<h1>{esc(d["titulo"])}</h1>
<div class="meta">{fecha} · {dur//60}:{dur%60:02d} min · <span id="views">…</span> vistas</div>
<video id="v" controls playsinline preload="metadata" poster="{BASE_URL}/media/{d["id"]}/thumb.jpg">
<source src="{BASE_URL}/media/{d["id"]}/video.mp4" type="video/mp4"></video>
<div class="controls">
  <span style="color:var(--dim);font-size:13px">Velocidad</span>
  <button class="chip" data-r="0.8">0.8×</button><button class="chip" data-r="1">1×</button>
  <button class="chip on" data-r="1.2">1.2×</button><button class="chip" data-r="1.5">1.5×</button>
  <button class="chip" data-r="2">2×</button><button class="chip" data-r="2.5">2.5×</button>
  <span class="spacer"></span>
  <button class="chip" id="copyLink">🔗 Copiar link</button>
  <button class="chip" id="copyEmbed">&lt;/&gt; Copiar embed</button>
</div>
{f'<section><h2>Resumen</h2><p>{esc(d["resumen"])}</p></section>' if d["resumen"] else ""}
{f'<section><h2>Capítulos</h2><div class="caps">{caps_html}</div></section>' if d["capitulos"] else ""}
<section><h2>Transcript</h2><p class="tr" id="tr"></p></section>
<div class="foot">Grabado con <b>SFCast</b> — infraestructura propia de <a href="https://www.saasfactory.so">SaaS Factory</a></div>
</div>
<script>
const D={data_json};const v=document.getElementById('v');
v.addEventListener('loadedmetadata',()=>{{v.playbackRate=1.2}});
document.querySelectorAll('.chip[data-r]').forEach(b=>b.onclick=()=>{{
  v.playbackRate=parseFloat(b.dataset.r);
  document.querySelectorAll('.chip[data-r]').forEach(x=>x.classList.remove('on'));b.classList.add('on');}});
const tr=document.getElementById('tr');
D.segments.forEach((s,i)=>{{const sp=document.createElement('span');sp.textContent=s.text+' ';
  sp.dataset.s=s.s;sp.dataset.e=s.e;sp.id='seg'+i;
  sp.onclick=()=>{{v.currentTime=s.s;v.play()}};tr.appendChild(sp);}});
v.addEventListener('timeupdate',()=>{{const t=v.currentTime;
  D.segments.forEach((s,i)=>{{document.getElementById('seg'+i).classList.toggle('on',t>=s.s&&t<s.e)}});}});
document.querySelectorAll('.caps a').forEach(a=>a.onclick=e=>{{e.preventDefault();
  v.currentTime=parseFloat(a.dataset.t);v.play()}});
document.getElementById('copyLink').onclick=()=>navigator.clipboard.writeText('{BASE_URL}/v/{d["id"]}/').then(()=>toast('Link copiado'));
document.getElementById('copyEmbed').onclick=()=>navigator.clipboard.writeText(
 `<iframe src="{BASE_URL}/embed/{d["id"]}/" width="800" height="450" frameborder="0" allowfullscreen></iframe>`).then(()=>toast('Embed copiado'));
function toast(m){{const t=document.createElement('div');t.textContent=m;
 t.style.cssText='position:fixed;bottom:24px;left:50%;transform:translateX(-50%);background:#ff9101;color:#111;padding:8px 18px;border-radius:999px;font-weight:600;z-index:9';
 document.body.appendChild(t);setTimeout(()=>t.remove(),1800);}}
fetch('{BASE_URL}/api/cast/view/{d["id"]}',{{method:'POST'}}).then(r=>r.json())
 .then(j=>document.getElementById('views').textContent=j.views).catch(()=>document.getElementById('views').textContent='—');
</script></body></html>"""


def embed_html(d: dict) -> str:
    return f"""<!doctype html><html lang="es"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow"><link rel="icon" href="data:,"><title>{esc(d["titulo"])}</title>
<style>html,body{{margin:0;height:100%;background:#000}}
video{{width:100%;height:100%;object-fit:contain;display:block}}
.tag{{position:absolute;left:10px;bottom:10px;background:rgba(11,12,14,.82);color:#e8e8e6;
padding:5px 12px;border-radius:8px;font:12.5px -apple-system,sans-serif;text-decoration:none;border:1px solid #26292e}}
.tag b{{color:#ff9101}}</style></head><body>
<video controls playsinline preload="metadata" poster="{BASE_URL}/media/{d["id"]}/thumb.jpg">
<source src="{BASE_URL}/media/{d["id"]}/video.mp4" type="video/mp4"></video>
<a class="tag" href="{BASE_URL}/v/{d["id"]}/" target="_blank">▶ {esc(d["titulo"][:48])} · <b>SFCast</b></a>
</body></html>"""


def library_html(items: list) -> str:
    cards = ""
    for d in items:
        dur = int(d.get("duration", 0))
        cards += f"""<a class="card" href="{BASE_URL}/v/{d["id"]}/" data-q="{esc(d["titulo"].lower())}">
<img loading="lazy" src="{BASE_URL}/media/{d["id"]}/thumb.jpg" alt="">
<div class="cb"><div class="ct">{esc(d["titulo"])}</div>
<div class="cm">{d["created"][:10]} · {dur//60}:{dur%60:02d} · {d.get("views",0)} vistas</div></div></a>"""
    return f"""<!doctype html><html lang="es"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow"><link rel="icon" href="data:,"><title>Biblioteca — SFCast</title>
<style>{CSS}
.grid{{display:grid;grid-template-columns:repeat(auto-fill,minmax(280px,1fr));gap:16px;margin-top:18px}}
.card{{background:var(--card);border:1px solid var(--line);border-radius:14px;overflow:hidden;text-decoration:none;color:var(--txt)}}
.card:hover{{border-color:var(--acc)}}
.card img{{width:100%;aspect-ratio:16/9;object-fit:cover;background:#000}}
.cb{{padding:12px 14px}}.ct{{font-weight:600;font-size:15px;line-height:1.35}}
.cm{{color:var(--dim);font-size:12.5px;margin-top:5px}}
#q{{width:100%;background:var(--card);border:1px solid var(--line);color:var(--txt);border-radius:10px;padding:10px 14px;font-size:15px}}</style>
</head><body><div class="wrap">
<div class="brand"><b>SFCast</b> · Biblioteca privada</div>
<input id="q" placeholder="Buscar en {len(items)} videos…">
<div class="grid" id="grid">{cards}</div>
<div class="foot">SFCast — el Loom soberano de SaaS Factory</div></div>
<script>document.getElementById('q').oninput=e=>{{const q=e.target.value.toLowerCase();
document.querySelectorAll('.card').forEach(c=>c.style.display=c.dataset.q.includes(q)?'':'none')}};</script>
</body></html>"""


# ── procesamiento de una sesión ──────────────────────────────────────────────
async def process_session(session_dir: Path):
    vid = session_dir.name
    log(f"▶ procesando {vid}")
    meta = {}
    mf = session_dir / "meta.json"
    if mf.exists():
        meta = json.loads(mf.read_text())

    media_dir = WWW / "media" / vid
    media_dir.mkdir(parents=True, exist_ok=True)
    video = media_dir / "video.mp4"

    loop = asyncio.get_event_loop()
    await loop.run_in_executor(None, concat_segments, session_dir, video)
    duration = await loop.run_in_executor(None, probe_duration, video)
    await loop.run_in_executor(None, make_thumb, video, media_dir / "thumb.jpg", duration)
    log(f"{vid}: video.mp4 {duration:.0f}s + thumb listos")

    transcript = await loop.run_in_executor(None, transcribe, video)
    llm = await enrich(transcript["text"], duration)

    data = {
        "id": vid,
        "titulo": llm["titulo"],
        "resumen": llm["resumen"],
        "resumen_corto": llm["resumen_corto"],
        "capitulos": llm["capitulos"],
        "duration": duration,
        "created": meta.get("startedAt") or datetime.now(timezone.utc).isoformat(),
        "mode": meta.get("mode", "screen"),
        "views": 0,
        "transcript": transcript,
    }
    (media_dir / "data.json").write_text(json.dumps(data, ensure_ascii=False, indent=1))

    vdir = WWW / "v" / vid
    edir = WWW / "embed" / vid
    vdir.mkdir(parents=True, exist_ok=True)
    edir.mkdir(parents=True, exist_ok=True)
    (vdir / "index.html").write_text(viewer_html(data))
    (edir / "index.html").write_text(embed_html(data))

    rebuild_library()
    shutil.rmtree(session_dir)
    log(f"✓ {vid} publicado: {BASE_URL}/v/{vid}/ («{data['titulo']}»)")


def rebuild_library():
    views = {}
    if VIEWS_FILE.exists():
        views = json.loads(VIEWS_FILE.read_text())
    items = []
    for dj in sorted(WWW.glob("media/*/data.json"),
                     key=lambda p: p.stat().st_mtime, reverse=True):
        try:
            d = json.loads(dj.read_text())
            d["views"] = views.get(d["id"], 0)
            items.append({k: d[k] for k in
                          ("id", "titulo", "resumen_corto", "duration", "created", "views")})
        except Exception as e:  # noqa: BLE001
            log(f"library skip {dj}: {e}")
    LIBRARY_FILE.write_text(json.dumps(items, ensure_ascii=False, indent=1))
    bib = WWW / "biblioteca"
    bib.mkdir(parents=True, exist_ok=True)
    (bib / "index.html").write_text(library_html(items))


# ── poller + http ────────────────────────────────────────────────────────────
async def poller():
    log(f"poller arriba (cada {POLL_S}s) — base {BASE_URL}")
    while True:
        try:
            for done in sorted(INCOMING.glob("*/UPLOAD_DONE")):
                sd = done.parent
                if sd.name in _processing:
                    continue
                _processing.add(sd.name)
                try:
                    await process_session(sd)
                except Exception as e:  # noqa: BLE001
                    log(f"✗ {sd.name} FALLÓ: {e}")
                    (sd / "FAILED").write_text(str(e))
                    done.unlink(missing_ok=True)   # no reintentar en loop
                finally:
                    _processing.discard(sd.name)
        except Exception as e:  # noqa: BLE001
            log(f"poller error: {e}")
        await asyncio.sleep(POLL_S)


async def handle_health(_req):
    return web.json_response({
        "ok": True, "service": "sfcast-pipeline",
        "queue": len(list(INCOMING.glob("*/UPLOAD_DONE"))),
        "processing": sorted(_processing),
        "videos": len(list(WWW.glob("media/*/data.json"))),
    })


async def handle_view(req):
    vid = req.match_info["id"]
    if not re.fullmatch(r"[a-z0-9-]{4,40}", vid):
        return web.json_response({"error": "id"}, status=400)
    async with _views_lock:
        views = json.loads(VIEWS_FILE.read_text()) if VIEWS_FILE.exists() else {}
        views[vid] = views.get(vid, 0) + 1
        VIEWS_FILE.write_text(json.dumps(views))
    return web.json_response({"views": views[vid]})


async def main():
    INCOMING.mkdir(parents=True, exist_ok=True)
    rebuild_library()
    app = web.Application()
    app.router.add_get("/health", handle_health)
    app.router.add_get("/api/cast/health", handle_health)
    app.router.add_post("/api/cast/view/{id}", handle_view)
    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, "127.0.0.1", PORT)
    await site.start()
    log(f"http 127.0.0.1:{PORT} listo")
    await poller()


if __name__ == "__main__":
    asyncio.run(main())
