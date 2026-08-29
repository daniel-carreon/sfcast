import Foundation
import AppKit
import AVFoundation
import ScreenCaptureKit
import CoreImage
import CoreMedia
import CoreVideo
import IOSurface
import Metal

/// MODO ESTUDIO — motor de frames y compositor del programa.
///
/// Topología (del grafo del spec):
///   pantalla (SCStream .screen) ──┐
///   cámara (AVCaptureVideoData) ──┤→ LatestFrameStore → Compositor (render loop
///   testPattern (sintética)     ──┘   CoreImage @ fps) → frame de programa
///                                        ├→ preview (IOSurface → CALayer)
///                                        └→ ProgramSink (AVAssetWriter, si graba)
///
/// El modo Loom NO pasa por aquí: su ruta barata (SCRecordingOutput directo)
/// queda intacta. Este motor corre SOLO con la ventana de Estudio abierta.
///
/// COMPARADOR anti "merge silencioso" (spec): si una fuente está activa en la
/// escena pero NO entrega frames, el compositor lo cuenta y la UI lo muestra —
/// jamás se ignora una fuente en silencio.
@MainActor
final class StudioEngine: NSObject {

    // MARK: - estado observable (la UI lee esto)

    private(set) var isRunning = false
    /// Cuándo arrancó el motor. Sirve para medir la edad de una fuente que NUNCA
    /// entregó un frame: sin esto, el watchdog no podía distinguir "acaba de
    /// arrancar" de "lleva media hora muerta desde el segundo cero".
    private var startedRunningAt: Double = CACurrentMediaTime()
    /// Los observadores de la sesión de cámara se cuelgan UNA vez.
    private var cameraObserversWired = false
    private(set) var screenAvailable = false     // permiso + stream vivo
    private(set) var cameraAvailable = false
    /// Fuentes activas en la escena que NO están entregando frames (comparador).
    private(set) var starvedSources: Set<StudioSourceKind> = []
    /// La pantalla dejó de entregar frames aunque el stream se cree vivo — el
    /// compositor estaría RECICLANDO el último frame (la "congelada" del 25 jul).
    private(set) var screenFrozen = false
    private(set) var screenRestarts = 0
    /// El micrófono lleva más de `deadAfter` sin entregar una muestra.
    private(set) var micDead = false
    /// Copia del fps del lienzo legible fuera de MainActor (la configuración de
    /// la cámara corre en `sessionQueue`).
    nonisolated(unsafe) private var fpsParaCamara: Int = 30
    private var micRetryAt: Double = 0
    /// La CÁMARA lleva rato sin entregar imagen nueva. Descubierto el 9 ago en
    /// una prueba de 50 min: la ZV-E10 se apagó sola al minuto 31.6 (las Sony
    /// tienen auto power off) y la grabación siguió 18 minutos componiendo su
    /// ÚLTIMO frame congelado, a 30 fps perfectos, sin UNA SOLA línea de aviso.
    /// Es exactamente la pantalla congelada del 25 jul por el otro lado — y el
    /// caso más probable de Daniel, porque su cámara se apaga sola.
    private(set) var cameraFrozen = false
    private var cameraRetryAt: Double = 0
    var onStatusChange: (() -> Void)?
    /// Aviso de alto nivel para la UI (congelada / disco / recuperada).
    /// La CAUSA existe para poder curarlo: ver `onAlertResolved`.
    var onAlert: ((String, Bool, String?) -> Void)?   // (mensaje, esCrítico, causa)
    /// LA CURA DE LA ALARMA (28 ago 2026). Una alarma crítica es PEGAJOSA a
    /// propósito —se queda hasta que la situación se arregle— pero hasta hoy
    /// NADIE decía que se había arreglado. Medido: el 28 ago la sesión se
    /// bloqueó a las 17:50, la pantalla volvió sola a las 18:07 y el banner rojo
    /// «No pude reenganchar la pantalla» siguió pintado encima de un preview que
    /// estaba capturando perfectamente. Un instrumento que sobrevive a su causa
    /// miente, y encima entrena a ignorar el único sitio donde salen las cosas
    /// graves. Quien levanta la alarma es el que tiene que apagarla.
    var onAlertResolved: ((String) -> Void)?          // (causa)

    /// Solo para marcar "esta fuente lleva rato sin imagen nueva" en la UI.
    /// NO dispara nada: una pantalla quieta es legítima.
    /// QA: congela la entrada de cámara a propósito (`--freezecam`).
    nonisolated(unsafe) static var qaFreezeCamera = false
    /// QA: corta la entrada de micrófono a propósito (`--mutemic`).
    nonisolated(unsafe) static var qaMuteMic = CommandLine.arguments.contains("--mutemic")

    nonisolated static let staleAfter: Double = 3.0
    /// Silencio TOTAL del stream (video + audio) que ya no es reposo sino
    /// muerte. 5s es holgado a propósito: prefiero tardar 5s en reaccionar que
    /// reenganchar de más (el reenganche corta el raw de pantalla).
    nonisolated static let deadAfter: Double = 5.0

    // MARK: - infra compartida con los hilos de captura/render

    let frames = LatestFrameStore()
    let previewGate = PreviewGate()
    let levels = AudioLevelBox()
    /// Latido del STREAM de pantalla (no de la imagen). Ver StreamHealth.
    let screenHealth = StreamHealth()
    let sceneBox = SceneBox()
    /// Sink de grabación (nil = no se está grabando). Lo pone StudioRecorder.
    let sink = SinkBox()

    /// ⚠️ `.userInteractive`, NO `.userInitiated` (9 ago 2026). Con el render ya
    /// canalizado, compose cuesta ~4 ms de 33 y aun así el governor bajaba: el
    /// trabajo no era el problema, el SCHEDULER sí. Bajo carga, macOS posterga
    /// una cola `.userInitiated` y el timer pierde disparos — que es
    /// exactamente el hueco que el `CadenceKeeper` tiene que rellenar con
    /// frames repetidos. Subir la prioridad no hace el trabajo más rápido:
    /// hace que nos toque el turno a tiempo, y así los frames son NUEVOS en vez
    /// de repetidos. Es el mismo motivo por el que los motores de audio corren
    /// con prioridad de tiempo real.
    private let renderQueue = DispatchQueue(label: "so.saasfactory.sfcast.studio.render", qos: .userInteractive)
    private let videoQueue = DispatchQueue(label: "so.saasfactory.sfcast.studio.video", qos: .userInitiated)
    /// CARRIL PROPIO PARA LA CÁMARA (28 ago 2026). Hasta hoy los frames de
    /// pantalla y los de cámara se entregaban en la MISMA cola serial: dos
    /// fuentes independientes de alta frecuencia haciendo fila una detrás de
    /// otra. Con `alwaysDiscardsLateVideoFrames = true` (que es lo correcto),
    /// cada milisegundo que la cámara pasa esperando su turno detrás de un
    /// frame de pantalla es un frame de cara que AVFoundation tira. Medido: con
    /// las tres salidas activas la cámara caía de 25.00 a 12-15 fps.
    /// `FrameStore.set` y `sondaPTS` son lock-protected, así que las dos colas
    /// pueden correr a la vez sin carreras.
    private let camVideoQueue = DispatchQueue(label: "so.saasfactory.sfcast.studio.camvideo", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "so.saasfactory.sfcast.studio.audio", qos: .userInitiated)
    /// TODA la cirugía del AVCaptureSession (begin/commitConfiguration, start/
    /// stopRunning) vive AQUÍ, serializada. En main era la bolita de arcoíris:
    /// commitConfiguration se queda esperando el lock interno de la sesión
    /// mientras stopRunning lo tiene en otro hilo (bug del "Aplicar", 6 ago).
    private let sessionQueue = DispatchQueue(label: "so.saasfactory.sfcast.studio.session", qos: .userInitiated)

    private var renderTimer: DispatchSourceTimer?
    private var watchdog: Timer?
    private let compositor = Compositor()
    /// El reloj que compensa la latencia de captura al estampar el programa.
    /// Vive en el motor (no en el sink) porque la latencia es propiedad de las
    /// FUENTES, y el sink va y viene con cada grabación.
    let programClock = ProgramClock()
    /// Baja (y sube) la cadencia cuando la Mac no da el ritmo pedido.
    let governor = RenderGovernor()
    /// Dónde se van los milisegundos del loop, por fase.
    let profile = RenderProfile()
    /// Rellena los ticks que el timer pierda: cadencia SIN huecos en el archivo.
    let cadence = CadenceKeeper()
    /// La cadencia cambió: (efectiva, pedida). La UI lo enseña — una grabación
    /// que se degrada en silencio fue el patrón de TODOS los bugs del Estudio.
    var onCadenceChange: ((Int, Int) -> Void)?
    /// Una fuente se congeló (o volvió): (source, frozen, motivo). Lo consume el
    /// grabador para dejarlo escrito en el manifest — el editor tiene que saber
    /// qué segundos son una foto fija.
    var onSourceFrozen: ((String, Bool, String) -> Void)?
    /// FPS que está corriendo ahora mismo el render loop (≤ el configurado).
    var effectiveFPS: Int { governor.effective == 0 ? fps : governor.effective }

    // pantalla
    private var screenStream: SCStream?
    private var screenRecOutput: SCRecordingOutput?
    private var screenRecDelegate: SegmentDelegate?

    // cámara (sesión PROPIA del Estudio — la burbuja es artefacto del Loom)
    private let cameraSession = AVCaptureSession()
    private var cameraVideoOut: AVCaptureVideoDataOutput?
    private var cameraAudioOut: AVCaptureAudioDataOutput?
    private var cameraMovieOut: AVCaptureMovieFileOutput?
    private var cameraMovieDelegate: CamFileDelegate?

    /// Canvas del programa en píxeles (nativo del display, o 1920x1080 sin pantalla).
    private(set) var canvasSize = CGSize(width: 1920, height: 1080)
    private(set) var fps = 30
    private var canvasOverride: CGSize?
    /// Resolución nativa del display capturado (la mide startScreenTap). Se
    /// guarda para que applyLive pueda volver a "Nativa" sin tirar el stream.
    private var nativeCanvas: CGSize?
    /// Píxeles que el stream entrega DE VERDAD. Desde el 9 ago no siempre son
    /// los nativos: si el lienzo es menor, se le pide a SCK que escale en la
    /// captura. Ahí el downscale lo hace el compositor de ventanas (gratis, ya
    /// va a tocar esos píxeles) en vez de CoreImage, y sobre todo cada buffer
    /// pesa lo que pesa la SALIDA: a 4K son 37 MB × queueDepth 8 = 302 MB de
    /// pool, contra 66 MB a 1080p. En una Mac de 16 GB con dos monitores 4K,
    /// esos 236 MB son la diferencia entre tener margen y no tenerlo.
    private var streamPixels: CGSize?
    /// ¿Se está guardando `screen.mp4`? Decide si la captura puede subir por
    /// encima del lienzo (ver `captureSize`). Se refresca en start/applyLive.
    private var rawScreenWanted = false
    // MARK: - ARRANQUE REAL DE CADA RAW (v3, 28 ago 2026)
    //
    // El desfase entre las pistas NO se deriva del cierre. Medido el 28 ago:
    // derivarlo de "todos terminan juntos" daba 2.23 s donde el real era 1.63
    // (18 frames), porque la cámara cierra antes que el programa. Aquí se
    // ANOTA el instante host del PRIMER frame que cada raw pudo escribir, que
    // es el único dato con el que la edición puede alinear las capas.
    /// Caja aparte porque los delegates de captura son `nonisolated` y el motor
    /// vive en el MainActor: el estado que tocan las dos orillas no puede ser
    /// una propiedad aislada. Mismo patrón que la sonda de PTS.
    let rawStarts = RawStartBox()
    /// Cuándo EMPEZÓ A ESCRIBIR cada raw (del callback del writer, no del
    /// instante en que se le pidió: ver `CamFileDelegate.startedHost`). El
    /// primer frame posterior a la llamada queda de respaldo por si el callback
    /// no llegara, pero es una cota inferior, no la verdad.
    var camRawFirstFrameHost: Double? { cameraMovieDelegate?.startedHost ?? rawStarts.first(camara: true) }
    var screenRawFirstFrameHost: Double? { screenRecDelegate?.startedHost ?? rawStarts.first(camara: false) }
    func armRawStarts(camera: Bool, screen: Bool) { rawStarts.arm(camara: camera, pantalla: screen) }
    func disarmRawStarts() { rawStarts.disarm() }
    /// Techo del raw de pantalla: el mismo `captureMaxHeight` del Loom.
    private var rawScreenMaxHeight: CGFloat { CGFloat(AppSettings.load().captureMaxHeight) }
    /// La config viva del SCStream: applyLive la muta y la re-aplica con
    /// updateConfiguration (fps / audio del sistema en caliente, estilo OBS).
    private var screenCfg: SCStreamConfiguration?
    private var systemAudioWanted = true
    private var retryingScreen = false
    private var restartingScreen = false

    var onPreviewSurface: ((IOSurface) -> Void)?   // llega en MAIN thread
    /// Lo provee StudioRecorder: siguiente URL para el raw de pantalla cuando
    /// hay que reenganchar a mitad de grabación (screen-002.mp4, -003…).
    var onNeedNewScreenRawURL: (() -> URL?)?

    // MARK: - lo que el ESPEJO necesita del motor (v2.9)

    /// La sesión de cámara del Estudio. El espejo cuelga de AQUÍ un
    /// `AVCaptureVideoPreviewLayer`: ni una sesión nueva (invariante: una sola
    /// dueña de cámara/mic), ni un frame extra viajando a main.
    var cameraCaptureSession: AVCaptureSession? { cameraAvailable ? cameraSession : nil }

    /// Resolución NATIVA del display capturado, en px. El espejo la usa para
    /// mapear canvas ⇄ pantalla con el mismo número que usa el stream, no con
    /// una re-derivación desde NSScreen que podría diferir.
    /// Lo que el stream entrega DE VERDAD (no lo nativo del display): el espejo
    /// mapea canvas ⇄ pantalla con este número, así que tiene que ser el real o
    /// el panel se despega del programa.
    var capturedPixelSize: CGSize? { streamPixels ?? nativeCanvas }

    /// El dispositivo de cámara que quedó DE VERDAD en la sesión — no el que
    /// pide settings.json. Si el elegido no está conectado (una cámara apagada,
    /// por ejemplo), `Devices.camera(id:)` cae a otro y el video sale de un
    /// sitio que nadie eligió: pasó en el QA del 9 ago, donde la ZV-E10 estaba
    /// apagada y el Estudio grabó de "OBS Virtual Camera" (un cuadro fijo, y
    /// con OBS cerrado ni eso). El nombre resuelto es el sensor de eso.
    /// La entrada de MICRÓFONO que quedó de verdad en la sesión. Hermana de
    /// `cameraDeviceName`, y por el mismo motivo: lo que pide settings.json no
    /// siempre es lo que macOS entrega.
    var micDeviceName: String? {
        cameraSession.inputs.compactMap { ($0 as? AVCaptureDeviceInput)?.device }
            .first(where: { $0.hasMediaType(.audio) })?.localizedName
    }

    var cameraDeviceName: String? {
        cameraSession.inputs.compactMap { ($0 as? AVCaptureDeviceInput)?.device }
            .first(where: { $0.hasMediaType(.video) })?.localizedName
    }

    /// ¿El programa sale espejeado? Se LEE de la conexión real del data-output
    /// (que es de donde el compositor toma los frames), jamás se asume: si el
    /// espejo volteara por su cuenta, mentiría sobre el encuadre.
    var cameraMirroredInProgram: Bool {
        cameraVideoOut?.connection(with: .video)?.isVideoMirrored ?? false
    }

    // MARK: - arranque / parada del motor (preview vivo, sin grabar)

    func start(config: StudioConfig) async {
        guard !isRunning else { return }
        fps = max(10, min(60, config.fps))
        fpsParaCamara = fps
        canvasOverride = config.canvasMode.size
        if let o = canvasOverride { canvasSize = o }
        rawScreenWanted = config.outputs.rawScreen
        systemAudioWanted = config.systemAudioEnabled
        isRunning = true
        startedRunningAt = CACurrentMediaTime()
        sceneBox.set(config.scenes.first(where: { $0.id == config.activeSceneID }) ?? config.scenes.first)

        // Cámara y mic por el BROKER (serializado — invariante TCC).
        let camOK = await PermissionBroker.shared.request(.video)
        if config.micEnabled { _ = await PermissionBroker.shared.request(.audio) }
        guard isRunning else { return }   // lo cerraron durante el prompt
        if camOK { startCameraTap(micEnabled: config.micEnabled) }

        // Pantalla: si no hay permiso, el motor corre igual (cámara/testPattern)
        // y la UI lo reporta — nunca silencioso.
        if Permissions.screenGranted {
            do { try await startScreenTap(systemAudio: config.systemAudioEnabled) }
            catch {
                Log.error("Estudio: pantalla no arrancó: \(error.localizedDescription)")
                screenAvailable = false
                // Preflight dijo sí y la captura dijo no = fila de TCC
                // muerta-en-vida → el doctor la repara (candado interno
                // anti-duplicados; con el de arranque ya corrido, no-op).
                Task { @MainActor in await ScreenDoctor.checkAndRepair(razon: "pantalla no arrancó") }
            }
        } else {
            screenAvailable = false
            if Permissions.canPrompt {
                Task { @MainActor in await ScreenDoctor.checkAndRepair(razon: "sin preflight al arrancar el estudio") }
            }
        }
        startRenderLoop()
        startWatchdog()
        onStatusChange?()
        Log.info("Estudio: motor arriba (pantalla=\(screenAvailable) cámara=\(cameraAvailable) canvas=\(Int(canvasSize.width))x\(Int(canvasSize.height))@\(fps))")
    }

    func stop() async {
        guard isRunning else { return }
        isRunning = false
        renderTimer?.cancel()
        renderTimer = nil
        watchdog?.invalidate()
        watchdog = nil
        screenFrozen = false
        if let s = screenStream {
            try? await Deadline.run(seconds: 8, name: "studio stopCapture") { try await s.stopCapture() }
        }
        screenStream = nil
        screenCfg = nil
        screenRecOutput = nil
        screenAvailable = false
        stopCameraTap()
        compositor.drainPipeline()
        frames.clear()
        _ = previewGate.take()   // suelta el último IOSurface retenido
        onStatusChange?()
        Log.info("Estudio: motor abajo")
    }

    func setActiveScene(_ scene: StudioScene?) {
        sceneBox.set(scene)
    }

    /// Ajustes → Aplicar EN CALIENTE, estilo OBS: el motor NO se reinicia.
    /// Cada cambio viaja por su canal barato: fps/canvas re-agendan el render
    /// loop e `updateConfiguration` del SCStream (async, sin tirar la captura);
    /// cámara/mic se reconcilian en la cola de sesión. El viejo camino
    /// (stop() + start()) bloqueaba main peleando el lock del AVCaptureSession
    /// — la bolita de arcoíris del 6 ago.
    func applyLive(config: StudioConfig) async {
        guard isRunning else { await start(config: config); return }

        let newFPS = max(10, min(60, config.fps))
        let fpsChanged = newFPS != fps
        fps = newFPS
        fpsParaCamara = fps
        canvasOverride = config.canvasMode.size
        let newCanvas = canvasOverride ?? nativeCanvas ?? canvasSize
        let rawChanged = config.outputs.rawScreen != rawScreenWanted
        rawScreenWanted = config.outputs.rawScreen
        let canvasChanged = newCanvas != canvasSize || rawChanged
        canvasSize = newCanvas
        let audioChanged = config.systemAudioEnabled != systemAudioWanted
        systemAudioWanted = config.systemAudioEnabled

        if fpsChanged || canvasChanged { restartRenderLoop() }
        if fpsChanged || audioChanged || canvasChanged, let stream = screenStream, let cfg = screenCfg {
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
            cfg.capturesAudio = systemAudioWanted
            // El lienzo cambió ⇒ la captura se re-dimensiona con él. Sin esto,
            // bajar a 1080p seguiría trayendo buffers de 4K y el ahorro de
            // memoria (el que de verdad da margen) no llegaría nunca.
            if canvasChanged, let native = nativeCanvas {
                let cap = Self.captureSize(native: native, canvas: canvasSize,
                                           rawScreen: rawScreenWanted, rawMaxHeight: rawScreenMaxHeight)
                cfg.width = Int(cap.width)
                cfg.height = Int(cap.height)
                streamPixels = cap
            }
            do {
                try await Deadline.run(seconds: 6, name: "studio updateConfiguration") {
                    try await stream.updateConfiguration(cfg)
                }
                screenHealth.reset(audioExpected: systemAudioWanted)
            } catch {
                Log.error("Estudio: updateConfiguration falló (\(error.localizedDescription)) — reenganchando")
                restartScreenTap(reason: "ajustes en caliente")
            }
        }
        // Mic recién prendido puede necesitar permiso (broker, serializado).
        if config.micEnabled, !Permissions.micGranted {
            _ = await PermissionBroker.shared.request(.audio)
        }
        applyDeviceSelection(micEnabled: config.micEnabled)
        onStatusChange?()
        Log.info("Estudio: ajustes en caliente → \(Int(canvasSize.width))x\(Int(canvasSize.height))@\(fps) sys=\(systemAudioWanted) mic=\(config.micEnabled)")
    }

    /// Cambio de cámara/micrófono EN CALIENTE (doble clic en Fuentes/Mixer, o
    /// Ajustes → Aplicar): reconcilia los inputs de la sesión con lo elegido en
    /// AppSettings, sin parar la sesión y jamás en main.
    func applyDeviceSelection(micEnabled: Bool, forceCamera: Bool = false, forceMic: Bool = false) {
        guard cameraAvailable else { return }   // sin permiso de cámara no hay sesión viva
        let s = AppSettings.load()
        let camID = s.cameraDeviceID
        let micID = s.micDeviceID
        let micOK = micEnabled && Permissions.micGranted
        let session = cameraSession
        sessionQueue.async {
            let antes = session.inputs.compactMap { ($0 as? AVCaptureDeviceInput)?.device.uniqueID }
            session.beginConfiguration()
            Self.reconcileInputs(session, camID: camID, micID: micID, micEnabled: micOK,
                                 forceCamera: forceCamera, forceMic: forceMic)
            session.commitConfiguration()
            if !session.isRunning { session.startRunning() }
            let devs = session.inputs.compactMap { ($0 as? AVCaptureDeviceInput)?.device }
            // Se dice si de verdad CAMBIÓ algo. La versión anterior imprimía esta
            // línea igual cuando no había tocado nada, así que un no-op se leía
            // como un reenganche exitoso — 32 horas seguidas, en un caso.
            let despues = devs.map { $0.uniqueID }
            let cambio = forceCamera || forceMic || antes != despues
            Log.info("Estudio: dispositivos en caliente → "
                     + devs.map { "\($0.localizedName) [\($0.hasMediaType(.audio) ? "audio" : "video")]" }
                           .joined(separator: " + ")
                     + (cambio ? (forceCamera ? " (RE-PEGADA a la fuerza)" : "") : " (sin cambios)"))
        }
    }

    /// RE-PEGAR LA CÁMARA A LA FUERZA — lo que Daniel hacía a mano.
    ///
    /// Quita el `AVCaptureDeviceInput` de video y lo vuelve a crear, aunque sea el
    /// MISMO dispositivo. Es la única cosa que revive una ZV-E10 que sigue
    /// enumerada pero dejó de entregar frames; `applyDeviceSelection` normal no
    /// puede porque se salta el trabajo cuando el ID coincide.
    ///
    /// ⚠️ NO se hace mientras se graba, a propósito: reconfigurar los inputs de una
    /// sesión viva es justo lo que produjo el "estruendo" de v2.3, y si la cámara se
    /// congeló a mitad de toma esa toma ya está perdida — vale más avisarle a Daniel
    /// (alarma + notificación + el punto de estado en ROJO) y que él decida, que
    /// meterle mano al audio de una grabación en curso.
    func rebindCamera(reason: String) {
        guard cameraAvailable else { return }
        guard !StudioController.shared.recorder.isRecording else {
            Log.error("Estudio: NO re-pego la cámara con una toma en curso (\(reason)) — "
                      + "se avisa y Daniel decide")
            return
        }
        // LA GUARDA QUE HACE SEGURO EL FORZADO.
        //
        // `Devices.camera(id:)` cae a `AVCaptureDevice.default(for: .video)` cuando
        // la elegida no está. Con `forceCamera: true` eso sería peor que no hacer
        // nada: arrancaríamos el input bueno para pegar la "OBS Virtual Camera",
        // que entrega un cuadro fijo — y entonces el watchdog la declararía VIVA y
        // se apagaría solo. Un sensor que se auto-satisface con una imagen falsa es
        // peor que no tener sensor (el gotcha que v2.9 ya había documentado).
        //
        // Por eso la presencia se verifica AQUÍ, en el único sitio que fuerza, y no
        // en cada llamador: el watchdog, el runtime error, la interrupción y el
        // despertar del Mac quedan todos cubiertos por esta misma línea.
        let elegida = AppSettings.load().cameraDeviceID
        guard let id = elegida, AVCaptureDevice(uniqueID: id) != nil else {
            Log.error("Estudio: NO re-pego (\(reason)) — la cámara elegida no está enumerada. "
                      + "Forzar aquí pegaría la cámara equivocada (¿OBS Virtual?).")
            return
        }
        Log.info("Estudio: RE-PEGANDO la cámara — \(reason)")
        applyDeviceSelection(micEnabled: AppSettings.load().micEnabled, forceCamera: true)
    }

    /// RE-PEGAR EL MICRÓFONO A LA FUERZA — hermano de `rebindCamera`.
    ///
    /// El 26 ago el Shure MV7+ dejó de entregar buffers a media toma y no volvió
    /// solo: de ahí en adelante el guard de voz auto-detuvo cada grabación a los
    /// 20 s, correctamente y para siempre. El dispositivo seguía ahí (macOS lo
    /// listaba como entrada por defecto a 48 kHz); lo que se había caído era el
    /// input de la sesión. La cámara tiene este remedio desde el 9 ago; el
    /// micrófono nunca lo tuvo, y es la fuente que decide si una toma sirve.
    ///
    /// NO se re-pega con una toma en curso: la sesión es la MISMA que la de la
    /// cámara, y reconfigurarla a media grabación le daría un tirón a la imagen.
    /// Con la toma parada —que es cuando de verdad importa, porque si no la
    /// siguiente también nace muerta— se re-pega sin coste.
    func rebindMic(reason: String) {
        guard cameraAvailable else { return }
        guard !StudioController.shared.recorder.isRecording else {
            Log.error("Estudio: NO re-pego el micrófono con una toma en curso (\(reason))")
            return
        }
        let s = AppSettings.load()
        guard s.micEnabled, Permissions.micGranted else { return }
        // Misma guarda que la cámara: forzar sin comprobar la presencia pegaría
        // el dispositivo equivocado. Con `micDeviceID` nil vale el del sistema.
        if let id = s.micDeviceID, Devices.microphone(id: id)?.uniqueID != id {
            Log.error("Estudio: NO re-pego el micrófono (\(reason)) — el elegido no está enumerado")
            return
        }
        Log.info("Estudio: RE-PEGANDO el micrófono — \(reason)")
        applyDeviceSelection(micEnabled: true, forceMic: true)
    }

    // MARK: - pantalla (SCStream con frames + SCRecordingOutput opcional)

    private func startScreenTap(systemAudio: Bool) async throws {
        let content = try await Deadline.run(seconds: 12, name: "SCShareableContent") {
            try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }
        // LA PANTALLA LA ELIGE DANIEL (25 ago 2026, doble clic en la fuente
        // Pantalla). Antes esto era `CGMainDisplayID()` a secas: con tres
        // pantallas conectadas, grabar la que NO es la principal exigia ir a
        // Ajustes del sistema a mover cual es la principal. La cascada deja el
        // comportamiento viejo intacto cuando no hay eleccion guardada, y
        // sobrevive a desconectar el monitor elegido (cae a la principal).
        let mainID = CGMainDisplayID()
        // QUÉ PANTALLA SE ESTÁ GRABANDO, dicho en voz alta (26 ago 2026). Daniel
        // tiene TRES salidas —dos BenQ y una Kamvas, dos de ellas en espejo por
        // hardware— y hasta hoy el log no decía cuál se capturaba. "Grabé 45
        // minutos de la pantalla equivocada" era un desenlace posible y mudo.
        Log.info("Estudio: pantallas visibles = "
                 + content.displays.map { d in
                     "#\(d.displayID) \(d.width)x\(d.height)"
                       + (d.displayID == mainID ? " (principal)" : "")
                       + (d.displayID == (AppSettings.load().screenDisplayID.flatMap { UInt32($0) } ?? 0)
                          ? " ←ELEGIDA" : "")
                   }.joined(separator: " · "))
        let elegida = AppSettings.load().screenDisplayID.flatMap { UInt32($0) }
        guard let display = content.displays.first(where: { $0.displayID == elegida })
                ?? content.displays.first(where: { $0.displayID == mainID })
                ?? content.displays.first else {
            // EL MENSAJE TIENE QUE DISTINGUIR (26 ago 2026). Con la sesión
            // bloqueada macOS deniega la captura por diseño y devuelve un error
            // que se lee idéntico a un permiso revocado. Decirle a Daniel que
            // vaya a aprobar algo que ya está aprobado es mandarlo a perseguir
            // un fantasma — y fue el mismo malentendido que llevó al doctor a
            // borrarle esa noche una aprobación buena.
            if ScreenDoctor.sesionBloqueada() {
                throw NSError(domain: "SFCast", code: 4, userInfo: [NSLocalizedDescriptionKey:
                    "La sesión está bloqueada: macOS no deja capturar la pantalla hasta que "
                    + "desbloquees. El permiso está bien."])
            }
            throw NSError(domain: "SFCast", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Sin permiso de pantalla efectivo (aprueba «Grabación de pantalla» y reabre)."])
        }
        let scale = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
        })?.backingScaleFactor ?? 2.0
        let w = Int(CGFloat(display.width) * scale)
        let h = Int(CGFloat(display.height) * scale)
        nativeCanvas = CGSize(width: w, height: h)
        canvasSize = canvasOverride ?? CGSize(width: w, height: h)

        let cap = Self.captureSize(native: CGSize(width: w, height: h), canvas: canvasSize,
                                   rawScreen: rawScreenWanted, rawMaxHeight: rawScreenMaxHeight)
        streamPixels = cap
        let cfg = SCStreamConfiguration()
        cfg.width = Int(cap.width)
        cfg.height = Int(cap.height)
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        cfg.showsCursor = true
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        // 8 = máximo de SCK. Guardamos el último frame FUERA del callback (el
        // compositor lo recicla), o sea que un buffer del pool vive retenido
        // permanentemente; con 5 y el encoder cargado el pool se quedaba sin
        // sitio y SCK deja de entregar EN SILENCIO. Holgura, no lujo.
        cfg.queueDepth = 8
        cfg.capturesAudio = systemAudio
        // La ventana del Estudio lleva sharingType=.none: no hace falta filtrarla.
        let filter = SCContentFilter(display: display, excludingWindows: [])
        // delegate: SELF, jamás nil — sin delegate, `didStopWithError` no llega
        // y un stream muerto se ve idéntico a uno vivo (raíz de la congelada
        // del 25 jul: 50 min grabando el MISMO frame sin una sola línea de log).
        let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        // El output de audio se engancha SIEMPRE; `capturesAudio` decide si
        // fluye. Así el toggle "Audio del sistema" aplica en caliente en ambos
        // sentidos vía updateConfiguration (a un stream corriendo no se le
        // pueden añadir outputs).
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        try await Deadline.run(seconds: 12, name: "studio startCapture") { try await stream.startCapture() }
        screenStream = stream
        screenCfg = cfg
        screenAvailable = true
        screenFrozen = false
        screenHealth.reset(audioExpected: systemAudio)
    }

    /// A qué resolución pedirle la captura a SCK. Nunca MÁS que lo nativo (no
    /// se inventa detalle) y nunca más que el lienzo (no se paga por píxeles
    /// que el compositor va a tirar). Preserva el aspecto del display: si se
    /// deformara, el espejo y el programa dejarían de coincidir.
    /// EL RAW MANDA SOBRE LA CAPTURA; EL LIENZO SOLO MANDA SOBRE EL PROGRAMA
    /// (28 ago 2026). Cuando se está guardando `screen.mp4`, ese archivo ES la
    /// capa de pantalla que la edición va a componer después: clamparlo al
    /// lienzo del programa lo condenaba a la resolución del PROXY. Con el raw
    /// apagado no cambia nada (no se paga por píxeles que el compositor tira).
    nonisolated static func captureSize(native: CGSize, canvas: CGSize,
                                        rawScreen: Bool = false, rawMaxHeight: CGFloat = 0) -> CGSize {
        guard native.width > 1, native.height > 1, canvas.width > 1, canvas.height > 1 else { return native }
        // Techo efectivo: el lienzo, o el del raw si es mayor y el raw está vivo.
        var techo = canvas
        if rawScreen, rawMaxHeight > canvas.height, native.height > 1 {
            let k = rawMaxHeight / native.height
            techo = CGSize(width: native.width * k, height: rawMaxHeight)
        }
        let s = min(techo.width / native.width, techo.height / native.height, 1.0)
        guard s < 0.999 else { return native }
        // Pares: los codificadores y los escaladores de vídeo lo agradecen, y
        // un impar aquí produce medio píxel de corrimiento en el mapeo.
        let w = max(2, (native.width * s).rounded())
        let h = max(2, (native.height * s).rounded())
        return CGSize(width: w - w.truncatingRemainder(dividingBy: 2),
                      height: h - h.truncatingRemainder(dividingBy: 2))
    }

    /// QA (`--studiobench N --killstream`): mata el stream a mitad de grabación
    /// SIN avisar a nadie, exactamente como se murió el 25 jul. Es la única
    /// forma de probar que el watchdog lo nota y reengancha; un fix de
    /// recuperación que nunca se ejerció no es un fix, es una intención.
    func simulateStreamDeath() async {
        guard let s = screenStream else { return }
        Log.error("QA: matando el stream de pantalla a propósito")
        try? await Deadline.run(seconds: 6, name: "QA stopCapture") { try await s.stopCapture() }
    }

    /// Reintento de pantalla: si el permiso llegó DESPUÉS de abrir el Estudio
    /// (el re-toggle post-rebuild), engancha el tap sin reabrir la ventana.
    /// Lo llama el controller cada ~3s mientras la ventana está abierta.
    /// Reintentos del enganche de pantalla, CON FRENO (fix 26 ago 2026).
    ///
    /// Antes esto reintentaba cada 3 segundos para siempre. Medido en el log de
    /// Daniel: **8,193 reintentos fallidos seguidos**, del 21 ago 22:07 al 26 ago
    /// 07:04 — cinco días. Cada uno pedía `SCShareableContent` en MainActor y
    /// escribía una línea de ERROR; el `sfcast.log` llegó a 7.75 MB y las 8,193
    /// líneas idénticas sepultaron todo lo demás que ese log tenía que contar.
    ///
    /// Un órgano que reintenta para siempre no es resiliencia: es un órgano que
    /// no sabe que está fallando. Ahora la espera se dobla (3 → 6 → 12 → 24 → 60 s,
    /// con techo), el log habla cuando el número cambia de orden de magnitud, y al
    /// tercer fallo seguido el aviso SALE DE LA VENTANA hacia el humano — que es
    /// lo único que puede resolverlo (aprobar el permiso).
    private var screenRetryFails = 0
    private var nextScreenRetryAt: Double = 0
    private var screenRetryNotified = false

    func retryScreenIfNeeded() {
        guard isRunning, !screenAvailable, !retryingScreen, !restartingScreen,
              Permissions.screenGranted else { return }
        // Con la sesión bloqueada no hay nada que reintentar: la captura está
        // denegada por diseño y volverá sola al desbloquear. Insistir solo
        // llenaría el log de una falla que no lo es.
        if ScreenDoctor.sesionBloqueada() { return }
        let ahora = CACurrentMediaTime()
        guard ahora >= nextScreenRetryAt else { return }
        retryingScreen = true
        Task { @MainActor in
            do {
                try await startScreenTap(systemAudio: systemAudioWanted)
                if screenRetryFails > 0 {
                    Log.info("Estudio: pantalla enganchada tras \(screenRetryFails) intento(s)")
                } else {
                    Log.info("Estudio: pantalla enganchada en reintento")
                }
                screenRetryFails = 0
                nextScreenRetryAt = 0
                screenRetryNotified = false
                onAlertResolved?("pantalla")   // la causa murió: el banner también
                onStatusChange?()
            } catch {
                screenRetryFails += 1
                let espera = min(60.0, 3.0 * pow(2.0, Double(screenRetryFails - 1)))
                nextScreenRetryAt = CACurrentMediaTime() + espera
                // Se habla en 1, 2, 4, 8, 16… y nunca más: el ruido de 8,193
                // líneas idénticas es lo que hizo ilegible el log de agosto.
                if screenRetryFails & (screenRetryFails - 1) == 0 {
                    Log.error("Estudio: reintento de pantalla falló (\(screenRetryFails)): "
                              + "\(error.localizedDescription) — próximo en \(Int(espera))s")
                }
                if screenRetryFails >= 3, !screenRetryNotified {
                    screenRetryNotified = true
                    notify("SFCast — SIN PANTALLA",
                           "No puedo capturar la pantalla. Aprueba «Grabación de pantalla» en Ajustes.")
                    onAlert?("No consigo capturar la pantalla. Aprueba «Grabación de pantalla» "
                             + "en Ajustes del sistema y reabre SFCast.", true, "pantalla")
                }
            }
            retryingScreen = false
        }
    }

    /// RAW de pantalla (salida A): SCRecordingOutput colgado del MISMO stream de
    /// preview — la captura ya corre, solo se le añade el writer a archivo.
    func attachScreenRecording(url: URL) throws {
        guard let stream = screenStream else {
            throw NSError(domain: "SFCast", code: 2, userInfo: [NSLocalizedDescriptionKey: "Sin stream de pantalla vivo"])
        }
        let recCfg = SCRecordingOutputConfiguration()
        recCfg.outputURL = url
        recCfg.outputFileType = .mp4
        recCfg.videoCodecType = .hevc
        let del = SegmentDelegate()
        let rec = SCRecordingOutput(configuration: recCfg, delegate: del)
        armRawStarts(camera: false, screen: true)
        try stream.addRecordingOutput(rec)
        screenRecOutput = rec
        screenRecDelegate = del
    }

    func detachScreenRecording() async {
        guard let stream = screenStream, let rec = screenRecOutput else { return }
        // Si el stream ya murió, quitarle el output tira "parámetro no válido":
        // es ruido esperado, no un fallo nuevo. El writer cierra igual.
        do { try stream.removeRecordingOutput(rec) }
        catch {
            if screenAvailable {
                Log.error("Estudio: removeRecordingOutput falló: \(error.localizedDescription)")
            }
        }
        // Esperar el didFinish del writer (deadline — invariante #5).
        if let del = screenRecDelegate {
            for _ in 0..<100 where !del.finished {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if !del.finished { Log.error("Estudio: raw de pantalla no confirmó cierre en 10s (suele quedar OK)") }
        }
        screenRecOutput = nil
        screenRecDelegate = nil
    }

    // MARK: - cámara (VideoDataOutput → compositor; MovieFileOutput → raw)

    private func startCameraTap(micEnabled: Bool) {
        // Los outputs se crean UNA vez (los delegates apuntan a las colas de
        // captura); añadirlos a la sesión es cirugía y va a sessionQueue.
        if cameraVideoOut == nil {
            let out = AVCaptureVideoDataOutput()
            // ⭐ NV12, NO BGRA (27 ago 2026). Esto es lo que separaba a SFCast de
            // OBS con la MISMA camara: OBS recibia 30.00 fps y nosotros 25.
            //
            // Pedir `32BGRA` obliga a AVFoundation a CONVERTIR cada frame desde
            // el formato nativo del dispositivo. A 1920x1080 son 8.3 MB por
            // cuadro (4 bytes/pixel) contra 3.1 MB de NV12: 249 MB/s de
            // conversion y ancho de banda a 30 fps, por una imagen que acto
            // seguido se entrega a CoreImage, que traga NV12 sin despeinarse.
            // La cadena no sostenia el ritmo y entregaba 25 — y como la API
            // reportaba "30 fps" tan campante, tres cacerias del "lag" pasaron
            // de largo por aqui.
            //
            // El buffer de camara NUNCA se lee byte a byte (va directo a
            // `frames.set` y de ahi a CIImage), asi que el subespacio de color
            // es indiferente para todo lo demas.
            let deseado = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange   // '420v' = NV12
            let soportados = out.availableVideoPixelFormatTypes
            let elegidoPF = soportados.contains(deseado) ? deseado : kCVPixelFormatType_32BGRA
            if elegidoPF != deseado {
                Log.error("Estudio: la camara no ofrece NV12 — me quedo en BGRA (puede costar fps)")
            }
            out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: elegidoPF]
            out.alwaysDiscardsLateVideoFrames = true
            // Cola PROPIA, no la compartida con la pantalla — ver camVideoQueue.
            out.setSampleBufferDelegate(self, queue: camVideoQueue)
            cameraVideoOut = out
        }
        if cameraAudioOut == nil {
            let out = AVCaptureAudioDataOutput()
            out.setSampleBufferDelegate(self, queue: audioQueue)
            cameraAudioOut = out
        }
        // El MovieFileOutput se añade AQUÍ (antes de startRunning), NO al grabar:
        // agregar un output a una sesión corriendo reconfigura el grafo de audio
        // y ese pop quedaba GRABADO al inicio (el "estruendo" — feedback v2.3).
        if cameraMovieOut == nil { cameraMovieOut = AVCaptureMovieFileOutput() }

        let session = cameraSession
        let outs = [cameraVideoOut, cameraAudioOut, cameraMovieOut].compactMap { $0 }
        let s = AppSettings.load()
        let camID = s.cameraDeviceID
        let micID = s.micDeviceID
        // Mic en la MISMA sesión: va al raw de cámara (.mov con voz, estilo
        // Screen Studio) y al programa. Solo con permiso YA otorgado (broker).
        let micOK = micEnabled && Permissions.micGranted
        sessionQueue.async {
            session.beginConfiguration()
            session.sessionPreset = .high
            Self.reconcileInputs(session, camID: camID, micID: micID, micEnabled: micOK)
            for out in outs where !session.outputs.contains(out) && session.canAddOutput(out) {
                session.addOutput(out)
            }
            session.commitConfiguration()
            // Qué dispositivos quedaron DE VERDAD en la sesión. Sin esto no hay
            // cómo saber si el audio viene del Shure o del capturador de video.
            let devs = session.inputs.compactMap { ($0 as? AVCaptureDeviceInput)?.device }
            Log.info("Estudio: sesión de cámara → "
                     + devs.map { "\($0.localizedName) [\($0.hasMediaType(.audio) ? "audio" : "video")]" }
                           .joined(separator: " + "))
            // ⚠️ ¿Quedó la cámara que Daniel ELIGIÓ? `Devices.camera(id:)` cae a
            // `AVCaptureDevice.default` cuando la suya no está conectada, y eso
            // es silencioso y caro: con la ZV-E10 apagada engancha la "OBS
            // Virtual Camera", que entrega un CUADRO FIJO. Se graba una hora
            // creyendo que hay cámara. Aquí se dice, y en voz alta.
            // A CUÁNTOS FPS ENTREGA LA CÁMARA, dicho al enganchar (26 ago 2026).
            // El latido decía `cam:25fps` toda la noche y no había forma de saber
            // si eso lo pedía SFCast o lo mandaba la cámara. No lo pide nadie:
            // ⚠️ AQUI VIVIA UNA MENTIRA QUE COSTO MEDIO DIA: "25 fps es la ZV-E10
            // en PAL, se arregla en la camara". FALSO, y medido el 27 ago: la
            // camara estaba en NTSC, y OBS —misma camara, mismo cable, misma
            // Cam Link— recibia 30.00 fps de contenido unico mientras nosotros
            // recibiamos 25. El culpable era NUESTRO (pedir BGRA, ver abajo).
            // Un comentario que afirma una causa sin medirla manda al siguiente
            // que lo lea a cambiarle los menus a la camara, que fue justo lo que
            // estuvo a punto de pasar.
            //
            // Un lienzo a 30 con una fuente a 25 significa que uno de cada seis
            // frames del programa repite cara. No es un bug, pero es una decisión
            // que Daniel merece tomar sabiendo el número.
            // LOS FPS DEL LIENZO, PEDIDOS POR EL RANGO MÁS CERCANO (26 ago 2026).
            //
            // Nadie se los pedía nunca: `sessionPreset = .high` acepta lo que el
            // dispositivo traiga puesto, y la Cam Link venía a 25. Con un lienzo a
            // 30 eso son 5 de cada 30 frames del programa repitiendo cara — el 17%
            // del movimiento de la burbuja, regalado por no preguntar.
            //
            // ⚠️ Y NO SE COMPARA POR IGUALDAD. La primera versión pedía un rango
            // que CONTUVIERA 30.0 exacto y no encontraba ninguno, aunque el log
            // imprimía "30-30": ese rango es **29.97** (NTSC, 30000/1001), y
            // 30.0 no cabe en [29.97, 29.97]. Una comparación de flotantes contra
            // un número redondo, en un dominio donde los números redondos casi no
            // existen. Se elige el rango más cercano dentro de una tolerancia y se
            // usa SU `minFrameDuration`, que es el CMTime exacto del dispositivo.
            //
            // Solo se toca la CADENCIA, nunca el formato: cambiar de formato
            // cambiaría la resolución, y eso no lo decide un watchdog.
            if let cam = devs.first(where: { $0.hasMediaType(.video) }) {
                let objetivo = Double(self.fpsParaCamara)
                let actualAntes = 1.0 / max(CMTimeGetSeconds(cam.activeVideoMinFrameDuration), 1.0 / 1000)

                // ⭐ SE ELIGE EL **FORMATO**, NO SOLO LA CADENCIA (27 ago 2026).
                //
                // La versión anterior sólo tocaba `activeVideoMin/MaxFrameDuration`
                // y dejaba el formato en manos de `sessionPreset = .high`. Con eso
                // la API respondía "30 fps" y la Cam Link seguía entregando 25:
                // en un dispositivo UVC la tasa es parte del formato NEGOCIADO,
                // y la duración de cuadro sólo puede TIRAR frames, nunca fabricar
                // los que el stream no trae. El log decía 30, el contador decía 25,
                // y la cara de Daniel se repetía 5 de cada 30 cuadros.
                //
                // Daniel lo cazó con el dato que ningún log tenía: *"¿por qué es
                // diferente a OBS? allá funciona con la misma config"*. OBS elige
                // `activeFormat` explícitamente — resolución Y tasa juntas. Eso
                // pasa la sesión a `.inputPriority`, que es justo lo que hace falta.
                //
                // El miedo del comentario viejo ("cambiar de formato cambiaría la
                // resolución") era legítimo y se respeta: sólo se consideran
                // formatos con LAS MISMAS DIMENSIONES que el activo. Si ninguno de
                // ésos ofrece la tasa, no se toca nada y se dice por qué.
                let dimAct = CMVideoFormatDescriptionGetDimensions(cam.activeFormat.formatDescription)
                func mejorRango(_ f: AVCaptureDevice.Format) -> AVFrameRateRange? {
                    // Tolerancia 1.5 porque los rangos reales son 29.97/59.94 (NTSC),
                    // no números redondos: comparar por igualdad no encuentra nada.
                    f.videoSupportedFrameRateRanges
                        .filter { abs($0.maxFrameRate - objetivo) <= 1.5 }
                        .max(by: { $0.maxFrameRate < $1.maxFrameRate })
                }
                // DIAGNÓSTICO: qué ofrece de verdad el dispositivo. Sin esto la
                // discusión "la cámara no puede" vs "no se lo pedimos bien" no
                // se puede cerrar con datos.
                func fourCC(_ f: AVCaptureDevice.Format) -> String {
                    let c = CMFormatDescriptionGetMediaSubType(f.formatDescription)
                    let b = [UInt8((c >> 24) & 255), UInt8((c >> 16) & 255),
                             UInt8((c >> 8) & 255), UInt8(c & 255)]
                    return String(bytes: b, encoding: .ascii) ?? "????"
                }
                let inventario = cam.formats.enumerated().map { (i, f) -> String in
                    let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
                    let rr = f.videoSupportedFrameRateRanges
                        .map { String(format: "%.2f", $0.maxFrameRate) }.joined(separator: "/")
                    let act = (f == cam.activeFormat) ? "◀ACTIVO" : ""
                    return "[\(i)]\(fourCC(f)) \(d.width)x\(d.height)@\(rr)\(act)"
                }.joined(separator: " · ")
                Log.info("Estudio: formatos de «\(cam.localizedName)» → \(inventario)")

                let candidatos = cam.formats.filter {
                    let d = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                    return d.width == dimAct.width && d.height == dimAct.height
                }
                // ⭐ ENTRE FORMATOS EMPATADOS, GANA EL QUE EL DISPOSITIVO LISTA
                // PRIMERO. La Cam Link presenta cada resolución DOS veces —
                // `yuvs` (4:2:2 empaquetado, lo que de verdad sale por USB) y
                // `420v` (4:2:0, que el driver SINTETIZA)— y ambas anuncian los
                // mismos rangos 60/50/30/25. `max(by:)` con empates devuelve el
                // ÚLTIMO, así que caíamos siempre en el sintetizado, que no
                // sostiene el ritmo: la sonda de PTS medía 40.000 ms clavados
                // (25.00 fps de metrónomo) mientras la API juraba 30.
                // El orden de `device.formats` es el del descriptor USB, y ahí
                // el nativo va primero.
                let elegido = candidatos
                    .compactMap { f in mejorRango(f).map { (f, $0) } }
                    .max(by: { a, b in
                        if a.1.maxFrameRate != b.1.maxFrameRate { return a.1.maxFrameRate < b.1.maxFrameRate }
                        // empate en tasa: el de índice MENOR gana
                        let ia = cam.formats.firstIndex(of: a.0) ?? .max
                        let ib = cam.formats.firstIndex(of: b.0) ?? .max
                        return ia > ib
                    })

                if let (formato, r) = elegido {
                    do {
                        try cam.lockForConfiguration()
                        if formato != cam.activeFormat {
                            cam.activeFormat = formato      // ⇒ la sesión pasa a .inputPriority
                        }
                        cam.activeVideoMinFrameDuration = r.minFrameDuration
                        cam.activeVideoMaxFrameDuration = r.minFrameDuration
                        cam.unlockForConfiguration()
                        Log.info(String(format: "Estudio: FORMATO fijado %dx%d @ %.2f fps (venia a %.2f)",
                                        dimAct.width, dimAct.height, r.maxFrameRate, actualAntes))
                    } catch {
                        Log.error("Estudio: no pude fijar el formato de la camara: \(error.localizedDescription)")
                    }
                } else {
                    Log.error(String(format: "Estudio: NINGUN formato de %dx%d ofrece ~%.0f fps — se queda a %.2f. "
                                     + "Revisa la salida HDMI de la camara.",
                                     dimAct.width, dimAct.height, objetivo, actualAntes))
                }
            }
            if let cam = devs.first(where: { $0.hasMediaType(.video) }) {
                let f = cam.activeFormat
                let rangos = f.videoSupportedFrameRateRanges
                    .map { String(format: "%.0f-%.0f", $0.minFrameRate, $0.maxFrameRate) }
                    .joined(separator: ",")
                let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
                let actual = 1.0 / max(CMTimeGetSeconds(cam.activeVideoMinFrameDuration), 1.0 / 1000)
                Log.info(String(format: "Estudio: la cámara entrega %dx%d a %.0f fps (rangos del formato: %@)",
                                d.width, d.height, actual.isFinite ? actual : 0, rangos))
            }
            let resuelta = devs.first(where: { $0.hasMediaType(.video) })
            if let camID, let resuelta, resuelta.uniqueID != camID {
                Log.error("Estudio: LA CÁMARA NO ES LA ELEGIDA — quedó «\(resuelta.localizedName)». "
                          + "La configurada no está conectada.")
                Task { @MainActor in
                    self.onAlert?("Ojo: estás con «\(resuelta.localizedName)», no con tu cámara de "
                                  + "siempre. ¿Está encendida y conectada?", true, "camara")
                }
            }
            if !session.isRunning { session.startRunning() }
        }
        // Optimista: si al final no entrega frames, el comparador starved lo
        // delata en la UI (jamás en silencio).
        cameraAvailable = true
        observeCameraSession()
    }

    /// LOS AVISOS QUE macOS YA MANDABA Y NADIE ESCUCHABA.
    ///
    /// AVFoundation publica `AVCaptureSessionRuntimeError` cuando la sesión se
    /// rompe (USB reseteado, dispositivo perdido) y `WasInterrupted` /
    /// `InterruptionEnded` cuando otra app se lleva la cámara o el hardware se
    /// suspende. Son EXACTAMENTE las señales de este bug, publicadas por el
    /// sistema, gratis — y esta app no observaba ninguna. Tampoco observaba el
    /// despertar del Mac, que es el disparador real: el log muestra la cámara
    /// muriendo de noche (20:13, 20:52, 21:09, 21:17, 21:18) y siguiendo muerta
    /// 9-10 h hasta la mañana siguiente.
    ///
    /// Con esto el reenganche deja de depender de un sondeo de 30 s y pasa a ser
    /// una reacción al evento. El sondeo se queda como red por si el evento no
    /// llega (una cámara que se apaga sola no siempre genera notificación).
    private func observeCameraSession() {
        guard !cameraObserversWired else { return }
        cameraObserversWired = true
        let nc = NotificationCenter.default
        let session = cameraSession

        nc.addObserver(forName: .AVCaptureSessionRuntimeError, object: session,
                       queue: .main) { [weak self] note in
            let err = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            Log.error("Estudio: AVCaptureSession RUNTIME ERROR — \(err?.localizedDescription ?? "?")")
            self?.rebindCamera(reason: "runtime error de la sesión")
        }
        // OJO: `AVCaptureSessionInterruptionReasonKey` es solo de iOS (no compila en
        // macOS), así que aquí la razón no viaja. Basta con saber QUE pasó.
        nc.addObserver(forName: .AVCaptureSessionWasInterrupted, object: session,
                       queue: .main) { _ in
            Log.error("Estudio: la sesión de cámara fue INTERRUMPIDA — ¿otra app tomó la cámara, "
                      + "o el hardware se suspendió?")
        }
        nc.addObserver(forName: .AVCaptureSessionInterruptionEnded, object: session,
                       queue: .main) { [weak self] _ in
            Log.info("Estudio: terminó la interrupción de la cámara — re-pegando")
            self?.rebindCamera(reason: "terminó la interrupción")
        }
        // El Mac despertando: el disparador del "vuelvo al día siguiente y está
        // congelada". Se re-pega con un respiro para que el USB termine de subir.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Log.info("Estudio: el Mac despertó — re-pegando la cámara en 3s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                self?.rebindCamera(reason: "el Mac despertó")
            }
        }
        Log.info("Estudio: observadores de la sesión de cámara enganchados "
                 + "(runtime error · interrupción · despertar del Mac)")
    }

    /// Reconcilia los INPUTS de la sesión con lo pedido: deja EXACTAMENTE la
    /// cámara elegida y el mic elegido (o ninguno si está apagado). El código
    /// viejo solo AGREGABA si faltaba — cambiar de cámara en Ajustes no
    /// aplicaba de verdad hasta relanzar la app. Corre SIEMPRE en sessionQueue.
    nonisolated private static func reconcileInputs(_ session: AVCaptureSession,
                                                    camID: String?, micID: String?,
                                                    micEnabled: Bool,
                                                    forceCamera: Bool = false,
                                                    forceMic: Bool = false) {
        func inputs() -> [AVCaptureDeviceInput] {
            session.inputs.compactMap { $0 as? AVCaptureDeviceInput }
        }
        let wantCam = Devices.camera(id: camID)
        // `forceCamera` existe por un no-op que costó semanas de cámara congelada.
        //
        // Sin él, la condición de abajo solo quita el input cuando el ID pedido es
        // DISTINTO del pegado. Y el reintento del watchdog pide SIEMPRE la misma
        // cámara — así que cuando la ZV-E10 sigue enumerada pero dejó de entregar
        // frames (se apagó sola, o el USB se suspendió de noche), el reconcile no
        // quitaba nada, el `addInput` se saltaba porque ya había un input de video,
        // `session.isRunning` seguía diciendo true, y `applyDeviceSelection`
        // terminaba imprimiendo "dispositivos en caliente → ZV-E10 [video]" sin
        // haber tocado NADA. El remedio era un no-op exactamente en el caso para el
        // que se escribió.
        //
        // Medido en el log: se congela de noche (20:13, 20:52, 21:09, 21:17, 21:18)
        // y sigue muerta 9-10 h hasta la mañana; una vez reportó 115,087.9 s (32 h)
        // sin imagen nueva. El reintento corría cada 30 s todo ese tiempo, en vano.
        //
        // Por eso Daniel lo arreglaba a mano cambiando de cámara y volviendo: ESO
        // sí rompe la comparación de identidad y fuerza un `AVCaptureDeviceInput`
        // nuevo. `forceCamera` hace justo eso, sin que él tenga que tocar nada.
        for i in inputs() where i.device.hasMediaType(.video)
            && (forceCamera || i.device.uniqueID != wantCam?.uniqueID) {
            session.removeInput(i)
        }
        if let cam = wantCam,
           !inputs().contains(where: { $0.device.hasMediaType(.video) }),
           let input = try? AVCaptureDeviceInput(device: cam),
           session.canAddInput(input) {
            session.addInput(input)
        }
        let wantMic = micEnabled ? Devices.microphone(id: micID) : nil
        // `forceMic` es el hermano de `forceCamera`, y existe por la MISMA razón
        // (26 ago 2026). Esta condición solo quitaba el input de audio cuando el
        // ID pedido era DISTINTO del pegado — así que re-pegar el mismo Shure era
        // un no-op perfecto, exactamente en el único caso donde hace falta:
        // el micro sigue enumerado, sigue siendo el elegido, y ha dejado de
        // entregar buffers.
        //
        // Medido esa noche: el Shure entregó 39,363 muestras en la toma 1, 8,050
        // en la toma 2 (murió a media toma) y CERO a partir de ahí. El guard de
        // voz hizo bien su trabajo y auto-detuvo la toma 3 a los 20 s… y la 4, y
        // la 5. Nadie volvía a pegar el micro porque nadie podía.
        for i in inputs() where i.device.hasMediaType(.audio) && !i.device.hasMediaType(.video)
            && (forceMic || i.device.uniqueID != wantMic?.uniqueID) {
            session.removeInput(i)
        }
        if let mic = wantMic,
           !inputs().contains(where: { $0.device.hasMediaType(.audio) }),
           let input = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(input) {
            session.addInput(input)
        }
    }

    private func stopCameraTap() {
        let session = cameraSession
        sessionQueue.async { if session.isRunning { session.stopRunning() } }
        cameraAvailable = false
    }

    /// Bitrate EXPLÍCITO del raw de cámara. Sin esto, el MovieFileOutput con
    /// preset `.high` escribe a lo que le da la gana (con una cámara buena, ~30
    /// Mbps): era el segundo tragón de disco de la sesión del 25 jul.
    func setCameraRawBitrate(kbps: Int) {
        guard let out = cameraMovieOut,
              let conn = out.connection(with: .video) else { return }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: kbps * 1000,
                AVVideoMaxKeyFrameIntervalDurationKey: 2.0,
            ],
        ]
        out.setOutputSettings(settings, for: conn)
        Log.info("Estudio: raw de cámara a \(kbps) kbps HEVC")
    }

    /// RAW de cámara (salida A): .mov con video+mic, patrón camOnly probado.
    /// El output YA vive en la sesión desde el arranque — aquí solo se escribe
    /// (cero reconfiguración del grafo = cero pop).
    func startCameraMovie(url: URL) {
        guard cameraAvailable, let out = cameraMovieOut, !out.isRecording else { return }
        let del = CamFileDelegate(label: "Estudio raw de cámara")
        cameraMovieDelegate = del
        armRawStarts(camera: true, screen: false)
        out.startRecording(to: url, recordingDelegate: del)
    }

    /// Instante host en que arrancó `camera.mov`, RECONSTRUIDO al cerrarlo:
    /// `instanteDelStop − recordedDuration`. Es el único camino exacto que da
    /// AVFoundation. Los otros dos se midieron el 28 ago y fallan: el instante
    /// de la LLAMADA a `startRecording` se adelanta 52 frames (la apertura del
    /// archivo es asíncrona) y `didStartRecordingTo` llega 6 frames TARDE
    /// (el writer ya venía guardando muestras cuando avisa).
    /// Instante host EXACTO en que se pidió detener `camera.mov`. El arranque
    /// del archivo se reconstruye como `camRawStopHost − duraciónRealDelArchivo`.
    /// Los otros tres caminos se midieron el 28 ago y fallan: la LLAMADA a
    /// `startRecording` se adelanta ~52 frames (la apertura es asíncrona),
    /// `didStartRecordingTo` llega ~6 frames tarde, y `recordedDuration` cuenta
    /// desde la llamada (~48 frames de más).
    private(set) var camRawStopHost: Double?

    func stopCameraMovie() async {
        guard let out = cameraMovieOut, out.isRecording else { return }
        // El instante del STOP es el ancla: el arranque se reconstruye después
        // restándole la duración REAL del archivo (la que trae el contenedor,
        // no `recordedDuration` — esa cuenta desde la LLAMADA a startRecording e
        // ignora el ~1.6 s de cabeza que AVFoundation descarta mientras abre).
        camRawStopHost = CACurrentMediaTime()
        out.stopRecording()
        if let del = cameraMovieDelegate {
            let deadline = Date().addingTimeInterval(10)
            while !del.finished && Date() < deadline {
                try? await Task.sleep(nanoseconds: 60_000_000)
            }
            if !del.finished { Log.error("Estudio: raw de cámara no confirmó cierre en 10s (suele quedar OK)") }
        }
        cameraMovieDelegate = nil
    }

    // MARK: - render loop (el corazón del compositor)

    /// El timer captura fps y canvas al crearse: re-crearlo es la forma barata
    /// (e instantánea) de aplicar un cambio de fps/canvas sin tocar la captura.
    private func restartRenderLoop() {
        renderTimer?.cancel()
        renderTimer = nil
        // El frame en vuelo pertenece al lienzo VIEJO: soltarlo antes de
        // re-armar, o quedaría un buffer del pool anterior retenido para
        // siempre (y con el tamaño equivocado).
        compositor.drainPipeline()
        startRenderLoop()
    }

    private func startRenderLoop() {
        let timer = DispatchSource.makeTimerSource(queue: renderQueue)
        governor.reset(target: fps, now: CACurrentMediaTime())
        cadence.reset()
        timer.schedule(deadline: .now(), repeating: .init(1.0 / Double(fps)), leeway: .milliseconds(3))
        let comp = compositor
        let frames = frames
        let scenes = sceneBox
        let sink = sink
        let canvas = canvasSize
        let preview = previewGate
        let clock = programClock
        let gov = governor
        let prof = profile
        let cad = cadence
        let targetFPS = fps
        // QA: ahoga el loop a propósito para ejercer el governor (--chokems).
        let chokeNs = UInt32(max(0, StudioRecTest.chokeMs)) * 1000
        timer.setEventHandler { [weak self] in
            guard let scene = scenes.get() else { return }
            // EL INSTANTE SE TOMA AQUÍ, ANTES de componer. Si se tomara después,
            // el tiempo que tarde el compositor se sumaría al desfase de audio:
            // el error crecería justo cuando la Mac va peor. Ver ProgramClock.
            let hostNow = CMClockGetTime(CMClockGetHostTimeClock())
            let t = CACurrentMediaTime()
            let tStart = t
            if chokeNs > 0 { usleep(chokeNs) }
            var starved: Set<StudioSourceKind> = []
            var stale: Set<StudioSourceKind> = []
            // CANALIZADO: lanza el render de este tick y recoge el del anterior
            // (que la GPU pintó mientras tanto). Lo que sale es del tick previo
            // y trae SU hostTime — por eso el timestamp viaja pegado al buffer.
            guard let listo = comp.composePipelined(scene: scene, canvas: canvas, t: t,
                                                    hostNow: hostNow, frames: frames,
                                                    starved: &starved,
                                                    stale: &stale) else { return }
            let pb = listo.buffer
            let tCompose = CACurrentMediaTime()
            // preview → main por la COMPUERTA: un solo hop en vuelo, siempre el
            // frame más nuevo. Si main va atrás, aquí se TIRAN frames de preview
            // (gratis) en vez de apilarlos — el apilado era el "1 fps al minuto
            // 15" del 6 ago. La grabación va aparte, abajo, y no se entera.
            if let surface = CVPixelBufferGetIOSurface(pb)?.takeUnretainedValue() {
                let s = unsafeBitCast(surface, to: IOSurface.self)
                if preview.offer(s) {
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        if let latest = self.previewGate.take() {
                            self.onPreviewSurface?(latest)
                        }
                        self.updateStarved(starved, stale: stale)
                    }
                }
            }
            let tPreview = CACurrentMediaTime()
            // grabación del programa (salida B) — best-effort, jamás bloquea.
            // La fuente crítica del lip-sync es la CÁMARA (es la cara que se
            // mira); si no hay, la pantalla. Se usa la de la cámara aunque la
            // escena de este instante no la muestre: así un cambio de escena no
            // mueve el reloj y no se oye ningún ajuste al cortar.
            if let s = sink.get() {
                let lat = frames.latency(.camera) ?? frames.latency(.screen)
                // `listo.hostTime` = el instante del tick en que se LANZÓ este
                // frame, no el de ahora. Usar `hostNow` aquí metería el frame de
                // latencia del pipeline como desfase de audio — justo lo que
                // acabamos de matar.
                //
                // Y si el timer perdió disparos, el guardián devuelve TAMBIÉN
                // los timestamps que faltan: el mismo contenido, sin huecos en
                // la cadencia. Un mp4 de 30 fps constantes es lo que el editor
                // quiere; los saltos de 750 ms del 9 ago eran justo esto.
                for ts in cad.timestamps(for: listo.hostTime, fps: targetFPS) {
                    s.appendVideo(pb, hostTime: clock.stamp(hostNow: ts, target: lat))
                }
            }
            let tEncode = CACurrentMediaTime()
            prof.add(compose: (tCompose - tStart) * 1000,
                     preview: (tPreview - tCompose) * 1000,
                     encode: (tEncode - tPreview) * 1000,
                     total: (tEncode - tStart) * 1000)
            // GOVERNOR: si la Mac no sostiene la cadencia pedida, se le pide
            // menos — pero REGULAR. Re-agendar el mismo timer es barato y no
            // toca la captura ni el writer.
            if let nuevo = gov.frameComposed(now: t, target: targetFPS) {
                timer.schedule(deadline: .now(), repeating: .init(1.0 / Double(nuevo)),
                               leeway: .milliseconds(3))
                Log.info("Estudio: compongo a \(nuevo) fps (pedidos \(targetFPS)) para darle aire a la "
                         + "GPU — el ARCHIVO sigue saliendo a \(targetFPS) constantes (frames rellenados)")
                DispatchQueue.main.async { [weak self] in self?.onCadenceChange?(nuevo, targetFPS) }
            }
        }
        timer.resume()
        renderTimer = timer
    }

    private func updateStarved(_ s: Set<StudioSourceKind>, stale: Set<StudioSourceKind>) {
        if s != starvedSources {
            starvedSources = s
            onStatusChange?()
        }
    }

    // MARK: - watchdog del stream (el comparador honesto de la congelada)

    /// Corre 1x/s mientras el motor vive. NO mira la imagen: mira si el stream
    /// habla. Sin esto, un SCStream muerto se ve exactamente igual que uno vivo
    /// porque el compositor sigue pintando el último frame — 50 minutos de
    /// grabación congelada el 25 jul sin una sola línea en el log.
    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkStreamHealth()
                self?.checkCameraHealth()
                self?.checkMicHealth()
            }
        }
    }

    /// El comparador de la CÁMARA. `frames.age` ya existía como sensor; lo que
    /// faltaba era que alguien lo MIRARA y avisara: un frame viejo se compone
    /// igual de bien que uno nuevo, así que una cámara muerta produce un video
    /// impecable de una foto fija.
    private func checkCameraHealth() {
        guard isRunning, cameraAvailable else { return }
        // UNA CÁMARA QUE NUNCA ENTREGÓ UN FRAME TAMBIÉN ESTÁ MUERTA.
        //
        // Antes esto era `guard let age = ... else { return }`: si `stamps[.camera]`
        // nunca se llenó —porque la cámara no dio ni un frame desde que arrancó la
        // sesión— el watchdog se iba por la puerta de atrás y no volvía a mirar
        // NUNCA. Cero alarma, cero reintento, cero registro. Es el caso exacto de la
        // sesión hpa3ky02t5ss: 3:52 de una foto con `cam:0fps` desde el segundo 0.
        //
        // Un sensor que solo sabe evaluar lo que ya funcionó una vez no es un sensor.
        let age = frames.age(.camera) ?? (CACurrentMediaTime() - startedRunningAt)
        let dead = age > Self.deadAfter
        if dead != cameraFrozen {
            cameraFrozen = dead
            onStatusChange?()
            onSourceFrozen?("camera", dead, "sin imagen nueva (¿se apagó sola? ¿cable USB?)")
            if dead {
                Log.error(String(format: "Estudio: CÁMARA CONGELADA — %.1fs sin imagen nueva "
                                 + "(¿se apagó sola? ¿cable USB?)", age))
                onAlert?("La cámara dejó de dar imagen: se está grabando su último frame congelado.", true, "camara")
                if StudioController.shared.recorder.isRecording
                    || RecordingController.shared.state != .idle {
                    notify("SFCast — LA CÁMARA SE APAGÓ",
                           "Llevas grabando con la imagen CONGELADA. Revisa la cámara "
                           + "(las Sony se apagan solas).")
                    Log.error("Estudio: NOTIFICACIÓN enviada (cámara congelada grabando)")
                }
            } else {
                Log.info("Estudio: cámara viva de nuevo")
                onAlertResolved?("camara")     // se curó: el banner se va solo
            }
        }
        // Mientras siga muerta, reintentar — pero SOLO si la cámara ELEGIDA
        // volvió a aparecer en el sistema.
        //
        // ⚠️ Reconciliar a ciegas es peor que no hacer nada: `Devices.camera(id:)`
        // cae a `AVCaptureDevice.default` cuando la elegida no está, así que con
        // la ZV-E10 apagada enganchaba la "OBS Virtual Camera" — que entrega un
        // cuadro fijo. El watchdog entonces la declaraba VIVA y se apagaba solo:
        // un sensor que se auto-satisface con una imagen falsa es peor que no
        // tener sensor. (Es el gotcha que v2.9 ya había documentado, y este
        // reintento lo estaba disparando cada 10 s.)
        if dead {
            let now = CACurrentMediaTime()
            if now > cameraRetryAt {
                cameraRetryAt = now + 30
                let elegida = AppSettings.load().cameraDeviceID
                let presente = elegida.flatMap { AVCaptureDevice(uniqueID: $0) } != nil
                if presente {
                    // FUERZA. Antes se llamaba `applyDeviceSelection` normal, que
                    // se salta todo cuando el ID coincide — o sea que este reintento
                    // era un no-op cada 30 s, para siempre. Ahora re-pega de verdad.
                    Log.info("Estudio: la cámara elegida sigue enumerada pero no entrega "
                             + "imagen — RE-PEGÁNDOLA")
                    rebindCamera(reason: "watchdog: \(Int(age))s sin imagen")
                }
            }
        }
    }

    /// EL WATCHDOG DEL MICRÓFONO (26 ago 2026). La cámara tiene el suyo desde el
    /// 9 ago; el micrófono no tenía ninguno, y es la fuente que decide si una
    /// toma sirve para algo: una grabación sin imagen se salva con B-roll, una
    /// sin voz no se salva.
    ///
    /// El guard de voz (v3.3) ya avisaba y hasta detenía la toma — pero solo
    /// SABE, no CURA. Esa noche el Shure murió en la toma 2 y el guard hizo lo
    /// suyo en la 3, la 4 y la 5, cada vez a los 20 s, para siempre. Un sensor
    /// sin actuador acaba siendo un sensor que se ignora.
    private func checkMicHealth() {
        guard isRunning, AppSettings.load().micEnabled, Permissions.micGranted else { return }
        let age = levels.micAge()
        let dead = age > Self.deadAfter
        if dead != micDead {
            micDead = dead
            if dead {
                Log.error(String(format: "Estudio: MICRÓFONO MUDO — %.1fs sin una muestra", age))
                onAlert?("El micrófono dejó de entregar audio. Si estás grabando, esta toma va sin voz.", true, "microfono")
                if StudioController.shared.recorder.isRecording {
                    notify("SFCast — EL MICRÓFONO SE CAYÓ", "Llevas grabando SIN VOZ. Revisa el Shure.")
                }
            } else {
                Log.info("Estudio: micrófono vivo de nuevo")
                onAlertResolved?("microfono")
            }
            onStatusChange?()
        }
        if dead {
            let now = CACurrentMediaTime()
            if now > micRetryAt {
                micRetryAt = now + 20
                rebindMic(reason: "watchdog: \(Int(age))s sin audio")
            }
        }
    }

    private func checkStreamHealth() {
        guard isRunning, screenAvailable, !restartingScreen, !retryingScreen else { return }
        let silence = screenHealth.silence()
        let bad = screenHealth.failure()
        let dead = bad != nil || silence > Self.deadAfter
        if dead != screenFrozen {
            screenFrozen = dead
            onSourceFrozen?("screen", dead, bad ?? "stream mudo")
            onStatusChange?()
            if dead {
                let b = screenHealth.beats()
                Log.error(String(format: "Estudio: PANTALLA CONGELADA — el stream lleva %.1fs mudo "
                                 + "(motivo: %@, latidos video=%d audio=%d). Reenganchando…",
                                 silence, bad ?? "silencio", b.video, b.audio))
                onAlert?("Pantalla congelada — reenganchando la captura", false, "pantalla")   // se está curando; si falla, reportRestartFailure sí grita
                restartScreenTap(reason: bad ?? String(format: "%.1fs sin latido", silence))
            } else {
                Log.info("Estudio: pantalla viva de nuevo")
                onAlertResolved?("pantalla")
            }
        }
    }

    // MARK: - recuperación del tap de pantalla (la cura de la congelada)

    /// Tira el stream y lo vuelve a montar. Si estábamos grabando el RAW de
    /// pantalla, abre un archivo NUEVO (`screen-002.mp4`, …) y lo reporta para
    /// el manifest: el corte queda documentado, no escondido.
    func restartScreenTap(reason: String) {
        guard isRunning, !restartingScreen else { return }
        restartingScreen = true
        screenRestarts += 1
        let wasRecordingRaw = screenRecOutput != nil
        Log.error("Estudio: reiniciando captura de pantalla (motivo: \(reason), intento \(screenRestarts))")
        Task { @MainActor in
            defer { restartingScreen = false }
            // 1) soltar todo lo viejo (el raw actual se cierra limpio)
            if wasRecordingRaw { await detachScreenRecording() }
            if let s = screenStream {
                try? await Deadline.run(seconds: 6, name: "restart stopCapture") { try await s.stopCapture() }
            }
            screenStream = nil
            screenAvailable = false
            frames.drop(.screen)
            guard isRunning else { return }
            // 2) montar de cero
            do {
                try await startScreenTap(systemAudio: systemAudioWanted)
                Log.info("Estudio: captura de pantalla reenganchada")
                onAlertResolved?("pantalla")
            } catch {
                reportRestartFailure(error.localizedDescription)
                // Si el reenganche murió por permiso (fila de TCC muerta),
                // el doctor guía la reparación; su alerta pide el clic, jamás
                // relanza solo — si hay grabación viva, Daniel decide.
                Task { @MainActor in await ScreenDoctor.checkAndRepair(razon: "reenganche falló") }
                return
            }
            // 3) si grabábamos el raw, seguir en un archivo nuevo
            if wasRecordingRaw, let next = onNeedNewScreenRawURL?() {
                do {
                    try attachScreenRecording(url: next)
                    Log.info("Estudio: raw de pantalla continúa en \(next.lastPathComponent)")
                } catch {
                    Log.error("Estudio: no pude continuar el raw de pantalla: \(error.localizedDescription)")
                }
            }
            onStatusChange?()
        }
    }

    /// El reenganche de pantalla falló. Extraído del `catch` a proposito: el QA
    /// (`--failstream`) llama AQUÍ, así ejerce el camino REAL y no una copia
    /// que podría divergir — probar un mock del error no prueba nada.
    ///
    /// ⚠️ Si esto pasa GRABANDO, el programa sigue escribiendo con la última
    /// imagen de pantalla CONGELADA y la cámara y la voz perfectas — o sea, se
    /// ve sano. Medido el 9 ago en la prueba de 25 min: 60 segundos así, con la
    /// alerta viviendo en la ventana del Estudio, que está en el OTRO monitor
    /// mientras Daniel presenta. Mismo patrón que costó 45 minutos esa mañana.
    func reportRestartFailure(_ motivo: String) {
        Log.error("Estudio: reenganche falló: \(motivo)")
        let grabando = RecordingController.shared.state != .idle
            || StudioController.shared.recorder.isRecording

        // ⛔ LA SESIÓN BLOQUEADA NO ES UNA AVERÍA (28 ago 2026, Daniel: *"es
        // molesto porque sí estoy grabando pantalla y ese anuncio no debería
        // salir"*). macOS deniega la captura mientras la pantalla está
        // bloqueada, POR DISEÑO, y la devuelve sola al desbloquear: medido ese
        // mismo día —cayó 17:50:35, volvió 18:07:42, nadie tocó nada— y también
        // el 27 (16:45 y 16:57). O sea: la clase de fallo más frecuente de este
        // banner es la que NO es un fallo. Sin grabación viva no hay nada que
        // decirle a nadie; queda en el log, que es donde se revisa en frío.
        if ScreenDoctor.sesionBloqueada(), !grabando {
            Log.info("Estudio: … la sesión está BLOQUEADA — no es una falla, la captura "
                     + "vuelve sola al desbloquear. Sin alarma.")
            onStatusChange?()
            return
        }
        // Bloqueada PERO grabando sí importa (el programa está escribiendo el
        // último frame congelado), y el aviso dice la verdad: qué pasa y qué lo
        // arregla. Se cura solo en cuanto la pantalla vuelve (onAlertResolved).
        if ScreenDoctor.sesionBloqueada() {
            onAlert?("La pantalla está BLOQUEADA: mientras lo esté, la toma graba su último "
                     + "frame congelado. Se reengancha sola al desbloquear.", true, "pantalla")
            notify("SFCast — PANTALLA BLOQUEADA GRABANDO",
                   "Sigo grabando cámara y voz, pero la pantalla está bloqueada y sale "
                   + "congelada. Desbloquea y se reengancha sola.")
            Log.error("Estudio: NOTIFICACIÓN enviada (sesión bloqueada con grabación viva)")
            onStatusChange?()
            return
        }

        onAlert?("No pude reenganchar la pantalla: \(motivo)", true, "pantalla")
        if grabando {
            notify("SFCast — LA PANTALLA SE CAYÓ",
                   "Sigo grabando tu cámara y tu voz, pero la PANTALLA quedó "
                   + "congelada y no pude reengancharla. Revisa el permiso.")
            Log.error("Estudio: NOTIFICACIÓN enviada al sistema (la pantalla cayó grabando)")
        }
        onStatusChange?()
    }

    /// QA (`--failstream`): ejerce el fallo de reenganche SIN necesitar permiso
    /// de pantalla. Lo que importa verificar es que la grabación SOBREVIVE (la
    /// cámara y la voz siguen) y que el aviso ALCANZA a Daniel.
    func simulateRestartFailure() {
        screenRestarts += 1
        reportRestartFailure("simulado por QA (--failstream)")
    }

    /// Foto acumulada del FLUJO de frames: cámara entrando, preview saliendo.
    /// Los consumidores (chip de fps, heartbeat, bench) miden fps por DELTA
    /// entre dos fotos — el fps se mide contando frames, no se supone.
    func flowCounts() -> StudioFlowCounts {
        let p = previewGate.counts()
        return StudioFlowCounts(camera: frames.count(.camera),
                                previewDelivered: p.delivered,
                                previewDropped: p.dropped)
    }

    /// Salud del COMPOSITOR: cuánto tarda en componer y cuántos frames no
    /// llegaron a existir por falta de buffer. Es el hilo que alimenta al
    /// archivo, así que esto predice los fps del MP4 antes de abrirlo.
    func compositorStats() -> Compositor.Stats { compositor.stats() }
    func compositorSubFases() -> (grafo: Double, buffer: Double, render: Double) { compositor.subFases() }
    func resetCompositorWindow() { compositor.resetWindow() }

    /// Latencia de captura medida por fuente (segundos) + corrección aplicada.
    func syncReport() -> (camera: Double?, screen: Double?, appliedMs: Double) {
        (frames.latency(.camera), frames.latency(.screen), programClock.appliedMs)
    }

    /// QA (--studiotest): compone UN frame del programa con el estado actual,
    /// para evidenciar el compositor/escena sin depender de screenshots del
    /// sistema (la ventana es sharingType=.none). Thread-safe vs el render loop.
    func snapshotProgramFrame() -> CVPixelBuffer? {
        guard let scene = sceneBox.get() else { return nil }
        var starved: Set<StudioSourceKind> = []
        var stale: Set<StudioSourceKind> = []
        return compositor.compose(scene: scene, canvas: canvasSize,
                                  t: CACurrentMediaTime(), frames: frames,
                                  starved: &starved, stale: &stale)
    }
}

// MARK: - delegates de captura (corren en videoQueue/audioQueue)

extension StudioEngine: SCStreamDelegate {
    /// SCK avisa AQUÍ cuando el stream muere (cambio de display, error del
    /// WindowServer, permiso revocado, pool agotado). Antes nadie escuchaba.
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.error("Estudio: el stream de pantalla MURIÓ — \(error.localizedDescription)")
        Task { @MainActor [weak self] in
            guard let self, self.isRunning else { return }
            self.screenAvailable = false
            self.frames.drop(.screen)
            self.onAlert?("La captura de pantalla se cayó — reenganchando", false, "pantalla")   // idem
            self.onStatusChange?()
            self.restartScreenTap(reason: "didStopWithError")
        }
    }
}

extension StudioEngine: SCStreamOutput {
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .screen:
            // LATIDO PRIMERO, filtro después. SCK entrega frames `.idle` cuando
            // la pantalla no cambió: si el latido se tomara solo de los
            // `.complete`, una pantalla QUIETA se vería idéntica a un stream
            // MUERTO (falso positivo medido en el bench del 25 jul: 10
            // reenganches en 45s con la Mac en reposo). El stream está vivo si
            // el callback ocurre, tenga o no imagen nueva.
            screenHealth.beat()
            guard sb.isValid,
                  let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let statusRaw = attachments.first?[.status] as? Int,
                  let status = SCFrameStatus(rawValue: statusRaw) else { return }
            if status == .stopped || status == .suspended {
                screenHealth.markBad(status == .stopped ? "stopped" : "suspended")
                return
            }
            guard status == .complete, let pb = CMSampleBufferGetImageBuffer(sb) else { return }
            rawStarts.notar(camara: false)
            frames.set(pb, for: .screen, pts: CMSampleBufferGetPresentationTimeStamp(sb))
        case .audio:
            // El tap de audio del MISMO stream late aunque la pantalla no
            // cambie: es el sensor de vida más fiable que tenemos. En el
            // incidente real el delator fue justo este (sys=0 en 50 min).
            screenHealth.beatAudio()
            AudioMath.describeOnce(sb, label: "sistema")
            levels.setSystem(AudioMath.rms(from: sb))
            sink.get()?.appendSystemAudio(sb)
        default:
            break
        }
    }
}

extension StudioEngine {
    // MARK: - SONDA DE CADENCIA DE LA CÁMARA (27 ago 2026 — SE QUEDA)
    //
    // El sensor que por fin dijo la verdad. El contador de callbacks decía
    // "cam:25fps" y la API de AVFoundation decía "30 fps": con esos dos datos
    // no se puede saber si el dispositivo MANDA 25 o si manda 30 y nosotros
    // tiramos 5, y esa duda costó medio día y cuatro hipótesis falsas (PAL,
    // formato, pixel format, MovieFileOutput). Los PTS lo resolvieron en una
    // corrida: 40.000 ms clavados, 120 de 120 — un metrónomo a 25.00, o sea
    // señal de entrada, no pérdida nuestra.
    //
    // REGLA: cuando un contador y una API se contradigan, mide el INTERVALO,
    // no la cuenta. La cuenta te dice cuántos llegaron; el intervalo te dice
    // a qué ritmo los MANDAN, que es la pregunta.
    nonisolated(unsafe) private static var sondaUlt: Double = 0
    nonisolated(unsafe) private static var sondaDeltas: [Double] = []
    nonisolated(unsafe) private static let sondaLock = NSLock()
    nonisolated static func sondaPTS(_ pts: CMTime) {
        guard pts.isValid, pts.isNumeric else { return }
        let t = CMTimeGetSeconds(pts)
        sondaLock.lock(); defer { sondaLock.unlock() }
        if sondaUlt > 0 {
            let d = t - sondaUlt
            if d > 0, d < 1 { sondaDeltas.append(d) }
        }
        sondaUlt = t
        if sondaDeltas.count >= 1800 {   // ~1 min, no cada 4 s
            let ds = sondaDeltas.sorted()
            let med = ds[ds.count/2]
            var hist: [Int: Int] = [:]
            for d in ds { hist[Int((d*1000).rounded()), default: 0] += 1 }
            let top = hist.sorted { $0.value > $1.value }.prefix(4)
                .map { "\($0.key)ms×\($0.value)" }.joined(separator: " ")
            Log.info(String(format: "SONDA cámara: mediana %.1f ms (=%.2f fps) · min %.1f · max %.1f · top: %@",
                            med*1000, 1/med, ds.first!*1000, ds.last!*1000, top))
            sondaDeltas.removeAll()
        }
    }
}

extension StudioEngine: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output is AVCaptureVideoDataOutput {
            // QA (--freezecam): simula que la cámara se apagó sola (auto power
            // off de las Sony) tirando sus frames en silencio, que es EXACTO lo
            // que se vio el 9 ago: el store conserva el último y el compositor
            // sigue produciendo 30 fps impecables de una foto fija.
            if StudioEngine.qaFreezeCamera { return }
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
            // SONDA (27 ago): ¿el dispositivo MANDA 25, o manda 30 y nosotros
            // tiramos 5? El PTS lo dice y el contador de callbacks no.
            StudioEngine.sondaPTS(CMSampleBufferGetPresentationTimeStamp(sb))
            rawStarts.notar(camara: true)
            // El PTS viaja con el frame: es la única forma de saber CUÁNDO se
            // capturó de verdad esta imagen y no cuándo nos llegó.
            frames.set(pb, for: .camera, pts: CMSampleBufferGetPresentationTimeStamp(sb))
        } else if output is AVCaptureAudioDataOutput {
            // QA (--mutemic): simula EXACTAMENTE el fallo del 10 ago — el mic
            // deja de entregar y la app sigue grabando imagen impecable.
            if StudioEngine.qaMuteMic { return }
            AudioMath.describeOnce(sb, label: "mic")
            AudioMath.traceOnce(sb, label: "mic", every: 180)
            AudioMath.noteLatency(sb)
            levels.setMic(AudioMath.rms(from: sb))
            sink.get()?.appendMicAudio(sb)
        }
    }
}

// MARK: - compositor CoreImage (corre en renderQueue)

/// N fuentes + layout de escena → UN frame de programa (CVPixelBuffer BGRA,
/// IOSurface-backed). CoreImage = GPU sin shaders propios ni deps externas.
final class Compositor: @unchecked Sendable {

    /// Cómo se construye el CIContext y cómo se rinde. NO es una preferencia de
    /// gusto: se eligió MIDIENDO (`--compbench`), porque CoreImage por default
    /// convierte cada entrada a un espacio de trabajo lineal y vuelve a
    /// convertir a la salida — un peaje que aquí no compra nada, porque el
    /// compositor solo PEGA imágenes (no aplica filtros de color).
    enum Modo: String, CaseIterable {
        /// Lo que había hasta el 9 ago: working space por default + salida sRGB.
        case clasico
        /// Sin espacio de trabajo: los valores de píxel pasan tal cual.
        case sinColorManagement
        /// Sin color management + Metal explícito + prioridad baja de caché.
        case sinColorMasMetal
    }

    private let modo: Modo
    private let context: CIContext
    private var pool: CVPixelBufferPool?
    private var poolSize = CGSize.zero
    private let lock = NSLock()   // render loop vs snapshot de QA

    init(modo: Modo = .sinColorMasMetal) {
        self.modo = modo
        switch modo {
        case .clasico:
            context = CIContext(options: [.cacheIntermediates: false])
        case .sinColorManagement:
            context = CIContext(options: [
                .cacheIntermediates: false,
                .workingColorSpace: NSNull(),
                .outputColorSpace: NSNull(),
            ])
        case .sinColorMasMetal:
            // El device explícito evita que CoreImage elija por su cuenta (y en
            // una Mac con GPU integrada + WindowServer peleando, elegir mal
            // cuesta milisegundos por frame).
            if let dev = MTLCreateSystemDefaultDevice() {
                context = CIContext(mtlDevice: dev, options: [
                    .cacheIntermediates: false,
                    .workingColorSpace: NSNull(),
                    .outputColorSpace: NSNull(),
                    .highQualityDownsample: false,
                ])
            } else {
                context = CIContext(options: [
                    .cacheIntermediates: false,
                    .workingColorSpace: NSNull(),
                    .outputColorSpace: NSNull(),
                ])
            }
        }
    }

    /// El espacio de salida del render. Con color management apagado se pasa
    /// `nil`: pedir sRGB ahí reintroduciría justo la conversión que quitamos.
    private var renderColorSpace: CGColorSpace? {
        modo == .clasico ? CGColorSpace(name: CGColorSpace.sRGB) : nil
    }

    // MARK: - PIPELINING (la cura de raíz, 9 ago 2026)
    //
    // Medición que lo motiva, en vivo con la escena real de Daniel:
    //
    //     grafo (CPU)   0.58 ms
    //     buffer (pool) 0.02 ms
    //     RENDER (GPU) 22.32 ms   ← el 97%
    //
    // `CIContext.render(_:to:…)` es SÍNCRONO: se queda esperando a que la GPU
    // termine. Y la GPU no es nuestra — WindowServer compone dos monitores 4K,
    // el encoder HEVC codifica, el preview y el espejo pintan. Componer no es
    // caro; ESPERAR en el hilo que marca la cadencia, sí.
    //
    // Esta es la diferencia real con OBS, y no es "mejor código": es que ellos
    // no bloquean. Aquí se hace igual — el trabajo de la GPU se SOLAPA con el
    // siguiente tick: en el frame N se LANZA el render sin esperar, y en el
    // N+1 se recoge el resultado (que la GPU pintó mientras tanto) y se manda
    // al encoder. El handler pasa de esperar 22 ms a gastar ~0.6.
    //
    // Cuesta UN frame de latencia (33 ms), y por eso el hostTime viaja PEGADO
    // a su buffer: el frame que se entrega es el del tick anterior y tiene que
    // llevar el timestamp de ESE tick, o reintroduciríamos el desfase de audio
    // que acabamos de matar.
    private var pendingTask: CIRenderTask?
    private var pendingBuffer: CVPixelBuffer?
    private var pendingHostTime: CMTime?
    private var pipelineFallos = 0

    /// Frame LISTO (el del tick anterior) + su timestamp, o nil si aún no hay.
    struct Listo {
        let buffer: CVPixelBuffer
        let hostTime: CMTime
    }

    // MARK: - SENSOR del compositor (invariante 5b)

    /// Frames que NUNCA existieron porque el pool no dio buffer, y cuánto cuesta
    /// componer. Hasta el 9 ago `makeBuffer` devolvía nil y el render loop hacía
    /// `return` sin contar NADA: el frame se evaporaba, `droppedFrames` seguía
    /// en 0 y el log decía `drops:0` mientras el archivo caía a 8 fps. El agujero
    /// estaba exactamente en el único sitio donde nadie miraba.
    struct Stats {
        var composed = 0
        var bufferFailures = 0
        var composeMsP50 = 0.0
        var composeMsMax = 0.0
    }
    private var composeMs: [Double] = []
    private var grafoMs: [Double] = []
    private var bufferMs: [Double] = []
    private var renderMs: [Double] = []
    private var composed = 0
    private var bufferFailures = 0

    func stats() -> Stats {
        lock.lock(); defer { lock.unlock() }
        let s = composeMs.sorted()
        return Stats(composed: composed,
                     bufferFailures: bufferFailures,
                     composeMsP50: s.isEmpty ? 0 : s[s.count / 2],
                     composeMsMax: s.last ?? 0)
    }

    /// Vacía la ventana de tiempos (el heartbeat mide por tramo, no acumulado —
    /// un promedio de 45 min esconde un colapso de 4).
    func resetWindow() {
        lock.lock()
        composeMs.removeAll(keepingCapacity: true)
        grafoMs.removeAll(keepingCapacity: true)
        bufferMs.removeAll(keepingCapacity: true)
        renderMs.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    func compose(scene: StudioScene, canvas: CGSize, t: Double,
                 frames: LatestFrameStore, starved: inout Set<StudioSourceKind>,
                 stale: inout Set<StudioSourceKind>) -> CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }
        let t0 = CACurrentMediaTime()
        let image = buildImage(scene: scene, canvas: canvas, t: t,
                               frames: frames, starved: &starved, stale: &stale)
        let tGrafo = CACurrentMediaTime()
        guard let pb = makeBuffer(canvas) else {
            // NO es un no-op: es un frame que no va a existir en el archivo.
            // Se cuenta aquí porque más arriba (el render loop) ya no hay a
            // quién contárselo — ver Stats.
            bufferFailures += 1
            return nil
        }
        let tBuffer = CACurrentMediaTime()
        context.render(image, to: pb, bounds: CGRect(origin: .zero, size: canvas),
                       colorSpace: renderColorSpace)
        let tRender = CACurrentMediaTime()
        composed += 1
        composeMs.append((tRender - t0) * 1000)
        // Las TRES sub-fases por separado: armar el grafo (CPU), sacar buffer
        // del pool (memoria) y renderizar (GPU, y `render` es SÍNCRONO: si
        // WindowServer tiene la GPU ocupada con dos monitores 4K, aquí se
        // ESPERA). Sin este desglose, "compose cuesta 20 ms" no dice si la cura
        // es menos trabajo, más memoria o no bloquear.
        grafoMs.append((tGrafo - t0) * 1000)
        bufferMs.append((tBuffer - tGrafo) * 1000)
        renderMs.append((tRender - tBuffer) * 1000)
        if composeMs.count > 600 {
            // El exceso se calcula UNA vez y ANTES de tocar nada: usar
            // `composeMs.count` después del primer removeFirst borraba los
            // otros tres arrays enteros (medían 0.00 ms, que era imposible).
            let exceso = composeMs.count - 600
            composeMs.removeFirst(exceso)
            if grafoMs.count >= exceso { grafoMs.removeFirst(exceso) }
            if bufferMs.count >= exceso { bufferMs.removeFirst(exceso) }
            if renderMs.count >= exceso { renderMs.removeFirst(exceso) }
        }
        return pb
    }

    /// Arma el grafo CoreImage de la escena (CPU pura, ~0.6 ms medidos). No
    /// toca la GPU: eso pasa al renderizar. Lo comparten la vía síncrona (QA)
    /// y la canalizada (producción) para que no puedan divergir.
    private func buildImage(scene: StudioScene, canvas: CGSize, t: Double,
                            frames: LatestFrameStore,
                            starved: inout Set<StudioSourceKind>,
                            stale: inout Set<StudioSourceKind>) -> CIImage {
        var image = CIImage(color: CIColor(red: 0.04, green: 0.04, blue: 0.05))
            .cropped(to: CGRect(origin: .zero, size: canvas))
        for item in scene.items where item.enabled {
            // COMPARADOR de CONGELADA: la fuente tiene frame pero es VIEJO.
            // Se sigue pintando (mejor imagen vieja que negro mientras se
            // reengancha), pero queda REPORTADA — jamás en silencio.
            if item.kind != .testPattern, let age = frames.age(item.kind),
               age > StudioEngine.staleAfter {
                stale.insert(item.kind)
            }
            guard let src = sourceImage(kind: item.kind, t: t, canvas: canvas, frames: frames) else {
                starved.insert(item.kind)   // COMPARADOR: fuente activa sin frames
                continue
            }
            // HALO NEÓN debajo del video (el anillo se retiró — ver SceneGlow).
            if let halo = glowLayer(item: item, canvas: canvas) {
                image = halo.composited(over: image)
            }
            image = place(src, item: item, canvas: canvas).composited(over: image)
        }
        return image
    }

    /// Recorte de las ventanas de medición (mismo exceso para las cuatro).
    private func trimVentanas() {
        guard composeMs.count > 600 else { return }
        let exceso = composeMs.count - 600
        composeMs.removeFirst(exceso)
        if grafoMs.count >= exceso { grafoMs.removeFirst(exceso) }
        if bufferMs.count >= exceso { bufferMs.removeFirst(exceso) }
        if renderMs.count >= exceso { renderMs.removeFirst(exceso) }
    }

    /// COMPOSICIÓN CANALIZADA — lanza el render de ESTE frame sin esperarlo y
    /// devuelve el del tick ANTERIOR, ya terminado por la GPU.
    ///
    /// El contrato con el llamador cambia: lo que sale NO es el frame que
    /// acabas de pedir, es el de hace un tick — por eso trae su propio
    /// `hostTime`. Devolver nil es normal en el primer tick (todavía no hay
    /// nada anterior que entregar).
    func composePipelined(scene: StudioScene, canvas: CGSize, t: Double,
                          hostNow: CMTime, frames: LatestFrameStore,
                          starved: inout Set<StudioSourceKind>,
                          stale: inout Set<StudioSourceKind>) -> Listo? {
        lock.lock(); defer { lock.unlock() }

        // 1) RECOGER lo que la GPU pintó mientras tanto. Si por lo que sea no
        //    terminó, se espera aquí — pero ese tiempo ya se solapó con el
        //    trabajo del tick anterior, que es justamente la ganancia.
        var listo: Listo?
        if let task = pendingTask, let buf = pendingBuffer, let ht = pendingHostTime {
            do {
                try task.waitUntilCompleted()
                listo = Listo(buffer: buf, hostTime: ht)
            } catch {
                // Un render fallido no puede matar la grabación: se cuenta y se
                // sigue (el frame se pierde, pero jamás en silencio).
                pipelineFallos += 1
                bufferFailures += 1
            }
            pendingTask = nil; pendingBuffer = nil; pendingHostTime = nil
        }

        // 2) ARMAR y LANZAR el de este tick, sin esperarlo.
        let t0 = CACurrentMediaTime()
        let image = buildImage(scene: scene, canvas: canvas, t: t,
                               frames: frames, starved: &starved, stale: &stale)
        let tGrafo = CACurrentMediaTime()
        guard let pb = makeBuffer(canvas) else {
            bufferFailures += 1
            return listo
        }
        let tBuffer = CACurrentMediaTime()
        let dest = CIRenderDestination(pixelBuffer: pb)
        dest.colorSpace = renderColorSpace
        do {
            pendingTask = try context.startTask(toRender: image,
                                                from: CGRect(origin: .zero, size: canvas),
                                                to: dest, at: .zero)
            pendingBuffer = pb
            pendingHostTime = hostNow
            composed += 1
        } catch {
            pipelineFallos += 1
            bufferFailures += 1
        }
        let tLanzado = CACurrentMediaTime()
        composeMs.append((tLanzado - t0) * 1000)
        grafoMs.append((tGrafo - t0) * 1000)
        bufferMs.append((tBuffer - tGrafo) * 1000)
        renderMs.append((tLanzado - tBuffer) * 1000)
        trimVentanas()
        return listo
    }

    /// Suelta el frame en vuelo (al parar el motor o cambiar de lienzo): sin
    /// esto, un buffer del pool viejo quedaría retenido para siempre.
    func drainPipeline() {
        lock.lock()
        if let t = pendingTask { try? t.waitUntilCompleted() }
        pendingTask = nil; pendingBuffer = nil; pendingHostTime = nil
        lock.unlock()
    }

    var pipelineFailures: Int { lock.lock(); defer { lock.unlock() }; return pipelineFallos }

    /// Desglose de compose() en sus tres sub-fases (p50 de cada una).
    func subFases() -> (grafo: Double, buffer: Double, render: Double) {
        lock.lock(); defer { lock.unlock() }
        func p50(_ x: [Double]) -> Double {
            guard !x.isEmpty else { return 0 }
            let s = x.sorted(); return s[s.count / 2]
        }
        return (p50(grafoMs), p50(bufferMs), p50(renderMs))
    }

    private func sourceImage(kind: StudioSourceKind, t: Double, canvas: CGSize,
                             frames: LatestFrameStore) -> CIImage? {
        switch kind {
        case .screen, .camera:
            guard let pb = frames.get(kind) else { return nil }
            return CIImage(cvPixelBuffer: pb)
        case .testPattern:
            // Tablero animado (mostaza/titanium): QA sin permisos TCC — prueba
            // compositor, escenas, switch y writers de punta a punta.
            let f = CIFilter(name: "CICheckerboardGenerator")!
            f.setValue(CIVector(x: (t * 60).truncatingRemainder(dividingBy: 160), y: 0), forKey: "inputCenter")
            f.setValue(CIColor(red: 1.0, green: 0.567, blue: 0.004), forKey: "inputColor0")
            f.setValue(CIColor(red: 0.10, green: 0.10, blue: 0.12), forKey: "inputColor1")
            f.setValue(80, forKey: "inputWidth")
            return f.outputImage?.cropped(to: CGRect(origin: .zero, size: canvas))
        }
    }

    // MARK: - aro neón (el mismo del Loom, por item de escena)

    private struct GlowKey: Hashable {
        let x: Int, y: Int, w: Int, h: Int
        let circle: Bool
        let glow: String
        let opacity: Int
    }
    private var glowCache: [GlowKey: CIImage] = [:]

    /// El HALO (ya no hay anillo — ver `SceneGlow`). **Cacheado**: desenfocar en
    /// cada frame costaría 30 veces por segundo lo que cuesta una; solo cambia
    /// si cambia el rect, el color o el recorte.
    private func glowLayer(item: SceneItem, canvas: CGSize) -> CIImage? {
        guard let rgb = item.glow.rgb else { return nil }
        let target = targetRect(item, canvas: canvas)
        guard target.width > 4, target.height > 4 else { return nil }
        let key = GlowKey(x: Int(target.origin.x.rounded()), y: Int(target.origin.y.rounded()),
                          w: Int(target.width.rounded()), h: Int(target.height.rounded()),
                          circle: item.circleMask, glow: item.glow.rawValue,
                          opacity: Int((item.opacity * 100).rounded()))
        if let hit = glowCache[key] { return hit }

        let minSide = min(target.width, target.height)
        let halo = SceneGlow.halo(itemMinSide: minSide,
                                  canvasMinSide: min(canvas.width, canvas.height))
        // El desenfoque gaussiano muere a ~3σ: ese es el margen que hay que
        // dejar alrededor o el halo sale cortado en recto (el mismo error que
        // el `glowPad` corrige en el NSPanel de la burbuja).
        let pad = halo * 3
        let box = target.insetBy(dx: -pad, dy: -pad)
        // Con `circleMask` el video se recorta al círculo INSCRITO (lado menor,
        // centrado — ver `place`). El halo tiene que salir de ESE círculo, no de
        // un óvalo del rect completo, o quedaría despegado del recorte.
        var shape = target.offsetBy(dx: -box.origin.x, dy: -box.origin.y)
        if item.circleMask {
            shape = CGRect(x: shape.midX - minSide / 2, y: shape.midY - minSide / 2,
                           width: minSide, height: minSide)
        }
        let radius = SceneGlow.cornerRadius(minSide: minSide,
                                            fullBleed: SceneGlow.isFullBleed(item.rect),
                                            circle: item.circleMask)
        guard let bodyImg = drawShape(size: box.size, rect: shape, radius: radius, rgb: rgb,
                                      alpha: SceneGlow.haloAlpha * item.opacity, stroke: nil)
        else { return nil }

        let layer = bodyImg
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: halo])
            .cropped(to: CGRect(origin: .zero, size: box.size))
            .transformed(by: CGAffineTransform(translationX: box.origin.x, y: box.origin.y))
        if glowCache.count > 24 { glowCache.removeAll() }   // techo simple
        glowCache[key] = layer
        return layer
    }

    /// Dibuja el círculo/rect redondeado en un bitmap transparente: relleno para
    /// el halo (que luego se desenfoca), o trazo para el anillo definido.
    private func drawShape(size: CGSize, rect: CGRect, radius: CGFloat,
                           rgb: (r: Double, g: Double, b: Double), alpha: Double,
                           stroke: CGFloat?) -> CIImage? {
        let w = Int(size.width.rounded()), h = Int(size.height.rounded())
        guard w > 0, h > 0,
              let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let color = CGColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: alpha)
        // El trazo se centra en el path: se encoge medio grosor para que el
        // anillo quede DENTRO del borde del video, como el border de una capa.
        let inset = (stroke ?? 0) / 2
        let path = CGPath(roundedRect: rect.insetBy(dx: inset, dy: inset),
                          cornerWidth: max(0, radius - inset),
                          cornerHeight: max(0, radius - inset), transform: nil)
        ctx.addPath(path)
        if let s = stroke {
            ctx.setStrokeColor(color)
            ctx.setLineWidth(s)
            ctx.strokePath()
        } else {
            ctx.setFillColor(color)
            ctx.fillPath()
        }
        guard let img = ctx.makeImage() else { return nil }
        return CIImage(cgImage: img)
    }

    /// El rect del item en píxeles del canvas (lo comparten `place` y el aro —
    /// si se calcularan por separado, el aro se despegaría del video).
    private func targetRect(_ item: SceneItem, canvas: CGSize) -> CGRect {
        CGRect(x: item.rect.origin.x * canvas.width,
               y: item.rect.origin.y * canvas.height,
               width: item.rect.width * canvas.width,
               height: item.rect.height * canvas.height)
    }

    /// Coloca la imagen de la fuente en su rect normalizado del canvas
    /// (aspect-fill con recorte centrado, o aspect-fit), máscara circular
    /// opcional (burbuja Loom) y opacidad.
    private func place(_ src: CIImage, item: SceneItem, canvas: CGSize) -> CIImage {
        let target = targetRect(item, canvas: canvas)
        let s = src.extent.size
        guard s.width > 1, s.height > 1, target.width > 1, target.height > 1 else { return src }
        let scale = item.fit == .fill
            ? max(target.width / s.width, target.height / s.height)
            : min(target.width / s.width, target.height / s.height)
        var img = src.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        // centrar la imagen escalada sobre el centro del target
        let dx = target.midX - img.extent.midX
        let dy = target.midY - img.extent.midY
        img = img.transformed(by: CGAffineTransform(translationX: dx, y: dy))
        // ESPEJADO HORIZONTAL alrededor del CENTRO del rect del item: la
        // reflexión manda el target sobre sí mismo, así que el recorte y la
        // máscara (simétricos respecto al centro) no se enteran.
        if item.flipH {
            img = img.transformed(by: CGAffineTransform(scaleX: -1, y: 1)
                .concatenating(CGAffineTransform(translationX: 2 * target.midX, y: 0)))
        }
        if item.fit == .fill {
            img = img.cropped(to: target)
        }
        if item.circleMask {
            // círculo inscrito (diámetro = lado menor), borde duro
            let r = min(target.width, target.height) / 2
            let g = CIFilter(name: "CIRadialGradient")!
            g.setValue(CIVector(x: target.midX, y: target.midY), forKey: "inputCenter")
            g.setValue(r - 1, forKey: "inputRadius0")
            g.setValue(r, forKey: "inputRadius1")
            g.setValue(CIColor.white, forKey: "inputColor0")
            g.setValue(CIColor(red: 0, green: 0, blue: 0, alpha: 0), forKey: "inputColor1")
            if let mask = g.outputImage?.cropped(to: target) {
                img = img.applyingFilter("CIBlendWithAlphaMask", parameters: [
                    kCIInputMaskImageKey: mask,
                    kCIInputBackgroundImageKey: CIImage.empty(),
                ])
            }
        } else if item.kind == .camera {
            // ESQUINAS REDONDEADAS (9 ago). El espejo las pintaba y el programa
            // NO: la cámara a tamaño completo salía a escuadra en el video y
            // redondeada en el panel. Daniel lo cazó a ojo — "no parten de la
            // misma función" — y tenía razón literal. Mismo radio que
            // `MirrorLayout.shapePath`: lado menor × 0.035.
            //
            // Solo la CÁMARA: redondear la fuente Pantalla le pondría esquinas
            // curvas al video entero, que no es lo que nadie pidió.
            let r = min(target.width, target.height) * SceneGlow.cornerFraction
            if let mask = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
                "inputExtent": CIVector(cgRect: target),
                "inputRadius": r,
                "inputColor": CIColor.white,
            ])?.outputImage?.cropped(to: target) {
                img = img.applyingFilter("CIBlendWithAlphaMask", parameters: [
                    kCIInputMaskImageKey: mask,
                    kCIInputBackgroundImageKey: CIImage.empty(),
                ])
            }
        }
        if item.opacity < 0.999 {
            img = img.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(item.opacity)),
            ])
        }
        return img
    }

    private func makeBuffer(_ size: CGSize) -> CVPixelBuffer? {
        if pool == nil || poolSize != size {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
            var p: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 4] as CFDictionary,
                                    attrs as CFDictionary, &p)
            pool = p
            poolSize = size
        }
        guard let pool else { return nil }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        return pb
    }
}

/// EL GUARDIÁN DE LA CADENCIA — por qué a OBS "no se le bajan los fps".
///
/// Con el render ya canalizado, el handler cuesta ~3.7 ms de 33.3. Pero un
/// `DispatchSourceTimer` con `repeating` **no recupera los disparos perdidos**:
/// si el sistema lo posterga 70 ms (un hipo de scheduler, un pico de
/// WindowServer), esos dos ticks no vuelven y el archivo queda con un hueco.
/// Eso es lo que producía los saltos de 750 ms del 9 ago.
///
/// La cura no es componer más rápido — es **no dejar huecos en la cadencia**:
/// cuando faltan ticks, se reemiten los frames que faltan con el ÚLTIMO
/// contenido disponible. Un frame repetido y un frame que nunca se compuso
/// muestran EXACTAMENTE lo mismo en pantalla; la diferencia está en el
/// contenedor, y un mp4 de 30 fps constantes es lo que cualquier editor quiere
/// (los NLEs sufren el frame-rate variable). Es literalmente lo que hace OBS
/// con sus "lagged frames".
final class CadenceKeeper: @unchecked Sendable {
    private let lock = NSLock()
    private var lastEmitted: CMTime = .invalid
    private var repetidos = 0
    private var maxRelleno = 8
    /// Por encima de esto ya no es un ahogo: es una discontinuidad.
    private static let huecoDeDiscontinuidad = 1.0

    func reset() {
        lock.lock(); lastEmitted = .invalid; repetidos = 0; lock.unlock()
    }

    var repeatedFrames: Int { lock.lock(); defer { lock.unlock() }; return repetidos }

    /// Devuelve los timestamps que hay que emitir para llegar a `target` sin
    /// dejar huecos: los de relleno primero (con el contenido anterior) y el
    /// del frame nuevo al final.
    ///
    /// El relleno se topa a `maxRelleno`: si el hueco es enorme (la app estuvo
    /// suspendida, el disco se atoró) no tiene sentido inventar dos segundos de
    /// imagen congelada — ahí el hueco es información honesta.
    func timestamps(for target: CMTime, fps: Int) -> [CMTime] {
        lock.lock(); defer { lock.unlock() }
        let paso = 1.0 / Double(max(fps, 1))
        guard lastEmitted.isValid else {
            lastEmitted = target
            return [target]
        }
        let hueco = CMTimeGetSeconds(CMTimeSubtract(target, lastEmitted))
        guard hueco > paso * 1.6 else {
            lastEmitted = target
            return [target]
        }
        // RED DE SEGURIDAD (26 ago 2026): un hueco que ni siquiera cabe en el
        // relleno máximo no es un timer que perdió disparos — es una
        // DISCONTINUIDAD (otra toma, el motor que se detuvo, la app suspendida).
        // Rellenar desde `lastEmitted` ahí fecha los frames en el pasado y
        // arrastra el arranque del writer con ellos. Se re-ancla y ya: el hueco
        // es información honesta, pero no puede envenenar el reloj.
        // ⚠️ EL UMBRAL ES 1 SEGUNDO, NO `maxRelleno` (revisión adversarial, misma
        // noche). La primera versión re-anclaba en cuanto el hueco no cabía en el
        // relleno máximo — 0.3 s — y eso habría sido un RETROCESO al 9 ago: un
        // atasco de 750 ms a mitad de toma pasaba de rellenarse con 8 frames a no
        // rellenarse en absoluto, o sea justo el hueco que `CadenceKeeper` existe
        // para tapar ("OBS no siempre alcanza: nunca deja huecos").
        //
        // Un segundo separa las dos cosas sin ambigüedad: por debajo es la Mac
        // ahogándose y se rellena; por encima no es un timer que perdió disparos,
        // es una discontinuidad (otra toma, el motor parado, la app suspendida) y
        // rellenar desde `lastEmitted` fecharía los frames en el pasado.
        if hueco > Self.huecoDeDiscontinuidad, !QAFlags.revivirHuecoDeCabeza {
            lastEmitted = target
            return [target]
        }
        let faltan = min(Int((hueco / paso).rounded()) - 1, maxRelleno)
        guard faltan > 0 else { lastEmitted = target; return [target] }
        var out: [CMTime] = []
        for i in 1...faltan {
            out.append(CMTimeAdd(lastEmitted,
                                 CMTime(seconds: paso * Double(i), preferredTimescale: 90_000)))
        }
        repetidos += faltan
        out.append(target)
        lastEmitted = target
        return out
    }
}

/// PERFIL DEL RENDER LOOP — dónde se van los milisegundos, por fase.
///
/// El 9 ago el compositor medía 4 ms en el bench aislado y **23 ms en vivo**.
/// Con un solo número agregado no hay forma de saber si eso es la GPU
/// componiendo, el pool dando buffers, el encoder tragando o el preview: son
/// cuatro curas distintas y opuestas. Esto las separa.
final class RenderProfile: @unchecked Sendable {
    private let lock = NSLock()
    private var compose: [Double] = []
    private var preview: [Double] = []
    private var encode: [Double] = []
    private var total: [Double] = []

    func add(compose c: Double, preview p: Double, encode e: Double, total t: Double) {
        lock.lock()
        compose.append(c); preview.append(p); encode.append(e); total.append(t)
        if compose.count > 900 {
            compose.removeFirst(300); preview.removeFirst(300)
            encode.removeFirst(300); total.removeFirst(300)
        }
        lock.unlock()
    }

    func reset() {
        lock.lock()
        compose.removeAll(); preview.removeAll(); encode.removeAll(); total.removeAll()
        lock.unlock()
    }

    struct Fase { var p50 = 0.0; var p95 = 0.0; var max = 0.0 }
    private static func stat(_ xs: [Double]) -> Fase {
        guard !xs.isEmpty else { return Fase() }
        let s = xs.sorted()
        return Fase(p50: s[s.count / 2],
                    p95: s[min(s.count - 1, Int(Double(s.count) * 0.95))],
                    max: s[s.count - 1])
    }

    func snapshot() -> (compose: Fase, preview: Fase, encode: Fase, total: Fase, n: Int) {
        lock.lock(); defer { lock.unlock() }
        return (Self.stat(compose), Self.stat(preview), Self.stat(encode),
                Self.stat(total), compose.count)
    }

    /// Una línea legible para el log/QA.
    func line() -> String {
        let s = snapshot()
        return String(format: "compose %.1f/%.1f/%.1f · preview %.1f/%.1f · encode %.1f/%.1f/%.1f "
                      + "· TOTAL %.1f/%.1f/%.1f ms (p50/p95/max, n=%d)",
                      s.compose.p50, s.compose.p95, s.compose.max,
                      s.preview.p50, s.preview.p95,
                      s.encode.p50, s.encode.p95, s.encode.max,
                      s.total.p50, s.total.p95, s.total.max, s.n)
    }
}

/// EL GOVERNOR — la diferencia entre bajar de fps y ROMPERSE.
///
/// El 9 ago la grabación no "bajó a 10 fps": se quedó a 30 pedidos entregando
/// 10, con huecos IRREGULARES de hasta 750 ms. Un talking-head a 15 fps
/// constantes se ve pobre pero fluido; el mismo material con saltos de tres
/// cuartos de segundo se ve ROTO, y encima no hay interpolación que lo salve.
///
/// Pedir 30 cuando la máquina da 10 no consigue 30: consigue 10 feos. Este
/// comparador mide la cadencia REAL y baja el objetivo a un escalón que la Mac
/// sí pueda sostener, de forma regular. Cuando el sistema se despeja, sube solo
/// (despacio y con histéresis: nadie quiere que oscile a mitad de una toma).
final class RenderGovernor: @unchecked Sendable {
    private let lock = NSLock()
    private var windowStart: Double = 0
    private var framesInWindow = 0
    private var badWindows = 0
    private var goodWindows = 0
    private var current = 0
    private(set) var steppedDownAt: Double?
    /// Ventanas buenas necesarias para SUBIR un escalón. Crece cuando una
    /// subida fracasa: sin esto el governor oscila (medido el 9 ago con
    /// `--chokems 60`: bajó 30→24→19→15, aguantó 10 s, subió a 19, no alcanzó,
    /// y habría vuelto a bajar en bucle). Una cadencia que sube y baja cada 15
    /// segundos es exactamente el video irregular que vinimos a evitar: más
    /// vale quedarse un escalón por debajo que ir a tirones.
    private var upRequirement = 5
    private var lastUpAt: Double?

    /// Ventana de evaluación. 2 s es suficiente para distinguir una caída real
    /// de un tropiezo, y bastante más rápido que el latido de 15 s (que el 9 ago
    /// vio el colapso pero no podía hacer nada con él).
    private let window: Double = 2.0

    func reset(target: Int, now: Double) {
        lock.lock()
        current = target; windowStart = now; framesInWindow = 0
        badWindows = 0; goodWindows = 0; steppedDownAt = nil
        upRequirement = 5; lastUpAt = nil
        floorFailingSince = nil; floorAchieved = 0; everSteppedDown = false
        lock.unlock()
    }

    /// Cuánto lleva fallando el piso, en segundos. 0 = no está fallando.
    func floorFailingFor(now: Double) -> Double {
        lock.lock(); defer { lock.unlock() }
        guard let desde = floorFailingSince else { return 0 }
        return now - desde
    }

    var effective: Int { lock.lock(); defer { lock.unlock() }; return current }

    /// PISO DURO DE CADENCIA — orden de Daniel, 17 ago 2026:
    ///
    ///   "Queda prohibido bajar los frames por segundo. Prefiero que antes de eso
    ///    se pause y me diga algo, pero mantener estables los frames. 30 frames,
    ///    mínimo 24, pero no menos. Prefiero que se pause si es así y yo arreglar
    ///    otros detalles."
    ///
    /// Cambia la filosofía del governor: antes degradaba con gracia hasta 12 fps
    /// (30→24→19→15) y el archivo salía a 30 rellenando con frames repetidos, lo
    /// cual se ve como tirones. La toma del 15 ago se quedó en 15/30 siete minutos
    /// y salió con 12.8 fps de movimiento real. Eso ya no se permite.
    ///
    /// Ahora hay UN escalón de gracia y punto. Si no aguanta el piso, no se
    /// degrada más: se DETIENE la toma y se le dice (ver `cadenceGuard` en
    /// StudioRecorder — mismo patrón que el guard de voz, que detiene a los 20 s
    /// sin micrófono en vez de grabar media hora en silencio).
    static let hardFloorFPS = 24
    private func ladder(_ target: Int) -> [Int] {
        // Nunca por debajo de 24 absolutos ni del 80% del objetivo, y nunca por
        // encima del objetivo (si pide 20, el piso ES 20: no hay escalón).
        let piso = max(min(target, Self.hardFloorFPS), Int(Double(target) * 0.8))
        return piso >= target ? [target] : [target, piso]
    }

    /// Desde cuándo el governor está EN EL PISO y aun así no alcanza. `nil` = va
    /// bien o todavía tiene escalón de gracia. Es la señal que el guard de
    /// cadencia convierte en "detén la toma y dile".
    private(set) var floorFailingSince: Double?
    /// A cuántos fps se está quedando corto cuando falla el piso (para el mensaje).
    private(set) var floorAchieved: Double = 0
    /// ¿El governor bajó UN escalón en algún momento de esta toma?
    ///
    /// No es lo mismo que `effective < target`, que es un valor INSTANTÁNEO. El QA
    /// preguntaba lo segundo y por eso reprobaba con "el governor NUNCA bajó — eso
    /// sí es un bug" en tomas donde sí había bajado y ya se había recuperado a 30
    /// antes del stop. Un gate que confunde "se recuperó" con "nunca actuó" acusa
    /// al código de un bug que no existe.
    private(set) var everSteppedDown = false

    /// Un frame compuesto. Devuelve el nuevo fps si hay que re-agendar.
    func frameComposed(now: Double, target: Int) -> Int? {
        lock.lock(); defer { lock.unlock() }
        if current == 0 { current = target; windowStart = now }
        framesInWindow += 1
        guard now - windowStart >= window else { return nil }
        let achieved = Double(framesInWindow) / (now - windowStart)
        framesInWindow = 0
        windowStart = now
        let steps = ladder(target)
        let idx = steps.firstIndex(of: current) ?? 0

        // EN EL PISO la vara es más estricta, y se evalúa aparte.
        //
        // El 0.85 de abajo existe para decidir si vale la pena BAJAR un escalón, y
        // con el piso en 24 eso daría por bueno cualquier cosa arriba de 20.4 fps.
        // La orden es "mínimo 24, pero no menos", así que en el piso la vara es
        // 0.93 (≈22.3 fps): margen para el ruido de medir en ventanas de 2 s, no
        // para degradarse de a poquito por debajo de lo pactado.
        let enElPiso = idx + 1 >= steps.count
        if enElPiso {
            if achieved < Double(current) * 0.93 {
                if floorFailingSince == nil { floorFailingSince = now }
                floorAchieved = achieved
            } else {
                floorFailingSince = nil
            }
        }

        // ¿La Mac está entregando lo que le pedimos?
        if achieved < Double(current) * 0.85 {
            badWindows += 1; goodWindows = 0
            if badWindows >= 2, idx + 1 < steps.count {
                // ¿Venimos de una subida reciente? Entonces esa subida fue un
                // error de juicio: el techo real está aquí abajo. Se encarece
                // el próximo intento (backoff) hasta un tope de ~6 minutos.
                if let up = lastUpAt, now - up < 25 {
                    upRequirement = min(upRequirement * 3, 180)
                }
                current = steps[idx + 1]
                badWindows = 0
                steppedDownAt = now
                everSteppedDown = true
                return current
            }
        } else if achieved >= Double(current) * 0.97 {
            goodWindows += 1; badWindows = 0
            // Subir cuesta MÁS que bajar, y cada vez más si ya falló antes.
            if goodWindows >= upRequirement, idx > 0 {
                current = steps[idx - 1]
                goodWindows = 0
                lastUpAt = now
                return current
            }
        } else {
            badWindows = 0; goodWindows = 0
        }
        return nil
    }
}

/// EL RELOJ DEL PROGRAMA — el que decide en qué instante VIVE cada frame
/// compuesto dentro del archivo.
///
/// Hasta el 9 ago el frame se estampaba con `CMClockGetTime(hostClock)` al
/// TERMINAR de componer. Dos errores en una línea:
///
///  1. La imagen que lleva dentro es más vieja que ese instante — la cámara
///     tardó en entregarla (transporte UVC) y el compositor tardó en pintarla.
///     El audio, en cambio, sí se escribe con su PTS real. Resultado: los
///     labios van detrás de la voz, y se ve justo cuando la cara es grande.
///  2. Al estampar DESPUÉS de componer, cuanto más se atrasa la Mac, más crece
///     el desfase — el error empeora exactamente cuando ya estabas sufriendo.
///
/// Este reloj corrige las dos: toma el instante de ANTES de componer y le resta
/// la latencia MEDIDA de la fuente crítica. Y lo hace despacio (`maxSlew`), para
/// que un cambio de latencia no produzca un salto audible, con monotonicidad
/// estricta porque `AVAssetWriter` rechaza un PTS que no avance.
final class ProgramClock: @unchecked Sendable {
    private let lock = NSLock()
    private var applied: Double = 0
    private var anchored = false
    private var lastPTS = CMTime.invalid

    /// Cuánto puede moverse la corrección por frame. 2 ms a 30 fps = 60 ms/s:
    /// alcanza una latencia típica de cámara en un par de segundos sin que se
    /// oiga el ajuste. Un salto de golpe sería un tirón en el audio.
    private let maxSlew: Double = 0.002

    /// Empieza una grabación: la PRIMERA corrección se ancla de golpe (el motor
    /// lleva rato midiendo antes del REC, así que el valor ya es bueno) y de ahí
    /// en adelante solo se desliza.
    func begin() {
        lock.lock(); applied = 0; anchored = false; lastPTS = .invalid; lock.unlock()
    }

    /// `hostNow` DEBE tomarse antes de componer. `target` es la latencia medida
    /// de la fuente crítica (nil = no hay medición fiable ⇒ no se corrige).
    func stamp(hostNow: CMTime, target: Double?) -> CMTime {
        lock.lock(); defer { lock.unlock() }
        if let target {
            if !anchored {
                applied = target
                anchored = true
            } else {
                let delta = target - applied
                applied += max(-maxSlew, min(maxSlew, delta))
            }
        }
        var pts = CMTimeSubtract(hostNow, CMTime(seconds: applied, preferredTimescale: 1_000_000_000))
        // Monotonicidad ESTRICTA: el writer descarta en silencio un frame cuyo
        // PTS no avanza, y ese descarte no aparece en ningún contador.
        if lastPTS.isValid, CMTimeCompare(pts, lastPTS) <= 0 {
            pts = CMTimeAdd(lastPTS, CMTime(value: 1, timescale: 1000))
        }
        lastPTS = pts
        return pts
    }

    /// Corrección que se está aplicando ahora mismo, en ms (para el sensor).
    var appliedMs: Double {
        lock.lock(); defer { lock.unlock() }; return applied * 1000
    }
}

/// Contadores acumulados del flujo de frames (ver `flowCounts()`).
struct StudioFlowCounts {
    var camera = 0
    var previewDelivered = 0
    var previewDropped = 0
}

// MARK: - cajas thread-safe (los hilos de captura/render no tocan MainActor)

/// Coalescing REAL del preview — máximo UN hop a main en vuelo, siempre con el
/// frame más nuevo. `DispatchQueue.main.async` por frame NO coalesce nada: con
/// main ocupado los bloques se APILAN, y cada bloque encolado retiene su
/// IOSurface (a canvas 5K son ~59 MB por frame: 20 de backlog = 1.2 GB vivos →
/// presión de memoria → main más lento → más backlog). A los ~15 min el preview
/// parecía 1 fps mientras el archivo salía perfecto — el sink drena en
/// renderQueue directo al encoder y ni se entera (bug de Daniel, 6 ago).
final class PreviewGate: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: IOSurface?
    private var inFlight = false
    private var delivered = 0
    private var dropped = 0
    /// Deja el frame nuevo (el anterior no consumido se libera AQUÍ, no en una
    /// cola). Devuelve true si toca agendar el hop (no hay otro en vuelo).
    func offer(_ s: IOSurface) -> Bool {
        lock.lock(); defer { lock.unlock() }
        latest = s
        if inFlight { dropped += 1; return false }
        inFlight = true
        return true
    }
    /// El hop en main recoge el último frame y abre la puerta al siguiente.
    func take() -> IOSurface? {
        lock.lock(); defer { lock.unlock() }
        let s = latest
        latest = nil
        inFlight = false
        if s != nil { delivered += 1 }
        return s
    }
    /// SENSOR (invariante 5b): cuántos frames LLEGARON al ojo y cuántos se
    /// tiraron porque main no los consumió. La compuerta degrada con gracia,
    /// pero degradar EN SILENCIO fue el patrón de todos los bugs del Estudio:
    /// el "preview a 3 fps" del 7 ago era main saturado tirando frames aquí,
    /// y ningún número lo delataba.
    func counts() -> (delivered: Int, dropped: Int) {
        lock.lock(); defer { lock.unlock() }
        return (delivered, dropped)
    }
}

final class LatestFrameStore: @unchecked Sendable {
    private let lock = NSLock()
    private var store: [StudioSourceKind: CVPixelBuffer] = [:]
    private var stamps: [StudioSourceKind: Double] = [:]
    private var counts: [StudioSourceKind: Int] = [:]

    // MARK: - LATENCIA DE CADA FUENTE (la cura del lip-sync)
    //
    // Un frame de cámara NO nace cuando lo recibimos: nace cuando el sensor lo
    // capturó, y llega tarde por el transporte (la ZV-E10 por UVC es de las
    // peores en esto). El audio, en cambio, se escribe con su PTS REAL de
    // captura. Estampar el video con "ahora" y el audio con "cuando de verdad
    // pasó" es exactamente la asimetría que desincroniza los labios — y se
    // notaba justo en la escena "Mi cámara solo", donde la cara ocupa todo.
    //
    // Aquí se MIDE esa deuda (hostAhora − ptsDelFrame) por fuente. El render
    // loop la resta al estampar. No se supone un valor: se mide el que sea, y
    // si la cámara cambia el suyo, el número lo sigue.
    private var latencySamples: [StudioSourceKind: [Double]] = [:]
    private var latencyMedian: [StudioSourceKind: Double] = [:]

    /// Cota de cordura: por encima de esto la muestra se descarta como reloj de
    /// otro dominio, no como latencia. Sin este techo, un PTS en otra base de
    /// tiempo metería un desfase absurdo y el archivo saldría peor que antes.
    static let maxPlausibleLatency: Double = 0.75

    func set(_ pb: CVPixelBuffer, for kind: StudioSourceKind, pts: CMTime? = nil) {
        let now = CACurrentMediaTime()
        lock.lock()
        store[kind] = pb
        stamps[kind] = now
        counts[kind] = (counts[kind] ?? 0) + 1
        if let pts, pts.isValid, pts.isNumeric {
            let lat = now - CMTimeGetSeconds(pts)
            if lat >= 0, lat <= Self.maxPlausibleLatency {
                var s = latencySamples[kind] ?? []
                s.append(lat)
                if s.count > 90 { s.removeFirst(s.count - 90) }
                latencySamples[kind] = s
                let sorted = s.sorted()
                latencyMedian[kind] = sorted[sorted.count / 2]
            }
        }
        lock.unlock()
    }

    /// Latencia MEDIANA medida de esa fuente, en segundos. `nil` = todavía no
    /// hay muestras válidas (o los relojes no son comparables) ⇒ el llamador no
    /// debe corregir nada: mejor sin corregir que corrigiendo a ciegas.
    func latency(_ kind: StudioSourceKind) -> Double? {
        lock.lock(); defer { lock.unlock() }
        guard let m = latencyMedian[kind], (latencySamples[kind]?.count ?? 0) >= 8 else { return nil }
        return m
    }

    /// Muestras acumuladas de latencia (para el QA y el heartbeat).
    func latencyReport() -> [(StudioSourceKind, Double, Int)] {
        lock.lock(); defer { lock.unlock() }
        return latencyMedian.compactMap { k, v in
            (k, v, latencySamples[k]?.count ?? 0)
        }
    }
    func get(_ kind: StudioSourceKind) -> CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }; return store[kind]
    }
    /// Segundos desde el último frame de esa fuente. `nil` = jamás llegó uno.
    /// ES EL SENSOR de la congelada: sin esto, una fuente muerta se ve idéntica
    /// a una viva porque el compositor sigue pintando el último frame.
    func age(_ kind: StudioSourceKind) -> Double? {
        lock.lock(); defer { lock.unlock() }
        guard let t = stamps[kind] else { return nil }
        return CACurrentMediaTime() - t
    }
    func count(_ kind: StudioSourceKind) -> Int {
        lock.lock(); defer { lock.unlock() }; return counts[kind] ?? 0
    }
    /// Suelta el frame de una fuente (al morir su stream) para no seguir
    /// reciclando una imagen vieja y para devolver el IOSurface a su pool.
    func drop(_ kind: StudioSourceKind) {
        lock.lock(); store[kind] = nil; stamps[kind] = nil; lock.unlock()
    }
    func clear() { lock.lock(); store.removeAll(); stamps.removeAll(); lock.unlock() }
}

/// Latido del SCStream de pantalla — el sensor que faltaba.
///
/// La pregunta correcta NO es "¿la imagen cambió?" (una pantalla quieta no
/// cambia y está perfectamente sana) sino "¿el stream sigue hablando?". Dos
/// canales independientes: el callback de video (llega también con frames
/// `.idle`) y el tap de audio del mismo stream (llega SIEMPRE que el stream
/// vive, mire lo que mire la pantalla). Silencio en AMBOS = muerto.
final class StreamHealth: @unchecked Sendable {
    private let lock = NSLock()
    private var lastVideo: Double = 0
    private var lastAudio: Double = 0
    private var videoBeats = 0
    private var audioBeats = 0
    private var bad: String?
    private var audioExpected = true

    func reset(audioExpected: Bool) {
        lock.lock()
        let now = CACurrentMediaTime()
        lastVideo = now; lastAudio = now
        videoBeats = 0; audioBeats = 0; bad = nil
        self.audioExpected = audioExpected
        lock.unlock()
    }
    func beat() { lock.lock(); lastVideo = CACurrentMediaTime(); videoBeats += 1; lock.unlock() }
    func beatAudio() { lock.lock(); lastAudio = CACurrentMediaTime(); audioBeats += 1; lock.unlock() }
    func markBad(_ why: String) { lock.lock(); bad = why; lock.unlock() }

    /// Segundos de silencio TOTAL del stream (el mínimo de los dos canales:
    /// mientras uno hable, está vivo).
    func silence() -> Double {
        lock.lock(); defer { lock.unlock() }
        let now = CACurrentMediaTime()
        let v = now - lastVideo
        guard audioExpected, audioBeats > 0 else { return v }
        return min(v, now - lastAudio)
    }
    func failure() -> String? { lock.lock(); defer { lock.unlock() }; return bad }
    func beats() -> (video: Int, audio: Int) {
        lock.lock(); defer { lock.unlock() }; return (videoBeats, audioBeats)
    }
}

final class SceneBox: @unchecked Sendable {
    private let lock = NSLock()
    private var scene: StudioScene?
    func set(_ s: StudioScene?) { lock.lock(); scene = s; lock.unlock() }
    func get() -> StudioScene? { lock.lock(); defer { lock.unlock() }; return scene }
}

final class SinkBox: @unchecked Sendable {
    private let lock = NSLock()
    private var sink: ProgramSink?
    func set(_ s: ProgramSink?) { lock.lock(); sink = s; lock.unlock() }
    func get() -> ProgramSink? { lock.lock(); defer { lock.unlock() }; return sink }
}

/// Niveles RMS 0-1 para el Mixer (mic y audio del sistema).
///
/// CADUCAN. Si la fuente deja de entregar buffers (mic desconectado, stream de
/// pantalla muerto), el último valor se queda clavado y el vúmetro pinta una
/// LÍNEA FIJA que parece señal. Sin señal fresca ⇒ el nivel es 0, punto.
final class AudioLevelBox: @unchecked Sendable {
    /// Más de esto sin un buffer nuevo = mudo (a 48kHz llegan ~90/s).
    private static let freshFor: Double = 0.35
    private let lock = NSLock()
    private var mic: Float = 0
    private var system: Float = 0
    private var micAt: Double = 0
    private var systemAt: Double = 0
    private var micCuenta = 0
    func setMic(_ v: Float) {
        lock.lock(); mic = v; micAt = CACurrentMediaTime(); micCuenta &+= 1; lock.unlock()
    }

    /// Cuántos buffers de micrófono han entrado, MONÓTONO desde que se abrió el
    /// Estudio. El guard de voz necesita "¿llegó algo DESDE QUE ARRANCÓ ESTA
    /// TOMA?", y un `Bool` obligaría a acordarse de resetearlo al empezar cada
    /// una — un olvido ahí deja el guard ciego para siempre y en silencio.
    /// Con un contador, el guard toma su propia línea base y no hay nada que
    /// resetear: si el número no se movió, no entró audio.
    func micArrivals() -> Int {
        lock.lock(); defer { lock.unlock() }
        return micCuenta
    }
    func setSystem(_ v: Float) {
        lock.lock(); system = v; systemAt = CACurrentMediaTime(); lock.unlock()
    }
    func get() -> (mic: Float, system: Float) {
        lock.lock(); defer { lock.unlock() }
        let now = CACurrentMediaTime()
        return (now - micAt > Self.freshFor ? 0 : mic,
                now - systemAt > Self.freshFor ? 0 : system)
    }
    /// Segundos desde el último buffer de micrófono. `fresh()` da un sí/no con
    /// un umbral de milésimas, y para un watchdog hace falta la EDAD.
    func micAge() -> Double {
        lock.lock(); defer { lock.unlock() }
        return CACurrentMediaTime() - micAt
    }

    /// Para el heartbeat/diagnóstico: ¿llega audio de verdad?
    func fresh() -> (mic: Bool, system: Bool) {
        lock.lock(); defer { lock.unlock() }
        let now = CACurrentMediaTime()
        return (now - micAt <= Self.freshFor, now - systemAt <= Self.freshFor)
    }
}

enum AudioMath {
    /// Ruido por debajo de esto es silencio para el vúmetro (piso de sala).
    private static let floorDB: Double = -60

    nonisolated(unsafe) private static var described = Set<String>()
    nonisolated(unsafe) static var traceAudio = false      // --studiobench
    nonisolated(unsafe) private static var traceN: [String: Int] = [:]
    private static let describeLock = NSLock()

    // MARK: - latencia del AUDIO (la otra mitad de la sincronía)

    /// El audio se escribe con su PTS real, así que su latencia no se corrige —
    /// pero SÍ hay que conocerla: el desfase que se ve en pantalla es la
    /// DIFERENCIA entre la de la cámara y la del mic, no la de la cámara sola.
    /// Sin este número, "compensar la cámara" sería media medición.
    nonisolated(unsafe) private static var audioLatSamples: [Double] = []
    nonisolated(unsafe) private static var audioLatMedian: Double?
    private static let audioLatLock = NSLock()

    static func noteLatency(_ sb: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        guard pts.isValid, pts.isNumeric else { return }
        let lat = CACurrentMediaTime() - CMTimeGetSeconds(pts)
        guard lat >= 0, lat <= LatestFrameStore.maxPlausibleLatency else { return }
        audioLatLock.lock()
        audioLatSamples.append(lat)
        if audioLatSamples.count > 90 { audioLatSamples.removeFirst(audioLatSamples.count - 90) }
        let s = audioLatSamples.sorted()
        audioLatMedian = s[s.count / 2]
        audioLatLock.unlock()
    }

    /// Latencia mediana del mic en ms (nil = sin muestras suficientes).
    static var lastLatencyMs: Double? {
        audioLatLock.lock(); defer { audioLatLock.unlock() }
        guard audioLatSamples.count >= 8, let m = audioLatMedian else { return nil }
        return m * 1000
    }

    /// Traza periódica (solo en bench): la foto de un buffer CADA ~2s. El primer
    /// buffer siempre sale en silencio (arranque de la sesión) y por eso no
    /// bastaba para diagnosticar la línea fija.
    static func traceOnce(_ sb: CMSampleBuffer, label: String, every: Int) {
        guard traceAudio else { return }
        describeLock.lock()
        let n = (traceN[label] ?? 0) + 1
        traceN[label] = n
        describeLock.unlock()
        guard n % every == 0 else { return }
        let d = probe(sb)
        Log.info(String(format: "TRACE[%@] #%d media=%.5f pico=%.5f rms=%.5f rms-sin-DC=%.5f nivel=%.4f",
                        label, n, d.mean, d.peak, d.rms, d.acRMS, rms(from: sb)))
        // Volcado crudo: qué hay REALMENTE en los bytes. Es la única forma de
        // cerrar la discusión entre "el mic está caliente" y "el lector miente".
        guard n % (every * 3) == 0 else { return }
        var vals: [String] = []
        var hex: [String] = []
        withBufferList(sb) { list in
            guard let buf = list.first, let data = buf.mData else { return }
            let n32 = min(12, Int(buf.mDataByteSize) / 4)
            let f = data.bindMemory(to: Float32.self, capacity: n32)
            let u = data.bindMemory(to: UInt32.self, capacity: n32)
            for i in 0..<n32 {
                vals.append(String(format: "%.4f", f[i]))
                hex.append(String(format: "%08x", u[i]))
            }
            Log.info("DUMP[\(label)] canales=\(buf.mNumberChannels) bytes=\(buf.mDataByteSize) "
                     + "numSamples=\(CMSampleBufferGetNumSamples(sb))")
        }
        Log.info("DUMP[\(label)] float=[\(vals.joined(separator: " "))]")
        Log.info("DUMP[\(label)] hex  =[\(hex.joined(separator: " "))]")
    }

    /// Loggea UNA vez el formato real de cada fuente de audio. Es la evidencia
    /// que le faltaba al bug de la línea fija: si sale `noInterleaved planos=2`,
    /// leer el block buffer plano (lo que hacía v2.3) era leer basura.
    static func describeOnce(_ sb: CMSampleBuffer, label: String) {
        describeLock.lock()
        let isNew = described.insert(label).inserted
        describeLock.unlock()
        guard isNew,
              let fmt = CMSampleBufferGetFormatDescription(sb),
              let a = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee else { return }
        let planar = a.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let float = a.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let d = probe(sb)
        Log.info(String(format: "Audio[%@]: %dHz %dch %@%d %@ flags=0x%02x · planos=%d muestras=%d "
                        + "media(DC)=%.4f pico=%.4f rms=%.4f rms-sin-DC=%.4f",
                        label, Int(a.mSampleRate), Int(a.mChannelsPerFrame),
                        float ? "float" : "int", Int(a.mBitsPerChannel),
                        planar ? "NO-INTERLEAVED" : "interleaved", a.mFormatFlags,
                        d.planes, d.count, d.mean, d.peak, d.rms, d.acRMS))
    }

    struct Probe { var planes = 0; var count = 0; var mean = 0.0; var peak = 0.0; var rms = 0.0; var acRMS = 0.0 }

    /// Diagnóstico crudo de un buffer: media (offset DC), pico, RMS y RMS
    /// quitando la media. Si media≫0 y rms-sin-DC≈0, la señal es un OFFSET, no
    /// sonido — y un vúmetro que mide RMS crudo marca una línea fija para
    /// siempre. Ese es el sintoma exacto que reportó Daniel.
    static func probe(_ sb: CMSampleBuffer) -> Probe {
        var out = Probe()
        var samples: [Double] = []
        forEachSample(sb) { v in samples.append(v) }
        guard !samples.isEmpty else { return out }
        out.count = samples.count
        out.mean = samples.reduce(0, +) / Double(samples.count)
        out.peak = samples.map { abs($0) }.max() ?? 0
        out.rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Double(samples.count))
        out.acRMS = sqrt(samples.reduce(0) { $0 + ($1 - out.mean) * ($1 - out.mean) } / Double(samples.count))
        out.planes = planeCount(sb)
        return out
    }

    private static func planeCount(_ sb: CMSampleBuffer) -> Int {
        var n = 0
        withBufferList(sb) { list in n = list.count }
        return n
    }

    /// RMS normalizado 0-1 desde un CMSampleBuffer PCM.
    ///
    /// ⚠️ SE LEE POR AudioBufferList, NO por el CMBlockBuffer plano. El audio de
    /// AVCaptureAudioDataOutput (mic USB) y el de ScreenCaptureKit es Float32
    /// **NO INTERLEAVED**: su block buffer trae un plano por canal y NO es
    /// contiguo. La versión vieja hacía `CMBlockBufferGetDataPointer(atOffset:0)`
    /// y leía `totalLength` bytes desde ahí — o sea, se salía del primer plano y
    /// promediaba MEMORIA BASURA. Basura estable ⇒ RMS constante ⇒ la línea fija
    /// que el mixer marcaba siempre, aun en silencio absoluto (bug 25 jul).
    static func rms(from sb: CMSampleBuffer) -> Float {
        // Dos pasadas: primero la MEDIA (offset DC), luego el RMS ya sin ella.
        // Un vúmetro debe medir lo que SE OYE (la parte alterna); un offset
        // constante no se oye pero infla el RMS crudo y clava la barra.
        var sum = 0.0, sumSq = 0.0
        var count = 0
        forEachSample(sb) { v in sum += v; count += 1 }
        guard count > 0 else { return 0 }
        let mean = sum / Double(count)
        forEachSample(sb) { v in let d = v - mean; sumSq += d * d }
        let rms = sqrt(sumSq / Double(count))
        guard rms.isFinite, rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return Float(max(0, min(1, (db - floorDB) / -floorDB)))
    }

    /// Recorre las muestras REALES del buffer, plano por plano, normalizadas a
    /// -1…1. Es la única lectura correcta: el audio de AVCapture y de
    /// ScreenCaptureKit es float32 y su CMBlockBuffer NO es contiguo, así que
    /// leerlo plano (lo que hacía v2.3) se salía del primer plano y promediaba
    /// memoria basura.
    static func forEachSample(_ sb: CMSampleBuffer, _ body: (Double) -> Void) {
        guard let fmt = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee else { return }
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        // ⚠️ El ANCHO se lee del formato, NUNCA se asume. El Shure MV7+ entrega
        // PCM **int32** y el código viejo daba por hecho int16: partía cada
        // muestra de 32 bits en dos int16 falsos, y las estadísticas de ESE
        // troceo son casi constantes pase lo que pase por el micro. Ese era el
        // "el mixer siempre marca esa línea" — el medidor no medía sonido,
        // medía la estructura de los bytes. Medido el 25 jul: el lector daba
        // -7.8 dBFS clavado mientras ffmpeg y el propio archivo grabado del
        // mismo micro daban -76 dB y -60 dB.
        let bits = Int(asbd.mBitsPerChannel)
        let bigEndian = asbd.mFormatFlags & kAudioFormatFlagIsBigEndian != 0
        let alignedHigh = asbd.mFormatFlags & kAudioFormatFlagIsAlignedHigh != 0
        let frames = CMSampleBufferGetNumSamples(sb)
        guard frames > 0 else { return }
        withBufferList(sb) { list in
            for buf in list {
                guard let data = buf.mData, buf.mDataByteSize > 0 else { continue }
                let bytes = Int(buf.mDataByteSize)
                let chans = max(1, Int(buf.mNumberChannels))
                // EL CONTENEDOR SE MIDE, no se deduce de mBitsPerChannel: el
                // Shure entrega int24 **alineado alto en 4 bytes** (flags 0x14).
                // Suponer 2 bytes (v2.3) o 3 bytes partía cada muestra por la
                // mitad. bytes / (frames · canales) siempre da el ancho real.
                let stride = bytes / (frames * chans)
                let n = stride > 0 ? bytes / stride : 0
                guard n > 0 else { continue }
                switch (isFloat, stride) {
                case (true, 8):
                    let p = data.bindMemory(to: Float64.self, capacity: n)
                    for i in 0..<n { body(p[i]) }
                case (true, _):
                    let p = data.bindMemory(to: Float32.self, capacity: n)
                    for i in 0..<n { body(Double(p[i])) }
                case (false, 4):
                    let p = data.bindMemory(to: Int32.self, capacity: n)
                    // Alineado ALTO (o int32 real): el valor ya ocupa la parte
                    // alta ⇒ normaliza contra 2^31. Alineado BAJO: los bits
                    // útiles están abajo ⇒ normaliza contra 2^(bits-1).
                    let denom = (alignedHigh || bits >= 32) ? 2_147_483_648.0
                                                            : pow(2.0, Double(max(bits, 1) - 1))
                    for i in 0..<n {
                        var v = bigEndian ? Int32(bitPattern: UInt32(bitPattern: p[i]).byteSwapped) : p[i]
                        if !alignedHigh && bits < 32 {
                            let shift = Int32(32 - bits)
                            v = (v << shift) >> shift        // extiende el signo
                        }
                        body(Double(v) / denom)
                    }
                case (false, 3):
                    let p = data.bindMemory(to: UInt8.self, capacity: bytes)
                    for i in 0..<n {
                        let b0 = Int32(p[i * 3]), b1 = Int32(p[i * 3 + 1]), b2 = Int32(p[i * 3 + 2])
                        var raw = bigEndian ? (b0 << 16 | b1 << 8 | b2) : (b2 << 16 | b1 << 8 | b0)
                        if raw & 0x800000 != 0 { raw -= 0x1000000 }
                        body(Double(raw) / 8_388_608.0)
                    }
                case (false, 1):
                    let p = data.bindMemory(to: Int8.self, capacity: n)
                    for i in 0..<n { body(Double(p[i]) / 128.0) }
                default:                                                // int16
                    let p = data.bindMemory(to: Int16.self, capacity: n)
                    for i in 0..<n {
                        let v = bigEndian ? Int16(bitPattern: UInt16(bitPattern: p[i]).byteSwapped) : p[i]
                        body(Double(v) / 32_768.0)
                    }
                }
            }
        }
    }

    private static func withBufferList(_ sb: CMSampleBuffer, _ body: (UnsafeMutableAudioBufferListPointer) -> Void) {
        var ablSize = 0
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sb, bufferListSizeNeededOut: &ablSize, bufferListOut: nil,
                bufferListSize: 0, blockBufferAllocator: nil,
                blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil) == noErr,
              ablSize > 0 else { return }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: ablSize, alignment: 16)
        defer { raw.deallocate() }
        let ablPtr = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var block: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sb, bufferListSizeNeededOut: nil, bufferListOut: ablPtr,
                bufferListSize: ablSize, blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault,
                flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
                blockBufferOut: &block) == noErr else { return }
        defer { _ = block }   // el block buffer debe vivir mientras se lee
        body(UnsafeMutableAudioBufferListPointer(ablPtr))
    }
}

/// Deadline genérico (invariante #5: toda llamada de sistema con timeout).
/// Réplica utilitaria del patrón de CaptureEngine (allá es private).
enum Deadline {
    @discardableResult
    static func run<T: Sendable>(seconds: Double, name: String,
                                 _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        let once = OnceFlag()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            Task.detached {
                do { let v = try await op(); if once.claim() { cont.resume(returning: v) } }
                catch { if once.claim() { cont.resume(throwing: error) } }
            }
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if once.claim() {
                    cont.resume(throwing: NSError(domain: "SFCast", code: 98, userInfo: [
                        NSLocalizedDescriptionKey: "\(name) no respondió en \(Int(seconds))s"]))
                }
            }
        }
    }
}


/// ARRANQUE REAL DE CADA RAW (v3, 28 ago 2026) — ver `StudioManifest.OutputFile`.
///
/// El desfase entre pistas NO se deriva del cierre: medido el 28 ago, derivarlo
/// de "todos terminan juntos" daba 2.23 s donde el real era 1.63 (18 frames a 30
/// fps), porque la cámara cierra antes que el programa. Esto anota el instante
/// host del PRIMER frame que cada raw pudo escribir, que es el origen honesto.
final class RawStartBox: @unchecked Sendable {
    private let lock = NSLock()
    private var armadaCam = false, armadaPant = false
    private var primeraCam: Double?, primeraPant: Double?

    func arm(camara: Bool, pantalla: Bool) {
        lock.lock()
        if camara { armadaCam = true; primeraCam = nil }
        if pantalla { armadaPant = true; primeraPant = nil }
        lock.unlock()
    }
    func disarm() { lock.lock(); armadaCam = false; armadaPant = false; lock.unlock() }
    /// Se llama en el camino caliente de cada frame: sale por el `guard` en
    /// cuanto la primera ya se anotó, así que el costo es un lock y una lectura.
    func notar(camara: Bool) {
        lock.lock()
        if camara { if armadaCam, primeraCam == nil { primeraCam = CACurrentMediaTime() } }
        else { if armadaPant, primeraPant == nil { primeraPant = CACurrentMediaTime() } }
        lock.unlock()
    }
    func first(camara: Bool) -> Double? {
        lock.lock(); defer { lock.unlock() }
        return camara ? primeraCam : primeraPant
    }
}
