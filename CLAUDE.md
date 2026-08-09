# SFCast — el Loom soberano de SaaS Factory

> App macOS nativa (Swift) + pipeline propio en el VPS. Daniel graba pantalla con
> burbuja de cámara; al dar stop el link YA está en su portapapeles y el VPS genera
> transcript en español + título + resumen + capítulos + viewer web, solo. **$0/mes**
> (Loom Business cobra $18-24 por usuario al mes; Daniel lo canceló el mismo día).

**Repo independiente.** No es submódulo de `business-os` y no debe volver a serlo.
Hermano de `sflow-next`, `sfpoint`, `sfterm` en `~/Developer/software/`.

## Dónde está cada cosa

| Necesitas | Lee |
|---|---|
| Operar, instalar, grabar, permisos, troubleshooting | `README.md` (runbook E2E) |
| **Por qué** cada decisión es como es (v1.1 → v1.6) | `DECISIONS.md` |
| Spec de origen | `business-os/.claude/specs/sfcast-loom-soberano-2026-07-14-spec.md` |
| Memoria del proyecto | `business-os/.claude/memory/project/sfcast-loom-soberano-2026-07-14.md` |

## Stack

- **App Mac:** Swift 6 puro, SPM sin xcodeproj. El bundle `.app` se ensambla a mano
  en `scripts/build-app.sh` (patrón heredado de SFlow v3).
- **Captura:** ScreenCaptureKit + `SCRecordingOutput` (macOS 15+) directo a MP4 HEVC.
  Encode por hardware, CPU de un dígito.
- **Burbuja de cámara:** NSPanel circular flotante, **quemada** en la captura (no se
  compone después). Es decisión de producto: video terminado al instante del stop.
- **Upload:** rsync/ssh al VPS (alias `hermes-vps`) + marker `UPLOAD_DONE`.
- **Pipeline VPS:** Python asyncio (`infra/sfcast_worker.py`, ~600 líneas) — concat,
  faster-whisper large-v3-turbo int8 en español, LLM vía OpenRouter para
  título/resumen/capítulos, viewer HTML estático servido por Caddy.

## Comandos

```bash
./scripts/build-app.sh          # compila + firma "SFlow Dev" → dist/SFCast.app
./scripts/validate.sh           # validación
rm -rf /Applications/SFCast.app && cp -R dist/SFCast.app /Applications/   # instalar
./infra/deploy.sh               # sube el worker al VPS y reinicia el servicio
```

## Modo Estudio (v2.5, 25 jul 2026)

Estudio multi-escena estilo OBS/piel Screen Studio, ADITIVO sobre el Loom:
`StudioModel.swift` (escenas/fuentes, scenes.json) · `StudioEngine.swift`
(SCStream frames + compositor CoreImage + niveles) · `StudioRecorder.swift`
(doble salida: screen.mp4 + camera.mov raw, seg-001.mp4 programa con 2 pistas
AAC, manifest.json = contrato con SFStudio/edición agéntica) ·
`StudioWindow.swift` (vista desktop SwiftUI + `--studiotest`). Decisiones y
gotchas: `DECISIONS.md` §v2.0–§v2.8 (v2.7/v2.8: el preview se muere de hambre
si main se satura — nada de alta frecuencia viaja por `@Published` del
controller; vúmetro y preview van por CALayer directo, y el chip
"cámara N · preview N fps" es el sensor que lo delata). QA (SIEMPRE via `open` — TCC se atribuye al
proceso responsable, no al binario):

```bash
open -W /Applications/SFCast.app --args --studiotest 8                 # E2E compositor/escenas
open -W /Applications/SFCast.app --args --studiobench 45               # PESO por archivo + mic + salud
open -W /Applications/SFCast.app --args --studiobench 30 --killstream  # mata el stream: prueba la recuperación
open -W /Applications/SFCast.app --args --glowtest                     # aro neón: PNGs + costo por frame
open -W /Applications/SFCast.app --args --mirrortest 6                 # ESPEJO: invisibilidad, alineación, arrastre, tamaños, sensor, costo
open /Applications/SFCast.app --args --mirrorlook 16                   # ESPEJO capturable, para revisar el diseño con screenshot
```

`--mirrortest` imprime en `~/Library/Logs/sfcast.log` (con `open` no hay stdout).

Los tres bugs de la sesión real del 25 jul (mixer clavado, 15x el peso de OBS,
pantalla congelada 50 min) y sus raíces medidas están en `DECISIONS.md` §v2.4.
Resumen operativo: el programa sale a **~0.8 Mbps** (OBS hace 0.93), los RAW van
**apagados por default** (nada los consumía) y hay watchdog del stream +
guardias de disco con auto-stop.

## Espejo (v2.9, 9 ago 2026)

La burbuja del programa **proyectada sobre la pantalla que se captura**, para ver
—y poder mover— lo que estás tapando. `StudioMirror.swift`: NSPanel
`sharingType = .none` (invisible en el video), colocado por la **inversa de la
colocación de la fuente Pantalla** (`MirrorGeometry`), video colgado de la sesión
de cámara que YA tiene el Estudio. Arrastrarlo mueve el item de escena en vivo.
Botón **Espejo** en la barra; ojo/candado en su menú; tamaños del Loom
(`CameraBubble.Size`) en los chips de la burbuja. Sensor de oclusión
(`OcclusionProbe`) → aro punteado ámbar. Decisiones y el bug que encontró el QA
(esconder el panel estrangulaba la sesión de cámara: 60 → 0 fps):
`DECISIONS.md` §v2.9.

## Invariantes que NO se tocan

1. **El orden al detener es 1-link, 2-pill fuera, 3-cerrar MP4.** Cerrar el MP4 tarda
   ~0.3-1s esperando al writer, y ESE era todo el lag percibido. El link sale primero.
2. **Los permisos se piden EN SERIE por un broker único**, jamás en ráfaga: la ráfaga
   atasca `tccd` y los diálogos dejan de pintar. Fue la raíz del cuelgue de Daniel.
3. **La firma "SFlow Dev" es un cert local ESTABLE** (sin Apple Developer Program).
   macOS 15+ rompe ScreenCaptureKit con firma ad-hoc, y un cert estable mantiene el
   TCC de cámara/micrófono entre rebuilds. Por eso existe — no la cambies.
4. **Cada rebuild cuesta UNA re-aprobación del permiso de pantalla** (macOS lo liga al
   cdhash del binario). Es esperado, no un bug.
5. **La grabación siempre queda a salvo en local** (`~/Movies/SFCast/{id}/`) aunque la
   subida falle. `--partial` reanuda.

5b. **Todo órgano de captura lleva SENSOR, y el sensor se ejerce en QA** (v2.4).
   Los tres bugs del 25 jul sobrevivieron porque la app no medía su propia
   salida: no decía cuánto pesaba, no decía si el stream respiraba, y el vúmetro
   nunca se contrastó contra una segunda fuente. Reglas que salieron de ahí:
   - Un `SCStream` SIEMPRE lleva delegate. Sin él, uno muerto se ve idéntico a
     uno vivo (el compositor recicla el último frame).
   - La vida del stream se mide por **latido de callbacks**, jamás por "¿cambió
     la imagen?" — una pantalla quieta es legítima y SCK deja de mandar frames.
   - El **formato de audio se lee de CADA buffer y el ancho del contenedor se
     MIDE** (`bytes / (frames · canales)`). El mismo micro sale `float32` o
     `int24 alineado alto` según el arranque; asumir int16 fue el bug del mixer.
   - Video de pantalla se codifica en **calidad constante**, nunca a bitrate
     promedio (es la diferencia entre 334 MB y 6 GB por la misma hora).
   - Nada que escriba a disco arranca sin **preflight de espacio** ni corre sin
     auto-stop: mejor 40 min buenos que 50 corruptos.
   - Nada que ocurra >1 vez/s pasa por `@Published` de un objeto que observa
     la ventana entera (v2.8: el vúmetro a 15 Hz saturó main con layout de
     SwiftUI y el preview cayó a 3 fps con cámara y compositor sanos). Alta
     frecuencia = CALayer directo. Y toda compuerta que TIRA trabajo para
     degradar con gracia lleva contador visible (`flowCounts()`). Los arrastres
     (preview y espejo) van por `setItemRectLive` → `sceneBox`; `config` se
     escribe UNA vez al soltar.
   - El tramo **DESPUÉS** se mide igual que el durante (v2.9). Apagar el espejo
     estrangulaba la sesión de cámara (60 → 0 fps) y el QA no lo veía porque
     medía "antes" y "con espejo", los dos perfectos. Todo lo que se prende y se
     apaga tiene que **devolver el sistema a su línea base**, y eso se afirma.
   - Un sensor que mide sobre imagen reescalada **no puede inventar la señal
     que busca** (v2.9): reducir con escala afín cruda y amplificar el filtro
     hacía que tres zonas distintas de la pantalla midieran lo mismo. Lanczos,
     intensidad por defecto, y el umbral se fija del RANGO medido.
6. **Destino local vs VPS** (toggle del micropanel, `autoUpload` en settings.json, v1.7):
   ON = sube al VPS al terminar (lo de siempre); OFF = SOLO guarda en local, sin subir.
   Se empuja luego con "↑ subir" del Historial. El push posterior NO comprime en sitio
   (`compressBeforeUpload=false`) para no degradar el master local — la compresión de
   `Transcoder` reemplaza los originales, así que jamás corre sobre lo que guardaste para
   editar. En modo local el clipboard recibe la RUTA local (no el link del VPS, que aún
   no existe).

## El cuello de botella real

La subida Mac→VPS domina TODO (~15 min para un video de 17s medido el 15 jul). La
captura escribe a 7 Mbps y el upstream de Daniel mide ≤0.33 Mbps — es el ISP, no la
infra. El software ya se exprimió (compresión 4.5x antes de subir, modelo Whisper
precargado, sin `-z` en rsync). No busques más optimización de software aquí.
