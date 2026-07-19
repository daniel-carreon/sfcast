# SFStudio

Plataforma de video de la casa SaaS Factory. La línea de producción completa en dos etapas:

**Etapa 1 — edición** (tres piezas, un loop):

- **sfrender** — CLI determinista: cards HTML/GSAP → MP4 / WebM-alpha / ProRes 4444, cualquier
  aspecto (16:9, 9:16, lo que diga el card).
- **sfreview** — la Sala de Revisión (`:3010`): el proyecto real con overlays compuestos en vivo,
  velocidades 1-2x con tono normal, recortes no destructivos (**S** split · **A/D** trim · **⌘Z**),
  marcadores con nota (**M**) y export de `fixes.json` (**E**).
- **sfstudio-apply** — consume `fixes.json` y aplica los cortes al máster con ffmpeg
  (frame-accurate, `--dry-run` primero).

**Etapa 2 — publicación (SFPublish)**: del máster aprobado al video publicado.

- **sfpublish** — CLI por etapas: `metadata` (descripción/títulos/keywords con el system prompt
  del producto + tracked link `/go/` idempotente verificado en vivo) · `mentions` (transcript ↔
  videos del canal → plan de tarjetas/end screen) · `checklist` (gate duro) · `schedule` (peak
  hours) · `post` (anuncio, solo texto) · `upload` (agéntico a YouTube Studio, perfil persistente,
  SIEMPRE draft privado) · `connect` (ritual de login de 1 vez).
- **Panel ⌘Y** — en la sala: espejo AI-first de `publish.json` (estado + evidencia + comando por
  etapa, cero forms). El agente ejecuta; el panel refleja.

```bash
npm install && npm test    # 8 checks: sintaxis, 25 unit tests, humos render/apply/sala+panel

node bin/sfrender.js <card-dir> -o out.webm --format webm      # card → webm con ALPHA
python3 adapter/placed2timeline.py <proyecto>/design           # fábrica → proyecto de revisión
node bin/sfreview.js <proyecto>/sfreview_project --port 3010   # abrir la sala (⌘Y = panel publish)
node bin/sfstudio-apply.js fixes.json master.mp4 --dry-run     # cerrar el loop de edición

node bin/sfpublish.js <proyecto> metadata                      # etapa 2: arranca la publicación
node bin/sfpublish.js <proyecto> status                        # estado del pipeline post-edición
```

AI-first: la sala es para **ver, recortar fino y anotar**, el panel ⌘Y para **mirar el avance de
publicación** — la edición pesada, el máster y las etapas de publish los corre el agente (skill
`edicion-de-video`, `references/sfstudio.md` + `references/publicacion.md`). Detalle de
arquitectura e invariantes: `CLAUDE.md`.
