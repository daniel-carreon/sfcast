# SFStudio — plataforma de video de la casa (familia sf*)

Sustituye a HyperFrames en las DOS articulaciones donde la fábrica de edición lo tocaba:
**sfrender** (cards HTML/GSAP → video) y **sfreview** (la Sala de Revisión). El máster final
SIEMPRE lo imprime la fábrica ffmpeg de la skill `edicion-de-video` — SFStudio es pincel + sala,
no imprenta.

## DECISIÓN DE SOBERANÍA (18 jul 2026 — no reabrir el debate)

HyperFrames (Apache-2.0, HeyGen, release casi diario) cubría sfrender técnicamente al 100% el día
que construimos esto. Se construyó propio a propósito: mismo principio que sfterm — *"rentamos el
pincel, no el cuadro"* — cortar la dependencia del roadmap/namespace de un tercero (parches
studio_unmute vs checksums, pin 0.7.39, cache, init que sobrescribe skills). sfreview sí es terreno
abierto: ningún tool hacía master+overlays-alpha+trims no destructivos+fixes.json para consumo de
agente. HyperFrames queda INTACTO como fallback en la skill.

## Stack

Node ≥20 ESM sin build step · Playwright (chromium) solo para sfrender y tests · ffmpeg del
sistema (≥7; validado con 8.1) · Python 3 solo el adapter. Vanilla JS en la sala (cero deps de UI).

## Comandos

```bash
npm test                                                  # EL comando de validación (6 checks, incluye humo Playwright)
node bin/sfrender.js <card-dir> -o out.mp4|out.webm|out.mov [--format mp4|webm|prores] [--fps N]
python3 adapter/placed2timeline.py <proyecto>/design      # placed_events.json → sfreview_project/
node bin/sfreview.js <project-dir> --port 3010            # la sala (background siempre)
node bin/sfstudio-apply.js <fixes.json> <master.mp4> [--dry-run] [-o out.mp4]
```

## Invariantes (romperlos = romper la fábrica)

1. **Contrato de cards** (lo escriben los generadores de la skill, NO se cambia aquí):
   `<div id="root" data-composition-id data-start data-duration data-width data-height>` + assets
   RELATIVOS DENTRO del card dir + UNA `gsap.timeline({paused:true})` en `window.__timelines[id]`.
   Animación fuera de esa timeline NO se congela en el render.
2. **timeline.json**: `{name,width,height,fps,duration,base{src},audio{src},items[{id,type,src,
   start,dur,track,fit,muted,alpha}]}` · tracks 1=clips(cover) 2=alpha(contain) 3=caps(stretch).
   Cero hardcode de aspecto: TODO sale de estos campos (16:9 y 9:16 probados).
3. **fixes.json**: `{video, exported_at, trims[{start,end}], markers[{t,nota}], splits[]}` — es el
   contrato del loop AI-first (sala → fábrica). `sfstudio-apply` y la sala lo comparten.
4. **WebM alpha**: `libvpx-vp9 -pix_fmt yuva420p -auto-alt-ref 0`, UNA pasada continua (el alpha
   driftea en chunks). VP9 no tiene HW encode en Apple Silicon: paralelizar POR CARD.
5. **Determinismo sfrender**: seek de la timeline pausada + screenshot plano (beginFrame ya no
   existe en Chromium ≥147) + `--force-color-profile=srgb` + fonts.ready + warmup.
6. **La sala no re-renderiza nada**: trims saltados en vivo con rVFC (no timeupdate), overlays
   montados por ventana ±3s, server con Range + no-cache. Target Chrome (Safari no decodifica
   WebM alpha).

## Gotchas pagados (no re-pagar)

- `waitForFunction` cuyo predicado devuelve la timeline GSAP (objeto circular) = cuelgue infinito
  → devolver SIEMPRE bool.
- polling `'raf'` en headless ocioso se cuelga (sin frames no hay rAF) → polling por intervalo, y
  settles de rAF siempre con timeout de escape.
- CSS `display:flex` le gana al atributo `hidden` → `[hidden]{display:none!important}`.
- Cerrar un input flotante sin `blur()` deja el foco en el elemento oculto y mata el teclado global.
- Base sin `+faststart` no seekea en browser; GOP corto (`-g 30`) para scrub fino.
- `startsWith` desnudo para confinar rutas = traversal por hermano-prefijo (`root` vs
  `root-evil` + `%2e%2e` crudo): usar `insideRoot()` (frontera con `path.sep`). Sin header
  CORS `*` en el server local. Regresión cubierta en test/server.test.js.
- `sfstudio-apply`: guard duración `fixes.duration` vs máster (>1s → aborta, `--force` salta),
  trims fuera de rango SIEMPRE reportados, máster sin audio soportado (graph solo-video).

## Integración con la fábrica

El manual del agente vive en la skill: `.claude/skills/edicion-de-video/references/sfstudio.md`
(business-os). Etapa 6 del pipeline usa SFStudio por default; el fixture de aceptación fue el
proyecto real `video-final-5-practica` (42 items, base 40 min).
