import Foundation
import AppKit
import AVFoundation
import ScreenCaptureKit
import CoreImage
import CoreMedia
import CoreVideo
import IOSurface

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
    var onStatusChange: (() -> Void)?
    /// Aviso de alto nivel para la UI (congelada / disco / recuperada).
    var onAlert: ((String, Bool) -> Void)?       // (mensaje, esCrítico)

    /// Solo para marcar "esta fuente lleva rato sin imagen nueva" en la UI.
    /// NO dispara nada: una pantalla quieta es legítima.
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

    private let renderQueue = DispatchQueue(label: "so.saasfactory.sfcast.studio.render", qos: .userInitiated)
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
            }
        } else {
            screenAvailable = false
            if Permissions.canPrompt { CGRequestScreenCaptureAccess() }
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
        if fpsChanged || audioChanged, let stream = screenStream, let cfg = screenCfg {
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
            cfg.capturesAudio = systemAudioWanted
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

        let cfg = SCStreamConfiguration()
        cfg.width = w
        cfg.height = h
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
        startRenderLoop()
    }

    private func startRenderLoop() {
        let timer = DispatchSource.makeTimerSource(queue: renderQueue)
        timer.schedule(deadline: .now(), repeating: .init(1.0 / Double(fps)), leeway: .milliseconds(3))
        let comp = compositor
        let frames = frames
        let scenes = sceneBox
        let sink = sink
        let canvas = canvasSize
        let preview = previewGate
        timer.setEventHandler { [weak self] in
            guard let scene = scenes.get() else { return }
            let t = CACurrentMediaTime()
            var starved: Set<StudioSourceKind> = []
            var stale: Set<StudioSourceKind> = []
            guard let pb = comp.compose(scene: scene, canvas: canvas, t: t,
                                        frames: frames, starved: &starved,
                                        stale: &stale) else { return }
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
            // grabación del programa (salida B) — best-effort, jamás bloquea
            sink.get()?.appendVideo(pb, hostTime: CMClockGetTime(CMClockGetHostTimeClock()))
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
            Task { @MainActor in self?.checkStreamHealth() }
        }
    }

    private func checkStreamHealth() {
        guard isRunning, screenAvailable, !restartingScreen, !retryingScreen else { return }
        let silence = screenHealth.silence()
        let bad = screenHealth.failure()
        let dead = bad != nil || silence > Self.deadAfter
        if dead != screenFrozen {
            screenFrozen = dead
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
                Log.error("Estudio: reenganche falló: \(error.localizedDescription)")
                onAlert?("No pude reenganchar la pantalla: \(error.localizedDescription)", true)
                onStatusChange?()
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
            frames.set(pb, for: .screen)
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
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
            frames.set(pb, for: .camera)
        } else if output is AVCaptureAudioDataOutput {
            AudioMath.describeOnce(sb, label: "mic")
            AudioMath.traceOnce(sb, label: "mic", every: 180)
            levels.setMic(AudioMath.rms(from: sb))
            sink.get()?.appendMicAudio(sb)
        }
    }
}

// MARK: - compositor CoreImage (corre en renderQueue)

/// N fuentes + layout de escena → UN frame de programa (CVPixelBuffer BGRA,
/// IOSurface-backed). CoreImage = GPU sin shaders propios ni deps externas.
final class Compositor: @unchecked Sendable {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var pool: CVPixelBufferPool?
    private var poolSize = CGSize.zero
    private let lock = NSLock()   // render loop vs snapshot de QA

    func compose(scene: StudioScene, canvas: CGSize, t: Double,
                 frames: LatestFrameStore, starved: inout Set<StudioSourceKind>,
                 stale: inout Set<StudioSourceKind>) -> CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }
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
            // ARO NEÓN: halo DEBAJO del video, anillo ENCIMA — igual que la
            // burbuja del Loom (allá el shadow vive en glowView y el borde en
            // innerView, que dibuja sobre el contenido).
            let glow = glowLayers(item: item, canvas: canvas)
            if let halo = glow?.halo { image = halo.composited(over: image) }
            image = place(src, item: item, canvas: canvas).composited(over: image)
            if let ring = glow?.ring { image = ring.composited(over: image) }
        }
        guard let pb = makeBuffer(canvas) else { return nil }
        context.render(image, to: pb, bounds: CGRect(origin: .zero, size: canvas),
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return pb
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
    private var glowCache: [GlowKey: (halo: CIImage, ring: CIImage)] = [:]

    /// Devuelve las dos capas del aro. **Cacheadas**: dibujar el anillo y
    /// desenfocar el halo en cada frame costaría 30 veces por segundo lo mismo
    /// que cuesta una vez; solo cambian si cambia el rect, el color o el recorte.
    private func glowLayers(item: SceneItem, canvas: CGSize) -> (halo: CIImage, ring: CIImage)? {
        guard let rgb = item.glow.rgb else { return nil }
        let target = targetRect(item, canvas: canvas)
        guard target.width > 4, target.height > 4 else { return nil }
        let key = GlowKey(x: Int(target.origin.x.rounded()), y: Int(target.origin.y.rounded()),
                          w: Int(target.width.rounded()), h: Int(target.height.rounded()),
                          circle: item.circleMask, glow: item.glow.rawValue,
                          opacity: Int((item.opacity * 100).rounded()))
        if let hit = glowCache[key] { return hit }

        let minSide = min(target.width, target.height)
        let ringW = max(2.0, minSide * SceneGlow.ringFraction)
        let halo = minSide * SceneGlow.haloFraction
        // El desenfoque gaussiano muere a ~3σ: ese es el margen que hay que
        // dejar alrededor o el halo sale cortado en recto (el mismo error que
        // el `glowPad` corrige en el NSPanel de la burbuja).
        let pad = halo * 3 + ringW
        let box = target.insetBy(dx: -pad, dy: -pad)
        // Con `circleMask` el video se recorta al círculo INSCRITO (lado menor,
        // centrado — ver `place`). El aro tiene que ser ESE círculo, no un
        // óvalo del rect completo, o quedaría despegado del recorte.
        var shape = target.offsetBy(dx: -box.origin.x, dy: -box.origin.y)
        if item.circleMask {
            shape = CGRect(x: shape.midX - minSide / 2, y: shape.midY - minSide / 2,
                           width: minSide, height: minSide)
        }
        let radius = item.circleMask ? minSide / 2 : minSide * 0.035
        let alpha = item.opacity

        guard let ringImg = drawShape(size: box.size, rect: shape, radius: radius, rgb: rgb,
                                      alpha: SceneGlow.ringAlpha * alpha, stroke: ringW),
              let bodyImg = drawShape(size: box.size, rect: shape, radius: radius, rgb: rgb,
                                      alpha: SceneGlow.haloAlpha * alpha, stroke: nil)
        else { return nil }

        let blurred = bodyImg
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: halo])
            .cropped(to: CGRect(origin: .zero, size: box.size))
        let offset = CGAffineTransform(translationX: box.origin.x, y: box.origin.y)
        let layers = (halo: blurred.transformed(by: offset),
                      ring: ringImg.transformed(by: offset))
        if glowCache.count > 24 { glowCache.removeAll() }   // techo simple
        glowCache[key] = layers
        return layers
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
    /// Deja el frame nuevo (el anterior no consumido se libera AQUÍ, no en una
    /// cola). Devuelve true si toca agendar el hop (no hay otro en vuelo).
    func offer(_ s: IOSurface) -> Bool {
        lock.lock(); defer { lock.unlock() }
        latest = s
        if inFlight { return false }
        inFlight = true
        return true
    }
    /// El hop en main recoge el último frame y abre la puerta al siguiente.
    func take() -> IOSurface? {
        lock.lock(); defer { lock.unlock() }
        let s = latest
        latest = nil
        inFlight = false
        return s
    }
}

final class LatestFrameStore: @unchecked Sendable {
    private let lock = NSLock()
    private var store: [StudioSourceKind: CVPixelBuffer] = [:]
    private var stamps: [StudioSourceKind: Double] = [:]
    private var counts: [StudioSourceKind: Int] = [:]
    func set(_ pb: CVPixelBuffer, for kind: StudioSourceKind) {
        lock.lock()
        store[kind] = pb
        stamps[kind] = CACurrentMediaTime()
        counts[kind] = (counts[kind] ?? 0) + 1
        lock.unlock()
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
