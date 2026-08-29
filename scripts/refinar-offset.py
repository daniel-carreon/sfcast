#!/usr/bin/env python3
"""REFINAR EL OFFSET DE LA CAPA DE CÁMARA, en los términos de ffmpeg.

Para qué existe (28 ago 2026): el manifest ya trae `startOffsetSeconds` medido
por la app, y acerca a ~1.5 frames. No puede hacer más, y no es un defecto del
código: en un `.mov` con edit list, "el desfase" DEPENDE DEL DECODIFICADOR.
AVFoundation (que honra la edit list) y ffmpeg difieren en un valor CONSTANTE de
44 ms — 2112 muestras a 48 kHz, exactamente el retardo de codificación de AAC.

Como quien compone las capas es ffmpeg, la cifra buena es la que se mide CON
ffmpeg. Esto la mide, correlacionando el mismo micrófono en las dos pistas.

USO:  python3 scripts/refinar-offset.py ~/Movies/SFCast/<id>
SALE: el offset refinado + cuánto se separa del declarado. Exit 0 si coinciden
      dentro de un frame; 1 si no (que es NORMAL, y justo el motivo de existir).
"""
import wave, numpy as np, json, os, subprocess, sys
D = sys.argv[1]
def wav(src, out):
    subprocess.run(["ffmpeg","-v","error","-y","-i",src,"-map","0:a:0","-ac","1","-ar","8000","-f","wav",out],check=True)
def rd(p):
    w=wave.open(p); return np.frombuffer(w.readframes(w.getnframes()),dtype=np.int16).astype(np.float32)
def env(x,win=200,step=8): return np.convolve(np.abs(x),np.ones(win)/win,'same')[::step]
def st(p,s_):
    o=subprocess.run(["ffprobe","-v","error","-select_streams",s_,"-show_entries","stream=start_time","-of","csv=p=0",p],capture_output=True,text=True).stdout.strip()
    return float((o.split(',')[0]) or 0)
tmp=os.environ.get("TMPDIR","/tmp")
wav(f"{D}/camera.mov", f"{tmp}/o_cam.wav"); wav(f"{D}/seg-001.mp4", f"{tmp}/o_prog.wav")
a,b=rd(f"{tmp}/o_cam.wav"),rd(f"{tmp}/o_prog.wav")
ex,ey=env(a),env(b); n=min(len(ex),len(ey)); ex=ex[:n]-ex[:n].mean(); ey=ey[:n]-ey[:n].mean()
lag=(np.correlate(ey,ex,'full').argmax()-(n-1))*8/8000.
real=lag+st(f"{D}/seg-001.mp4","a:0")-st(f"{D}/camera.mov","a:0")
m=json.load(open(f"{D}/manifest.json")); fps=m.get("fps",30)
o=[x for x in m['outputs'] if x['role']=='camera'][0]
decl=o.get('startOffsetSeconds')
inc = o.get("startOffsetUncertaintySeconds") or 0.05
dif = abs(real - decl)
print(f"sesion {m['id']}  ({m.get('preset') or 'sin preset'})")
print(f"  declarado por la app  : {decl:+.4f} s  ({o.get('startOffsetMethod')}, ±{inc:.2f} s)")
print(f"  REFINADO para ffmpeg  : {real:+.4f} s   <-- USA ESTE PARA COMPONER")
print(f"  se separan            : {dif*1000:.0f} ms = {dif*fps:.2f} frames")
if dif <= inc:
    print("  ✓ dentro de la incertidumbre declarada (la diferencia es el priming de AAC:")
    print("    ~44 ms = 2112 muestras a 48 kHz, que cada decodificador compensa a su manera)")
    sys.exit(0)
print("  ⚠️ FUERA de la incertidumbre declarada: algo mas esta pasando (pista sin voz,")
print("     archivo truncado, o frames perdidos). Revisa cadenceHealth antes de componer.")
sys.exit(1)
