#!/usr/bin/env python3
"""Pasa a H.264 los casts que quedaron en HEVC, y los re-espeja a R2.

POR QUE EXISTE
--------------
`SCRecordingOutput` solo escribe HEVC (forzado a proposito en el Mac: esquiva el
tope de H.264 a 4096x2304 en Retina/5K). Perfecto para grabar, pesimo para
distribuir: HEVC no reproduce en Chrome/Windows sin la extension de pago de
Microsoft, ni en Firefox en varias plataformas, ni en buena parte de Android.

Hasta el 10 ago 2026 el worker publicaba ese HEVC tal cual — y `publish_cast_r2`
lo espejaba igualito a R2. O sea que TODOS los casts nativos se estaban sirviendo
en un formato que una parte de la comunidad no puede ver, **en silencio**: un
reproductor en negro no genera reporte, la gente asume que se rompio y se va.

El worker ya lo arregla de aqui en adelante (fase 3 de `process_session`). Este
script cierra el pasado. Medido: 10 de 62 casts en HEVC — los nativos; los 52
importados de Loom ya venian en H.264 y se saltan solos.

USO (en el VPS, con el venv del worker)
---------------------------------------
    P=/opt/livekit/pipeline/venv/bin/python3
    $P backfill_h264.py --dry          # que haria
    $P backfill_h264.py                # todos los pendientes
    $P backfill_h264.py <id> [<id>...] # puntuales

Seguro por diseno: `distribute_encode` es best-effort y no pisa el original si
ffmpeg falla o si la duracion no cuadra. Un cast pesado que se ve es mejor que
uno ligero que se corto.
"""
import asyncio
import sys
from pathlib import Path

sys.path.insert(0, "/opt/sfcast/pipeline")

from sfcast_worker import (  # noqa: E402
    WWW, distribute_encode, espejo_r2, log, probe_video, publish, json,
)


def pendientes() -> list[str]:
    out = []
    for dj in sorted(WWW.glob("media/*/data.json")):
        vid = dj.parent
        video = vid / "video.mp4"
        if not video.exists():
            continue
        codec, _, h = probe_video(video)
        if codec != "h264":
            out.append(vid.name)
    return out


async def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    dry = "--dry" in sys.argv
    ids = args or pendientes()
    if not ids:
        print("nada pendiente: todos los casts ya estan en H.264")
        return

    print(f"pendientes: {len(ids)}")
    for i, vid in enumerate(ids, 1):
        media = WWW / "media" / vid
        video = media / "video.mp4"
        if not video.exists():
            print(f"[{i}/{len(ids)}] {vid}: sin video.mp4 — salto")
            continue
        codec, w, h = probe_video(video)
        mb = video.stat().st_size / 1e6
        print(f"[{i}/{len(ids)}] {vid}: {codec} {w}x{h} {mb:.0f} MB")
        if dry:
            continue

        loop = asyncio.get_event_loop()
        cambio = await loop.run_in_executor(None, distribute_encode, video)
        if not cambio:
            print(f"  · {vid}: sin cambios (ya compatible o ffmpeg fallo)")
            continue

        # La pagina se reescribe con el viewer NUEVO (el progresivo) leyendo el
        # data.json que ya existe: los casts viejos tambien ganan la mejora.
        try:
            data = json.loads((media / "data.json").read_text())
            data.setdefault("ready", True)
            publish(vid, data)
        except Exception as e:  # noqa: BLE001
            log(f"⚠ {vid}: no pude reescribir el viewer: {e}")

        # Solo re-espejo si el ARCHIVO cambio: subir de nuevo lo identico es
        # pagar ancho de banda por nada.
        await espejo_r2(vid)

    print("TERMINADO")


if __name__ == "__main__":
    asyncio.run(main())
