#!/usr/bin/env python3
"""Genera el preview animado estilo Loom para cada video importado.

Loom convierte los primeros segundos en una portada que se reproduce sola.
Aqui se hace igual pero con un MP4 corto y mudo en vez de un GIF: mismo efecto
visual, ~10x menos peso (un GIF de 5s son megas; esto ~200-400 KB).

Arranca al 10% del video, no en el segundo 0, porque el arranque suele ser
pantalla negra o el presentador acomodandose.

Uso (en el VPS):  python3 make_previews.py
"""
import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, "/opt/sfcast/pipeline")
import sfcast_worker as W  # noqa: E402

IMPORT_DIR = Path("/opt/sfcast/import")
WWW = W.WWW
DUR = 5  # segundos de preview


def main():
    mapping = json.loads((IMPORT_DIR / "mapping.json").read_text())
    ids = sorted(set(mapping.values()))
    hechos = fallidos = 0

    for n, vid in enumerate(ids, 1):
        media = WWW / "media" / vid
        video = media / "video.mp4"
        out = media / "preview.mp4"
        if not video.exists():
            fallidos += 1
            continue
        if out.exists() and out.stat().st_size > 10_000:
            hechos += 1
            continue

        try:
            dur = W.probe_duration(video)
            start = max(1.0, min(dur * 0.10, 60.0))
            subprocess.run(
                ["ffmpeg", "-y", "-ss", str(start), "-i", str(video), "-t", str(DUR),
                 "-an",                       # sin audio: es una portada, no un video
                 "-vf", "scale=640:-2,fps=15",
                 "-c:v", "libx264", "-crf", "30", "-preset", "veryfast",
                 "-movflags", "+faststart",   # que empiece a pintar sin bajar todo
                 str(out)],
                check=True, capture_output=True, timeout=300)
            kb = out.stat().st_size / 1024
            print(f"[{n}/{len(ids)}] {vid} preview {kb:.0f} KB", flush=True)
            hechos += 1
        except Exception as e:
            print(f"[{n}/{len(ids)}] FALLO {vid}: {str(e)[:120]}", flush=True)
            fallidos += 1

    print(f"\nTERMINADO previews: {hechos} ok · {fallidos} fallidos", flush=True)


if __name__ == "__main__":
    main()
