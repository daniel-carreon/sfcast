# SFCast — el Loom soberano de SaaS Factory

> App macOS nativa (Swift) + pipeline propio en el VPS. Grabas pantalla con
> burbuja de cámara, al dar stop **el link YA está en tu portapapeles**, y el VPS
> genera transcript en español + título + resumen + capítulos + viewer web, solo.
> **$0/mes** (Loom Business cobra $18-24 por usuario al mes).
>
> Repo: `~/Developer/software/sfcast` (independiente, sin remote).
> Por qué cada decisión es como es: **`DECISIONS.md`** (v1.1 → v1.6).

---

## 1. El camino de un video, de punta a punta

```
   TU MAC                                    │   VPS (hermes-vps)
                                             │
  micropanel ⏺                               │
      ↓  Empezar a grabar                    │
  SCStream + SCRecordingOutput ──→ seg-NNN.mp4   (0.6-1.6% CPU, HEVC ~7 Mbps)
      ↓  stop                                │
  ① link al portapapeles  ← INSTANTÁNEO      │
  ② pill fuera + navegador abre "Procesando…"│
  ③ se cierra el MP4                         │
  ④ Transcoder: re-encode por hardware       │   (~4.5x más chico, ~2.6s/17s)
  ⑤ rsync ──────────────────────────────────→│  /opt/sfcast/incoming/{id}/
                                             │        ↓ UPLOAD_DONE
                                             │  concat (stream copy) → thumb
                                             │        ↓
                                             │  faster-whisper es (~4x realtime)
                                             │        ↓
                                             │  LLM: título+resumen+capítulos
                                             │        ↓
                                             │  viewer HTML pisa el "Procesando…"
```

**El orden 1-2-3 no es casual y no se toca:** cerrar el MP4 tarda ~0.3-1s
esperando al writer, y ESE era todo el lag percibido. El link sale primero.

**Dónde se va el tiempo de verdad** (medido el 15 jul, video de 17s):

| Etapa | Tiempo |
|---|---|
| **Subida Mac → VPS** | **~15 min** ← el cuello, siempre |
| Pipeline entero del VPS | 89s (73 de ellos: cargar el modelo, ya precargado) |

La captura escribe a **7 Mbps** (52 MB por minuto grabado) y el upstream de
Daniel mide **≤0.33 Mbps** (medido contra Cloudflare, no contra el VPS: es el
ISP, no la infra). De ahí que comprimir antes de subir sea el fix grande.

---

## 2. Instalar / actualizar

```bash
cd ~/Developer/software/sfcast
./scripts/build-app.sh                    # compila + firma "SFlow Dev" → dist/SFCast.app
rm -rf /Applications/SFCast.app
cp -R dist/SFCast.app /Applications/
open /Applications/SFCast.app
```

Vive en **/Applications** con su icono propio (anillo mostaza): Spotlight o
Launchpad, como cualquier app. Con el hub abierto sale en el Dock y Cmd+Tab; al
cerrarlo queda solo el ⏺ del menu bar. Salir: Cmd+Q o "Salir de SFCast".

**Cada rebuild cuesta UNA re-aprobación del permiso de pantalla.** macOS 26 lo
liga al cdhash del binario. Cámara y micrófono NO se revocan porque la firma
("SFlow Dev") es estable — por eso existe.

---

## 3. Permisos (el arco que más dolió — ver DECISIONS v1.2/v1.3)

- Al abrir, la app pide cámara y micrófono **EN SERIE** por un broker único.
  Jamás en ráfaga: la ráfaga atasca tccd y los diálogos dejan de pintar.
- Estado y reparación: hub → Inicio → tarjeta **Permisos**. El botón
  **"Activar cámara y micrófono"** es lo más confiable (un diálogo pedido por
  gesto del usuario pinta mejor). **Reparar** = resetea + vuelve a pedir.
- La de pantalla se pide al primer Grabar.

> **Un permiso que dice "falta" y NUNCA pregunta está DENEGADO**, no pendiente
> (típico: un diálogo huérfano que macOS resolvió solo al reiniciar). Fix:
> `tccutil reset Camera so.saasfactory.sfcast` y relanzar. Con SIP activo no se
> puede reiniciar tccd; si NINGÚN diálogo sale ni con el botón, **reinicia la Mac
> una vez**. Nunca toques UserNotificationCenter: envenena la cola y todo se
> vuelve deny instantáneo.

---

## 4. Grabar (uso diario)

- **Click en el ⏺ del menu bar → MICROPANEL** (estilo Loom): modo
  Pantalla/Ventana/Cámara · cámara con toggle (la burbuja se enciende **en vivo**
  como preview) · mic con toggle + **vúmetro en tiempo real** · **Empezar a
  grabar**. Click otra vez, ✕ o Esc = se oculta. **Click derecho = menú clásico.**
- Atajo directo: **⌘⇧L** (countdown 3s → grabando).
- **Burbuja**: arrástrala · hover = chips S·M·L·⛶ · doble clic = ciclar tamaño ·
  clic derecho = tamaño y glow. **Queda quemada en el video** tal como la ves.
- **Pill vertical** (arriba-izquierda, arrastrable): cuadro mostaza = **detener
  y copiar link** · timer · ⏸ pausa. **Hover = se expande**: ↺ reiniciar · 🗑
  descartar. No sale en el video.
- **Al detener**: link copiado al instante + el navegador abre la página del
  video ("Procesando…" que se convierte sola en el viewer).
- **Historial**: hub → Historial (o menú ⏺: últimas 8, clic = copiar link).

---

## 4b. Modo Estudio (v2.0 — escenas + doble salida)

> Menú ⏺ (clic derecho) → **🎬 Modo Estudio…** Es el OBS/Streamlabs soberano con
> piel Screen Studio: paneles de **Escenas · Fuentes · Preview/Programa · Mixer ·
> Salidas**. El modo Loom queda intacto; el Estudio es opt-in.

- **Escenas**: presets de fábrica "Completa", **"Loom"** (pantalla + burbuja de
  cámara POR COMPOSICIÓN, sin burn-in — cámara editable después), "Mi cámara
  solo", "Lado a lado". Crear/duplicar/renombrar/borrar; **switch EN VIVO**
  durante la grabación (queda en el timeline del manifest).
- **Fuentes** por escena: Pantalla, Cámara, Patrón de prueba. Reordenables (la
  última de la lista queda encima), transform con sliders (x/y/ancho/alto),
  llenar/ajustar, **burbuja circular**, mostrar/ocultar.
- **Doble salida** (config por grabación, panel Salidas):
  - `screen.mp4` — pantalla RAW (SCRecordingOutput del mismo stream del preview)
  - `camera.mov` — cámara RAW con tu voz (mic)
  - `seg-001.mp4` — el PROGRAMA compuesto (HEVC) con 2 pistas de audio
    SEPARADAS: track 1 mic, track 2 audio del sistema (estilo Screen Studio)
- **Local-first**: todo cae en `~/Movies/SFCast/{id}/` con **`manifest.json`**
  (inventario de archivos con rol, timeline de switches, snapshot de escenas) —
  el contrato para que un agente edite con cámara y pantalla separadas. Si el
  programa está activo también se escribe `meta.json`: el "↑ subir" del
  Historial y el worker del VPS lo tratan como un video normal (ojo: el rsync
  sube la carpeta ENTERA, raws incluidos — con tu upstream, pesa).
- La ventana del Estudio es **invisible a la captura** (`sharingType = .none`,
  como el pill). Escenas en `~/Library/Application Support/SFCast/scenes.json`.
- Grabación Loom y Estudio son excluyentes (guard cruzado con aviso).

### Espejo (v2.9 — ver qué estás tapando, y moverlo desde ahí)

> **Clic derecho en la fuente Cámara** → «Espejo en la pantalla».

En el Estudio la cámara no toca la pantalla física (la pega el compositor), así
que la burbuja te tapa el texto y no te enteras. El espejo proyecta esa burbuja
**sobre la pantalla que se está grabando**, en su posición, tamaño, forma y aro
exactos. Es **invisible en el video** (`sharingType = .none`, medido en cada
corrida de `--mirrortest`: fuga neta 0.0007 sobre 1.0).

- **Arrástrala en la pantalla** y el programa la sigue en el mismo frame (y al
  revés: si la mueves en el preview del Estudio, el espejo va detrás).
- **Al hover** salen los chips de tamaño — los cuatro del Loom (S · M · L ·
  completo). Clic derecho: el mismo menú.
- **Aviso de oclusión**: si debajo de la burbuja hay contenido de verdad, sale
  un **aro punteado ámbar**, y el punto de la fila Cámara (panel Fuentes) se
  pone ámbar.
- **Rayos X** (mismo menú): baja la burbuja al 18% para ver qué hay debajo.
  **Fijar**: deja de recibir clics, para que no te coma la esquina en plena
  toma; se suelta desde el mismo menú.
- **Sin borde, solo halo**: el aro definido se retiró de las dos cámaras (la del
  programa y la del espejo) a pedido de Daniel. El halo se topa contra el
  lienzo, así que a tamaño completo no crece hasta leerse como una banda.
- Se apaga solo, diciendo por qué, cuando la escena no lo admite ("aquí la
  cámara no tapa la pantalla" en Lado a lado, "esta escena no tiene cámara" en
  Completa). El toggle vive en `scenes.json` (`mirrorEnabled`) y se recuerda.

**Regalable:** el Estudio no toca el VPS ni credenciales. Para regalar el build:
`./scripts/build-app.sh` → compartir `dist/SFCast.app` (arrastrar a /Applications).
El tercero aprueba cámara/mic/pantalla en su primer uso; si no quiere el VPS,
apaga "subir" en el micropanel (`autoUpload=false`) o usa solo el Estudio.

---

## 5. Mejores prácticas (sacarle el jugo)

**Antes de grabar**
- **Usa el micropanel, no el atajo.** Los 3 segundos que te toma ver tu cara en
  la burbuja y ver el vúmetro moverse te ahorran regrabar 10 minutos. Para eso
  existe: es lo único que Loom hacía y nosotros no.
- **Graba en la pantalla más chica que tengas.** La captura toma la resolución
  NATIVA: un Retina o un 5K es 3-6x más píxeles = 3-6x más peso = 3-6x más
  subida. Un monitor externo 1080p es el modo barato.
- **Modo Ventana cuando no necesites tu cara.** Menos píxeles y sin burbuja.

**Durante**
- El pill se arrastra: si te tapa algo, muévelo. No sale en el video.
- Pausa (⏸) en vez de rehacer: cada pausa abre un segmento nuevo y el VPS los
  pega solos.
- ¿Te trabaste? Hover al pill → **↺ reiniciar** tira lo grabado y empieza de
  cero sin salir de la grabación.

**Después**
- **Pega el link YA.** Ya está en tu portapapeles y ya funciona: la página se
  convierte sola en el viewer cuando el video llegue. No esperes mirando.
- **Cada minuto grabado ≈ 12 MB ≈ 3 min de subida** con tu conexión actual (era
  52 MB/min antes de comprimir). Un video de 20 minutos son ~50 min de subida:
  si vas a grabar largo, arráncalo y vete a hacer otra cosa.
- **No duermas la Mac mientras sube.** Si se corta, el video NO se pierde
  (queda en `~/Movies/SFCast/{id}/`) y `--partial` reanuda, pero es tiempo tirado.
- Si algo falla, **la grabación siempre está a salvo en local**. Dile a Levy que
  la suba.

**La palanca real**
- Tu subida (~0.3-0.5 Mbps por Ethernet, contra 3.6 de bajada) es anormalmente
  mala y es el techo de todo. Ya exprimimos el software: comprimimos 4.5x y
  quitamos el gzip inútil. Lo que queda es tu ISP.

---

## 6. Ajustes

Casi todo se opera desde el micropanel (modo, cámara, mic) o la burbuja (tamaño,
glow). El hub guarda permisos, audio del sistema, countdown e historial.

Lo demás vive en `~/Library/Application Support/SFCast/settings.json` (decode
tolerante: agregar un campo no resetea tu config):

| Campo | Default | Para qué |
|---|---|---|
| `compressBeforeUpload` | `true` | `false` sube el original de 7 Mbps (subida ~5x más lenta) |
| `videoBitrateKbps` | `1200` | Ancla medida a 1080p de pantalla. **Escala sola con la resolución** (3024x1964 → ~3437k) y la cámara lleva el doble. Súbelo solo si ves borroso |
| `fps` | `30` | |
| `countdownSeconds` | `3` | |
| `baseURL` | `https://videos.saasfactory.so` | |

---

## 7. URLs

| Qué | URL |
|---|---|
| Video | `https://videos.saasfactory.so/v/{id}/` |
| Embed (iframe) | `https://videos.saasfactory.so/embed/{id}/` |
| Biblioteca privada | `https://videos.saasfactory.so/biblioteca/` (user `daniel`, password en `~/Library/Application Support/SFCast/biblioteca-access.txt`) |

**Embed en la comunidad:** botón "Copiar embed" en el viewer → pegar el
`<iframe>` en cualquier lección de SFC o página externa.

`livekit.saasfactory.so/v/{id}` sigue en 200 (ambos dominios sirven la misma
carpeta): ningún link viejo se rompe. Ahí vive además el stack de videollamadas.

---

## 8. Operar via Levy (AI-first — la UI es espejo)

Los videos viven en `/opt/sfcast/www/media/{id}/` (video.mp4, thumb.jpg,
data.json con el transcript). Dile a Levy:

- *"lista mis videos de SFCast"* → lee `/opt/sfcast/www/library.json`
- *"borra el video X"* → borra `www/media/{id}`, `www/v/{id}`, `www/embed/{id}` y regenera la biblioteca
- *"renómbralo a …"* → edita `titulo` en data.json + regenera el HTML
- *"recórtale los primeros N segundos"* → ffmpeg stream-copy + regenerar thumb
- *"resube el video X"* → el que se quedó en `~/Movies/SFCast/{id}/`

---

## 9. Monitoreo / recuperación

| Síntoma | Qué hacer |
|---|---|
| ¿Pipeline vivo? | `curl -s https://videos.saasfactory.so/api/cast/health` |
| Validación completa | `./scripts/validate.sh` (5 checks, GREEN esperado) |
| **El video tarda mucho** | Es la SUBIDA, casi nunca el VPS. El pipeline tarda 20-90s **desde que LLEGA** el archivo: `ssh hermes-vps 'tail -20 /var/log/sfcast-pipeline.log'` |
| Video no aparece tras subir | Mismo log. Las sesiones fallidas quedan en `/opt/sfcast/incoming/{id}/` con un archivo `FAILED`; borrar `FAILED` y `touch UPLOAD_DONE` para reintentar |
| Upload falló en la Mac | El video está en `~/Movies/SFCast/{id}/`. Resubir: `rsync -a ~/Movies/SFCast/{id}/ hermes-vps:/opt/sfcast/incoming/{id}/ && ssh hermes-vps touch /opt/sfcast/incoming/{id}/UPLOAD_DONE` |
| Reiniciar worker | `ssh hermes-vps systemctl restart sfcast-pipeline` (ojo: el modelo tarda ~130s en precargar; el health responde antes) |
| App no graba pantalla | System Settings → Privacidad → Grabación de pantalla → SFCast ON, y relanzar (típico tras un rebuild) |
| Se ve borroso | `videoBitrateKbps` arriba (ver §6) |
| Disco Mac <10GB | ScreenCaptureKit corta grabaciones (-3821). Liberar disco |

**QA headless** (no requieren gesto humano):

```bash
/Applications/SFCast.app/Contents/MacOS/SFCast --selftest 4       # motor de captura real
/Applications/SFCast.app/Contents/MacOS/SFCast --paneltest 8      # muestra el pill sin grabar
/Applications/SFCast.app/Contents/MacOS/SFCast --compresstest ~/Movies/SFCast/{id}   # compresor sobre una COPIA
open -W /Applications/SFCast.app --args --studiotest 8            # QA del Modo Estudio E2E
open -W /Applications/SFCast.app --args --rectest 14              # graba y VERIFICA el MP4 (pistas alineadas, cadencia, nada perdido)
open -W /Applications/SFCast.app --args --rectest 22 --chokems 60 # ahoga el loop a propósito → ejerce el governor
open -W /Applications/SFCast.app --args --synctest 12             # latencia REAL de cámara/pantalla/mic
./.build/debug/SFCast --compbench 60                              # costo y RAM por tamaño de lienzo (headless, sin TCC)
```

**`--rectest` es el gate del archivo (v3.0).** Verifica contra el MP4 —no contra la
intención— las tres cosas que el 9 ago salieron mal y nadie vio hasta el día
siguiente: que las dos pistas arrancan en el mismo instante (antes: video 0.000,
audio 0.152 en TODAS las grabaciones), que la cadencia se sostiene o baja pareja, y
que nada se pierde en silencio. Con `--chokems N` se ahoga el render loop a propósito:
un mecanismo de recuperación que nunca se disparó no es un fix, es una intención.
`--synctest` y `--compbench` salen al LOG (`~/Library/Logs/sfcast.log`) porque una app
lanzada con `open` no tiene stdout.

**OJO --studiotest:** lánzalo con `open` (launchd), no con el binario directo —
desde terminal el TCC se atribuye a la TERMINAL y pantalla/cámara salen "sin
señal" (graba solo el patrón de prueba, que es el fallback diseñado). Deja en
`~/Movies/SFCast/{id}/` los 3 archivos + manifest + PNGs del frame de programa
por escena + PNG de la ventana. Restaura `scenes.json` al salir.

---

## 10. Invariantes (para quien toque el código — Levy incluido)

1. **Una grabación JAMÁS se pierde.** Todo lo opcional es best-effort: sin
   ffmpeg, ffmpeg falla, rebasa el deadline, el resultado sale más grande o con
   otra duración ⇒ **se sube el original**. Comprimir no puede costar un video.
2. **El link se copia ANTES de cerrar el MP4.** Ese orden ES la experiencia.
3. **Todo proceso o llamada de sistema lleva deadline.** tccd se atasca y
   `startCapture`/`stopCapture` se cuelgan para siempre; sin deadline el estado
   queda en `.stopping` y "grabar de nuevo no hace nada". Y ojo:
   `withTaskGroup` NO sirve de timeout (espera a las child tasks) — tasks no
   estructuradas + continuation resume-once.
4. **stderr de subprocesos a un ARCHIVO, nunca a un Pipe que nadie drena.** Se
   llena a los ~64KB y bloquea al hijo para siempre. Mismo pie, dos veces ya.
5. **camOnly graba `.mov`; los otros modos `.mp4`.** Cualquier cosa que itere
   segmentos debe cubrir las dos extensiones.
6. **La captura no baja de resolución POR SÍ SOLA** (nativa × backingScaleFactor):
   todo bitrate fijo hay que escalarlo por píxeles o el texto sale borroso en
   Retina. ⚠️ **Enmienda v3.0:** sí baja cuando el LIENZO es menor — ahí se le pide
   a SCK la captura ya escalada (`StudioEngine.captureSize`, aspecto preservado,
   nunca hacia arriba) porque cada buffer pesa lo que pesa la salida: 302 MB de
   pool a 4K contra 66 MB a 1080p. El bitrate sigue escalándose por píxeles.
6b. **El programa se estampa con el reloj de ANTES de componer, menos la latencia
   MEDIDA de la fuente crítica** (`ProgramClock`). Estampar al terminar suma el
   tiempo de composición al desfase de labios, y lo empeora justo cuando la Mac va
   mal. Y **las dos pistas arrancan en el mismo instante**: el warmup del audio se
   mide contra el primer AUDIO, jamás contra el primer video (eso dejaba
   `audio start_time = 0.152` en todas las grabaciones).
6c. **Lo que puede fallar en silencio se cuenta en el sitio donde falla.** Un
   `return nil` en el camino caliente es un frame que desaparece del archivo sin
   aparecer en ningún contador — fue exactamente el bug del 9 ago. Y **ninguna
   alarma se decide por promedio**: por peor ventana. Un promedio de 45 minutos
   esconde un colapso de 6.
7. **Las vistas layer-backed de AppKit tienen las animaciones implícitas
   APAGADAS.** `layer.transform = x` salta. Usa `CABasicAnimation` explícita.
8. **El pill lleva `sharingType = .none`**: es invisible a CUALQUIER captura,
   incluido `screencapture`. Para revisar su diseño: `--paneltest`.
9. **Review adversarial antes de shippear.** 3 rondas, 3 veces encontró algo
   real que se me había pasado (el `.mov`, el bitrate sin escalar, el
   `stopCapture` sin deadline).

---

## 11. Límites conocidos (decisiones honestas)

- **Burbuja quemada** = no editable después. A cambio: link instantáneo.
- **Modo ventana = sin burbuja** (la burbuja vive en el display, no en la ventana).
- **El Estudio graba SOLO el display principal** (`CGMainDisplayID`), y no hay
  selector. Con dos monitores, lo que pongas en el segundo **no sale en el
  video**. El espejo (v2.9) lo delata de rebote: solo aparece en la pantalla que
  sí se está grabando.
- **Si la cámara elegida no está conectada, se cae a otra en silencio** (en el
  QA del 9 ago: la ZV-E10 apagada → grabó de "OBS Virtual Camera"). El nombre
  RESUELTO sale en el log al arrancar la sesión y en `--mirrortest`.
- **Grabación en pausa no sobrevive** al reinicio de la app.
- **No controlamos el bitrate de captura**: `SCRecordingOutputConfiguration` solo
  expone outputURL, fileType y codec. Bajarlo en origen exigiría re-arquitecturar
  a SCStream + AVAssetWriter y perder el 0.6-1.6% de CPU. Por eso comprimimos
  después.
- **ffmpeg es dependencia externa** (Homebrew). Si no está, todo funciona igual:
  solo sube más lento.
- El unit de Caddy puede mostrar "reloading" cosmético (la config nueva SÍ está
  aplicada vía admin API); `systemctl restart caddy` lo limpia cuando no haya
  clases en vivo.
