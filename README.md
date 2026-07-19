# SFStudio

Plataforma de video de la casa SaaS Factory. Tres piezas, un loop:

- **sfrender** — CLI determinista: cards HTML/GSAP → MP4 / WebM-alpha / ProRes 4444, cualquier
  aspecto (16:9, 9:16, lo que diga el card).
- **sfreview** — la Sala de Revisión (`:3010`): el proyecto real con overlays compuestos en vivo,
  velocidades 1-2x con tono normal, recortes no destructivos (**S** split · **A/D** trim · **⌘Z**),
  marcadores con nota (**M**) y export de `fixes.json` (**E**).
- **sfstudio-apply** — consume `fixes.json` y aplica los cortes al máster con ffmpeg
  (frame-accurate, `--dry-run` primero).

```bash
npm install && npm test    # 6 checks, incluye humo Playwright de la sala

node bin/sfrender.js <card-dir> -o out.webm --format webm      # card → webm con ALPHA
python3 adapter/placed2timeline.py <proyecto>/design           # fábrica → proyecto de revisión
node bin/sfreview.js <proyecto>/sfreview_project --port 3010   # abrir la sala
node bin/sfstudio-apply.js fixes.json master.mp4 --dry-run     # cerrar el loop
```

AI-first: la sala es para **ver, recortar fino y anotar** — la edición pesada y el máster los hace
la fábrica (skill `edicion-de-video`). Detalle de arquitectura e invariantes: `CLAUDE.md`.
