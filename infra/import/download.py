#!/usr/bin/env python3
"""Baja los videos Loom del classroom de SaaS Factory a MAXIMA calidad.

Idempotente: salta lo ya bajado. Escribe progreso a state.json para poder
reanudar y para que el ingestor sepa que esta listo.

Uso: python3 download.py
"""
import json
import os
import subprocess
import sys
import time
from pathlib import Path

WORK = Path(__file__).resolve().parent
# OUT_DIR permite correr el MISMO script en el Mac o directo en el VPS
# (bajar en el VPS evita el round-trip de subida: ~20h -> minutos).
VIDEOS = Path(os.environ.get("OUT_DIR", WORK / "videos"))
STATE = WORK / "state.json"
TIMEOUT = 1800  # 30 min por video: son 1080p largos, no hay prisa


def load_state():
    return json.loads(STATE.read_text()) if STATE.exists() else {}


def save_state(st):
    STATE.write_text(json.dumps(st, indent=1, ensure_ascii=False))


def main():
    inv = json.loads((WORK / "inventory.json").read_text())
    VIDEOS.mkdir(exist_ok=True)
    st = load_state()
    total = len(inv)

    for i, item in enumerate(inv, 1):
        lid = item["loom_id"]
        out = VIDEOS / f"{lid}.mp4"
        rec = st.get(lid, {})

        if out.exists() and out.stat().st_size > 100_000:
            if rec.get("status") != "ok":
                st[lid] = {**item, "status": "ok", "bytes": out.stat().st_size,
                           "file": str(out)}
                save_state(st)
            print(f"[{i}/{total}] SKIP (ya existe) {lid}", flush=True)
            continue

        print(f"[{i}/{total}] bajando {lid} — {item['title'][:50]}", flush=True)
        t0 = time.time()
        try:
            # -S res,br  => prioriza MAYOR resolucion y bitrate (max calidad).
            # -f bv*+ba/b => mergea el mejor video con el mejor audio.
            subprocess.run(
                ["yt-dlp", "-S", "res,br", "-f", "bv*+ba/b/best",
                 "--merge-output-format", "mp4", "--no-warnings", "--no-update",
                 "--socket-timeout", "30", "--fragment-retries", "10",
                 "--retries", "10", "-o", str(VIDEOS / f"{lid}.%(ext)s"),
                 f"https://www.loom.com/share/{lid}"],
                check=True, capture_output=True, timeout=TIMEOUT)
        except subprocess.CalledProcessError as e:
            err = (e.stderr or b"").decode()[-400:]
            print(f"    FALLO: {err}", flush=True)
            st[lid] = {**item, "status": "error", "error": err}
            save_state(st)
            continue
        except subprocess.TimeoutExpired:
            print("    TIMEOUT", flush=True)
            st[lid] = {**item, "status": "timeout"}
            save_state(st)
            continue

        # yt-dlp pudo dejar .mkv/.webm si el merge no dio mp4
        if not out.exists():
            for p in VIDEOS.glob(f"{lid}.*"):
                if p.suffix in (".mkv", ".webm"):
                    p.rename(out)
                    break

        if out.exists() and out.stat().st_size > 100_000:
            mb = out.stat().st_size / 1e6
            print(f"    OK {mb:.1f}MB en {time.time()-t0:.0f}s", flush=True)
            st[lid] = {**item, "status": "ok", "bytes": out.stat().st_size,
                       "file": str(out)}
        else:
            st[lid] = {**item, "status": "error", "error": "archivo no encontrado"}
        save_state(st)

    ok = sum(1 for v in st.values() if v.get("status") == "ok")
    gb = sum(v.get("bytes", 0) for v in st.values()) / 1e9
    print(f"\nTERMINADO: {ok}/{total} ok · {gb:.2f} GB", flush=True)


if __name__ == "__main__":
    sys.exit(main())
