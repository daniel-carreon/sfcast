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
    private(set) var screenAvailable = false     // permiso + stream vivo
    private(set) var cameraAvailable = false
    /// Fuentes activas en la escena que NO están entregando frames (comparador).
    private(set) var starvedSources: Set<StudioSourceKind> = []
    /// La pantalla dejó de entregar frames aunque el stream se cree vivo — el
    /// compositor estaría RECICLANDO el último frame (la "congelada" del 25 jul).
    private(set) var screenFrozen = false
    private(set) var screenRestarts = 0
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
    var onAlert: ((String, Bool) -> Void)?       // (mensaje, esCrítico)

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
        canvasOverride = config.canvasMode.size
        if let o = canvasOverride { canvasSize = o }
        systemAudioWanted = config.systemAudioEnabled
        isRunning = true
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
        canvasOverride = config.canvasMode.size
        let newCanvas = canvasOverride ?? nativeCanvas ?? canvasSize
        let canvasChanged = newCanvas != canvasSize
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
                let cap = Self.captureSize(native: native, canvas: canvasSize)
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
    func applyDeviceSelection(micEnabled: Bool) {
        guard cameraAvailable else { return }   // sin permiso de cámara no hay sesión viva
        let s = AppSettings.load()
        let camID = s.cameraDeviceID
        let micID = s.micDeviceID
        let micOK = micEnabled && Permissions.micGranted
        let session = cameraSession
        sessionQueue.async {
            session.beginConfiguration()
            Self.reconcileInputs(session, camID: camID, micID: micID, micEnabled: micOK)
            session.commitConfiguration()
            if !session.isRunning { session.startRunning() }
            let devs = session.inputs.compactMap { ($0 as? AVCaptureDeviceInput)?.device }
            Log.info("Estudio: dispositivos en caliente → "
                     + devs.map { "\($0.localizedName) [\($0.hasMediaType(.audio) ? "audio" : "video")]" }
                           .joined(separator: " + "))
        }
    }

    // MARK: - pantalla (SCStream con frames + SCRecordingOutput opcional)

    private func startScreenTap(systemAudio: Bool) async throws {
        let content = try await Deadline.run(seconds: 12, name: "SCShareableContent") {
            try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }
        let mainID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainID })
                ?? content.displays.first else {
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

        let cap = Self.captureSize(native: CGSize(width: w, height: h), canvas: canvasSize)
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
    nonisolated static func captureSize(native: CGSize, canvas: CGSize) -> CGSize {
        guard native.width > 1, native.height > 1, canvas.width > 1, canvas.height > 1 else { return native }
        let s = min(canvas.width / native.width, canvas.height / native.height, 1.0)
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
    func retryScreenIfNeeded() {
        guard isRunning, !screenAvailable, !retryingScreen, !restartingScreen,
              Permissions.screenGranted else { return }
        retryingScreen = true
        Task { @MainActor in
            do {
                try await startScreenTap(systemAudio: systemAudioWanted)
                Log.info("Estudio: pantalla enganchada en reintento")
                onStatusChange?()
            } catch {
                Log.error("Estudio: reintento de pantalla falló: \(error.localizedDescription)")
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
            out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            out.alwaysDiscardsLateVideoFrames = true
            out.setSampleBufferDelegate(self, queue: videoQueue)
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
            let resuelta = devs.first(where: { $0.hasMediaType(.video) })
            if let camID, let resuelta, resuelta.uniqueID != camID {
                Log.error("Estudio: LA CÁMARA NO ES LA ELEGIDA — quedó «\(resuelta.localizedName)». "
                          + "La configurada no está conectada.")
                Task { @MainActor in
                    self.onAlert?("Ojo: estás con «\(resuelta.localizedName)», no con tu cámara de "
                                  + "siempre. ¿Está encendida y conectada?", true)
                }
            }
            if !session.isRunning { session.startRunning() }
        }
        // Optimista: si al final no entrega frames, el comparador starved lo
        // delata en la UI (jamás en silencio).
        cameraAvailable = true
    }

    /// Reconcilia los INPUTS de la sesión con lo pedido: deja EXACTAMENTE la
    /// cámara elegida y el mic elegido (o ninguno si está apagado). El código
    /// viejo solo AGREGABA si faltaba — cambiar de cámara en Ajustes no
    /// aplicaba de verdad hasta relanzar la app. Corre SIEMPRE en sessionQueue.
    nonisolated private static func reconcileInputs(_ session: AVCaptureSession,
                                                    camID: String?, micID: String?,
                                                    micEnabled: Bool) {
        func inputs() -> [AVCaptureDeviceInput] {
            session.inputs.compactMap { $0 as? AVCaptureDeviceInput }
        }
        let wantCam = Devices.camera(id: camID)
        for i in inputs() where i.device.hasMediaType(.video) && i.device.uniqueID != wantCam?.uniqueID {
            session.removeInput(i)
        }
        if let cam = wantCam,
           !inputs().contains(where: { $0.device.hasMediaType(.video) }),
           let input = try? AVCaptureDeviceInput(device: cam),
           session.canAddInput(input) {
            session.addInput(input)
        }
        let wantMic = micEnabled ? Devices.microphone(id: micID) : nil
        for i in inputs() where i.device.hasMediaType(.audio) && !i.device.hasMediaType(.video)
            && i.device.uniqueID != wantMic?.uniqueID {
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
        out.startRecording(to: url, recordingDelegate: del)
    }

    func stopCameraMovie() async {
        guard let out = cameraMovieOut, out.isRecording else { return }
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
            }
        }
    }

    /// El comparador de la CÁMARA. `frames.age` ya existía como sensor; lo que
    /// faltaba era que alguien lo MIRARA y avisara: un frame viejo se compone
    /// igual de bien que uno nuevo, así que una cámara muerta produce un video
    /// impecable de una foto fija.
    private func checkCameraHealth() {
        guard isRunning, cameraAvailable else { return }
        guard let age = frames.age(.camera) else { return }
        let dead = age > Self.deadAfter
        if dead != cameraFrozen {
            cameraFrozen = dead
            onStatusChange?()
            onSourceFrozen?("camera", dead, "sin imagen nueva (¿se apagó sola? ¿cable USB?)")
            if dead {
                Log.error(String(format: "Estudio: CÁMARA CONGELADA — %.1fs sin imagen nueva "
                                 + "(¿se apagó sola? ¿cable USB?)", age))
                onAlert?("La cámara dejó de dar imagen: se está grabando su último frame congelado.", true)
                if StudioController.shared.recorder.isRecording
                    || RecordingController.shared.state != .idle {
                    notify("SFCast — LA CÁMARA SE APAGÓ",
                           "Llevas grabando con la imagen CONGELADA. Revisa la cámara "
                           + "(las Sony se apagan solas).")
                    Log.error("Estudio: NOTIFICACIÓN enviada (cámara congelada grabando)")
                }
            } else {
                Log.info("Estudio: cámara viva de nuevo")
                onAlert?("La cámara volvió.", false)
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
                    Log.info("Estudio: la cámara elegida volvió a aparecer — reenganchando")
                    applyDeviceSelection(micEnabled: true)
                }
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
                onAlert?("Pantalla congelada — reenganchando la captura", true)
                restartScreenTap(reason: bad ?? String(format: "%.1fs sin latido", silence))
            } else {
                Log.info("Estudio: pantalla viva de nuevo")
                onAlert?("Pantalla recuperada", false)
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
        onAlert?("No pude reenganchar la pantalla: \(motivo)", true)
        if RecordingController.shared.state != .idle
            || StudioController.shared.recorder.isRecording {
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
            self.onAlert?("La captura de pantalla se cayó — reenganchando", true)
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

extension StudioEngine: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output is AVCaptureVideoDataOutput {
            // QA (--freezecam): simula que la cámara se apagó sola (auto power
            // off de las Sony) tirando sus frames en silencio, que es EXACTO lo
            // que se vio el 9 ago: el store conserva el último y el compositor
            // sigue produciendo 30 fps impecables de una foto fija.
            if StudioEngine.qaFreezeCamera { return }
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
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
        let radius = item.circleMask ? minSide / 2 : minSide * SceneGlow.cornerFraction
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
        lock.unlock()
    }

    var effective: Int { lock.lock(); defer { lock.unlock() }; return current }

    /// Escalones por debajo del objetivo. Se paran en 12: por debajo el
    /// resultado ya no es "video con menos frames", es otra cosa.
    private func ladder(_ target: Int) -> [Int] {
        [target, Int(Double(target) * 0.8), Int(Double(target) * 0.66),
         Int(Double(target) * 0.5)].map { max(12, $0) }
    }

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
    func setMic(_ v: Float) {
        lock.lock(); mic = v; micAt = CACurrentMediaTime(); lock.unlock()
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
