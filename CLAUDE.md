# SFCast — contrato para agentes

App macOS Swift/SPM para grabar pantalla/cámara, con pipeline VPS. Repo independiente
`~/Developer/software/sfcast`. La sala de revisión/publicación vive en `sala/` (SFStudio
fusionado con su historia); leer `sala/CLAUDE.md` antes de tocarla. No es un submódulo de Arbrain.

## Abrir por necesidad

| Trabajo | Fuente |
|---|---|
| Instalar, operar, permisos y diagnóstico | `README.md` |
| Cámara, panel El Set, PTP, preparación de rodaje | `docs/agent-reference.md` → «La Cámara», «La cámara se deja lista SOLA», «El Set no se recarga EN CÁMARA» |
| Compositor, grabación, audio, escenas, espejo y pruebas | `docs/agent-reference.md` → «Modo Estudio», «Espejo», «Dos Caras», «Invariantes» |
| Razones históricas de diseño | `DECISIONS.md`, sección de la función afectada |
| Edición/revisión/publicación | `sala/CLAUDE.md` |

`docs/agent-reference.md` conserva íntegro el contrato detallado del 17 sep 2026.
Sus mediciones tienen fecha; no usar cifras antiguas de red o rendimiento como estado vivo.
Al modificar un mecanismo, abrir su sección completa y actualizar su documentación canónica.

## Reglas que gobiernan sin abrir más

- **No interrumpir una toma.** Comprobar `~/.sfcast/grabando` y log vivo en
  `~/Library/Logs/sfcast.log` antes de cerrar, instalar o hacer QA de captura.
  La recarga del panel El Set se aplaza mientras haya grabación.
- **Firma estable `SFlow Dev`, nunca ad-hoc.** Cerrar SFCast antes de sustituir su bundle;
  conservar respaldo, preparar/verificar la nueva app y mantener rollback. No copiar encima
  del proceso vivo. Los permisos se solicitan en serie mediante el broker existente.
- **Original local siempre a salvo** en `~/Movies/SFCast/<id>/`, aunque falle la subida.
  No recomprimir masters para una subida posterior. Respetar `autoUpload` y destino local/VPS.
- Al detener Loom: primero enlace, luego quitar pill, después cerrar MP4.
- Cámara por CLI del repo `sfcam`; no duplicar PTP ni su preset. Una lectura PTP interrumpe
  la imagen 1–4 segundos: no añadir polling de cámara durante la toma. El gate de preparación
  corre antes de grabar y solo en escenas con cámara.
- `StudioConfig` tiene decoder manual: registrar cada campo nuevo en `init(from:)`.
  Offsets finales entre pistas se miden por audio y se refinan con ffmpeg.
- Captura exige sensor real: delegate/latidos del stream, formato de cada buffer, espacio
  libre y auto-stop. Alta frecuencia va por CALayer, no por `@Published` de toda la ventana.
  Un mic muerto debe recuperarse; uno vivo no se reconfigura a media toma.
- QA no roba foco ni cambia la configuración de Daniel. Cambios de arranque/cierre exigen
  tomas encadenadas; cambios de recuperación del mic exigen `--micdrop` y su salida verificada.

## Comandos

```bash
swift build -c release           # compilar, sin instalar ni cerrar la app
bash scripts/build-app.sh       # bundle firmado en dist/SFCast.app
bash scripts/validate.sh        # leer antes: comprobar alcance y efectos de la validación
```

Instalación y QA: seguir `README.md` y la sección pertinente de `docs/agent-reference.md`;
verificar que no haya toma, respaldar y cerrar antes de reemplazar. Sin Xcode, existe
`scripts/build-sin-xcode.sh`. Los arneses de captura se lanzan por `open` para que TCC
atribuya permisos correctamente; detalles y señales esperadas están en la referencia.

Operación conversacional del Estudio: `touch ~/.sfcast/abrir-estudio`.
`sfcast://rodaje` abre la superficie de rodaje; no usarlo durante mantenimiento silencioso.
