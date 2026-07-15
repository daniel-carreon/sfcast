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
