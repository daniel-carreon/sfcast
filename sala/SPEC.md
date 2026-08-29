# SFStudio — Spec (build nocturno one-shot, 18 jul 2026)

> Compilado por Levy con goal-compiler, tras editar 2 videos E2E contra HyperFrames y cargar las
> cicatrices: parche studio_unmute vs checksum, pin forzado a 0.7.39, ProRes que no reproduce,
> cache del navegador, init que sobrescribe skills, sin ripple, sin 2x con tono normal.
> Decisión de Daniel: soberanía en las DOS articulaciones donde la fábrica toca HyperFrames,
> en UN solo build. "Rentamos el pincel, no el cuadro" → ahora el pincel también es nuestro.

## MISIÓN

Plataforma de video de la casa (familia sf*: sflow, sfcast, sfterm, sfpoint) que sustituye a
HyperFrames en sus dos articulaciones reales: (1) el render HTML→video de cards y (2) la mesa de
revisión. **AI-first radical**: la fábrica (ffmpeg + scripts de la skill `edicion-de-video`) sigue
siendo quien corta, compone e imprime el máster; SFStudio es el pincel de cards + la Sala de
Revisión donde Daniel VE, RECORTA fino y ANOTA — y sus recortes/notas vuelven a la fábrica como
datos (`fixes.json`), no como render manual. La única cabina manual que existe: recortes A/S/D,
porque ahí el ojo humano ve lo que el agente no alcanza a percibir.

Vive en `~/Developer/software/sfstudio` (repo git propio, sin remote por ahora, con su CLAUDE.md,
igual que los repos hermanos). Marca de la casa: UI oscura mínima, paleta `#09090b` / `#ff9101` /
`#8C27F1` sutil. **Cero hardcode de aspecto**: hoy 16:9, mañana 9:16 — dimensiones y fps son
siempre datos del proyecto/card, nunca constantes.

## CONTEXTO OBLIGATORIO (leer antes de escribir código)

- Skill `edicion-de-video` ENTERA: SKILL.md + `references/pipeline.md` (Etapa 6 = qué hace hoy
  HyperFrames en la línea) + `references/gotchas.md` #33-36 (las heridas de Studio/HF) y #40-44.
- **Fixture real de aceptación**: `~/Developer/business-os/agent-server/workspace/generated/video-final-5-practica/`
  → `design/cards/*` (fuentes HTML de cards bajo nuestro contrato), `design/cardmp4/*` (renders HF
  de referencia para paridad), `design/placed_events.json` (el montaje real), `edit/clean30f7.mp4`
  (base 40 min) y `studio/` (el proyecto HF actual que vamos a superar; su `base-720p.mp4` sirve tal cual).
- `design/gen_studio_v5.py` — el generador programático actual: SFStudio hereda este patrón
  (proyecto de revisión EMITIDO por la fábrica, jamás armado a mano).
- HyperFrames local (pineado `hyperframes@0.7.39`) y su repo público: **referencia permitida**
  (Apache-2.0; si vendorizas código conserva los avisos de copyright). Róbate las ideas buenas
  (render determinista frame-a-frame, contrato de composición), no el producto entero.

## EL CONTRATO DE CARDS (invariante — NO se toca)

Nuestros generadores emiten cards HTML así y DEBEN renderizar sin cambiar una línea:
`<div id="root" data-composition-id="X" data-start="0" data-duration="N" data-width="W"
data-height="H">` + assets relativos (fonts/, img/, gsap.min.js local) + UNA
`gsap.timeline({paused:true})` registrada en `window.__timelines[id]`. Ese contrato lo escribimos
nosotros; HyperFrames solo lo ejecutaba. Ahora lo ejecuta sfrender.

## COMPONENTE 1 — `sfrender` (CLI: card HTML → video)

- Motor: navegador headless (tu elección: Playwright/Puppeteer) que hace **seek determinista** de
  la timeline GSAP frame a frame (`tl.seek(f/fps)` + settle; nada de reloj real ni capturas al
  vuelo), screenshot por frame, y muxeo con ffmpeg.
- **Hallazgos verificados 18 jul 2026 (research web, no negociables)**:
  - NO usar `HeadlessExperimental.beginFrame`: removido en Chromium 147 (HF lo parcheó en su
    issue #294 → PR #296 cambiando a screenshot plano post-seek). Screenshot normal tras el seek.
  - Lanzar Chromium con `--force-color-profile=srgb` (sin esto el color varía entre máquinas;
    el determinismo debe cubrir color, no solo timing).
  - Gate de fonts: `await document.fonts.ready` + 1 screenshot de calentamiento descartable
    antes del loop real.
  - Si una card contiene `<video>` embebido: pre-extraer a secuencia de imágenes con ffmpeg e
    inyectar `<img>` por frame ocultando el `<video>` (los decoders de Chrome headless NO
    obedecen el seek; HeyGen y Replit documentan la misma solución). Paso del pipeline, no edge case.
  - Animación FUERA de la timeline GSAP (CSS @keyframes sueltos, rAF propio, Date.now()) NO se
    congela con el paused — el contrato exige todo dentro de la timeline; escape-hatch opcional:
    `Emulation.setVirtualTimePolicy` vía CDP (sigue Experimental, solo fallback).
- Salidas: **MP4 h264** (videotoolbox si disponible, libx264 fallback) y **WebM VP9 con ALPHA**
  (receta verificada: `libvpx-vp9 -pix_fmt yuva420p` + screenshots con `omitBackground`; SIEMPRE
  una sola pasada continua — el alpha de VP9 driftea/resetea si se renderiza en chunks). OJO:
  Apple Silicon NO tiene encoder de hardware VP9 (solo decode) ⇒ el webm-alpha es CPU-bound por
  diseño; si necesitas velocidad, paraleliza POR CARD, nunca por chunks del mismo card. ProRes
  4444 opcional. fps por parámetro (default 30), resolución del `data-width/height` del card —
  cualquier aspecto.
- CLI: `sfrender <card-dir> -o out.mp4 [--format mp4|webm|prores] [--fps N]`. Silencioso, exit
  codes correctos, tiempos impresos.
- **Paridad obligatoria** contra HF: renderiza ≥2 cards reales del v5 — `demo-mercado-ruptura`
  (mp4 opaco) y `logo-google-R` (webm alpha) — y compara vs `design/cardmp4/*` existentes:
  duración exacta, conteo de frames, y frames clave MIRADOS con vision lado a lado.
- Rendimiento: razonable (≤2x el tiempo de HF por card está bien; son clips de 2-7s).

## COMPONENTE 2 — `sfreview` (la Sala de Revisión, app web local)

- **Formato de proyecto PROPIO**: `timeline.json` — `{width, height, fps, duration, base:{src},
  audio:{src}, items:[{id, type: video|image, src, start, dur, track, fit, muted}]}` + carpeta
  `assets/`. Simple, legible, editable por agente.
- **Adapter incluido**: script que convierte el `placed_events.json` + assets del v5 real a
  `timeline.json` (heredando la lógica de resolución/ráfagas de `gen_studio_v5.py`). El proyecto
  v5 REAL cargado y reproduciendo en sfreview ES la prueba de aceptación E2E.
- **Player**: base + overlays compuestos en vivo (elementos posicionados absolutos, como el
  index.html actual de Studio pero con NUESTRO runtime, no el suyo). Seek fluido: base con
  faststart Y GOP corto (si re-encodeas el proxy: `-g 15` a `-g 30` @30fps — es archivo local,
  prioriza scrubbing sobre peso). Timeline visual inferior con los items por track, zoom básico.
  **Overlay manager por VENTANA DE TIEMPO**: monta/desmonta los `<video>` overlay que intersectan
  playhead ±3s (cada webm-alpha cuesta 2 decoders — plano color + plano alpha — y Chromium capa
  75 media players por página; "dynamic creation and destruction" es la recomendación textual de
  los ingenieros de Chromium). Target: **Chrome/Chromium** — Safari NO decodifica WebM+alpha en
  absoluto; documéntalo en el README.
- **Velocidades 1 / 1.25 / 1.5 / 2x con TONO NORMAL NATIVO** (`preservesPitch=true`, que es el
  default de HTML5 audio). La razón #1 de nuestros parches contra HF muere aquí. Atajo de teclado.
- **Recortes — la única cabina manual (pedido literal de Daniel)**:
  - `S` = split en el playhead · `A` = trim del segmento hacia la IZQUIERDA (desde el split/inicio
    hasta el playhead se marca recorte) · `D` = trim hacia la DERECHA · `⌘Z` undo.
  - **No destructivos**: el player SALTA los rangos recortados en vivo (preview inmediato del
    resultado) y se pintan tachados en la timeline. Nada se re-renderiza en la sala.
    El loop de salto va con `requestVideoFrameCallback` (chequeo por-frame), NUNCA con
    `timeupdate` (granularidad de hasta 250ms = 7-15 frames del material cortado visibles
    antes de saltar; se vería sucio).
- **Marcadores AI-first**: `M` (o click en la timeline) = marcador en el timestamp con nota de
  texto ("este corte luce weird"). Lista lateral de marcadores navegable.
- **Export `fixes.json`** (botón + atajo `E`): `{video, exported_at, trims:[{start,end}],
  markers:[{t, nota}]}`. Es EL puente del loop AI-first: Daniel recorta/anota → la fábrica (Levy)
  consume el archivo y aplica los cortes al máster con ffmpeg (trim/atrim+concat, gotcha #20).
  Incluye en el repo el consumidor: `sfstudio-apply fixes.json master.mp4 -o master2.mp4` con modo
  `--dry-run` que imprime los cortes que aplicaría.
- Servidor local **puerto 3010**, un comando de arranque, headers no-cache para assets (mata el
  gotcha #34 del cache), cero telemetría, cero checksums que bloqueen nada.
- UI mínima: player + timeline + velocidades + marcadores. NADA de storyboard, inspector,
  export-cloud ni features de HF que nunca usamos. **Vendor permitido**: `media-chrome` (MIT,
  de Mux — scrubber + thumbnail-preview al hover + menú de velocidad ya resueltos y activos a
  jul 2026) si te acelera; NO meter OpenCut (monorepo Rust/WASM en rewrite inestable),
  LosslessCut (GPL-2.0 y forma equivocada: remuxea streams de UN archivo, no compone overlays)
  ni libs de timeline genéricas (vis-timeline/react-timeline-editor: no son video-aware) — el
  timeline de overlays se construye a medida, es más barato que adaptarlas.

## COMPONENTE 3 — Integración con la fábrica (la skill)

- Nuevo `edicion-de-video/references/sfstudio.md`: el manual del AGENTE — generar `timeline.json`
  desde placed_events, arrancar la sala, renderizar cards con sfrender, consumir `fixes.json`
  (comando exacto + cómo aplicar los trims al máster), gotchas del build.
- Edición MÍNIMA de `SKILL.md` + `pipeline.md` (Etapa 6): sfstudio pasa a ser el camino DEFAULT de
  entrega (sala + fixes.json); HyperFrames queda documentado como fallback hasta que Daniel valide
  el primer video real en sfstudio. **No inflar la skill**; el detalle vive en la reference nueva.
- `CLAUDE.md` del repo sfstudio: stack, comandos, invariantes (contrato de cards, formato
  timeline.json/fixes.json), gotchas descubiertos en el build.

## DEFINICIÓN DE HECHO (el evaluador solo ve esta conversación — surfea TODA la evidencia)

1. **Paridad sfrender pegada**: tabla duración/frames de las 2 cards reales vs sus cardmp4 de HF +
   frames lado a lado MIRADOS con vision (incluye verificación del alpha del webm).
2. **sfreview corriendo**: comando + URL + screenshots Playwright de: (a) el proyecto v5 REAL
   cargado con overlays visibles en el player y la timeline poblada, (b) reproducción a 2x
   (indicador visible), (c) un split `S` + trim `D` aplicado y visible tachado en la timeline,
   (d) un marcador con nota, (e) el `fixes.json` exportado con ese trim y ese marcador (contenido
   pegado en la conversación).
3. **Round-trip AI-first**: `sfstudio-apply --dry-run` sobre ese fixes.json imprime los cortes
   ffmpeg exactos (output pegado).
4. **Aspect-agnostic probado**: una composición 9:16 sintética mínima cargada en la sala
   (screenshot) y una card 9:16 renderizada por sfrender (probe pegado).
5. **Skill actualizada**: resumen del diff de `references/sfstudio.md` + SKILL.md/pipeline.md.
6. **Repo limpio**: git init con commits atómicos, CLAUDE.md + README cortos, `npm test`/arnés en
   verde (0 errores de consola en la sala vía Playwright).
7. Lista explícita de las formas en que podría estar roto/incompleto — y resuélvelas antes de
   declarar terminado.

## COMANDO DE VALIDACIÓN

Stack libre ⇒ decláralo tú: en tu PRIMER checkpoint define UN comando (build + test + arnés de
humo Playwright en uno) y córrelo tras cada cambio grande, surfeando su output en la conversación.

## RESTRICCIONES REALES

- El contrato de cards existente NO cambia (generadores actuales renderizan sin tocarse).
- El MÁSTER final sigue siendo la imprenta ffmpeg de la fábrica: sfstudio NO renderiza el video
  completo (stretch opcional solo si toda la DoD ya está verde).
- Todo local. NUNCA `--upload`/publicar. Sub-agentes SIEMPRE en Sonnet (regla dura del sistema).
- HyperFrames queda intacto y funcional como fallback (no desinstalar, no romper el `studio/` v5).
- No tocar el máster v5 entregado (`~/Downloads/video-final-5-practica.mp4`) ni el raw.
- Apache-2.0: si vendorizas código de HF, conserva avisos de copyright. ANTES de escribir de
  cero las 2 piezas más difíciles de sfrender (captura sin beginFrame, pre-extracción de
  `<video>`), lee cómo las resuelve HF en su fuente — ya están probadas en producción.
- Documenta en el CLAUDE.md del repo la DECISIÓN DE SOBERANÍA, explícita: HyperFrames
  (v0.7.64 del 18 jul 2026, cadencia casi diaria) cubre sfrender técnicamente al 100%;
  construimos propio por soberanía y marca de la casa (mismo principio que sfterm: "rentamos
  el pincel, no el cuadro"), y sfreview SÍ es terreno abierto (ningún tool existente hace
  master+overlays-alpha+trims no destructivos+fixes.json para consumo de agente). Escrito
  para que ninguna sesión futura reabra el debate.
- Chequeo al arrancar: `ffmpeg -version` (estable actual 8.1.2 "Hoare"; h264_videotoolbox y
  libvpx-vp9 yuva420p llevan años estables — cualquier 7.x/8.x de brew sirve).

## RED DE SEGURIDAD

Si tras 80 turnos no converges, o el mismo blocker se repite 3 veces por la misma causa, DETENTE y
deja por escrito: qué funciona (con evidencia), qué falta, y la decisión que necesitas de Daniel.
