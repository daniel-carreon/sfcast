#!/usr/bin/env python3
"""Reescribe los embeds con portada animada estilo Loom y los publica a R2.

Comportamiento (igual que Loom):
  1. Al cargar se ve un loop mudo de 5s: el video "se mueve" sin dar click.
  2. Al hacer click se cambia al video completo, con audio y controles, y arranca.

El preview pesa ~30 KB, asi que la pagina abre al instante; el mp4 completo
(~140 MB) solo se descarga si el miembro decide verlo.

Uso (en el VPS):  python3 publish_preview_embeds.py
"""
import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, "/opt/sfcast/pipeline")
import sfcast_worker as W  # noqa: E402

IMPORT_DIR = Path("/opt/sfcast/import")
WWW = W.WWW
R2 = "https://pub-c75cfa5a9fd04b828a8b5b455028154e.r2.dev"
REMOTE = "r2:sfcast-videos"


def embed_html(d: dict) -> str:
    vid = d["id"]
    titulo = W.esc(d["titulo"])
    return f"""<!doctype html><html lang="es"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow"><link rel="icon" href="data:,">
<title>{titulo}</title>
<style>
/* Titaniumorphism: negro metalico cepillado + glow mostaza. Valores tomados del
   sistema oficial (--titanium-top/mid/bot, --gold) para que el player se sienta
   parte de la plataforma y no un reproductor generico. */
:root{{
  --titanium-top:#24242b; --titanium-mid:#16161c; --titanium-bot:#0d0d12;
  --titanium-border:#2c2c34; --titanium-border-top:#42424c;
  --gold:#ff9101; --gold-bright:#ffac3d;
}}
html,body{{margin:0;height:100%;background:#000;overflow:hidden}}
/* aspect-ratio fija el marco en 16:9 y lo centra: nunca se deforma ni desborda */
#stage{{position:relative;width:100%;height:100%;cursor:pointer;
background:#000;display:flex;align-items:center;justify-content:center}}
video{{width:100%;height:100%;object-fit:contain;display:block;background:#000}}
#full{{display:none}}
#veil{{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;
background:radial-gradient(ellipse at center,rgba(0,0,0,.12),rgba(0,0,0,.5));
transition:background .25s}}
#stage:hover #veil{{background:radial-gradient(ellipse at center,rgba(0,0,0,.04),rgba(0,0,0,.42))}}

/* halo mostaza POR DETRAS del boton (capa propia para poder crecer en hover) */
#glow{{position:absolute;width:88px;height:88px;border-radius:50%;
background:radial-gradient(circle,rgba(255,145,1,.55) 0%,rgba(255,145,1,.22) 45%,transparent 70%);
filter:blur(12px);transition:opacity .28s,transform .28s;opacity:.85}}
#stage:hover #glow{{opacity:1;transform:scale(1.22)}}

#play{{position:relative;width:66px;height:66px;border-radius:50%;
background:linear-gradient(180deg,var(--titanium-top) 0%,var(--titanium-mid) 52%,var(--titanium-bot) 100%);
border:1.5px solid var(--titanium-border);border-top-color:var(--titanium-border-top);
display:flex;align-items:center;justify-content:center;
box-shadow:
  inset 0 1.5px 0 rgba(255,255,255,.12),      /* filo superior iluminado = volumen */
  inset 0 -1.5px 0 rgba(0,0,0,.55),           /* filo inferior hundido */
  inset 0 0 22px rgba(0,0,0,.45),
  0 0 40px rgba(255,145,1,.32),               /* glow mostaza del sistema */
  0 14px 36px rgba(0,0,0,.65);                /* sombra que lo despega del video */
transition:transform .2s cubic-bezier(.22,1,.36,1),box-shadow .25s,border-color .25s}}
#stage:hover #play{{transform:scale(1.07);
border-color:rgba(255,145,1,.6);border-top-color:rgba(255,172,61,.85);
box-shadow:
  inset 0 1.5px 0 rgba(255,255,255,.16),
  inset 0 -1.5px 0 rgba(0,0,0,.55),
  inset 0 0 22px rgba(0,0,0,.4),
  0 0 60px rgba(255,145,1,.5),
  0 0 0 1px rgba(255,145,1,.2),
  0 16px 42px rgba(0,0,0,.7)}}
#stage:active #play{{transform:scale(.98)}}
/* triangulo como TIRA LED: solo perimetro encendido, centro negro (el metal del boton).
   El path esta trazado con centroide en 12,12 del viewBox, asi que centra optico sin
   necesidad de margin-left (el path clasico de play va corrido a la derecha). */
#play svg{{filter:drop-shadow(0 0 8px rgba(255,145,1,.75)) drop-shadow(0 0 16px rgba(255,145,1,.4))}}
#play path{{fill:none;stroke:var(--gold);stroke-width:2.1;
stroke-linejoin:round;stroke-linecap:round}}
#stage:hover #play path{{stroke:var(--gold-bright);stroke-width:2.3}}
#stage:hover #play svg{{filter:drop-shadow(0 0 12px rgba(255,145,1,.9)) drop-shadow(0 0 24px rgba(255,145,1,.55))}}

#tag{{position:absolute;left:14px;bottom:14px;
background:linear-gradient(180deg,var(--titanium-top) 0%,var(--titanium-bot) 100%);
color:#e8e8e6;padding:7px 14px;border-radius:10px;
font:12.5px -apple-system,BlinkMacSystemFont,sans-serif;text-decoration:none;
border:1px solid var(--titanium-border);border-top-color:var(--titanium-border-top);
box-shadow:inset 0 1px 0 rgba(255,255,255,.08),0 6px 18px rgba(0,0,0,.5);
max-width:74%;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;
transition:opacity .25s}}
#tag b{{color:var(--gold);text-shadow:0 0 12px rgba(255,145,1,.5)}}
</style></head><body>
<div id="stage">
  <!-- portada animada: 5s en loop, muda. Da vida al card sin bajar el video completo -->
  <video id="prev" autoplay muted loop playsinline preload="metadata"
         poster="{R2}/media/{vid}/thumb.jpg">
    <source src="{R2}/media/{vid}/preview.mp4" type="video/mp4">
  </video>
  <!-- el video real: solo se carga cuando el miembro da click -->
  <video id="full" controls playsinline preload="none"
         poster="{R2}/media/{vid}/thumb.jpg">
    <source src="{R2}/media/{vid}/video.mp4" type="video/mp4">
  </video>
  <div id="veil">
    <div id="glow"></div>
    <div id="play"><svg width="36" height="36" viewBox="0 0 24 24"><path d="M6 3.7 L20.1 12 L6 20.3 Z"/></svg></div>
  </div>
  <a id="tag" href="{R2}/embed/{vid}/index.html" target="_blank">▶ {W.esc(d["titulo"][:52])} · <b>SFCast</b></a>
</div>
<script>
(function(){{
  var stage=document.getElementById('stage'),prev=document.getElementById('prev'),
      full=document.getElementById('full'),veil=document.getElementById('veil'),
      tag=document.getElementById('tag'),abierto=false;
  function abrir(e){{
    if(abierto) return;
    // contains() y no ===: el click puede caer en el <b> de adentro del credito
    if(e&&e.target&&tag.contains(e.target)) return;
    abierto=true;
    prev.pause(); prev.style.display='none';
    veil.style.display='none'; tag.style.display='none';
    full.style.display='block'; full.play();
  }}
  stage.addEventListener('click',abrir);
  // si el navegador bloquea el autoplay, queda el poster: no se rompe nada
  prev.play().catch(function(){{}});
}})();
</script>
</body></html>"""


def main():
    mapping = json.loads((IMPORT_DIR / "mapping.json").read_text())
    ids = sorted(set(mapping.values()))
    staging = IMPORT_DIR / "r2-embeds"
    subprocess.run(["rm", "-rf", str(staging)])

    for vid in ids:
        data = json.loads((WWW / "media" / vid / "data.json").read_text())
        d = staging / "embed" / vid
        d.mkdir(parents=True, exist_ok=True)
        (d / "index.html").write_text(embed_html(data))

        # el preview vive junto al resto del media
        pm = staging / "media" / vid
        pm.mkdir(parents=True, exist_ok=True)
        subprocess.run(["cp", str(WWW / "media" / vid / "preview.mp4"), str(pm / "preview.mp4")])

    print(f"embeds + previews preparados: {len(ids)}", flush=True)
    r = subprocess.run(["rclone", "copy", str(staging), REMOTE, "--transfers", "8",
                        "--checkers", "16", "--stats", "20s", "--stats-one-line"],
                       capture_output=True, text=True, timeout=3600)
    if r.returncode != 0:
        print("ERROR:", r.stderr[-1000:], flush=True)
        return 1
    print("publicado. ejemplo:", f"{R2}/embed/{ids[0]}/index.html", flush=True)
    size = subprocess.run(["rclone", "size", f"{REMOTE}/"], capture_output=True, text=True)
    print(size.stdout, flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
