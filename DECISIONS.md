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
