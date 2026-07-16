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

## El cuello de botella real

La subida Mac→VPS domina TODO (~15 min para un video de 17s medido el 15 jul). La
captura escribe a 7 Mbps y el upstream de Daniel mide ≤0.33 Mbps — es el ISP, no la
infra. El software ya se exprimió (compresión 4.5x antes de subir, modelo Whisper
precargado, sin `-z` en rsync). No busques más optimización de software aquí.
