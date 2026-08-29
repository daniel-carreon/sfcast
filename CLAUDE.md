# SFCast — el Loom soberano de SaaS Factory

> App macOS nativa (Swift) + pipeline propio en el VPS. Daniel graba pantalla con
> burbuja de cámara; al dar stop el link YA está en su portapapeles y el VPS genera
> transcript en español + título + resumen + capítulos + viewer web, solo. **$0/mes**
> (Loom Business cobra $18-24 por usuario al mes; Daniel lo canceló el mismo día).

**Repo independiente.** No es submódulo de `business-os` y no debe volver a serlo.
Hermano de `sflow-next`, `sfpoint`, `sfterm` en `~/Developer/software/`.

**`sala/` es SFStudio, fusionado aquí con su historia de git completa (29 ago 2026).**
Grabar (este repo) y revisar/publicar (`sala/`, ex `~/Developer/software/sfstudio`) viven
ahora en un solo repo — Node/Playwright, independiente del target Swift, `npm install`
dentro de `sala/` antes de usarlo. Detalle: `sala/CLAUDE.md`. El repo `sfstudio` original
queda intacto y sin tocar hasta que Daniel decida su destino (archivar o retirar).

## La Cámara — UNA tarjeta, la primera de El Set (28 ago 2026)

**ISO, obturación, apertura y balance de blancos de la ZV-E10 sin salir de
aquí.** Durante una toma, cambiar de ventana para corregir el ISO no es una
opción.

Vive en `SetCameraCard` (CameraPanel.swift): **la primera tarjeta del cajón
derecho**, encima del panel web. Llegó a estar en TRES sitios a la vez —columna
del panel inferior, cajón propio y la tarjeta del enchufe al fondo de El Set— y
Daniel los contó: *"la cámara es lo principal, ponla la primerita hasta arriba a
la derecha en el set"*. Ahora:

- **Sin abrir nada:** ISO (lo único que toca a mano), «Exponer a la cara», lo que
  el ojo mide (cara/quemado, gratis: sale del frame que ya entra), los avisos que
  cuestan una toma y el interruptor de la corriente (Shelly).
- **«Avanzado»** (se recuerda, `studio.camAvanzado`): todo lo demás — los cinco
  grupos, las huérfanas y los códigos sin traducir.
- El panel inferior quedó en 4 columnas: Escenas / Fuentes / Mixer / Salidas.
- En el panel web embebido (`?embed=sfcast`) se quitan sus dos tarjetas de cámara
  («Cómo se ve» y el enchufe): en iPhone/escritorio siguen ahí.

Habla con la cámara **llamando al CLI `sfcam`** (repo `sfcam`, control por PTP
sobre libgphoto2). El motor NO se duplica aquí: tiene su propia batería de 25
pruebas contra la cámara real, y dos copias del mismo protocolo se separan en
cuanto una se toca.

⚠️ **CADA LECTURA LE APAGA LA IMAGEN A LA CÁMARA 1-4 SEGUNDOS.** Está medido: la
ZV-E10 corta su live view mientras atiende el USB. Por eso el panel **no
consulta solo** — lee al abrirse, al escribir, y cuando se pulsa ↻. Si aparece
la tentación de poner un temporizador ahí, ya se probó: es exactamente lo que
hacía parpadear la grabación.

## El Set no se recarga EN CÁMARA (28 ago 2026)

El panel web se recarga solo cuando su HTML cambia en disco (`/version`, cada
4 s) — sin eso se queda pintando una versión vieja durante horas. Pero está
DENTRO del encuadre: esa tarde, grabando, una edición del HTML lo recargó a
mitad de toma y una tarjeta desapareció en el video.

`MarcaDeRodaje.swift` deja `~/.sfcast/grabando` mientras hay grabación viva (los
dos caminos: Estudio y Loom); `panel_server.py` lo reporta en `/version` y la
página **aplaza** la recarga hasta el corte. No se pierde el cambio: entra en
cuanto se para.

## Puerta para agentes

```bash
touch ~/.sfcast/abrir-estudio      # abre el Modo Estudio
```

El Estudio solo se abría desde el menú de la barra, que no se puede pulsar por
software sin permisos de Accesibilidad. Con esto Levy lo abre cuando Daniel se
lo pide hablando, y las pruebas automáticas pueden llegar al Estudio.

## Compilar sin Xcode

`swift build` se cae en máquinas sin Xcode (`unable to lookup item
'PlatformPath'`). Hay salida: `scripts/build-sin-xcode.sh` compila
KeyboardShortcuts aparte como librería estática, le escribe a mano el puente de
`Bundle.module` que normalmente genera SPM, y enlaza todo con `swiftc`.

⚠️ Se firma con **"SFlow Dev"**, la misma identidad de la app instalada.
Cambiar de identidad tira los permisos de Pantalla, Cámara y Micrófono.


## Dónde está cada cosa

| Necesitas | Lee |
|---|---|
| Operar, instalar, grabar, permisos, troubleshooting | `README.md` (runbook E2E) |
| **Por qué** cada decisión es como es (v1.1 → v1.6) | `DECISIONS.md` |
| Spec de origen | `business-os/.claude/specs/sfcast-loom-soberano-2026-07-14-spec.md` |
| Memoria del proyecto | `business-os/.claude/memory/project/sfcast-loom-soberano-2026-07-14.md` |
| Revisar (Sala), recortar, publicar a YouTube | `sala/CLAUDE.md` (ex SFStudio) — flujo completo también en `README.md` §4c |

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

## URL scheme `sfcast://` (18 ago 2026)

`sfcast://rodaje` (alias `//studio`) abre el Estudio a **pantalla completa en el
monitor IZQUIERDO** (el de menor `minX` en el arreglo — pedido de Daniel: el
rodaje va en el izquierdo) **con el drawer "El Set" abierto**. Handler en
`main.swift` (`applicationWillFinishLaunching` + kAEGetURL, registrado en WILL
para que llegue aunque LaunchServices arranque la app por la URL); fullscreen en
`StudioController.enterFullScreen()`. Consumidor: el MODO RODAJE (F4 del Logi) —
`business-os/entorno-fisico/modo-rodaje.sh`.

**El drawer "El Set"** (`SetPanelDrawer`, 18 ago): el panel del estudio físico
(`entorno-fisico/panel_server.py`, :8088) embebido como WKWebView a la derecha
del Estudio — luces/Pixoo/cámara sin salir de pantalla completa, también
grabando. Toggle: botón 💡 en la barra. El panel web sigue siendo la ÚNICA
implementación (esto es espejo, no copia); requiere `NSAllowsLocalNetworking`
en Info.plist y que el servicio :8088 esté arriba (modo-rodaje.sh lo garantiza).
Trae **resizer** (`SetResizeHandle`, 300-560px) y MEMORIA: ancho y
abierto/cerrado persisten en UserDefaults (`studio.setPanelWidth` /
`studio.setPanelOpen`); el acordeón interno del panel persiste en su propio
localStorage. `sfcast://rodaje` fuerza el drawer abierto.

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
open -W /Applications/SFCast.app --args --tomas 6 --dura 8              # TOMAS ENCADENADAS: 6 grabaciones con pausas crecientes
open -W /Applications/SFCast.app --args --tomas 6 --dura 8 --bug26ago   # …con el hueco de cabeza REVIVIDO a propósito
open -W /Applications/SFCast.app --args --bloqueamain 12                # congela main: ejerce el vigía MainWatch
```

⚠️ **`--tomas` es el arnés que faltaba** (26 ago 2026). Todo lo demás de esta lista
prueba UNA toma, y el bug del hueco de cabeza solo aparecía **de la segunda en
adelante** — la primera de cada sesión siempre salía perfecta. Si tocas el arranque
o el cierre de una grabación, este es el test que tiene que quedar verde.

⚠️ **Nunca sustituyas el bundle con la app corriendo.** Ahí sí se rompe el permiso
de pantalla (el proceso vivo se queda con una firma que ya no coincide con el
disco). Cierra SFCast, copia, abre.

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
Se prende en el **clic derecho de la fuente Cámara** → "Espejo en la pantalla"
(ahí viven también rayos X, fijar y los tamaños); los chips de la burbuja son
los del Loom (`CameraBubble.Size`). Sin anillo: solo halo, topado contra el
lienzo para que a tamaño completo no se lea como banda. Sensor de oclusión
(`OcclusionProbe`) → aro punteado ámbar. Decisiones y el bug que encontró el QA
(esconder el panel estrangulaba la sesión de cámara: 60 → 0 fps):
`DECISIONS.md` §v2.9.

## «Dos Caras» — pantalla y cámara como dos archivos (v4.0, 28 ago 2026)

La escena estándar de grabación: se elige y ya está todo puesto. Carga su propia
**receta** (`StudioScene.receta`) — las tres salidas + lienzo 1080 — y al salir
DEVUELVE la config de Daniel. Escribe `preset: "dos-caras"` en el manifest, que es
la señal para la edición de que esa sesión trae capas separadas y alineables.

- **El lienzo va a 1080 a propósito y NO es una rebaja de calidad.** `screen.mp4`
  conserva 2560×1440 porque la captura ya no está atada al lienzo (`captureSize`);
  lo único que baja es el PROGRAMA, que aquí es el proxy. Con el lienzo en 1440 se
  codifica la pantalla dos veces a tamaño completo y **la cámara cae de 25 a 12-15
  fps** (medido, A/B de 4 condiciones — `DECISIONS.md` §v4.0).
- **El offset entre pistas se mide por AUDIO, no por reloj** (`AlineadorDeAudio`):
  el mismo micrófono está en los dos archivos. Los cuatro caminos de reloj de
  AVFoundation fallan entre 3 y 52 frames.
- ⚠️ **El número final lo da ffmpeg, no la app.** En un `.mov` con edit list el
  desfase depende del decodificador: AVFoundation y ffmpeg difieren 44 ms
  constantes (el priming de AAC). Para componer:
  `python3 scripts/refinar-offset.py ~/Movies/SFCast/<id>`.
- ⛔ **El decoder de `StudioConfig` es A MANO**: un `var` nuevo que no se agregue a
  su `init(from:)` se escribe en disco y se lee como `nil`, en silencio.
- ⛔ **El QA no roba el foco**: `open -g` no basta si la app hace `NSApp.activate`.
  En `testMode` la ventana se queda atrás.

## Invariantes que NO se tocan

1. **El orden al detener es 1-link, 2-pill fuera, 3-cerrar MP4.** Cerrar el MP4 tarda
   ~0.3-1s esperando al writer, y ESE era todo el lag percibido. El link sale primero.
2. **Los permisos se piden EN SERIE por un broker único**, jamás en ráfaga: la ráfaga
   atasca `tccd` y los diálogos dejan de pintar. Fue la raíz del cuelgue de Daniel.
3. **La firma "SFlow Dev" es un cert local ESTABLE** (sin Apple Developer Program).
   macOS 15+ rompe ScreenCaptureKit con firma ad-hoc, y un cert estable mantiene el
   TCC de cámara/micrófono entre rebuilds. Por eso existe — no la cambies.
4. **El permiso de pantalla SÍ sobrevive a los rebuilds** (medido el 26 ago 2026, y
   corrige lo que este archivo afirmó durante un mes). El requisito designado del
   bundle es `identifier "so.saasfactory.sfcast" and certificate leaf =
   H"3039…"` — **habla del CERTIFICADO, no del cdhash**. Con la identidad estable
   "SFlow Dev", TCC revalida contra ese requisito y el permiso aguanta. Verificado
   esa noche en **7 ciclos seguidos de compilar + reinstalar** con cdhash distinto
   cada vez (`ddbd3d11` → `9c0918b9` → … → `a70e619d`): las grabaciones de pantalla
   siguieron funcionando sin un solo clic.
   ⚠️ Lo que sí lo rompe es otra cosa, y conviene no confundirlas: sustituir el
   bundle **con la app corriendo** deja al proceso vivo con una firma que ya no
   coincide con el disco. Por eso `scripts/instalar` (y cualquier mano) debe
   CERRAR SFCast antes de copiar. El apagón de cinco días de agosto (8,193
   reintentos fallidos, 21 ago 22:07 → 26 ago 07:04) encaja con eso o con una
   firma hecha por otro camino — **no con "cada rebuild cuesta un clic"**, que es
   lo que se creyó y lo que dejó dos veces un "⏳ pendiente de un gesto de Daniel"
   sin ejercer.
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
