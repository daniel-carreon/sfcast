#!/usr/bin/env python3
"""Adapter de la fábrica → sfreview: placed_events.json → proyecto timeline.json.

Hereda la lógica canónica de resolución de assets y el scheduler de ráfagas de
gen_studio_v5.py (video-final-5-practica) — el proyecto de revisión lo EMITE la
fábrica programáticamente, jamás se arma a mano.

Uso:
  python3 placed2timeline.py <design-dir> [-o <proyecto-out>] [--base <mp4>] [--name X]

<design-dir> = carpeta design/ del video (contiene placed_events.json, cardmp4/, caps/...).
Default de salida: <proyecto>/sfreview_project/ (hermano de design/).
"""
import argparse
import json
import os
import shutil
import subprocess
import sys

BOS = os.path.expanduser("~/Developer/business-os")
V4CM_CANDIDATES = [
    f"{BOS}/agent-server/workspace/generated/video-final-4/edit/design/cardmp4",
    f"{BOS}/claudeclaw/workspace/generated/video-final-4/edit/design/cardmp4",
]
LIBMO = f"{BOS}/youtube/assets/library/motions"

LIB = {"036": "036-seguridad", "040": "040-desbloquear-habilidades-skills2", "044": "044-comunidad",
       "045": "045-libertad-estilo-de-vida", "028": "028-poder-agentes-titanes",
       "032": "032-oportunidad-ventana-historica", "037": "037-cerebro-ia-title-card",
       "046": "046-poder-software-propietario"}


def ffprobe_dur(path):
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration",
                          "-of", "default=nk=1:nw=1", path], capture_output=True, text=True).stdout.strip()
    return round(float(out), 3)


def make_resolver(design):
    cm = os.path.join(design, "cardmp4")
    v4cm = next((p for p in V4CM_CANDIDATES if os.path.isdir(p)), V4CM_CANDIDATES[0])

    def resolve(e):
        t = e["type"]; a = e.get("asset", ""); tr = e.get("treatment", "")
        if t == "caption":
            return ("cap", f"{design}/caps/{e['id']}.png")
        if t == "lowerthird":
            return ("webm", f"{v4cm}/lowerthird-daniel.webm")
        if t == "logo3d":
            p1 = f"{cm}/{a}.webm"
            return ("webm", p1 if os.path.exists(p1) else f"{v4cm}/{a}.webm")
        if t == "logo2d":
            if "sflogo" in a:
                side = "L" if e["id"] == "logo_saasfactory" else "R"
                return ("webm", f"{cm}/logo-sf-{side}.webm")
            return ("webm", f"{v4cm}/logo-openai-L.webm")
        if t == "lumino":
            key = a.replace("REUSE:", "")
            if tr.startswith("beside"):
                side = "L" if tr.endswith("L") else "R"
                return ("webm", f"{cm}/lb-{key}-{side}.webm")
            return ("clip", f"{LIBMO}/{LIB[key]}.mp4")
        if t in ("demo", "card", "receipt", "matte", "agenda"):
            base = a.replace("NEW:", "")
            p1 = f"{cm}/{base}.mp4"; p2 = f"{v4cm}/{base}.mp4"
            return ("clip", p1 if os.path.exists(p1) else p2)
        if t == "coldopen":
            return ("clip", f"{design}/coldopen.mp4")
        if t == "thumb":
            return ("webm", f"{cm}/{e['id']}.webm")
        raise ValueError(t)

    return resolve


def schedule(events, r0, r1, resolve):
    """Scheduler canónico (gen_studio_v5): ventanas + ráfagas butt-joined (default #14)."""
    items = []
    for e in events:
        if not (r0 - 0.02 <= e["out_start"] < r1 - 0.5):
            continue
        cat, path = resolve(e)
        if not os.path.exists(path):
            print(f"  ⚠️ MISSING {e['id']} {path}")
            continue
        items.append({"id": e["id"], "cat": cat, "path": path, "start": e["out_start"], "dur": e["dur"],
                      "layer": "fs" if cat == "clip" else "of"})
    fs = sorted([x for x in items if x["layer"] == "fs"], key=lambda x: x["start"])
    of = sorted([x for x in items if x["layer"] == "of"], key=lambda x: x["start"])
    prev = -1
    for x in fs:
        if x["id"] == "matte_pasemos":
            x["w"] = (round(r1 - 1.27, 3), round(r1 - 0.02, 3)); continue
        s = max(x["start"], prev + 0.12); en = min(s + x["dur"], r1 - 0.05)
        x["w"] = (round(s, 3), round(en, 3)); prev = en
    fs.sort(key=lambda x: x["w"][0])
    # rafagas (default #14): inserts a <1.2s se encadenan butt-joined
    for i in range(1, len(fs)):
        A, Bx = fs[i - 1], fs[i]
        gap = Bx["w"][0] - A["w"][1]
        if 0 <= gap < 1.2:
            s = A["w"][1]
            Bx["w"] = (round(s, 3), round(min(s + Bx["dur"], r1 - 0.05), 3))
    wins = [x["w"] for x in fs]

    def hits(s, en):
        for a, b in wins:
            if s < b - 0.05 and en > a + 0.05:
                return (a, b)
        return None

    kept = []
    for x in of:
        s = x["start"]; en = s + x["dur"]
        if en > r1:
            en = r1 - 0.05; s = max(r0, en - x["dur"])
        h = hits(s, en)
        if h:
            a, b = h; s2, e2 = b + 0.10, b + 0.10 + x["dur"]
            if e2 <= r1 and not hits(s2, e2):
                s, en = s2, e2
            else:
                e3, s3 = a - 0.10, a - 0.10 - x["dur"]
                if s3 >= r0 and not hits(s3, e3):
                    s, en = s3, e3
                else:
                    continue
        x["w"] = (round(s, 3), round(en, 3)); kept.append(x)
    of = kept
    caps = sorted([x for x in of if x["cat"] == "cap"], key=lambda x: x["w"][0])
    for i in range(1, len(caps)):
        pv = caps[i - 1]["w"]; cu = caps[i]
        if cu["w"][0] < pv[1] + 0.10:
            d = cu["w"][1] - cu["w"][0]; s = pv[1] + 0.12
            cu["w"] = (round(s, 3), round(min(s + d, r1 - 0.05), 3))
    return fs, of


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("design")
    ap.add_argument("-o", "--out", default=None)
    ap.add_argument("--base", default=None, help="mp4 base ya listo (default: <proyecto>/studio/base-720p.mp4 o edit/clean30f7.mp4 re-encodeado)")
    ap.add_argument("--name", default=None)
    ap.add_argument("--copy-base", action="store_true", help="copiar el base al proyecto en vez de symlink")
    args = ap.parse_args()

    design = os.path.abspath(args.design)
    proj = os.path.dirname(design)
    out = os.path.abspath(args.out or os.path.join(proj, "sfreview_project"))
    name = args.name or os.path.basename(proj)

    placed = json.load(open(os.path.join(design, "placed_events.json")))
    B = placed["compositing_boundary_out"]; O = placed["outro_start_out"]; TOTAL = placed["total_output_s"]

    resolve = make_resolver(design)
    ev = placed["events"]
    fs1, of1 = schedule(ev, 0, B, resolve)
    fs2, of2 = schedule(ev, O, TOTAL + 5, resolve)

    # base
    base_src = args.base
    if not base_src:
        cand = os.path.join(proj, "studio", "base-720p.mp4")
        if os.path.exists(cand):
            base_src = cand
        else:
            clean = os.path.join(proj, "edit", "clean30f7.mp4")
            if not os.path.exists(clean):
                sys.exit("no hay base: pasa --base o ten studio/base-720p.mp4 / edit/clean30f7.mp4")
            base_src = os.path.join(out, "assets", "base-720p.mp4")
            os.makedirs(os.path.dirname(base_src), exist_ok=True)
            print("encodeando base 720p faststart GOP-corto (scrub suave)...")
            subprocess.run(["ffmpeg", "-nostdin", "-y", "-loglevel", "error", "-i", clean,
                            "-vf", "scale=1280:720", "-r", "30", "-c:v", "h264_videotoolbox", "-b:v", "5M",
                            "-g", "30", "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", base_src], check=True)

    for d in ("assets/cards", "assets/alpha", "assets/caps"):
        os.makedirs(os.path.join(out, d), exist_ok=True)

    # base al proyecto (symlink por default: 300MB no se duplican; el server los sigue)
    base_dst = os.path.join(out, "assets", "base.mp4")
    if os.path.abspath(base_src) != os.path.abspath(base_dst):
        if os.path.lexists(base_dst):
            os.remove(base_dst)
        if args.copy_base:
            shutil.copy(base_src, base_dst)
        else:
            os.symlink(os.path.abspath(base_src), base_dst)
    DUR = ffprobe_dur(base_dst)

    def cp(src, sub):
        dst = os.path.join(out, "assets", sub, os.path.basename(src))
        shutil.copy(src, dst)  # SIEMPRE sobrescribe (gotcha #33)
        return f"assets/{sub}/{os.path.basename(src)}"

    items = []
    for x in fs1 + fs2:
        items.append({"id": x["id"], "type": "video", "src": cp(x["path"], "cards"),
                      "start": x["w"][0], "dur": round(x["w"][1] - x["w"][0], 3),
                      "track": 1, "fit": "cover", "muted": True})
    for x in of1 + of2:
        if x["cat"] == "webm":
            items.append({"id": x["id"], "type": "video", "src": cp(x["path"], "alpha"),
                          "start": x["w"][0], "dur": round(x["w"][1] - x["w"][0], 3),
                          "track": 2, "fit": "contain", "muted": True, "alpha": True})
        else:
            items.append({"id": x["id"], "type": "image", "src": cp(x["path"], "caps"),
                          "start": x["w"][0], "dur": round(x["w"][1] - x["w"][0], 3),
                          "track": 3, "fit": "stretch"})

    timeline = {
        "name": name,
        "width": placed.get("width", 1920), "height": placed.get("height", 1080),
        "fps": 30, "duration": DUR,
        "base": {"src": "assets/base.mp4"},
        "audio": {"src": "assets/base.mp4"},
        "items": sorted(items, key=lambda i: i["start"]),
    }
    with open(os.path.join(out, "timeline.json"), "w") as f:
        json.dump(timeline, f, indent=1)
    n_fs = len(fs1) + len(fs2); n_of = len(of1) + len(of2)
    print(f"sfreview project: {out}")
    print(f"  {n_fs} clips fullscreen · {n_of} overlays (webm/caps) · base {DUR}s · B={B} O={O}")


if __name__ == "__main__":
    main()
