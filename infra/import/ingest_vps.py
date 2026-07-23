#!/usr/bin/env python3
"""Ingestor de videos EXTERNOS al formato SFCast. Corre EN EL VPS.

El worker de SFCast publica grabaciones nuevas (incoming -> transcribe -> LLM).
Este ingestor hace lo mismo para video YA EXISTENTE (los Loom del classroom):
genera media/<vid>/{video.mp4,thumb.jpg,data.json} + embed/<vid>/ + v/<vid>/
con el MISMO html del worker, para que el embed sea identico al nativo.

NO toca library.json ni los casts existentes (migracion en curso, etapa 1).

Uso (en el VPS):  python3 ingest_vps.py /opt/sfcast/import/manifest.json
"""
import hashlib
import json
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, "/opt/sfcast/pipeline")
import sfcast_worker as W  # noqa: E402  (reusa embed_html/viewer_html/thumb/BASE_URL)

IMPORT_DIR = Path("/opt/sfcast/import")
WWW = W.WWW
ALPHABET = "abcdefghijklmnopqrstuvwxyz0123456789"


def short_id(loom_id: str) -> str:
    """ID de 12 chars, determinista => re-correr no duplica."""
    h = hashlib.sha256(f"sfc-loom:{loom_id}".encode()).digest()
    return "".join(ALPHABET[b % len(ALPHABET)] for b in h[:12])


def main():
    manifest = json.loads(Path(sys.argv[1]).read_text())
    mapping = {}
    done = skipped = failed = 0

    for item in manifest:
        loom_id = item["loom_id"]
        # el downloader corriendo en el VPS deja los mp4 en import/videos/;
        # una subida manual desde el Mac los deja sueltos en import/.
        src = IMPORT_DIR / "videos" / f"{loom_id}.mp4"
        if not src.exists():
            src = IMPORT_DIR / f"{loom_id}.mp4"
        if not src.exists():
            print(f"  SIN ARCHIVO {loom_id}", flush=True)
            failed += 1
            continue

        vid = short_id(loom_id)
        media = WWW / "media" / vid
        video = media / "video.mp4"

        if video.exists() and video.stat().st_size == src.stat().st_size:
            mapping[loom_id] = vid
            skipped += 1
            continue

        media.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, video)
        duration = W.probe_duration(video)
        W.make_thumb(video, media / "thumb.jpg", duration)

        data = {
            "id": vid,
            "titulo": item["title"],
            "resumen": "",
            "resumen_corto": item.get("curso", ""),
            "capitulos": [],
            "duration": duration,
            "created": datetime.now(timezone.utc).isoformat(),
            "mode": "import",
            "views": 0,
            "origen": {"fuente": "loom", "loom_id": loom_id,
                       "curso": item.get("curso"), "lesson_id": item.get("lesson_id")},
            "transcript": {"text": "", "segments": []},
        }
        (media / "data.json").write_text(json.dumps(data, ensure_ascii=False, indent=1))

        for sub, fn in (("v", W.viewer_html), ("embed", W.embed_html)):
            d = WWW / sub / vid
            d.mkdir(parents=True, exist_ok=True)
            (d / "index.html").write_text(fn(data))

        mapping[loom_id] = vid
        done += 1
        print(f"  OK {loom_id} -> {vid}  ({duration:.0f}s) {item['title'][:45]}", flush=True)

    out = IMPORT_DIR / "mapping.json"
    out.write_text(json.dumps(mapping, indent=1))
    print(f"\nnuevos={done} ya_estaban={skipped} fallidos={failed}")
    print(f"mapping -> {out}")
    print(f"base: {W.BASE_URL}")


if __name__ == "__main__":
    main()
