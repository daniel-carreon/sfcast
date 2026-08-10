#!/usr/bin/env python3
"""SFCast pipeline worker — el backend soberano del Loom de SaaS Factory.

Corre en el VPS (systemd sfcast-pipeline, cores 5-7, Nice 15 — SIEMPRE por
debajo de meet-pipeline). Flujo por sesión subida a /opt/sfcast/incoming/{id}:

  UPLOAD_DONE
    │
    ├─ FASE 1  concat (stream copy + faststart) → thumbnail → PUBLICA el
    │          reproductor con ready:false.  ← aquí el video ya SE VE
    ├─ FASE 2  transcript (Groq, fallback faster-whisper) → OpenRouter para
    │          título/resumen/capítulos → republica con ready:true.
    │          La página abierta se completa SOLA sondeando data.json.
    └─ FASE 3  transcode a H.264 (compatibilidad real) → espejo a R2.

POR QUÉ EN TRES FASES (medido el 10 ago 2026): el pipeline tardaba 5m53s en un
video de 4:28, y el `video.mp4` estaba reproducible en el servidor 2m35s antes
de que la página dejara de decir "Procesando". Se esperaba al transcript para
mostrar un video que nadie necesita transcrito para verlo. Loom no hace eso.

Las otras dos mediciones del mismo día:
  · Groq whisper-large-v3-turbo tarda 2.0s donde faster-whisper tarda 153s
    (no por el modelo: por `CPUQuota=200%`, 2 de los 8 cores del EPYC).
  · Se servía HEVC 4096x2304, que NO reproduce en Chrome/Windows ni Firefox ni
    buena parte de Android — reproductor en negro, en silencio, también desde R2.

Además sirve en 127.0.0.1:9096: GET /health, POST /api/cast/view/{id} (vistas).
"""
import asyncio
import json
import os
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

from aiohttp import web, ClientSession, FormData

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
GROQ_KEY = ENV.get("GROQ_API_KEY", "")
STT_MODEL = ENV.get("SFCAST_STT_MODEL", "whisper-large-v3-turbo")
# Alto máximo del archivo de DISTRIBUCIÓN. La captura ya llega a 1440 (tope del
# lado Mac, v3.4); esto solo defiende contra material viejo o importado en 4K.
DIST_MAX_HEIGHT = int(ENV.get("SFCAST_DIST_MAX_HEIGHT", "1440"))

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


def extract_audio(video: Path, out: Path, ss: float = 0, dur: float = 0) -> bool:
    """Pista de audio sola, mono 16 kHz mp3 32 kbps: ~1 MB por 4:30 de video.

    Whisper remuestrea a 16 kHz mono de todos modos, así que esto no tira ni un
    bit que el modelo fuera a usar — solo evita empujar el video entero por la
    red.
    """
    cmd = ["ffmpeg", "-y", "-v", "error"]
    if ss:
        cmd += ["-ss", f"{ss:.3f}"]
    cmd += ["-i", str(video)]
    if dur:
        cmd += ["-t", f"{dur:.3f}"]
    cmd += ["-vn", "-ac", "1", "-ar", "16000", "-c:a", "libmp3lame", "-b:a", "32k", str(out)]
    return run(cmd, timeout=900).returncode == 0 and out.exists() and out.stat().st_size > 0


async def transcribe_groq(video: Path, duration: float) -> dict | None:
    """Transcript por Groq. Devuelve None si no se puede (el que llama cae al local).

    POR QUÉ (medido el 10 ago sobre el mismo audio de 4:28): faster-whisper en
    este VPS tarda 153s — no por el modelo, sino porque el servicio corre con
    `CPUQuota=200%` sobre 3 cores permitidos, o sea 2 de los 8 del EPYC, y ese
    techo existe para proteger al SFU del Meet. Groq hace lo mismo en **2.0s**,
    con transcript equivalente (97 segmentos / 3,925 chars contra 107 / 3,969) y
    $0.003 por video.

    El troceo es por si algún día entra una grabación larguísima: a 32 kbps, los
    25 MB que acepta la API son ~1.7 horas de audio. Se corta en tramos de 1h y
    se reajustan los tiempos de cada tramo a la línea de tiempo del video.
    """
    if not GROQ_KEY:
        return None
    t0 = time.time()
    tmp = Path("/tmp") / f"sfcast-stt-{video.parent.name}"
    tmp.mkdir(parents=True, exist_ok=True)
    CHUNK = 3600.0
    try:
        offsets = [0.0] if duration <= CHUNK else [
            i * CHUNK for i in range(int(duration // CHUNK) + 1)]
        segs: list[dict] = []
        async with ClientSession() as http:
            for i, off in enumerate(offsets):
                piece = tmp / f"p{i}.mp3"
                if not extract_audio(video, piece, ss=off,
                                     dur=CHUNK if len(offsets) > 1 else 0):
                    return None
                form = FormData()
                form.add_field("file", piece.read_bytes(), filename=piece.name,
                               content_type="audio/mpeg")
                form.add_field("model", STT_MODEL)
                form.add_field("language", "es")
                form.add_field("response_format", "verbose_json")
                async with http.post(
                    "https://api.groq.com/openai/v1/audio/transcriptions",
                    headers={"Authorization": f"Bearer {GROQ_KEY}"},
                    data=form, timeout=600,
                ) as resp:
                    if resp.status != 200:
                        log(f"groq HTTP {resp.status}: {(await resp.text())[:200]}")
                        return None
                    payload = await resp.json()
                for s in payload.get("segments", []):
                    text = (s.get("text") or "").strip()
                    if text:
                        segs.append({"s": round(float(s["start"]) + off, 2),
                                     "e": round(float(s["end"]) + off, 2),
                                     "text": text})
        if not segs:
            return None
        text = " ".join(s["text"] for s in segs)
        log(f"transcript (groq/{STT_MODEL}): {len(segs)} segmentos, "
            f"{len(text)} chars en {time.time()-t0:.1f}s")
        return {"segments": segs, "text": text, "language": "es",
                "processing_s": round(time.time() - t0, 1), "engine": "groq"}
    except Exception as e:  # noqa: BLE001
        log(f"groq falló ({str(e)[:160]}) — caigo a whisper local")
        return None
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


async def transcribe_best(video: Path, duration: float) -> dict:
    """Groq primero, faster-whisper local de red de seguridad.

    El local se queda a propósito: es lo que hace que un corte de internet o una
    llave vencida degraden la calidad de servicio (más lento) en vez de tumbar
    el pipeline (sin transcript).
    """
    got = await transcribe_groq(video, duration)
    if got:
        return got
    loop = asyncio.get_event_loop()
    return await loop.run_in_executor(None, transcribe, video)


def transcribe(video: Path) -> dict:
    t0 = time.time()
    model = get_model()
    segments, info = model.transcribe(
        str(video), language="es", vad_filter=True,
        condition_on_previous_text=False, beam_size=5)
    segs = [{"s": round(s.start, 2), "e": round(s.end, 2), "text": s.text.strip()}
            for s in segments if s.text.strip()]
    text = " ".join(s["text"] for s in segs)
    log(f"transcript (local): {len(segs)} segmentos, {len(text)} chars en {time.time()-t0:.0f}s")
    return {"segments": segs, "text": text, "language": info.language,
            "processing_s": round(time.time() - t0, 1), "engine": "local"}


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


def probe_video(video: Path) -> tuple[str, int, int]:
    r = run(["ffprobe", "-v", "error", "-select_streams", "v:0",
             "-show_entries", "stream=codec_name,width,height",
             "-of", "csv=p=0:s=x", str(video)])
    parts = (r.stdout.strip().split("x") + ["", "0", "0"])[:3]
    try:
        return parts[0], int(parts[1]), int(parts[2])
    except ValueError:
        return parts[0], 0, 0


def distribute_encode(video: Path) -> bool:
    """Deja `video.mp4` en H.264 reproducible EN CUALQUIER LADO. Devuelve si tocó algo.

    POR QUÉ ES CORRECCIÓN Y NO OPTIMIZACIÓN (10 ago 2026): `SCRecordingOutput`
    solo escribe **HEVC** — está forzado en el Mac a propósito, porque esquiva el
    tope de H.264 a 4096x2304 en Retina/5K. Perfecto para grabar; pésimo para
    distribuir. HEVC no reproduce en Chrome/Windows sin la extensión de pago de
    Microsoft, ni en Firefox en varias plataformas, ni en buena parte de Android.
    Verificado el mismo día contra R2: el video del anuncio a ~570 miembros se
    servía como `hevc/hvc1 4096x2304`, o sea reproductor en negro para una parte
    de la comunidad. Y falla EN SILENCIO: nadie escribe para avisar que un video
    no cargó.

    Corre DESPUÉS de publicar el reproductor: nadie está esperando esto. El
    reemplazo es atómico (`os.replace`), así que un espectador que ya tenga el
    archivo abierto sigue con su descriptor; a lo mucho, si busca en la línea de
    tiempo justo en ese instante, recarga.

    Best-effort: si ffmpeg falla, se queda el original. Un video que no se puede
    ver en Chrome sigue siendo mejor que ningún video.
    """
    codec, w, h = probe_video(video)
    marker = video.parent / ".dist.json"
    if codec == "h264" and h <= DIST_MAX_HEIGHT:
        marker.write_text(json.dumps({"codec": codec, "w": w, "h": h, "skipped": True}))
        return False

    t0 = time.time()
    before = video.stat().st_size
    tmp = video.parent / "video-dist.mp4"
    vf = []
    if h > DIST_MAX_HEIGHT > 0 and w > 0:
        nh = DIST_MAX_HEIGHT
        nw = max(2, int(round(w * nh / h)) & ~1)   # PAR: yuv420p no admite impares
        vf = ["-vf", f"scale={nw}:{nh}"]
    r = run(["ffmpeg", "-y", "-nostdin", "-v", "error", "-i", str(video),
             *vf,
             "-c:v", "libx264", "-profile:v", "high", "-pix_fmt", "yuv420p",
             "-preset", "veryfast", "-crf", "23", "-tag:v", "avc1",
             # El audio ya viene aac mezclado: recodificarlo solo perdería.
             "-c:a", "copy",
             "-movflags", "+faststart", str(tmp)], timeout=7200)
    if r.returncode != 0 or not tmp.exists() or tmp.stat().st_size == 0:
        tmp.unlink(missing_ok=True)
        log(f"⚠ distribución: ffmpeg falló en {video.parent.name} — se queda el HEVC "
            f"({r.stderr[-200:].strip()})")
        return False
    # Compuerta de duración ANTES de pisar el original: un archivo más chico pero
    # cortado es peor que uno pesado pero completo.
    d0, d1 = probe_duration(video), probe_duration(tmp)
    if d0 > 0 and abs(d0 - d1) > 1.0:
        tmp.unlink(missing_ok=True)
        log(f"⚠ distribución: duración cambió ({d0:.1f}s → {d1:.1f}s) — se queda el original")
        return False
    after = tmp.stat().st_size
    os.replace(tmp, video)
    marker.write_text(json.dumps({"codec": "h264", "w": w, "h": h,
                                  "before": before, "after": after}))
    log(f"✓ distribución {video.parent.name}: {codec} {w}x{h} → h264 "
        f"{before/1e6:.0f} MB → {after/1e6:.0f} MB en {time.time()-t0:.0f}s")
    return True


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
.wait{color:var(--dim);font-size:13.5px;font-style:italic}
.wait::before{content:'';display:inline-block;width:9px;height:9px;margin-right:8px;
 border-radius:50%;background:var(--acc);opacity:.35;animation:p 1.4s ease-in-out infinite}
@keyframes p{50%{opacity:1}}
"""


def viewer_html(d: dict) -> str:
    """El reproductor. Se escribe DOS VECES por video, y esa es la idea.

    La primera pasada sale en cuanto el `video.mp4` existe, con `ready:false` y
    sin transcript: lo único que importa en ese momento es que el video SE PUEDA
    VER. La segunda, cuando llegan transcript/título/capítulos, la reescribe
    completa para que un visitante nuevo y las og: del link tengan el título real.

    Entre una y otra, la página YA ABIERTA se completa sola: sondea `data.json`
    y pinta lo que falta SIN recargar y sin tocar el `<video>` — para que
    completarse no le corte la reproducción a nadie. Es exactamente lo que hace
    Loom, y es la diferencia entre publicar en ~40s y publicar en 5m53s: medido
    el 10 ago, el video estuvo reproducible en el servidor 2m35s antes de que la
    página dejara de decir "Procesando".
    """
    data_json = json.dumps({"id": d["id"], "ready": d.get("ready", True),
                            "titulo": d["titulo"], "resumen": d["resumen"],
                            "segments": d["transcript"]["segments"],
                            "capitulos": d["capitulos"]}, ensure_ascii=False)
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
<h1 id="h1">{esc(d["titulo"])}</h1>
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
<section id="sResumen" hidden><h2>Resumen</h2><p id="resumen"></p></section>
<section id="sCaps" hidden><h2>Capítulos</h2><div class="caps" id="caps"></div></section>
<section><h2>Transcript</h2><p class="tr" id="tr"></p><p id="trWait" class="wait">Transcribiendo… aparece aquí solo, sin recargar.</p></section>
<div class="foot">Grabado con <b>SFCast</b> — infraestructura propia de <a href="https://www.saasfactory.so">SaaS Factory</a></div>
</div>
<script>
let D={data_json};const v=document.getElementById('v');
v.addEventListener('loadedmetadata',()=>{{v.playbackRate=1.2}});
document.querySelectorAll('.chip[data-r]').forEach(b=>b.onclick=()=>{{
  v.playbackRate=parseFloat(b.dataset.r);
  document.querySelectorAll('.chip[data-r]').forEach(x=>x.classList.remove('on'));b.classList.add('on');}});

// `cur` evita recorrer los N segmentos en cada timeupdate (~4 veces por
// segundo): solo se apaga el que estaba y se prende el que toca.
let cur=-1;
function pintar(d){{
  if(d.titulo){{document.getElementById('h1').textContent=d.titulo;document.title=d.titulo+' — SFCast';}}
  if(d.resumen){{document.getElementById('resumen').textContent=d.resumen;
    document.getElementById('sResumen').hidden=false;}}
  const caps=document.getElementById('caps');
  if(d.capitulos&&d.capitulos.length){{
    caps.innerHTML='';
    d.capitulos.forEach(c=>{{const a=document.createElement('a');a.href='#';a.dataset.t=c.t;
      const mm=String(Math.floor(c.t/60)).padStart(2,'0'),ss=String(Math.floor(c.t%60)).padStart(2,'0');
      const t=document.createElement('span');t.className='t';t.textContent=mm+':'+ss;
      const n=document.createElement('span');n.textContent=c.titulo;
      a.append(t,n);a.onclick=e=>{{e.preventDefault();v.currentTime=parseFloat(a.dataset.t);v.play()}};
      caps.appendChild(a);}});
    document.getElementById('sCaps').hidden=false;}}
  const tr=document.getElementById('tr');
  if(d.segments&&d.segments.length){{
    tr.innerHTML='';cur=-1;
    d.segments.forEach((s,i)=>{{const sp=document.createElement('span');sp.textContent=s.text+' ';
      sp.id='seg'+i;sp.onclick=()=>{{v.currentTime=s.s;v.play()}};tr.appendChild(sp);}});
    document.getElementById('trWait').hidden=true;}}
  D=d;
}}
pintar(D);
v.addEventListener('timeupdate',()=>{{const t=v.currentTime,S=D.segments||[];
  if(cur>=0&&t>=S[cur].s&&t<S[cur].e)return;
  let n=-1;for(let i=0;i<S.length;i++){{if(t>=S[i].s&&t<S[i].e){{n=i;break;}}}}
  if(n===cur)return;
  if(cur>=0)document.getElementById('seg'+cur).classList.remove('on');
  if(n>=0)document.getElementById('seg'+n).classList.add('on');
  cur=n;}});

// La página se COMPLETA sola. Sondea data.json hasta que el worker marque
// ready, sin recargar: recargar reiniciaría el video que ya estás viendo.
if(!D.ready){{(async()=>{{
  for(let i=0;i<450;i++){{
    await new Promise(r=>setTimeout(r,4000));
    try{{const res=await fetch('{BASE_URL}/media/{d["id"]}/data.json?t='+Date.now(),{{cache:'no-store'}});
        if(!res.ok)continue;const nd=await res.json();
        if(nd.ready){{pintar({{id:nd.id,ready:true,titulo:nd.titulo,resumen:nd.resumen,
          segments:(nd.transcript&&nd.transcript.segments)||[],capitulos:nd.capitulos||[]}});break;}}
    }}catch(e){{}}
  }}
}})();}}
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

    t0 = time.time()
    loop = asyncio.get_event_loop()

    # ── FASE 1: que se pueda VER ────────────────────────────────────────────
    # Lo único que importa aquí. El transcript no hace falta para mirar un
    # video, y hacer esperar a la página por él era el 43% de la demora.
    await loop.run_in_executor(None, concat_segments, session_dir, video)
    duration = await loop.run_in_executor(None, probe_duration, video)
    await loop.run_in_executor(None, make_thumb, video, media_dir / "thumb.jpg", duration)

    data = {
        "id": vid,
        "titulo": f"Grabación {datetime.now().strftime('%d %b %Y %H:%M')}",
        "resumen": "", "resumen_corto": "", "capitulos": [],
        "duration": duration,
        "created": meta.get("startedAt") or datetime.now(timezone.utc).isoformat(),
        "mode": meta.get("mode", "screen"),
        "views": 0,
        "ready": False,
        "transcript": {"segments": [], "text": "", "language": "es"},
    }
    publish(vid, data)
    log(f"▶ {vid} REPRODUCIBLE en {time.time()-t0:.0f}s ({duration:.0f}s de video) "
        f"→ {BASE_URL}/v/{vid}/")

    # ── FASE 2: transcript + título + capítulos ─────────────────────────────
    # La página abierta se completa sola sondeando data.json; nadie recarga y a
    # nadie se le corta el video.
    t1 = time.time()
    transcript = await transcribe_best(video, duration)
    llm = await enrich(transcript["text"], duration)
    data.update({
        "titulo": llm["titulo"], "resumen": llm["resumen"],
        "resumen_corto": llm["resumen_corto"], "capitulos": llm["capitulos"],
        "transcript": transcript, "ready": True,
    })
    publish(vid, data)
    shutil.rmtree(session_dir, ignore_errors=True)
    log(f"✓ {vid} completo en {time.time()-t1:.0f}s («{data['titulo']}»)")

    # ── FASE 3: distribución ────────────────────────────────────────────────
    # H.264 ANTES del espejo: subir el HEVC a R2 sería pagar la subida dos veces
    # y dejar un rato el archivo que no reproduce en Chrome como el público.
    await loop.run_in_executor(None, distribute_encode, video)
    await espejo_r2(vid)


def publish(vid: str, data: dict) -> None:
    """Escribe data.json + viewer + embed + biblioteca. Idempotente a propósito:
    se llama una vez con `ready:false` y otra con el video ya completo."""
    media_dir = WWW / "media" / vid
    vdir, edir = WWW / "v" / vid, WWW / "embed" / vid
    vdir.mkdir(parents=True, exist_ok=True)
    edir.mkdir(parents=True, exist_ok=True)
    (media_dir / "data.json").write_text(json.dumps(data, ensure_ascii=False, indent=1))
    (vdir / "index.html").write_text(viewer_html(data))
    (edir / "index.html").write_text(embed_html(data))
    rebuild_library()


async def espejo_r2(vid: str):
    """Sube el cast recien publicado a R2 (origen publico de la comunidad).

    Por que aqui y no como paso manual: el frontend de SaaS Factory arma el
    embed contra R2 para CUALQUIER id (`sfcastEmbedUrl`), asi que un cast que
    solo vive en el VPS se ve como la pagina "Is this your bucket?" de
    Cloudflare dentro del post. Paso el 10 ago 2026 en un anuncio a ~570
    miembros. Desde entonces publicar = VPS **y** R2, en el mismo movimiento.

    Best-effort a proposito: si R2 falla, el cast ya quedo publicado en el VPS
    y el fallo se ve en el log; nunca tumba el pipeline.
    """
    script = BASE / "import" / "publish_cast_r2.py"
    if not script.exists():
        log(f"⚠ {vid}: falta {script} — el cast queda SOLO en el VPS")
        return
    try:
        proc = await asyncio.create_subprocess_exec(
            sys.executable, str(script), vid,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT)
        out, _ = await asyncio.wait_for(proc.communicate(), timeout=3600)
        cola = (out or b"").decode(errors="replace").strip().splitlines()[-3:]
        if proc.returncode == 0:
            log(f"✓ {vid} espejado en R2 · " + " · ".join(cola))
        else:
            log(f"⚠ {vid} NO subio a R2 (queda en el VPS) · " + " · ".join(cola))
    except Exception as e:  # noqa: BLE001
        log(f"⚠ {vid} espejo R2 fallo: {str(e)[:200]}")


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


def orphans(older_than_h: float = 2.0) -> list[str]:
    """Sesiones en `incoming/` que nunca recibieron `UPLOAD_DONE`.

    Sin este sensor son INVISIBLES: el poller solo mira lo que tiene el marcador,
    así que una subida que murió a medias se queda ahí callada para siempre. Fue
    exactamente lo que pasó: 2 sesiones del 15 jul, 95 MB, 26 días sin que nadie
    se enterara. Un órgano sin sensor se ve idéntico a uno sano.
    """
    cutoff = time.time() - older_than_h * 3600
    out = []
    for d in INCOMING.glob("*/"):
        if not d.is_dir() or (d / "UPLOAD_DONE").exists() or d.name in _processing:
            continue
        if d.stat().st_mtime < cutoff:
            out.append(d.name)
    return sorted(out)


async def handle_health(_req):
    huerfanas = orphans()
    sin_h264 = [p.parent.name for p in WWW.glob("media/*/data.json")
                if not (p.parent / ".dist.json").exists()]
    return web.json_response({
        "ok": not huerfanas, "service": "sfcast-pipeline",
        "queue": len(list(INCOMING.glob("*/UPLOAD_DONE"))),
        "processing": sorted(_processing),
        "videos": len(list(WWW.glob("media/*/data.json"))),
        "stt": "groq" if GROQ_KEY else "faster-whisper (local, ~75x más lento)",
        "huerfanas": huerfanas,
        "sin_distribuir_h264": len(sin_h264),
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
    log(f"http 127.0.0.1:{PORT} listo · stt="
        f"{'groq/' + STT_MODEL if GROQ_KEY else 'faster-whisper local'}")
    if h := orphans():
        log(f"⚠ {len(h)} sesión(es) huérfana(s) sin UPLOAD_DONE: {', '.join(h)} "
            f"— subidas que murieron a medias; nadie las va a procesar")
    await poller()


if __name__ == "__main__":
    asyncio.run(main())
