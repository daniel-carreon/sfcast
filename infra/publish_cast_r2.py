#!/usr/bin/env python3
"""Publica a R2 los casts NATIVOS de SFCast (los que graba el worker).

Por que existe
--------------
La migracion de Loom (`import/`) dejo 51 videos en R2 con portada animada, y de
ahi salio la regla de oro medida: sirviendo desde el VPS el throughput agregado
se satura en ~1.3 MB/s (6 espectadores y ninguno llega a los 400 KB/s que pide
un 1080p); desde R2 son 92.8 MB/s agregados y el egress no se cobra.

Pero esa migracion fue de una sola vez y solo toco los importados
(`publish_r2.py`: "los casts nativos que ya vivian en el VPS NO se tocan").
El worker, en cambio, publica cada grabacion nueva SOLO en el VPS.

El frontend de la comunidad no sabe de esa division: `sfcastEmbedUrl()` arma
`R2/embed/<id>/index.html` para CUALQUIER id. Resultado del 10 ago 2026: un
anuncio a ~570 miembros con la pagina "Is this your bucket?" de Cloudflare
dentro del post, porque el cast recien grabado nunca habia subido a R2.

Este script cierra esa brecha: toma un cast nativo, le genera la portada
animada y lo deja en R2 con la MISMA estructura y el MISMO embed que los
importados. El HTML no se reescribe aqui — se importa de
`import/publish_preview_embeds.py`, que es su fuente unica.

Uso (en el VPS, con el venv del worker):
    P=/opt/livekit/pipeline/venv/bin/python3   # el worker corre ahi (aiohttp)
    $P publish_cast_r2.py <id> [<id> ...]   # casts puntuales
    $P publish_cast_r2.py --faltantes            # todo lo que no este en R2
    $P publish_cast_r2.py --faltantes --dry      # solo dice que haria
"""
import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, "/opt/sfcast/pipeline")
sys.path.insert(0, "/opt/sfcast/import")

import sfcast_worker as W  # noqa: E402
# El embed (Titaniumorphism + portada animada) tiene UNA sola fuente: la del
# importador. Importarlo en vez de copiarlo evita que los dos se separen.
from publish_preview_embeds import R2, REMOTE, embed_html  # noqa: E402

WWW = W.WWW
STAGING = Path("/opt/sfcast/import/r2-casts")
PREVIEW_S = 5  # segundos de portada animada, igual que en make_previews.py


def log(msg: str):
    print(msg, flush=True)


def en_r2(vid: str) -> bool:
    """¿El embed quedo puesto en el bucket?

    Se le pregunta al BUCKET (`rclone lsf`), no al origen publico. El subdominio
    `r2.dev` esta limitado por tasa en Cloudflare — ya lo advertia el README del
    importador — y desde el VPS devuelve rojo sobre objetos que SI existen: el
    10 ago 2026 dio "0/9 publicados" con los 9 puestos, y antes "61 faltantes"
    con 52 publicados. Un sensor que grita lobo se deja de leer, asi que el
    unico que manda es el autoritativo. La lectura publica se verifica aparte,
    a mano, cuando hace falta.
    """
    r = subprocess.run(["rclone", "lsf", f"{REMOTE}/embed/{vid}/"],
                       capture_output=True, text=True, timeout=120)
    return r.returncode == 0 and "index.html" in r.stdout


def hacer_preview(vid: str) -> bool:
    """Portada animada: 5s mudos en loop, ~30 KB. Arranca al 10% del video
    porque el segundo 0 suele ser pantalla negra o el presentador acomodandose."""
    media = WWW / "media" / vid
    video, out = media / "video.mp4", media / "preview.mp4"
    if not video.exists():
        log(f"  ✗ {vid}: no hay video.mp4 en el VPS")
        return False
    if out.exists() and out.stat().st_size > 10_000:
        log(f"  · {vid}: preview ya existe ({out.stat().st_size/1024:.0f} KB)")
        return True
    dur = W.probe_duration(video)
    start = max(1.0, min(dur * 0.10, 60.0))
    subprocess.run(
        ["ffmpeg", "-y", "-ss", str(start), "-i", str(video), "-t", str(PREVIEW_S),
         "-an", "-vf", "scale=640:-2,fps=15",
         "-c:v", "libx264", "-crf", "30", "-preset", "veryfast",
         "-movflags", "+faststart", str(out)],
        check=True, capture_output=True, timeout=600)
    log(f"  ✓ {vid}: preview {out.stat().st_size/1024:.0f} KB")
    return True


def hacer_tarjetas(vid: str) -> None:
    """Tarjetas para el CORREO: `card.gif` (se mueve) y `card.jpg` (estatico).

    Un correo no puede embeber el player: ningun cliente ejecuta iframes, y
    Outlook ni siquiera respeta gradientes. Asi que el video viaja como IMAGEN
    con el boton de play HORNEADO, enlazada al post. El GIF le devuelve el
    movimiento en Gmail/Apple Mail; donde no anima (Outlook de escritorio) se
    ve el primer fotograma, que ya trae el boton. Nunca queda un hueco.
    """
    media = WWW / "media" / vid
    boton = Path(__file__).parent / "assets" / "play-titanium.png"
    if not boton.exists():
        log(f"  ⚠ {vid}: falta {boton} — sin tarjetas de correo")
        return

    jpg = media / "card.jpg"
    if not jpg.exists() and (media / "thumb.jpg").exists():
        subprocess.run(
            ["ffmpeg", "-y", "-i", str(media / "thumb.jpg"), "-i", str(boton),
             "-filter_complex",
             "[0:v]scale=1200:-2[v];[1:v]scale=340:-1[b];[v][b]overlay=(W-w)/2:(H-h)/2",
             "-q:v", "3", str(jpg)],
            check=False, capture_output=True, timeout=300)

    gif = media / "card.gif"
    if not gif.exists() and (media / "preview.mp4").exists():
        # 3s/10fps/560px: el punto donde el movimiento se lee y el peso se
        # queda por debajo del MB. La paleta propia evita el banding de GIF.
        subprocess.run(
            ["ffmpeg", "-y", "-t", "3", "-i", str(media / "preview.mp4"),
             "-i", str(boton), "-filter_complex",
             "[0:v]fps=10,scale=560:-2[v];[1:v]scale=158:-1[b];"
             "[v][b]overlay=(W-w)/2:(H-h)/2,split[a][c];"
             "[a]palettegen=max_colors=128[p];"
             "[c][p]paletteuse=dither=bayer:bayer_scale=3",
             str(gif)],
            check=False, capture_output=True, timeout=600)

    for f in (jpg, gif):
        if f.exists():
            log(f"  ✓ {vid}: {f.name} {f.stat().st_size/1024:.0f} KB")


def subir(vid: str) -> bool:
    media = WWW / "media" / vid
    data = json.loads((media / "data.json").read_text())

    # El embed apunta a R2, no al VPS: se escribe aparte y se sube solo.
    edir = STAGING / "embed" / vid
    edir.mkdir(parents=True, exist_ok=True)
    (edir / "index.html").write_text(embed_html(data))

    # El media se sube desde su sitio: son ~200 MB, copiarlos a un staging
    # duplicaria el disco del VPS sin ganar nada.
    r = subprocess.run(
        ["rclone", "copy", str(media), f"{REMOTE}/media/{vid}",
         "--include", "video.mp4", "--include", "thumb.jpg",
         "--include", "data.json", "--include", "preview.mp4",
         "--include", "card.jpg", "--include", "card.gif",
         "--transfers", "4", "--stats", "20s", "--stats-one-line"],
        capture_output=True, text=True, timeout=3600)
    if r.returncode != 0:
        log(f"  ✗ {vid}: rclone media fallo — {r.stderr[-400:]}")
        return False

    r = subprocess.run(
        ["rclone", "copy", str(edir), f"{REMOTE}/embed/{vid}"],
        capture_output=True, text=True, timeout=600)
    if r.returncode != 0:
        log(f"  ✗ {vid}: rclone embed fallo — {r.stderr[-400:]}")
        return False
    return True


def publicar(vid: str, dry: bool = False) -> bool:
    if not (WWW / "media" / vid / "data.json").exists():
        log(f"  ✗ {vid}: no existe en el VPS")
        return False
    if dry:
        log(f"  → {vid}: se publicaria a R2")
        return True
    if not hacer_preview(vid):
        return False
    hacer_tarjetas(vid)
    if not subir(vid):
        return False
    # Sensor: no se declara publicado hasta que el origen publico responde.
    ok = en_r2(vid)
    log(f"  {'✓' if ok else '✗'} {vid}: {R2}/embed/{vid}/index.html "
        f"{'puesto' if ok else 'NO quedo en el bucket'}")
    return ok


def main() -> int:
    args = sys.argv[1:]
    dry = "--dry" in args
    ids = [a for a in args if not a.startswith("-")]

    if "--faltantes" in args:
        locales = sorted(p.parent.name for p in WWW.glob("media/*/data.json"))
        # El censo se le pregunta al BUCKET, no al edge: `r2.dev` limita por tasa
        # y 63 HEAD seguidos devuelven rojo sobre objetos que si estan (medido el
        # 10 ago 2026: dio 61/61 faltantes con 52 ya publicados). `rclone lsf` es
        # la fuente autoritativa y no gasta cuota publica.
        r = subprocess.run(["rclone", "lsf", f"{REMOTE}/embed/"],
                           capture_output=True, text=True, timeout=300)
        if r.returncode != 0:
            log(f"no pude listar el bucket: {r.stderr[-300:]}")
            return 1
        en_bucket = {ln.strip("/ \n") for ln in r.stdout.splitlines() if ln.strip()}
        log(f"casts en el VPS: {len(locales)} · ya en R2: {len(en_bucket)}")
        ids = [v for v in locales if v not in en_bucket]
        log(f"faltan en R2: {len(ids)}")

    if not ids:
        log("nada que publicar")
        return 0

    ok = 0
    for n, vid in enumerate(ids, 1):
        log(f"[{n}/{len(ids)}] {vid}")
        if publicar(vid, dry):
            ok += 1
    log(f"\nTERMINADO: {ok}/{len(ids)} publicados en R2")
    return 0 if ok == len(ids) else 1


if __name__ == "__main__":
    sys.exit(main())
