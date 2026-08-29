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
  hours) · `post --draft` (arma el anuncio en el proyecto) · `launch` (miniatura + metadata +
  PROGRAMA el video) · `watch` (el lazo: publica el post cuando YouTube confirma que el video ya
  es público) · `upload` (agéntico a YouTube Studio, SIEMPRE draft privado) · `connect`.
- **Panel ⌘Y** — en la sala: espejo AI-first de `publish.json` (estado + evidencia + comando por
  etapa, cero forms). El agente ejecuta; el panel refleja.
- **Galería ⌘⌥G** — el catálogo de TODOS los lanzamientos: rejilla con la portada de cada video y,
  a un clic, el expediente completo (descripción con capítulos, transcript navegable, miniaturas
  candidatas y el post de comunidad editable y aprobable). Se abre desde la sala, o sola con
  `sfreview --gallery`. Es la superficie desde la que Daniel opera sus lanzamientos.

```bash
npm install && npm test    # 9 checks: sintaxis, 64 unit tests, humos render/apply/sala+panel+galería

node bin/sfrender.js <card-dir> -o out.webm --format webm      # card → webm con ALPHA
python3 adapter/placed2timeline.py <proyecto>/design           # fábrica → proyecto de revisión
node bin/sfreview.js <proyecto>/sfreview_project --port 3010   # abrir la sala (⌘Y = panel publish)
node bin/sfstudio-apply.js fixes.json master.mp4 --dry-run     # cerrar el loop de edición

node bin/sfpublish.js <proyecto> metadata                      # etapa 2: arranca la publicación
node bin/sfpublish.js <proyecto> status                        # estado del pipeline post-edición
node bin/sfreview.js --gallery --port 3010                     # la GALERÍA sola: todos los lanzamientos
```

AI-first: la sala es para **ver, recortar fino y anotar**, el panel ⌘Y para **mirar el avance de
publicación** — la edición pesada, el máster y las etapas de publish los corre el agente (skill
`edicion-de-video`, `references/sfstudio.md` + `references/publicacion.md`). Detalle de
arquitectura e invariantes: `CLAUDE.md`.
