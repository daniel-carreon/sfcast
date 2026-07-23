#!/usr/bin/env python3
"""Publica a R2 los 51 videos importados del classroom, en formato SFCast.

Sube SOLO lo que esta en mapping.json (los importados de Loom). Los casts
nativos de SFCast que ya vivian en el VPS NO se tocan.

Estructura resultante en R2:
    media/<id>/video.mp4 · thumb.jpg · data.json
    embed/<id>/index.html   (con las URLs apuntando a R2, no al VPS)

Uso (en el VPS):  python3 publish_r2.py
"""
import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, "/opt/sfcast/pipeline")
import sfcast_worker as W  # noqa: E402

IMPORT_DIR = Path("/opt/sfcast/import")
WWW = W.WWW
R2_BASE = "https://pub-c75cfa5a9fd04b828a8b5b455028154e.r2.dev"
REMOTE = "r2:sfcast-videos"


def embed_html_r2(d: dict) -> str:
    """Mismo embed del worker, pero sirviendo el media desde R2."""
    return W.embed_html(d).replace(W.BASE_URL, R2_BASE)


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=3600)


def main():
    mapping = json.loads((IMPORT_DIR / "mapping.json").read_text())
    ids = sorted(set(mapping.values()))
    print(f"publicando {len(ids)} videos importados a R2\n", flush=True)

    staging = IMPORT_DIR / "r2-staging"
    subprocess.run(["rm", "-rf", str(staging)])
    (staging / "embed").mkdir(parents=True, exist_ok=True)

    # embeds regenerados con URLs de R2
    for vid in ids:
        data = json.loads((WWW / "media" / vid / "data.json").read_text())
        d = staging / "embed" / vid
        d.mkdir(parents=True, exist_ok=True)
        (d / "index.html").write_text(embed_html_r2(data))
    print(f"embeds regenerados apuntando a R2: {len(ids)}", flush=True)

    # media (video + thumb + data) de SOLO los importados
    media_stage = staging / "media"
    media_stage.mkdir(parents=True, exist_ok=True)
    for vid in ids:
        subprocess.run(["cp", "-r", str(WWW / "media" / vid), str(media_stage / vid)])
    print("media preparada, subiendo a R2...", flush=True)

    r = run(["rclone", "copy", str(staging), REMOTE, "--transfers", "8",
             "--checkers", "16", "--stats", "30s", "--stats-one-line"])
    if r.returncode != 0:
        print("ERROR en la subida:\n", r.stderr[-1500:], flush=True)
        return 1

    # limpiar la estructura vieja (mp4 sueltos por loom_id de la primera prueba)
    old = run(["rclone", "lsf", f"{REMOTE}/media/"])
    borrados = 0
    for line in old.stdout.splitlines():
        name = line.strip()
        if name.endswith(".mp4"):  # suelto == estructura vieja; los nuevos son carpetas
            run(["rclone", "deletefile", f"{REMOTE}/media/{name}"])
            borrados += 1
    print(f"objetos viejos borrados: {borrados}", flush=True)

    size = run(["rclone", "size", f"{REMOTE}/"])
    print("\n=== R2 final ===\n" + size.stdout, flush=True)
    print(f"ejemplo: {R2_BASE}/embed/{ids[0]}/", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
