# SFCast — Reporte de Decisiones (2026-07-14)

> Loom soberano construido por Levy vía /goal. Spec:
> `business-os/.claude/specs/sfcast-loom-soberano-2026-07-14-spec.md`.
> Contexto: Daniel canceló Loom ($18-24/user/mes) el mismo día.

## Stack elegido y por qué

| Capa | Elección | Por qué |
|---|---|---|
| App Mac | Swift puro SPM (patrón SFlow v3: bundle a mano, sin xcodeproj) | Stack ya dominado en casa; 832KB; cero deps runtime salvo KeyboardShortcuts |
| Captura | ScreenCaptureKit + **SCRecordingOutput** (macOS 15+) directo a MP4 HEVC | Encode hardware, CPU un dígito, mínimo código; HEVC esquiva el tope H.264 4096×2304 en Retina |
| Burbuja | NSPanel circular flotante con AVCaptureVideoPreviewLayer, **quemada** en la captura | Decisión de producto: video TERMINADO al instante del stop → link inmediato. Cap/Screen Studio componen post (editable) pero pierden el instante |
| Pausa | Segmentos: cada tramo = su propio SCStream/archivo; concat -c copy en el VPS | Robusto vs add/removeRecordingOutput en caliente; gap ~0.3s irrelevante |
| Link instantáneo | URL determinística (id generado al iniciar) → clipboard AL STOP; upload en background | El "momento mágico" de Loom sin imitar su patente de streaming progresivo |
| Upload | rsync/ssh (alias hermes-vps, llave existente) + marker UPLOAD_DONE | Cero endpoints nuevos expuestos; retry x3 con backoff; re-subible a mano |
| Pipeline VPS | Python asyncio (reusa venv + modelo whisper cacheado del meet-pipeline) | El VPS ya ERA el backend que Cap arma con Next.js+MySQL+MinIO; aquí son ~600 líneas |
| Transcript | faster-whisper large-v3-turbo int8, español, VAD | Mismo motor probado ayer en Meet Soberano; audio nunca sale del VPS |
| Título/resumen/capítulos | OpenRouter (gemini-2.5-flash) con salida JSON estricta + fallback | Barato, ya en el stack; si falla el LLM el video se publica igual |
| Web | HTML estáticos generados por el worker + Caddy file_server | Cero frameworks; viewer premium autocontenido (velocidad 1.2x, transcript clicable, capítulos, og:image); /embed para iframe; biblioteca con basic_auth |
| Firma | Cert local estable "SFlow Dev" (SIN Apple Developer Program) | macOS 15+ rompe SCK con ad-hoc; cert ESTABLE mantiene TCC entre rebuilds. Restaurada la confianza que el update a macOS 26.2 borró (trust settings vacíos) |

## Build vs adopt (por qué NO Cap self-hosted)

Cap (20K stars) se evaluó en serio: mete Next.js+MySQL+MinIO+media-server al
VPS, reliability inconsistente (crashes en Macs nuevos, multi-monitor roto),
AGPL cierra venderlo como parte del Business OS HT, y stack Rust/Tauri ajeno.
Capso (Swift, BSL) sirvió como referencia de arquitectura, sin copiar código.

## Descubrimientos técnicos (para el siguiente que toque esto)

1. **SCK exige NSApplication corriendo**: en CLI pelón, ScreenCaptureKit crea
   su status-item (indicador de grabación) vía AppKit en background thread →
   crash NSWindow. Fix: NSApp + app.run() (el spike lo encontró en 2 min).
2. **AVCaptureSession sin requestAccess = frames NEGROS silenciosos** (estado
   notDetermined no siempre dispara prompt). Siempre pedir permiso explícito.
3. **Los prompts TCC NO se disparan desde procesos CLI sueltos** (swift -e):
   solo la .app bundle como responsible process los genera confiablemente.
4. **macOS 26.2 borró los user trust settings** → "SFlow Dev" daba
   CSSMERR_TP_NOT_TRUSTED. `security add-trusted-cert -r trustRoot -p codeSign`
   lo restauró sin GUI (de paso arregló rebuilds de SFlow).
5. **Heredocs remotos + bcrypt = trampa**: `$2a$14$...` se expande a vacío si
   el heredoc no va quoteado ('PYEOF'). Pasar hashes por archivo, no inline.
6. **JAMÁS `pkill -f` en el VPS** (tercera vez que casi muerde: mata la propia
   sesión ssh si el patrón está en el cmdline remoto). Solo `pkill -x`.
7. **tccd SERIALIZA los prompts por proceso** (el cuelgue real de Daniel,
   14 jul 15:29): la burbuja pidió Cámara y 3s después `startCapture` (con
   `captureMicrophone=true` recién activado en el hub) necesitó el prompt de
   Micrófono → quedó ENCOLADO detrás del de cámara → startCapture nunca
   regresó → estado atorado en .countdown → botones "muertos" (los guards
   rebotaban). Cura de 3 capas: `Permissions.preflight` pide cámara→mic UNO
   POR UNO antes del countdown; el engine degrada a sin-mic si el permiso no
   está `authorized`; y `startCapture` corre con timeout de 12s → error
   recuperable en vez de zombie.
8. **macOS 26 liga la aprobación de Pantalla al cdhash del BUILD** aunque la
   firma (cert + identifier + designated requirement) sea estable: tras cada
   rebuild, un re-toggle. Confirmado 2 veces (selftest devolvió "0 displays"
   con DR idéntico). Cámara/Mic sí sobreviven rebuilds con el cert estable.
9. **`shadow` y `masksToBounds` NO pueden vivir en la misma capa** (el glow
   "que no funcionó"): el clip circular recortaba el shadow → invisible. Capa
   glow (sin clip) + capa video (con clip) separadas + `shadowPath`.
10. **Activation policy dinámica**: `LSUIElement=true` + `.regular` al abrir
    el hub / `.accessory` al cerrarlo = menu bar app que también es app "de
    verdad" (Dock, Cmd+Tab, Cmd+Q) solo cuando tiene ventana. Requiere armar
    `NSApp.mainMenu` a mano para que Cmd+Q/Cmd+W funcionen.
11. **`withTaskGroup` NO sirve para timeouts** (cazado por el review
    adversarial): la concurrencia estructurada espera a TODAS las child tasks
    antes de retornar — si `startCapture` está colgado, el "timeout" cuelga
    igual. Forma correcta: `Task.detached` (no estructuradas) + continuation
    con candado resume-once (`OnceFlag`); el perdedor tardío se auto-apaga.
12. **Todo `await` en @MainActor es una ventana de carrera**: cancel() puede
    correr mientras un start/pause/resume espera, y el código post-await
    "resucitaba" estados ya cancelados. Cura: `generation` por sesión +
    re-verificar `(gen, state)` tras CADA await + `.stopping` como estado
    CERRADO (pause/resume/stop/cancel lo ignoran — un doble-clic en Detener ya
    no puede borrar la sesión que se está subiendo).

## Riesgos / incompletos — item por item (final, post-evidencia)

| # | Item | Estado |
|---|---|---|
| 1 | Cámara y micrófono de SFCast.app: TCC pendiente de Daniel (2 clics one-time en su primer uso real) | La burbuja salió como PLACEHOLDER (círculo negro borde mostaza) en la evidencia — visible, movible, 4 tamaños ✓. Con su clic de Cámara se vuelve video en vivo sin tocar código. Mic: default OFF en settings hasta que lo otorgue (ver #9); el audio de sistema ya graba ✓ |
| 2 | Unit de Caddy en estado "reloading" cosmético | Config APLICADA y sirviendo (validate 5/5). `systemctl restart caddy` lo limpia cuando Daniel quiera |
| 3 | Panel de control salía EN el video (la exclusión por SCContentFilter no matcheó) | **Fix aplicado**: `sharingType = .none` (invisible a cualquier captura) — compilado y firmado, pendiente de verificar en la próxima grabación real (macOS pidió re-aprobar el permiso tras el rebuild y no quise quemar más clics de Daniel) |
| 4 | Modo ventana sin burbuja | Documentado como límite v1 (la burbuja vive en el display) |
| 5 | Worker sfcast comparte venv con meet-pipeline | Acoplamiento aceptado y documentado; separar si divergen deps |
| 6 | DNS videos.saasfactory.so | Namecheap sin API; migración de 5 min en runbook; BASE_URL configurable en ambos lados |
| 7 | Upload progresivo durante grabación (estilo Loom real) | v2: el diseño por segmentos deja la puerta (subir seg-N al cerrarse); hoy el link es instantáneo y el video tarda ~1-3 min en procesar |
| 8 | Retención/disco VPS | 351GB libres; sin política aún (video 5 min ≈ 50-200MB → años de margen). OJO disco del MAC: 2 veces ENOSPC hoy; liberé npm cache, VSCode ShipIt y ~/.cache/codex-runtimes (se re-descarga solo) |
| 9 | SCK `captureMicrophone` se COLGABA en startCapture | Causa: prompt de TCC imposible de pintar desde contexto CLI dejó a tccd en cola. En la app real (lanzada por Finder) el prompt sale normal. Default actual: mic OFF / audio de sistema ON. Para activar mic: otorgar Micrófono a SFCast y poner `micEnabled: true` en settings.json |
| 10 | macOS 26 pidió re-aprobar Grabación de Pantalla tras un rebuild (cdhash nuevo, mismo cert) | Comportamiento de macOS 15+ con apps de captura; re-toggle de 5 segundos. El cert estable evita lo peor (revocación total por firma ad-hoc) |

## Costo

$0/mes en servicios nuevos. Ahorro directo: la suscripción de Loom cancelada.

---

## v1.3 — El broker de permisos y la verdad dura del tccd atascado (15 jul)

Daniel reportó, ya de noche: los prompts de **cámara y micrófono NO aparecían** al
abrir la app, y la grabación **tardaba mucho** en mostrar la cámara. Diagnóstico E2E
con los logs de `tccd` y `UserNotificationCenter` (el proceso que RENDERIZA los
diálogos de consentimiento — no tccd, tccd solo DECIDE):

1. **Ráfaga concurrente = raíz.** Varias rutas de la app (arranque + burbuja +
   flujo de Grabar + Reparar) disparaban `AVCaptureDevice.requestAccess` a la vez.
   tccd los encola y deja **diálogos huérfanos** que ya no responden. Peor: cada
   relanzamiento de testing dejaba más peticiones colgadas en la cola de tccd.
   **Fix: `PermissionBroker`** — una sola puerta, serializa TODO (coalescing: N
   llamadas del mismo tipo → 1 solo `requestAccess`, los demás esperan su
   resultado). Jamás vuelve a inundar tccd. Es el arreglo de fondo.

2. **Arranque de grabación NO bloquea en permisos.** El flujo de Grabar arranca la
   pantalla YA; la cámara se pide en background y la burbuja se enciende cuando el
   permiso llega (con guarda `bubble.isVisible` para no prender la cámara si el
   usuario canceló). Mata el "tarda mucho en empezar a grabar".

3. **Diálogo en la pantalla equivocada.** Con 2 monitores el diálogo salía en el
   secundario. El broker ACTIVA la app y sube el hub como ventana clave antes de
   pedir, para sesgar el diálogo a la pantalla activa.

4. **Lo que NO se hace (y por qué):** intenté un "self-heal" que reiniciaba
   UserNotificationCenter cuando el prompt no pintaba. **Es dañino:** en una máquina
   con la cola de tccd ya atascada, matar UNC cerca de la petición la ENVENENA —
   tccd la resuelve como diálogo descartado = **DENEGADO** (probado en vivo). El
   broker JAMÁS toca UNC.

**La verdad dura de esa noche:** de tanto testing, la cola de prompts del **tccd de
usuario** (proceso desde el 12 jul) quedó atascada, y en macOS 26.2 tccd NO se puede
reiniciar con SIP activo — `killall tccd`, `launchctl kickstart -k`, `launchctl kill`
y `bootout` **todos fallan** ("Not privileged" / "Operation not permitted while SIP
is engaged"). Tampoco se puede escribir la TCC.db de usuario sin Full Disk Access
(mi contexto no lo tiene) ni reiniciar la Mac (FileVault ON → quedaría atascada en el
pre-boot). **La cola de tccd solo se limpia reiniciando la sesión/Mac.** Por eso el
código quedó correcto para un **tccd sano** (arranque normal o tras un reinicio del
sistema), y el hub muestra la guía honesta: si NINGÚN diálogo aparece ni con el botón
"Activar cámara y micrófono", reiniciar la Mac una vez destraba la cola de macOS.

**Verificado en este boot** (aunque el prompt no pueda pintar por el atasco): el
broker emite UNA sola petición por tipo, con espera paciente, sin ráfaga y sin tocar
UNC (log limpio). En un tccd sano eso pinta el diálogo a la primera.

**Revisión adversarial (Sonnet) antes del ship** cazó 3 bugs, todos arreglados:
(a) el hard-timeout + reintento podía denegar un prompt aún vivo → se eliminó todo
kill de UNC; (b) `resetAndReRequest` bloqueaba el MainActor con `waitUntilExit()` →
ahora corre en `Task.detached`; (c) la cámara en background podía encenderse tras
cancelar → guarda `bubble.isVisible`.

## v1.4 — El micropanel Loom-style y el preview honesto (15 jul, mañana)

Daniel pidió (con capturas de Loom): panel pre-grabación minimalista desde el
icono del menu bar, saber si el mic escucha y ver la cámara ANTES de grabar,
glow más sutil, y menos "basura" instructiva en el hub.

1. **LauncherPanel.swift (nuevo):** click IZQUIERDO en el icono → micropanel
   (modo Pantalla/Ventana/Cámara, fila cámara picker+toggle, fila mic
   picker+toggle+VÚMETRO en vivo, Empezar a grabar, footer mínimo). Click
   derecho (u Option, o durante grabación) → menú clásico. Esc o click al
   icono = se oculta todo.
2. **Preview honesto:** al abrir el panel, la burbuja se enciende EN VIVO
   (misma CameraBubble que se quema en el video) y el vúmetro
   (MicLevelMeter: AVCaptureSession propia + AVCaptureAudioDataOutput,
   -50dB→0dB normalizado, ataque rápido/caída suave) confirma que el mic
   escucha. **Invariante:** el meter se detiene SIEMPRE antes de grabar —
   centralizado en `RecordingController.prepareSession()` para que ⌘⇧L y el
   menú clásico también lo cumplan (hallazgo CONFIRMADO del review
   adversarial: 3 de 4 caminos de arranque dejaban el meter vivo peleando el
   mic con SCStream).
3. **Glow sutil:** shadowRadius 24→10, opacity .95→.5, borde 2→1.5. El blur
   viejo desbordaba el glowPad (34px) y se recortaba contra el borde cuadrado
   del panel — eso eran los "contornos cuadrados" que Daniel veía.
4. **cameraEnabled (setting nuevo)** con decode TOLERANTE en AppSettings
   (decodeIfPresent campo por campo): agregar un campo ya no invalida el
   settings.json viejo (antes reseteaba la config en silencio).
5. **Declutter:** hub sin card "Cómo grabar" ni marketing del sidebar;
   Ajustes queda solo audio del sistema + countdown (cámara/mic/modo viven en
   el micropanel; tamaño/glow en la burbuja misma con clic derecho).
6. **Fixes del review adversarial (workflow 17 agentes, 5 confirmados):**
   meter.stop() síncrono (queue.sync — carrera con countdown 0), keepPreview
   solo para arranque de grabación (el engrane/Historial apagan la cámara),
   clamp del panel contra la pantalla DEL ANCLA (no NSScreen.main), botón
   deshabilitado en modo Cámara con cámara OFF (startCamOnly ignoraba el
   toggle).

Gotcha vigente: cada rebuild cambia el cdhash → macOS re-pide el permiso de
PANTALLA una vez (cámara/mic sobreviven por bundle ID + cert estable).

## v1.5 — El pill de Loom: vertical, con hover vivo y stop instantáneo (15 jul)

Daniel, con captura de Loom al lado: "la nuestra se ve bien fea y la de Loom se
ve bien sutil… cuando poso el mouse se amplía y salen botones de reiniciar/
eliminar… la de Loom tiene un hover muy bonito, la nuestra ni siquiera tiene
animación y encima se tarda unos segundos".

1. **Pill VERTICAL** (58×112): cuadro mostaza de stop arriba (protagonista,
   como el rojo de Loom) · timer "2:02" (formato Loom, sin cero a la izquierda)
   · pausa. **Hover → 188px** revelando separador + **reiniciar (↺)** +
   **descartar (🗑)** con fade. Colapsa con 0.3s de gracia (cruzar entre
   botones no lo hace parpadear). Crece HACIA ABAJO: el borde superior queda
   clavado donde Daniel lo arrastró. Sin punto rojo pulsante — Loom no lo
   tiene; la pausa se señala con timer ámbar + icono play.
2. **PillButton**: hover = fondo que aparece + escala 1.09; clic = rebote a
   0.9. Las animaciones son **CABasicAnimation explícitas** a propósito: en
   vistas layer-backed de AppKit las implícitas están apagadas (el layer
   delegate devuelve NSNull), así que `layer.transform = …` saltaría sin
   animar.
3. **Geometría por constantes, no fittingSize**: el stack va pineado ARRIBA y
   el pill CLIPA los extras al colapsar (cero conflictos de constraints, cero
   medición por hover).
4. **STOP INSTANTÁNEO** (el "se tarda unos segundos"): `stopAndWait` cerraba el
   segmento ANTES de esconder la UI y copiar el link — cerrar el MP4 tarda
   ~0.3-1s esperando el didFinish del writer, y ese era TODO el lag. Ahora:
   link al portapapeles + pill fuera → y el cierre ocurre después, sin que
   nadie lo vea. La burbuja está quemada en el video: esconderla ~1s antes solo
   recorta el último instante.
   **Excepción camOnly:** ahí la burbuja ES la fuente (el movieOutput cuelga de
   SU sesión) → stopCamSegment → esperar al delegate (10s) → recién entonces
   apagar la burbuja, o el .mov se trunca.
5. **`stopCapture()` con deadline (10s)**: consecuencia del reorden — un
   stopCapture colgado (tccd atascado) dejaría `state` en .stopping para
   siempre y AHORA sin UI visible que lo delatara ("grabar de nuevo no hace
   nada"). Cazado por el review adversarial.
6. **`--paneltest N`**: modo QA que muestra el pill sin grabar. Existe porque
   el pill lleva `sharingType = .none` y es invisible a cualquier captura —
   sin este modo no hay forma de revisar su diseño con un screenshot. Es el
   ÚNICO modo donde el pill se deja capturable. Hover verificado midiendo el
   frame real: 112 → 188 → 112.

## v1.6 — Comprimir antes de subir (15 jul 2026)

Daniel preguntó "¿hay forma de acelerar la velocidad del procesamiento?". Se
midió antes de tocar nada, y la pregunta apuntaba al lugar equivocado:

| Etapa | Medido (video de 17s del 15 jul) |
|---|---|
| Subida Mac → VPS | **~15 min** |
| Pipeline del VPS entero | **89s** (de los cuales 73 eran cargar el modelo) |

1. **El cuello era la SUBIDA, no el pipeline.** SCRecordingOutput escribe a
   **7 Mbps** (15 MB por 17 segundos = 52 MB por minuto grabado) y su API NO
   expone bitrate: `SCRecordingOutputConfiguration` solo tiene outputURL,
   outputFileType y videoCodecType. El upstream de Daniel se midió en **≤0.33
   Mbps contra Cloudflare** (endpoint neutral, para descartar al VPS) contra
   3.6 Mbps de bajada, por Ethernet. 52 MB/min sobre 0.5 Mbps = ~14 min de
   espera por minuto grabado.
2. **Re-encode por hardware antes de subir** (`Transcoder.swift`): ffmpeg
   `hevc_videotoolbox` deja el archivo **4.5x más chico en 2.6s** (medido sobre
   el video real: 14.5 MB → 3.2 MB, y el frame 200 muestra los menús y la barra
   lateral perfectamente legibles). Corre DESPUÉS de copiar el link y abrir el
   navegador: no se siente, y el video aparece 4-5x antes.
   **Por qué no capturar más chico de origen:** habría que re-arquitecturar a
   SCStream + AVAssetWriter (`AVVideoAverageBitRateKey`) y perder el
   SCRecordingOutput que nos da 0.6-1.6% de CPU. Un re-encode de 2.6s en
   background es infinitamente más barato.
3. **Best-effort y NO destructivo, siempre**: sin ffmpeg / ffmpeg falla /
   rebasa el deadline / el resultado sale más grande o con otra duración ⇒ se
   sube el ORIGINAL. Comprimir jamás puede costar un video. El temporal vive
   FUERA de sessionDir (rsync sube el directorio entero) y el stderr va a un
   ARCHIVO, no a un Pipe (ffmpeg llenaría los 64KB del buffer y se colgaría).
4. **Bitrate escalado por PÍXELES** (hallazgo del review): el ancla de 1200k
   está medida a 1080p, pero la captura no baja de resolución — en Retina/5K
   son 3-6x más píxeles y el texto saldría borroso, justo el caso de uso.
   Se escala manteniendo los bits/píxel verificados: un 3024x1964 sale a 3437k
   solo. La cámara lleva ancla doble (el mundo real es menos compresible que
   una pantalla quieta).
5. **camOnly graba `.mov`, no `.mp4`** (hallazgo del review): filtrar solo
   `.mp4` dejaba el modo cámara entero sin comprimir — y encima ya sin el `-z`
   del rsync, o sea PEOR que v1.5. Se conserva la extensión del original: el
   worker ya globea las dos y así meta.json no se entera.
6. **`-a` en vez de `-az` en rsync**: el payload es HEVC, ya comprimido. gzip
   no gana un byte y quema CPU en los dos lados.
7. **Precarga de Whisper al arrancar el worker**: el modelo tarda **130s en
   frío** y lo pagaba el PRIMER video después de cada restart (se ve en el log
   del 15 jul: 14:19:22 → 14:20:35). Ahora carga en un hilo al arranque, con
   candado (sin él, la precarga y el poller podían cargar DOS modelos en RAM).
8. **`--compresstest <dir>`**: modo QA que corre el compresor sobre una COPIA
   del directorio. Comprimir es lo único del flujo que toca el MP4 en sitio;
   quería probar el camino real (compuertas, replace, temporal) contra videos
   de verdad sin arriesgar una grabación.

## v2.0 — Modo Estudio: escenas + doble salida (22 jul 2026)

Spec: `business-os/.claude/specs/sfcast-modo-estudio-2026-07-22-spec.md` (compilada
con goal-compiler; grafo del sistema adentro). Outcome: estudio de grabación
soberano estilo OBS/Streamlabs con piel Screen Studio, ADITIVO sobre el Loom.

### Stack elegido y por qué

| Capa | Elección | Por qué |
|---|---|---|
| Compositor | **CoreImage → CVPixelBuffer** (pool IOSurface, render loop DispatchSourceTimer @ fps) | GPU sin shaders propios ni deps; 0 drops medidos (242 frames). Metal crudo = más control, mucho más código |
| Frames pantalla | **SCStream + SCStreamOutput** (BGRA) — NUEVO junto al SCRecordingOutput | SCRecordingOutput no expone frames; el preview/programa los necesita. El Loom conserva su ruta barata intacta |
| Raw pantalla | **SCRecordingOutput colgado del MISMO stream del preview** (hot add/remove al grabar) | La captura ya corre; añadir el writer es gratis. Probado: didFinish llega tras removeRecordingOutput |
| Raw cámara | **AVCaptureMovieFileOutput** en sesión PROPIA del Estudio (+ mic input) | Patrón camOnly probado; .mov con voz = estilo Screen Studio |
| Programa | **AVAssetWriter** HEVC (bitrate escalado por píxeles, ~0.12 bits/px/frame) + **2 pistas AAC separadas** (mic / sistema) | Pistas separadas = editables; los players tocan la 1 (mic). Reloj host compartido (SCK y AVCapture timestampean igual) |
| Preview | IOSurface del pixel buffer → `layer.contents` (aspect-fit) | Cero framework extra; 30fps sin sudar |
| UI desktop | **SwiftUI en NSWindow** (NSHostingView), anatomía OBS (Escenas/Fuentes/Preview/Mixer/Salidas), piel oscura + mostaza | SwiftUI ya vive en el repo (micropanel); ventana con `sharingType=.none` (patrón pill) |
| Modelo | scenes.json aparte de settings.json, decode tolerante, rects NORMALIZADOS (0-1) | El layout sobrevive cambios de resolución; presets de fábrica incl. escena "Loom" POR COMPOSICIÓN |
| Programa → VPS | El programa se llama **seg-001.mp4** + meta.json | Compat total: "↑ subir" del Historial y el worker lo tratan como video normal |
| QA | `--studiotest N` + fuente **Patrón de prueba** sintética | E2E (compositor/escenas/switch/writers/manifest) SIN permisos TCC; PNGs del frame de programa como evidencia |

### Descubrimientos técnicos

1. **TCC se atribuye al proceso responsable, no al binario**: el MISMO
   /Applications/SFCast.app corrido desde terminal sale "sin permisos" (la
   terminal es la responsable); lanzado con `open` (launchd) sale con cámara y
   pantalla completas. Por eso --studiotest se corre con `open -W --args`.
2. **`open -W` con la app ya corriendo NO lanza instancia nueva** — activa la
   existente y espera a que ELLA muera (parece cuelgue). Quit primero.
3. **`exit(0)` NO ejecuta `defer`**: el restore de scenes.json del QA tuvo que
   ser explícito antes de cada salida.
4. **AVCaptureSession arranca lento**: camera.mov dura ~2s menos que screen.mp4
   (t0 distinto). Alineación derivable: ambos terminan juntos (endedAt del
   manifest) ⇒ t0_cam = end - duración. Documentado como límite v1.
5. Cross-guards Loom⇄Estudio: los start* del Loom rebotan si el Estudio GRABA;
   prepareSession cierra el Estudio en preview (misma regla que el micropanel).
   Abrir el Estudio esconde micropanel y burbuja (el vúmetro pelea el mic — v1.4).

### Límites conocidos (v2.0, honestos)

- Transform con sliders, no drag-on-canvas (el preview no es interactivo aún).
- Fuentes: display principal completo (sin picker de ventana/región en Estudio),
  UNA cámara. Audio global, no por escena. Sin transiciones en el switch.
- El push al VPS de una sesión de Estudio sube la carpeta ENTERA (raws incluidos).
- Grabación de Estudio no sobrevive reinicio de la app (igual que la pausa Loom).

## v2.1 — Canvas interactivo + Ajustes (22 jul 2026, feedback de Daniel)

1. **Preview interactivo estilo OBS**: clic selecciona (el de más arriba en la
   pila), drag mueve, 8 handles (esquinas + bordes) redimensionan — mapeo
   aspect-fit view↔canvas normalizado; overlay CAShapeLayer mostaza SOLO en la
   ventana (sharingType=.none ⇒ jamás en la grabación). Transform en vivo sin
   golpear disco; persiste al soltar. Los sliders del inspector MURIERON.
2. **Fuentes angosto** (210px) + fit/burbuja compactos bajo la lista.
3. **Escenas con drag & drop** (List + .onMove).
4. **Ajustes 80/20 de GRABACIÓN** (gear, no streaming): FPS 24/30/60, canvas
   (nativo/1080p/1440p), calidad del programa (bits/px/frame 0.16/0.12/0.08),
   cámara y mic (MISMOS AppSettings del Loom — una sola config), audio sistema,
   carpeta de salida. "Aplicar" reinicia el motor.
5. **"La escena Loom no funciona" = pantalla sin permiso post-rebuild.** Cura:
   `retryScreenIfNeeded()` cada ~3s engancha el tap cuando el permiso llega
   (sin reabrir), y el chip "Pantalla: dar permiso" es clicable (prompt + pane).

## v2.2 — Pulido del Estudio (22 jul 2026, ronda 2 de feedback)

1. **Doble-clic en titlebar = zoom**: `.fullSizeContentView` extendía el
   contenido bajo el titlebar y se comía el doble-clic. Fuera del styleMask.
2. **Overlay de selección morado, SOLO contorno**: el CAShapeLayer único
   rellenaba el rect completo de mostaza (bug). Ahora 2 capas: borde stroke
   morado #8C27F1 sin fill + handles rellenos.
3. **Simetría Streamlabs**: las 4 columnas del strip inferior a maxWidth
   .infinity (ancho igual, cero huecos).
4. **Drag & drop de escenas REAL**: List.onMove no funciona en macOS con
   controles dentro de la fila → onDrag/onDrop manual con DropDelegate
   (reorden vivo en dropEntered, persist en performDrop). Tap selecciona.
5. **Botón "Modo Loom"** fijo en el panel Escenas: cierra el Estudio y abre el
   micropanel clásico (pedido de Daniel: la escena compuesta no sustituye al
   flujo Loom real — se salta a él).

## v2.3 — Estruendo de audio + pulido final (22 jul 2026, ronda 3)

1. **El "estruendo" al inicio de las grabaciones (raíz encontrada):** el
   MovieFileOutput de cámara se AÑADÍA a la AVCaptureSession corriendo justo al
   dar Grabar → reconfiguración del grafo de CoreAudio → pop de ~0.5s GRABADO.
   Fix: el output vive en la sesión desde el arranque del motor (antes de
   startRunning); Grabar solo llama startRecording (cero reconfiguración).
   Refuerzo en el programa: warmup de 150ms — el writer recortaba audio a mitad
   de buffer en el startSession y también tronaba.
2. **Vúmetro con ataque/caída** (attack instantáneo, decay 0.80 por tick a
   15Hz): el valor crudo brincaba feo.
3. **Self-view "Burbuja" ELIMINADO** (el Loom vive aparte con su burbuja real).
4. **Escenas: clic derecho** → Renombrar / Duplicar (⌘D) / Eliminar; ⌘D global.
5. **Visibilidad en capturas configurable** (Ajustes → Ventana): default
   invisible estilo OBS (sharingType=.none); toggle ON = ventana normal
   (.readOnly), aplica al instante. Era la "app que no sale en mis screenshots".

## v2.4 — Los tres bugs del 25 jul: mixer, peso y congelada

Daniel intentó grabar en serio con el Modo Estudio (en paralelo con
OBS/Streamlabs, para comparar) y salió con tres cosas rotas. Las tres estaban
relacionadas por una misma causa de fondo: **la app no medía nada de lo que
hacía**, así que ninguna se notaba hasta que el daño estaba hecho.

Evidencia madre (log de esa mañana), sesión `tr4oulursct6`, 09:29:36 → 10:20:02:

```
09:29:36  Estudio: grabando tr4oulursct6 → [screen.mp4, camera.mov, seg-001.mp4]
10:12:22  ERROR: camOnly segmento: Disk Full          ← 43 min después
10:20:02  Estudio: programa cerró — 90438 frames, 0 drops, mic=282593 sys=0
                                                       ↑ CERO audio de sistema
                                                         en 50 minutos
```

`sys=0` es la huella del stream muerto: el tap de audio de ScreenCaptureKit late
mientras el stream vive. La sesión anterior (misma app, 6 min antes) traía
`sys=11196`. O sea: el SCStream murió al arrancar esa grabación y **se grabaron
50 minutos del mismo frame**, sin una sola línea de log.

### 1. El mixer marcaba una LÍNEA FIJA — no era el micrófono

Síntoma: la barra del micrófono clavada, pasara lo que pasara.

Camino hasta la raíz (cada paso descartó una hipótesis):

| Medición | Resultado | Qué descartó |
|---|---|---|
| `ffmpeg -f avfoundation -i :1` sobre el mismo Shure | −76.5 dB | El micro NO está caliente |
| La pista de mic del `seg-001.mp4` grabado | −60.6 dB | Lo que se GRABA está bien |
| `AudioMath.rms` sobre esos mismos buffers | −7.8 dBFS, constante | **El lector es el que miente** |
| Volcado en hexadecimal de los bytes | `fff90fca fffa07f7 …` | No son float32 (leído así ⇒ NaN) |
| ASBD real | `int24 flags=0x14` | 24 bits **alineados alto en 4 bytes** |

**Raíz:** el lector daba por hecho `Int16`. El Shure MV7+ entrega int24 en
contenedor de 32 bits, así que el código partía cada muestra en dos int16 falsos
y medía la ESTRUCTURA DE LOS BYTES, no el sonido. Esa estructura es casi
constante ⇒ una línea inmóvil. Y como el `else` era "todo lo que no es float es
int16", nadie lo iba a notar leyendo el código.

**Fix:** `forEachSample` deduce el ancho del contenedor **midiéndolo**
(`bytes / (frames · canales)`), no de `mBitsPerChannel`, y honra
`kAudioFormatFlagIsAlignedHigh`, big-endian, int8/16/24/32 y float32/64.
Además el RMS se calcula quitando la media (un offset DC no se oye pero clava la
barra) y `AudioLevelBox` CADUCA: sin buffer fresco en 350 ms el nivel es 0 —
antes, si la fuente moría, el último valor se quedaba pegado pareciendo señal.

⚠️ **El formato CAMBIA entre arranques.** Medido el mismo día: unas veces
`float32 flags=0x29`, otras `int24 flags=0x14` sobre el MISMO micro. Por eso hay
que leer el formato de CADA buffer y jamás cachearlo ni asumirlo.

Verificación: 0.87 clavado (rango 0.02 en 20 s) → **0.0000 en silencio y
subiendo con sonido real** (rango 0.05 con pings a través de las bocinas).

### 2. Pesaba 15x lo que OBS — bitrate promedio en vez de calidad constante

Comparación directa, mismo contenido, ambas apps grabando a la vez esa mañana:

| | Duración | Peso | Bitrate |
|---|---|---|---|
| OBS/Streamlabs | 41.7 min | 334 MB | 0.93 Mbps |
| SFCast Estudio | 50 min | ~6 GB | ~16 Mbps |

**Raíz (tres sumandos):**

1. `ProgramSink` fijaba `AVVideoAverageBitRateKey = w·h·fps·0.12` = **7.5 Mbps**
   a 1080p30. OBS no usa bitrate promedio: usa CQP/CRF. En captura de pantalla
   el bitrate promedio es el peor modo posible — paga lo mismo por una pantalla
   quieta que por una llena de movimiento.
2. `camera.mov` salía por `AVCaptureMovieFileOutput` con preset `.high` y **sin
   bitrate fijado**: escribía a lo que se le antojaba (medido: 8.3 Mbps, y con
   cámara buena sube).
3. Se escribían **tres archivos a la vez** y **nada consumía dos de ellos**: el
   worker del VPS solo glob-ea `seg-*.mp4`; SFStudio y la skill de edición no
   tocan los raws.

**Fix:** calidad constante (`AVVideoQualityKey`) + GOP largo (5 s) en el
programa; bitrate explícito en el raw de cámara; y los RAW **apagados por
default** (migración única, avisada en la UI, reversible con un clic en
Salidas). Además el panel de Salidas ahora muestra el peso proyectado en GB/hora
y el log imprime MB y Mbps por archivo al cerrar — el costo dejó de ser
invisible. El `Transcoder` gana una compuerta previa: si el archivo ya está por
debajo del objetivo, no lo re-encodea (sería quemar tiempo y degradar imagen
para no ahorrar un byte).

Verificación: **0.82 Mbps** (contra 0.93 de OBS) con texto haciendo scroll en
pantalla. 50 minutos pasan de ~6 GB a ~310 MB.

### 3. La pantalla se congelaba a mitad — y nadie se enteraba

**Raíz:** `SCStream(filter:configuration:delegate: nil)`. Sin delegate,
`didStopWithError` nunca llega. Y como el compositor pinta SIEMPRE el último
frame guardado, un stream muerto se ve **idéntico** a uno vivo. El "comparador"
que existía solo detectaba la fuente que jamás entregó un frame, nunca la que
dejó de entregarlos. Agravante: el disco lleno mata los writers a mitad y
tampoco había guardia.

**El sensor correcto — y el falso positivo que hubo que corregir.** El primer
intento midió la edad del último frame: 10 reenganches en 45 s con la Mac en
reposo. Obvio en retrospectiva: **SCK no manda frames nuevos si la pantalla no
cambia**, y una pantalla quieta está perfectamente sana. La pregunta correcta no
es "¿la imagen cambió?" sino **"¿el stream sigue hablando?"**, y se responde con
dos canales independientes: el callback de video (llega también con frames
`.idle`) y el tap de audio del mismo stream (late aunque la pantalla no cambie —
fue justo el delator del incidente real). Silencio en AMBOS más de 5 s = muerto.

**Fix:** `SCStreamDelegate` conectado + `StreamHealth` (latido de los dos
canales) + watchdog a 1 Hz que reengancha solo; si estaba grabando el raw de
pantalla, continúa en `screen-002.mp4` y el corte queda en el manifest.
`queueDepth` 5 → 8 (guardamos un frame fuera del callback: con 5 el pool de SCK
se queda sin sitio bajo carga y deja de entregar en silencio). Guardias de
disco: 5 GB para arrancar, aviso a 3 GB, y **auto-stop a 1.2 GB** — mejor una
grabación buena de 40 min que una corrupta de 50. Latido cada 15 s en el log con
estado de stream, audio, frames, drops y disco. Y alarma VISIBLE en la ventana.

Verificación (`--studiobench N --killstream`, que mata el stream a propósito):

```
16:47:11  QA: matando el stream de pantalla a propósito
16:47:15  ❤︎ 15s — stream:4.4s-mudo … sys:mudo
16:47:16  PANTALLA CONGELADA — 5.6s mudo. Reenganchando…
16:47:16  captura de pantalla reenganchada
16:47:30  ❤︎ 30s — stream:0.0s-mudo … sys:ok   (frames 451→902, 0 drops)
```

Detección en 5.6 s, recuperación en menos de 1 s, y el programa siguió grabando.

### Lo que hay que quedarse de esto

**Un órgano sin sensor se ve igual de sano que uno vivo.** Los tres bugs
sobrevivieron por lo mismo: la app no medía su propia salida. No decía cuánto
pesaba, no decía si el stream respiraba, y el vúmetro "medía" sin que nadie
comparara nunca su lectura contra una segunda fuente. Por eso los fixes no son
solo el parche: son los tres sensores (peso por archivo, latido del stream,
nivel con caducidad) más los modos de QA que los ejercen.

### QA nuevo

```bash
open -W /Applications/SFCast.app --args --studiobench 45              # peso + mic + salud
open -W /Applications/SFCast.app --args --studiobench 30 --killstream # prueba la recuperación
```

## v2.5 — El aro neón del Loom, ahora por fuente de escena (25 jul 2026)

Pedido de Daniel: "la burbuja del Loom tiene un aro morado neón y puedo cambiarlo
a ámbar; quiero eso mismo para la cámara en las escenas, con clic derecho en la
fuente".

**No es una feature nueva, es la MISMA receta portada.** El aro de la burbuja
(`CameraBubble.Glow`) es: anillo de **1.5pt al 90% de alpha** + halo de
**radio 10 al 50%**, en `#8C27F1` morado o `#ff9101` ámbar. Se copiaron los dos
colores y las dos proporciones tal cual a `SceneGlow`, expresadas como fracción
del lado menor del item (`ringFraction 0.007`, `haloFraction 0.045`) para que se
vea igual a cualquier tamaño de cámara o de canvas. Si el aro del Loom cambia
algún día, esto cambia con él — es el mismo lenguaje visual, no una paleta nueva.

Única diferencia deliberada: el halo va un pelo más ancho. En el Loom tenía que
morir dentro del `glowPad` de 34px del NSPanel o se veía el corte cuadrado
(feedback de Daniel del 15 jul); aquí el compositor no recorta y no hace falta
apretarlo.

**Cómo se pinta.** El halo va DEBAJO del video y el anillo ENCIMA — igual que en
la burbuja, donde el shadow vive en `glowView` y el borde en `innerView` (que
dibuja sobre su contenido). Ambas capas se generan con CoreGraphics (trazo para
el anillo, relleno + `CIGaussianBlur` para el halo) y se **cachean** por
(rect, color, recorte, opacidad): dibujarlas en cada frame costaría 30 veces por
segundo lo mismo que cuesta una vez.

⚠️ **Con `circleMask` el aro es el círculo INSCRITO, no un óvalo del rect.** El
recorte de `place` usa el lado menor centrado; si el aro usara el rect completo
quedaría despegado del video en cuanto el item no fuera cuadrado.

**Dónde se prende:** clic derecho en la fuente (lo pedido) **y** un selector
`Aro: — / Morado / Ámbar` en el inspector, porque un menú contextual es invisible
hasta que alguien lo descubre. Un punto del color en la fila de Fuentes indica
cuáles lo traen puesto. El clic derecho actúa **por id**, no sobre la selección:
clic derecho no selecciona, y editar "lo seleccionado" tocaría el item
equivocado.

**Costo medido** (`--glowtest`, presupuesto de 33.3 ms a 30fps):

| | ms/frame |
|---|---|
| Sin aro | 1.47 |
| Con aro, cacheado | 3.28 |
| Con aro, arrastrándolo (cache miss cada frame) | 4.27 |

Peor caso = 13% del presupuesto. Y como el aro se compone en el MISMO
`CVPixelBuffer` que alimenta preview y `ProgramSink`, lo que se ve es
exactamente lo que se graba.

QA visual (un aro no se valida leyendo código, se valida mirándolo):

```bash
open -W /Applications/SFCast.app --args --glowtest   # PNGs + perf + foto de la ventana
```

## v2.6 — El Estudio es la cara de la app + ajustes EN CALIENTE (6 ago 2026)

**El default de arranque ahora es el Estudio, no el micropanel Loom.** Daniel
graba de verdad en el Estudio; el Loom sigue a un clic ("Modo Loom" dentro del
Estudio, o el menú de la barra). Reabrir desde el Dock también va al Estudio —
salvo con el Loom GRABANDO (abrir el Estudio escondería la burbuja quemada y
pelearía la cámara; ahí se muestra el hub).

**Murió "Aplicar (reinicia el motor)" — y con él la bolita de arcoíris.** El
botón tiraba el motor entero (`engine.stop()` + `engine.start()`), y la
reconfiguración del `AVCaptureSession` corría en MAIN: `commitConfiguration`
se quedaba esperando el lock interno de la sesión mientras `stopRunning` lo
tenía en otro hilo → main bloqueado varios segundos = beachball. Peor: el
reinicio ni siquiera aplicaba el cambio de cámara, porque `startCameraTap`
solo AGREGABA inputs si faltaban — el input viejo se quedaba y la cámara nueva
jamás entraba (solo un relanzamiento completo la aplicaba).

La cura es estilo OBS — **nada se reinicia; cada cambio viaja por su canal
barato** (`StudioEngine.applyLive`):

- **fps / canvas** → re-crear el render timer (captura fps y canvas al nacer;
  instantáneo) + `updateConfiguration` del SCStream (async, sin tirar captura).
- **audio del sistema** → `capturesAudio` vía `updateConfiguration`. Para que
  el toggle funcione en AMBOS sentidos, el stream output de audio se engancha
  SIEMPRE al arrancar (a un stream corriendo no se le añaden outputs);
  `capturesAudio` decide si fluye.
- **cámara / mic** → `reconcileInputs`: deja EXACTAMENTE la cámara y el mic
  elegidos (quita el viejo, pone el nuevo), en `sessionQueue` — una cola serial
  dedicada donde ahora vive TODA la cirugía del AVCaptureSession
  (begin/commitConfiguration, start/stopRunning). En main, jamás.
- **calidad del programa** → se lee al armar la grabación; no toca nada vivo.

**Doble clic = cambiar dispositivo, sin abrir Ajustes.** Sobre la fuente
"Cámara" del panel Fuentes (también "Cambiar cámara…" en el clic derecho) y
sobre el mixer del micrófono: popover con la lista de dispositivos, el actual
marcado, cambio en caliente. Los toggles del Mixer también aplican al instante
(antes decían "aplican al abrir el Estudio de nuevo"); mientras GRABAS quedan
deshabilitados — quitar/poner un input a mitad de grabación reconfigura el
grafo de audio y el pop quedaría grabado (el "estruendo" de v2.3).

## v2.7 — El preview a "1 fps" del minuto 15 (6 ago 2026)

**Síntoma (Daniel, grabación real de ~20 min):** al minuto ~15 el preview de la
cámara en el Estudio se veía a tirones, casi congelado. El archivo final salió
perfecto. Le dio miedo — creyó que la grabación iba a salir así.

**Raíz: el preview encolaba, la grabación drena.** El render loop mandaba CADA
frame a main con `DispatchQueue.main.async` bajo un comentario que decía
"coalescing natural del runloop" — **falso**: GCD no coalesce nada. Son 30
bloques/s a la cola de main; si main va apenas atrás (vúmetros a 15Hz +
`elapsed` publicado a 15Hz + SwiftUI mientras grabas), los bloques se APILAN.
Y cada bloque retiene su IOSurface: a canvas 5K nativo son ~59 MB por frame —
20 frames de backlog = 1.2 GB de surfaces vivos → presión de memoria → main
más lento → más backlog. Bola de nieve que tarda minutos en hacerse visible:
por eso apareció al minuto 15 y jamás en un QA de 8 segundos. El archivo no
pasa por ahí: `ProgramSink.appendVideo` corre en renderQueue directo al
encoder (y si el encoder se atrasa TIRA el frame y lo cuenta — jamás encola).

**La cura: `PreviewGate` — coalescing de verdad.** Una caja con el ÚLTIMO
IOSurface y un flag de hop-en-vuelo: el render loop deposita el frame (el
anterior no consumido se libera ahí mismo) y solo agenda el hop a main si no
hay otro pendiente. Bajo presión el preview tira frames viejos gratis en vez
de acumularlos; en reposo se comporta idéntico a antes. Máximo 2 surfaces
vivos (el del layer + el de la caja), backlog imposible por construcción.

**De pilón:** `elapsed` ya solo se publica cuando cambia el SEGUNDO mostrado
(era a 15Hz: 15 re-renders SwiftUI/s de carga gratuita en main, justo mientras
se graba — exactamente cuando el preview necesita a main libre).

**Regla que deja:** un productor de UI a frecuencia fija JAMÁS hace
`main.async` por evento — siempre pasa por una compuerta de "último gana".
La cola de main no es un buffer de video.

## v2.8 — El preview a 3 fps con la cámara sana: el vúmetro re-layouteaba la ventana entera (7 ago 2026)

**Síntoma (Daniel, con la escena "Mi cámara solo" abierta):** el movimiento de
la cámara en el preview se veía "como con muy pocos frames por segundo", desde
el arranque, sin grabar siquiera. Sospecha natural: la cámara.

**El diagnóstico se MIDIÓ, no se supuso (y las dos primeras hipótesis
murieron):**
- La ZV-E10 por USB entrega **29.84 fps reales** (probe firmado con la misma
  config del Estudio: preset `.high`, conversión BGRA, discard de tardíos —
  gap p50 33 ms, p95 41 ms, 0 drops). La hipótesis "USB 2.0 no da para 720p
  NV12" quedó refutada por la medición.
- El compositor compone a 30 fps con ~5 ms/frame a canvas 5K (`sample` de la
  cola `studio.render`: 15% de un core) y el heartbeat lo confirma
  (`frames:452` en 15 s, `drops:0`). La grabación siempre estuvo bien.
- El main thread estaba al **99.7% en layout de SwiftUI** (2677 de 2685
  muestras en `NSHostingView.beginTransaction → StackLayout.sizeThatFits`,
  recursión de ~50 niveles). SFCast quemaba 105% de CPU con la ventana
  abierta, sin grabar.

**Raíz: los niveles del vúmetro eran `@Published` en el `StudioController`, a
15 Hz.** Todos los paneles observan ese MISMO objeto vía `@EnvironmentObject`:
cada asignación invalida la jerarquía completa, y un pase de layout de esta
ventana cuesta ~60-70 ms (stacks anidados profundos). 15 Hz × 2 propiedades ×
70 ms = main saturado permanente. Con la caída suave (`max(nivel, nivel·0.8)`)
el valor cambiaba en CADA tick aunque hubiera silencio — y `@Published`
dispara `objectWillChange` en cada asignación, cambie o no el valor. El
`PreviewGate` (v2.7) hizo su trabajo exacto: tiró los frames que main no
consumía. Por eso el preview iba a ~3 fps con TODO lo demás sano — v2.7 curó
la bola de nieve de memoria, pero dejó la degradación **muda**. La ironía: el
comentario de `startMeters` ya lo sabía ("a 15Hz cada asignación de @Published
re-renderiza la jerarquía SwiftUI entera") — protegió `elapsed` y dejó el
vúmetro publicando.

**La cura, en dos frentes:**
1. **El vúmetro salió de SwiftUI.** `MeterBarNSView`: la barra es un
   `CAGradientLayer` que recibe el nivel DIRECTO desde el `meterTimer`, mismo
   patrón que el preview (`registerMeter`, gemelo de `registerPreview`). Un
   CALayer se actualiza en microsegundos; la jerarquía SwiftUI ya no se entera
   de que existe audio. `freeDiskNote` también se gateó (asignaba nil→nil cada
   10 s).
2. **El SENSOR que faltaba (invariante 5b): fps medidos, a la vista.**
   `PreviewGate` ahora cuenta entregados y tirados; `LatestFrameStore` ya
   contaba frames por fuente. `engine.flowCounts()` expone los acumulados y
   tres consumidores miden por delta: el **chip "cámara N · preview N fps"**
   en la barra del Estudio (publica a ~1 Hz y SOLO si el número cambió; se
   pone naranja si el preview va >5 fps detrás de la cámara, con help que
   aclara que la grabación no se afecta), el **❤︎ del heartbeat**
   (`cam:30fps prev:30fps(-0)`) y **STUDIOTEST_FLOW / BENCH_FLOW** en QA.

**Reglas que deja:**
- Nada que ocurra más de ~1 vez por segundo pasa por `@Published` de un
  objeto que observe la ventana entera. Alta frecuencia = CALayer directo
  (preview, vúmetro) o un publisher gateado por cambio de valor mostrado.
- Toda compuerta que TIRA trabajo para degradar con gracia lleva contador, y
  el contador se muestra. Degradar en silencio es cómo el 25 jul grabó 50 min
  congelado y cómo este preview murió de hambre sin decirlo.

---

## v2.9 — El ESPEJO: la burbuja del programa, sobre la pantalla que grabas (9 ago 2026)

**El problema, en las palabras de Daniel:** dos monitores, a punto de grabar un
video de YouTube, escenas "Burbuja derecha" / "Burbuja izquierda". *"En ocasiones
mi texto queda por detrás de mi cámara y quiero ser consciente cuando eso pase."*

**Por qué pasaba.** En Modo Estudio la cámara **nunca toca la pantalla física**:
la pega el compositor sobre el canvas (`Compositor.place`). El modo Loom sí la
enseña, pero porque allá la burbuja **es** un `NSPanel` real que se quema en el
video. En el Estudio la pantalla no sabe que la burbuja existe, y con la ventana
del Estudio en el otro monitor no hay nada que mirar mientras trabajas. Números
de su setup: burbuja de **412 pt de diámetro** (28.6% del alto) en la esquina
inferior de un BenQ de 2560×1440 — un cuadrado de ~415 pt comiéndose el texto.

**Lo que se construyó.** Un panel flotante sobre la pantalla capturada, en la
posición, el tamaño, la forma y el aro EXACTOS de la burbuja del programa. Se
arrastra con el mouse y el programa la sigue en el mismo frame.

### Las tres decisiones que lo sostienen

1. **`sharingType = .none`, y probado, no supuesto.** Si el panel se colara a la
   captura saldría la cara **duplicada** (el panel real + la burbuja compuesta
   encima) — la clase de bug que se descubre viendo la grabación al día
   siguiente. `--mirrortest` mide el frame de pantalla real con el espejo
   apagado y prendido. Medido: **fuga neta 0.0007** sobre 1.0.
   - Con una salvedad que costó una corrida: comparar apagado vs prendido a
     secas NO sirve, porque el escritorio de abajo está VIVO. En una corrida el
     movimiento de un chat levantó el promedio 0.051 y el test gritó FUGA sin
     que nada se hubiera colado. La cura es una **región de control** del mismo
     tamaño donde el espejo jamás cae: se mide la diferencia de diferencias.
2. **La geometría es la INVERSA de la colocación de la fuente Pantalla**
   (`MirrorGeometry`), no una fórmula paralela. De ahí salen gratis los casos
   raros: en "Lado a lado" la cámara cae FUERA del recuadro de la pantalla y el
   espejo se apaga solo diciendo *"aquí la cámara no tapa la pantalla"*; en "Mi
   cámara solo" no hay fuente de pantalla que invertir. Medido: **0.00 px** de
   error contra la posición del programa, y los tamaños del Loom vuelven
   exactos (s=180.0/180, m=280.0/280, l=420.0/420, completo=1843.2/1843).
3. **El video sale de la sesión de cámara que YA tiene el Estudio**
   (`AVCaptureVideoPreviewLayer` colgado de ella). Ni una sesión nueva
   (invariante: una sola dueña de cámara/mic), ni un frame extra a main.

### El bug que el QA encontró y que nadie habría visto

Ocultar el espejo con `orderOut` **estrangulaba la sesión de cámara entera**: la
cámara pasaba de **60 fps a 0** al apagar el espejo, y ese cero se lo come el
PROGRAMA — cara congelada mientras grabas. Es el patrón del 25 jul otra vez,
ahora por el lado de la cámara. Un `AVCaptureVideoPreviewLayer` colgado de la
sesión con su ventana fuera de pantalla no basta con esconderlo: hay que
**soltar la sesión** (`layer.session = nil`) y desmontar el panel.

**Y la regla que deja:** *el tramo DESPUÉS es tan importante como el durante.*
El QA medía "antes" y "con espejo", los dos perfectos, y el bug vivía en el
tercer tramo que no existía. Ahora `MIRRORTEST_FLUJO` mide **antes / con espejo
/ después** y falla con `LA-CAMARA-NO-VOLVIO` si la cámara no vuelve a su línea
base. Medido tras el arreglo: 60.0 → 54.6 → 60.0 fps, veredicto `SIN-SECUELAS`.

### El sensor de oclusión (la pregunta original, hecha número)

El espejo hace la oclusión **visible**; el sensor la hace **avisada**. Recorta
del frame de pantalla el pedazo exacto que la burbuja tapa, lo baja a 360 px,
mide energía de bordes y prende un **aro punteado ámbar por fuera** del aro real
(el aro del programa NO se repinta: el espejo tiene que seguir enseñando cómo se
ve el video, y la alarma debe leerse como UI).

Dos errores de bulto en el primer intento, los dos del mismo tipo — **fabricar
la señal que se quería medir**:
- Reducir 825→360 px con una escala afín pelona INVENTA bordes por aliasing.
- `CIEdges` con `inputIntensity: 4.0` satura y todo lee "lleno de detalle".

Síntoma: tres sitios distintos de la pantalla midiendo 0.2784, 0.2797 y 0.2797
— un sensor que no distingue nada. Con Lanczos e intensidad 1.0, la rejilla 3×3
sobre su pantalla real da **0.0000 (escritorio vacío) → 0.3908 (texto denso)**.
El umbral (**0.100**) se fijó de ese rango, y `--mirrortest` reimprime la
rejilla en cada corrida para re-calibrarlo con evidencia.

### El arrastre no pasa por `@Published` (v2.8 aplicada, no repetida)

El mouse manda 60-120 eventos por segundo y cada asignación a `config` invalida
la jerarquía SwiftUI entera. `setItemRectLive` escribe una copia detachada al
`sceneBox` del compositor y al espejo; `config` se toca UNA vez al soltar. **El
arrastre del preview del Estudio se migró al mismo camino**: dos arrastres con
dos verdades habrían sido el siguiente bug.

### Dónde vive cada control (feedback de Daniel a mitad de la construcción)

- **Botón "Espejo"** en la barra del Estudio, junto a los sensores. Clic =
  prender/apagar; el chevron abre rayos X, fijar/soltar, los cuatro tamaños y la
  lectura cruda del sensor. Está ahí y no en Fuentes porque no es propiedad de
  la fuente (eso es el rect, que ya está en Fuentes): es un modo de trabajo.
- **Rayos X y fijar → en el Estudio**, no en la burbuja: *"el ojo pensaba verlo
  en el studio, no en el círculo"*. Son decisiones de sesión, se toman una vez.
- **Sobre la burbuja, solo lo que se hace mirándola: el tamaño.** Y en el idioma
  que ya existe — se reusa `CameraBubble.Size` del Loom (S 180 · M 280 · L 420 ·
  completo), no una escala nueva que se despegaría con el tiempo.
- **Iconos de línea (SF Symbols), cero emojis**: un emoji se pinta con la fuente
  de color del sistema, no hereda el tint y no pesa igual en cada Mac.
- **Fijar** existe porque un círculo de ~400 pt comiéndose los clics de una
  esquina en plena toma sería peor que el bug que vinimos a arreglar.

### QA nuevo

```bash
open -W /Applications/SFCast.app --args --mirrortest 6   # invisibilidad, alineación, arrastre, tamaños, sensor, costo
open /Applications/SFCast.app --args --mirrorlook 16     # lo deja CAPTURABLE para revisar el diseño con un screenshot
```

`--mirrorlook` existe por el mismo motivo que `--paneltest` para el pill: lo que
es invisible a la captura por diseño también es invisible para quien quiere
mirarlo, y el auto-retrato por `cacheDisplay` no sabe pintar ni la capa de video
ni la sombra del halo.

### Hallazgo colateral (no es del espejo, pero muerde)

- **El Estudio solo captura `CGMainDisplayID()`.** No hay selector de display.
  Con dos monitores, todo lo que Daniel ponga en el segundo **no se graba**. El
  espejo lo delata de rebote: solo aparece en la pantalla que sí se está
  grabando.
- **`Devices.camera(id:)` cae a otra cámara en silencio** si la elegida no está
  conectada. En el QA la ZV-E10 estaba apagada y el Estudio grabó de "OBS
  Virtual Camera" (con OBS cerrado: un cuadro fijo). Ahora
  `engine.cameraDeviceName` expone el dispositivo RESUELTO y el QA lo imprime.

---

## v3.0 — La grabación de 45 minutos que se rompió en los últimos 6 (9 ago 2026)

**Síntoma (Daniel, video real de 45.7 min):** *"el video se empezó a trabar a la
mitad... desde el minuto uno, cuando hago full en la cámara, mi voz está
desincronizada"*. Y la pregunta de fondo: *"¿por qué OBS siendo de código abierto
luce bien y lo nuestro se laguea?"*.

### Lo que el archivo dijo (medir primero, opinar después)

El perfil frame a frame del `seg-001.mp4` no se parece a "se trabó a la mitad":

```
min  0 → 37     30.0 fps clavados, peor congelamiento 82 ms   ← 82% del material, intacto
min 38 → 39     17.8 y 10.2 fps                               ← primer bache
min 40 → 41     30.0 fps                                       ← se recupera solo
min 42 → 45.7   12.7 / 10.6 / 11.9 / 8.4 fps, saltos de 750 ms ← colapso final
```

`drops: 0` en todo momento. **El encoder nunca tiró un frame**: los frames NO SE
COMPUSIERON. Y ahí estaba el agujero: `Compositor.compose` hacía
`guard let pb = makeBuffer(canvas) else { return nil }` y el render loop hacía
`return` sin contar nada. **Un frame que no llega a existir no aparecía en ningún
contador** — por eso el log decía `drops:0` mientras el archivo se caía a 8 fps.
Cuarta repetición del patrón órgano-sin-sensor, ahora en el único sitio del
pipeline donde nadie miraba.

### El desfase de audio eran TRES capas, no una

Y solo una era la que todos habrían buscado:

1. **El timestamp se tomaba DESPUÉS de componer.** `appendVideo(pb, hostTime:
   CMClockGetTime(hostClock))` al final del handler ⇒ el tiempo de composición se
   sumaba al desfase. El error crecía *justo cuando la Mac ya iba mal*.
2. **La latencia de captura se ignoraba.** El audio se escribe con su PTS real; el
   video, con "ahora". Medido con `--synctest`: **ZV-E10 por UVC = 52 ms**, Shure
   MV7+ = 12.7 ms ⇒ **40 ms netos** de labios detrás de la voz. Sub-umbral solo, pero
   suma.
3. **El hueco de arranque de 152 ms** — el que de verdad se veía. El warmup de audio
   se medía contra el primer frame de VIDEO, así que el track de audio empezaba en
   `0.152` con el de video en `0.000`. Verificado en **todas** las grabaciones del
   historial. Un reproductor que respeta `start_time` lo compensa; medio mundo (y
   varios editores) pega ambas pistas en cero ⇒ **voz 152 ms adelantada**.

**Nota honesta de método:** el desfase se intentó medir desde el archivo por
correlación audio↔movimiento de boca en 14 ventanas. Dio r≈0.02-0.16 con lags
contradictorios (+567 y −567 ms): **no daba para afirmar nada**, y no se afirmó. El
número salió de instrumentar el mecanismo (`--synctest`), no de la estadística.

### El benchmark que refutó la hipótesis obvia

La sospecha inicial era el lienzo 4096×2304. `--compbench` (headless, sin TCC) la
tumbó: componer a 4K cuesta **3.4 ms** de un presupuesto de 33.3, y el pipeline
completo —timer + compose + writer HEVC real + buffers retenidos— **sostiene 29.9
fps a 4K en una máquina limpia**. El diseño aguanta.

Lo que 4K sí cuesta es **memoria**: 244 MB de huella contra 120 MB (1440p) y 85 MB
(1080p), más el pool de captura (queueDepth 8 × 37.7 MB = 302 MB a 4K contra 66 MB
a 1080p). **Casi medio giga de diferencia** en un Mac mini M4 de 16 GB con dos
monitores 4K — que el 9 ago estaba con 15 GB ocupados, 675 MB de swap y 74 MB
libres. No fue el cómputo: fue el margen.

### Los cinco cambios

1. **`ProgramClock`** — el instante se toma ANTES de componer y se le resta la
   latencia MEDIDA de la fuente crítica (cámara si hay, si no pantalla), con
   `maxSlew` de 2 ms/frame (un salto sería un tirón audible) y monotonicidad
   estricta (`AVAssetWriter` descarta en silencio un PTS que no avanza).
   `LatestFrameStore` ahora guarda el PTS de cada frame y su latencia mediana.
2. **Pistas alineadas** — la sesión del writer no arranca hasta poder arrancar
   **las dos** en el mismo instante (`max(primerVideo, primerAudioTrasWarmup)`),
   con deadline de 0.6 s para no bloquear jamás una grabación sin mic. Verificado:
   `video start=0.000 · audio start=0.000`.
3. **`RenderGovernor`** — pedir 30 cuando la Mac da 10 no consigue 30: consigue 10
   feos. Baja la cadencia por escalones (30→24→19→15) de forma **regular**, con
   backoff exponencial en las subidas. Sin el backoff oscilaba: medido con
   `--chokems 60`, bajaba a 15, subía a 19 a los 10 s, no alcanzaba y volvía —
   cadencia yo-yo, peor que quedarse abajo.
4. **Menos trabajo** — lienzo por default a **2560×1440** (migración única avisada,
   reversible en Ajustes → Video) y **captura escalada**: si el lienzo es menor que
   el display, se le pide a SCK la captura ya reducida y el downscale lo hace el
   compositor de ventanas, gratis. El lienzo nativo no compraba nada: sus videos
   salen a 1080p/1440p en YouTube.
5. **Sensores que llegan** — fallos de buffer contados; **el aviso se decide por
   TRAMO, no por promedio** (ese día el promedio fue 92%, por encima del umbral del
   90%, así que *no avisó*, mientras seis minutos estaban a 10 fps); preflight de
   ritmo y RAM al dar REC; latido con `comp/sinBuf/cadencia/sync/ram`; y
   notificación del sistema cuando la cadencia baja **grabando** — el chip de fps ya
   existía y no sirvió de nada porque vive en la ventana del Estudio, que está en el
   otro monitor mientras Daniel presenta.

### La respuesta a "¿por qué OBS no?"

No es el código: es el trabajo pedido. OBS escala su salida a 1080p aunque el canvas
sea la pantalla; SFCast componía **y codificaba** a 4096×2304 — 4.6× más píxeles por
los que YouTube no paga. Streamlabs es OBS con otra piel.

### Lo que deja

- **Un sensor que mide el promedio no es un sensor.** El promedio de 45 minutos
  esconde un colapso de 6. Alarma por peor ventana, siempre.
- **Un `return nil` en el camino caliente es un frame que desaparece del mundo.**
  Si el código puede fallar en silencio, cuenta el fallo ahí mismo.
- **Degradar bien es una feature.** 15 fps parejos se ven pobres; 8 fps con saltos
  de 750 ms se ven rotos, y encima no hay interpolación que los salve.

### QA nuevo

```bash
open -W /Applications/SFCast.app --args --rectest 14              # graba y verifica el MP4
open -W /Applications/SFCast.app --args --rectest 22 --chokems 60 # ejerce el governor
open -W /Applications/SFCast.app --args --synctest 12             # latencia real por fuente
./.build/debug/SFCast --compbench 60                              # costo/memoria por lienzo (headless)
```

---

## v3.1 — Por qué OBS no se traba y nosotros sí: **no era componer, era ESPERAR** (9 ago 2026)

Daniel, después de ver el semáforo del governor: *"¿de qué me sirve esta madre con
semáforo si me va a dar pocos fps? ¿cómo logramos que sean estables a pesar de
todo, que no se bajen?"*. Tenía toda la razón: v3.0 construyó un **termómetro**
cuando lo que pidió es que no haya fiebre.

### La medición que lo resolvió (por FASE, no en bloque)

El agregado decía "compose cuesta 20 ms" y con eso no se puede decidir nada: podía
ser la GPU, el pool, el encoder o el preview — cuatro curas opuestas. Desglosado:

```
preview          0.0 ms
encode           0.1 ms          ← el encoder NO era el cuello
grafo (CPU)      0.58 ms
buffer (pool)    0.02 ms
RENDER (GPU)    22.32 ms         ← el 97%
```

Y el mismo render costaba **2 ms en el bench sintético**. La diferencia no era el
trabajo: era que **`CIContext.render` es SÍNCRONO** y la GPU no es nuestra —
WindowServer compone dos monitores 4K, el encoder HEVC codifica, el preview y el
espejo pintan. Estábamos parados esperando cola ajena **en el único hilo que marca
la cadencia**.

Eso —y no "mejor código"— es la diferencia con OBS. Ellos no bloquean.

### Las dos piezas

**1. Pipelining (`Compositor.composePipelined`).** El frame N lanza su render con
`startTask` y NO lo espera; el N+1 recoge el resultado que la GPU pintó mientras
tanto. Cuesta un frame de latencia, y por eso **el `hostTime` viaja pegado al
buffer**: lo que se entrega es del tick anterior y debe llevar el timestamp de ESE
tick, o reintroduciríamos el desfase de audio que v3.0 acababa de matar.

| | antes | después |
|---|---|---|
| compose p50 | 21.3 ms | **3.7 ms** |
| RENDER (GPU) | 22.3 ms | **2.8 ms** |
| fps del archivo | 29.85 | **29.99** |
| costo del espejo | −2.5 fps | **−0.2 fps** |

**2. `CadenceKeeper` — por qué a OBS "no se le bajan los fps".** Un
`DispatchSourceTimer` con `repeating` **no recupera disparos perdidos**: si el
sistema lo posterga 70 ms, esos dos ticks no vuelven y el archivo queda con un
hueco. Ahí nacían los saltos de 750 ms. Ahora, cuando faltan ticks, se reemiten los
timestamps que faltan con el último contenido — los *lagged frames* de OBS.

La clave conceptual: **un frame repetido y un frame que nunca se compuso muestran
exactamente lo mismo en pantalla.** La diferencia está en el contenedor, y 30 fps
constantes es lo que cualquier editor quiere (los NLEs sufren el VFR). OBS no
siempre alcanza — simplemente nunca deja huecos.

### La prueba que cierra la promesa

Con `--chokems 60` (ahogo del **doble** del presupuesto):

```
antes:  archivo a 14.53 fps
ahora:  archivo a 29.72 fps   (446 frames rellenados, pistas alineadas 0 ms)
        el compositor bajó a 15 fps — y el archivo salió a 30 igual
```

### El governor cambia de sentido (y de mensaje)

Ya no baja "la grabación": baja **cuántos frames nuevos compone**, para darle aire a
la GPU, mientras el archivo sigue saliendo a los fps pedidos. El mensaje al usuario
se reescribió por eso — decirle *"bajé tu grabación a 19"* cuando su archivo sale a
30 sería mentirle y asustarlo de gratis.

### Lo que NO se hizo, a propósito

**Damage tracking** (no recomponer el fondo cuando la pantalla no cambió) quedó
fuera: con 3.7 ms de 33.3 ya hay 9x de margen, y añadir invalidación de caché sobre
un compositor que ya funciona es riesgo de artefactos visuales a cambio de un margen
que no hace falta. Queda documentado como palanca si algún día la hiciera falta.

Los modos de `CIContext` (sin color management, Metal explícito) se midieron: 1.14x.
Se quedaron porque son gratis, pero el grueso era el bloqueo, no el color.

### La lección

**Un agregado no es una medición.** "Compose cuesta 20 ms" fue verdad todo el tiempo
y no permitía decidir nada; el desglose por fase señaló la cura en un intento. Y la
segunda: cuando algo tarda, la pregunta no es solo *"¿cómo lo hago más rápido?"*
sino *"¿por qué lo estoy ESPERANDO?"*.

### v3.1b — lo que la prueba larga descubrió sola: **la cámara se apaga y nadie avisa**

En la corrida de 50 min, al **minuto 31.6**, la ZV-E10 dejó de entregar frames
(`cam:30fps → cam:3fps → cam:0fps`) y **la grabación siguió 18 minutos a 30.00 fps
perfectos componiendo su último frame congelado, sin una sola línea en el log**.

Es la pantalla congelada del 25 jul otra vez, por el otro lado — y es el caso **más
probable de Daniel**, porque las Sony tienen auto power off y él graba tomas largas.
El sensor existía (`frames.age(.camera)`); lo que faltaba era que alguien lo MIRARA.

Un frame viejo se compone igual de bien que uno nuevo: **una cámara muerta produce
un video impecable de una foto fija.** Ahora `checkCameraHealth()` corre en el mismo
watchdog de 1 Hz: detecta a los 5 s, avisa en la ventana, **manda notificación del
sistema si está grabando**, y reconcilia la sesión cada 10 s para engancharla sola
cuando Daniel la vuelva a encender.

Ejercido a voluntad con `--rectest --freezecam` (tira los frames de cámara a
propósito): **detectado en 5.3 s**, `cameraFrozen=true`, notificación enviada.

### La batería completa, corrida al final

| Prueba | Resultado |
|---|---|
| Grabación **44.8 min** (la duración del incidente) | **30.00 fps de 30 — 100%**, 0 rellenados, 0 drops |
| **Soak 40 min**, escena compuesta, headless | **SOAK_OK** · 29.99 fps · 0.0% repetidos · RAM plana |
| Estrés `--chokems 60` (doble del presupuesto) | archivo a **29.72 fps** (antes 14.53) |
| `--failstream` (reenganche de pantalla falla) | grabación **sobrevive** a 29.99 fps + notificación |
| `--freezecam` (la cámara se apaga) | detectado en **5.3 s** + notificación |
| `--mirrortest` | alineación 0.00 px · fuga 0.0000 · costo −0.2 fps |
| `--compbench` / `--studiotest` / `--selftest` / `validate.sh` | verdes |

Las dos pruebas largas corrieron **en paralelo** (dos pipelines de video a la vez en
la misma Mac), que de paso es la prueba de estrés más realista que se hizo.

---

## v3.2 — El cable a la edición: marcadores en vivo, zonas y daño declarado (10 ago 2026)

Daniel, después de preguntar qué más se podía exportar para facilitar la edición:
*"debemos armar conectores entre sfstudio y edición de video skill, ese opino será
el verdadero MOAT de todo esto"*. Es exactamente el diagnóstico: cualquiera puede
pedirle a un LLM que corte un video; **nadie más tiene la cámara hablándole al
editor.**

### El problema, con su número

Grabó **45.7 minutos** para un máster de **14:30**. De la hora y media que tardó la
edición, la mayor parte no fue diseño ni animación: fue **decidir cuál de sus tres
intentos de cada frase era el bueno**, con seis sub-agentes leyendo transcript.

Él sabía cuál era el bueno **en el momento**. Esa información simplemente no tenía
dónde vivir, así que se tiraba y luego se reconstruía cara.

### Lo que ahora viaja en el manifest

- **`markers`** — ⌘⇧X ("la regué, corta") y ⌘⇧M ("esto estuvo bueno"), **globales**
  (`RegisterEventHotKey` de Carbon, que NO pide el permiso de Monitorización de
  entrada; esta app ya pagó caro esa moneda). Funcionan mientras presenta en otra
  app, que es justo cuando se traba.
- **`deadZones`** — los tramos con la imagen CONGELADA. En el archivo son
  indistinguibles de material sano: el 9 ago la cámara se apagó al minuto 31.6 y la
  grabación siguió 18 minutos de foto fija a 30 fps impecables. El editor los usaría
  sin saberlo.
- **`sceneTimeline`** ya existía y nadie lo leía. Ahora el conector lo traduce a
  ZONAS con su clase (`talking` / `pantalla`), que es lo que decide la intensidad de
  edición — algo que el pipeline venía **adivinando** del transcript o de los frames.

El traductor vive del lado de la edición:
`.claude/skills/edicion-de-video/scripts/sfcast_manifest.py`, y la skill lo declara
como **PASO 0.1, antes de sondear el raw**.

### Dos decisiones de diseño que importan

**El marcador es una SEÑAL, no un rango.** `t` es cuándo Daniel PULSÓ, y un humano
reacciona uno o dos segundos tarde. Inventar el rango sería fingir precisión: el
editor ya tiene el transcript con tiempos por palabra y encuentra la frontera de la
frase. Él aporta la intención, el editor la precisión.

**El acuse va en el aro del ESPEJO.** No en la ventana del Estudio (está en el otro
monitor — lección repetida cuatro veces el 9 ago) y no con sonido (se grabaría). El
espejo lleva `sharingType = .none`: lo ve él y no sale en el video. Sin acuse, un
marcador se pulsa dos veces "por si acaso" y deja de ser una señal limpia.

### Un bug propio, cazado en vivo el mismo día

El watchdog de cámara (v3.1b, de hace unas horas) reconciliaba la sesión cada 10 s
mientras la cámara estuviera muerta. Con la ZV-E10 apagada, `Devices.camera(id:)`
cae a `AVCaptureDevice.default` → enganchaba la **"OBS Virtual Camera"**, que
entrega un cuadro fijo, y entonces el watchdog **se declaraba satisfecho**.

**Un sensor que se auto-satisface con una imagen falsa es peor que no tener sensor.**
Ahora solo reintenta si la cámara ELEGIDA reapareció, cada 30 s. Y de paso: si al
arrancar la resuelta no es la elegida, se avisa — grabar una hora con la webcam
equivocada es un desastre silencioso, y era posible hasta hoy.

## v3.4 — Los 5m53s del video de 4:28: el compresor peleaba contra la red de hoy (10 ago 2026)

Daniel preguntó por qué SFCast tarda tanto en publicar comparado con Loom. Se midió
el pipeline entero en vivo, sobre un video real de **4:28** (`ib9z3jvsvog1`):

| Fase | Duración | % |
|---|---|---|
| Stop → link al portapapeles | instantáneo | — |
| Cerrar MP4 + placeholder | 10s | 3% |
| **Comprimir con ffmpeg en el Mac** | **147s** | **42%** |
| Subir 184.6 MB por rsync | 16s | 5% |
| Poller (cada 8s) | 5s | 1% |
| Concat + thumbnail | 20s | 6% |
| **Whisper en el VPS** | **153s** | **43%** |
| LLM (título + capítulos) | 2s | 1% |
| **TOTAL** | **5m 53s** | |

Dos cerdos se comían el 85%. Lo demás era ruido.

### El compresor estaba trabajando EN CONTRA (y era código correcto)

`Transcoder.swift` se escribió el 15 jul sobre una premisa **medida entonces**: la
subida iba a ~0.5 Mbps, así que comprimir 5x era comprimir la espera 5x. Impecable
para ese mundo.

Ese mundo se acabó con la mudanza a Morelia. Medición del 10 ago, con el mismo
comando rsync que usa la app: **106 Mbps de subida (13.3 MB/s reales)**. Con eso:

- **Con compresión:** 147s de encode + 16s de subida = **163s**
- **Sin compresión:** 778.9 MB crudos a 13.3 MB/s = **59s**

El compresor costaba **104 segundos netos** y encima degradaba la imagen.

**La lección no es "el compresor estaba mal".** Estaba bien y sus mediciones eran
honestas. Lo que faltó fue el **sensor de su propia premisa**: nadie volvió a medir
el ancho de banda, así que el órgano siguió optimizando para una restricción que ya
no existía. Es el patrón del órgano sin sensor otra vez, pero en su forma más
tramposa: no falla, no hace ruido, y sigue haciendo bien un trabajo que ya no hay
que hacer.

### La raíz de TODO: se capturaba a 4096x2304

`SCRecordingOutput` no expone bitrate, y a nativo Retina el archivo NACÍA a
**23 Mbps** (778.9 MB por 4:28). Ese tamaño explicaba las dos cosas a la vez:

- `targetBitrate` escala por píxeles ⇒ objetivo 1200 × 4.55 = **5461 kbps**.
- El encoder por hardware, que a 1080p corre a ~7x tiempo real, **a 4K cae a 0.55x**
  (de ahí los 147s para 268s de video).

Ahora `AppSettings.captureMaxHeight = 1440` capa la captura. Medido en la prueba E2E:
4096x2304 → **2560x1440** (escalado exacto, sin deformar) y el archivo baja de
23 Mbps a **7.7 Mbps**: **3x más chico desde el origen**, sin re-encodear nada.

Loom, para referencia, graba a 1080p.

### La pre-subida mientras grabas, y por qué no puede costar un video

Es el truco por el que Loom se siente instantáneo: cuando le das stop, ya tiene
arriba casi todo. `Uploader.liveSync` hace `rsync --inplace --append` del directorio
de sesión cada 20s mientras `state == .recording`.

`--append` **asume** que el remoto es un prefijo del local. Un MP4 en escritura lo
cumple casi siempre (el mdat crece secuencial, el moov se escribe al cerrar), pero
la garantía no puede depender de eso. La garantía real es que **el rsync del stop
corre SIN `--append`** — delta completo — y deja el remoto byte a byte igual al
local pase lo que pase.

Eso se verificó rompiendo el remoto a propósito: 10 MB de ceros en medio del archivo
más la cola truncada. El rsync final lo dejó **idéntico en 2.1s**. La pre-subida solo
puede ahorrar tiempo, jamás costar un video.

Dos detalles que sí importan:

- **Nunca crea `UPLOAD_DONE`.** Es ese marcador el que hace visible una sesión al
  poller; sin él, el worker no puede ver una sesión a medias.
- **Cancelar una grabación borra lo pre-subido** (`Uploader.discardRemote`). Sin eso,
  cada cancelación dejaría un directorio a medias en `incoming/` que nadie mira nunca
  — que es exactamente la basura que encontramos del 15 jul: 2 sesiones huérfanas,
  95 MB, 26 días invisibles.

### Resultado medido (demo E2E sin manos, contra un incoming de pruebas)

```
captura: 4096x2304 → 2560x1440 (tope 1440p)
live-sync: 2 tandas pre-subidas durante la grabación
Upload OK → … (intento 1, 5.5s de cola)      ← 163s en la ruta vieja
```

Sin línea de `Transcoder:` (compresión apagada) y los dos segmentos llegaron con
**md5 idéntico** al local.

El segundo de "cola" en `Upload OK` es el **sensor del live-sync**: con la pre-subida
funcionando tiene que quedar en pocos segundos aunque el video pese cientos de MB.
Si vuelve a crecer, el live-sync dejó de servir y hay que mirarlo.

### Lo que quedó FUERA y por qué

El lado VPS (publicación en dos tiempos, transcript por Groq, transcode a H.264) NO
se tocó en esta tanda: otra sesión estaba trabajando `infra/sfcast_worker.py` sin
commitear y corriendo un backfill a R2. Dos plumas sobre el mismo archivo se pisan.

Queda medido y listo para quien lo tome:

- **Groq `whisper-large-v3-turbo`: 2.0s contra los 153s de faster-whisper**
  estrangulado por `CPUQuota=200%` (2 de 8 cores). Transcript equivalente: 97
  segmentos / 3,925 chars contra 107 / 3,969. Costo $0.003 por video.
- **La página espera al transcript sin necesidad.** El `video.mp4` estuvo
  reproducible en el servidor 2m35s antes de que el worker escribiera el viewer.
  Loom publica el reproductor en cuanto el media aterriza y mete el transcript
  después.
- **Se sirve HEVC 4096x2304, y eso NO reproduce en Chrome/Windows** ni en Firefox
  ni en buena parte de Android. Verificado también contra R2: mismo archivo, mismo
  códec. El transcode a H.264 no es optimización, es corrección — y tiene que
  correr ANTES del espejo a R2 para no subir dos veces.

## v3.5 — El VPS: publicar en tres fases, y el códec que nadie estaba mirando (10 ago 2026)

Continuación de v3.4, ya con el lado VPS. Mismo video de referencia (`ib9z3jvsvog1`,
4:28): antes **5m53s** de punta a punta.

### El reproductor ya no espera al transcript

El `video.mp4` estaba reproducible en el servidor **2m35s antes** de que la página
dejara de decir "Procesando". Se hacía esperar a un video por su transcript, que es
justo lo que nadie necesita para ver un video.

`process_session` ahora corre en tres fases:

1. **Se puede VER** — concat + thumbnail → publica con `ready:false`.
2. **Se puede LEER** — transcript + título + capítulos → republica con `ready:true`.
3. **Se puede DISTRIBUIR** — transcode a H.264 → espejo a R2.

La página abierta se completa **sola**: sondea `data.json` cada 4s y pinta lo que
falta sin recargar y sin tocar el `<video>`. Recargar habría reiniciado el video que
la persona ya está viendo — por eso se pinta en vez de refrescar.

Medido con una sesión real de 45s: **reproducible en 1s, completa en 4s.**

### Groq: 2.0s contra 153s, y por qué el local se queda

El cuello no era el modelo, era el techo: el servicio corre con `CPUQuota=200%`
sobre 3 cores permitidos — **2 de los 8** del EPYC — y ese techo existe para que una
clase en vivo del Meet siempre gane. Subirlo habría sido romper un invariante bueno
para arreglar el síntoma.

Groq hace lo mismo en 2.0s y el transcript es equivalente (97 segmentos / 3,925
chars contra 107 / 3,969). $0.003 por video, ~2 centavos al mes a la cadencia real.

`faster-whisper` se queda de red de seguridad a propósito: así un corte de internet
o una llave vencida **degradan** el servicio (más lento) en vez de **tumbarlo** (sin
transcript). Solo se carga si se usa, o sea que ya no cuesta 1.4 GB de RAM ni 80s de
arranque.

### El hallazgo que nadie estaba buscando: se servía HEVC

`SCRecordingOutput` **solo** escribe HEVC — está forzado en el Mac a propósito,
porque esquiva el tope de H.264 a 4096x2304 en Retina/5K. Excelente para grabar.
Pésimo para distribuir: HEVC no reproduce en Chrome/Windows sin la extensión de pago
de Microsoft, ni en Firefox en varias plataformas, ni en buena parte de Android.

Verificado el mismo día contra R2: el video del anuncio a ~570 miembros se servía
como `hevc/hvc1 4096x2304`, 193 MB. **Reproductor en negro para una parte de la
comunidad, y en silencio** — un video que no carga no genera reporte; la gente asume
que está roto y se va.

Por eso la fase 3 no es optimización, es corrección. Y va **antes** del espejo a R2:
subir el HEVC y reemplazarlo después es pagar la subida dos veces y dejar un rato el
archivo malo como el público.

Resultado en el video del anuncio: **194 MB → 27 MB**, `h264/avc1 2560x1440`, 92s de
transcode que nadie esperó. `backfill_h264.py` cerró el pasado: 10 casts nativos en
HEVC (los 52 importados de Loom ya venían compatibles y se saltaron solos).

### Las huérfanas: recuperar antes que borrar

El sensor nuevo (`orphans()`) delató 2 sesiones del 15 jul sin `UPLOAD_DONE` — 26
días invisibles, porque el poller solo mira lo que tiene el marcador. Un órgano sin
sensor se ve idéntico a uno sano.

Lo fácil era borrarlas: 95 MB de basura de un día de pruebas. Antes de tocarlas se
revisó, y resultó que **eran las únicas copias** (sin respaldo local, fuera del
historial de la app) y estaban **truncadas** — el meta decía 45.9s y el archivo tenía
39.9s: la subida murió a media transferencia.

Se procesaron en vez de borrarse. Salieron «Edición de Video: Ajuste de Elementos y
Transición a IA» y «Mejoras en la interfaz de grabación de SaaS Factory». Contenido
real. **Ante la duda, recuperar: borrar es la única operación que no se deshace.**

### Un sensor propio que exageraba, cazado en el acto

`sin_distribuir_h264` contaba "sin marcador" como "sin distribuir", y marcaba 51
pendientes que en realidad ya eran H.264 (los importados de Loom, que nunca pasaron
por el transcodificador porque no lo necesitaban).

Es exactamente el defecto que se le señaló ese mismo día al verificador de
`publish_cast_r2.py` (decía 0/9 publicados y las 9 URLs respondían 200). Un sensor
que exagera se deja de leer, y el día que tenga razón nadie le va a creer. Se
estamparon los marcadores de los ya-compatibles y el contador dice la verdad: 0.

### El antes y el después

| | Antes | Después |
|---|---|---|
| Stop → se puede VER | 5m 53s | **~40s** (1s de worker + subida ya casi hecha) |
| Stop → transcript listo | 5m 53s | **~45s** |
| Transcript | 153s (2 de 8 cores) | **2.0s** (Groq) |
| Compresión en el Mac | 147s | **0s** (murió) |
| Cola de subida al detener | 163s | **5.5s** |
| Códec servido | HEVC 4K (negro en Chrome) | **H.264 1440p** |
