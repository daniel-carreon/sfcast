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
    var onStatusChange: (() -> Void)?

    // MARK: - infra compartida con los hilos de captura/render

    let frames = LatestFrameStore()
    let levels = AudioLevelBox()
    let sceneBox = SceneBox()
    /// Sink de grabación (nil = no se está grabando). Lo pone StudioRecorder.
    let sink = SinkBox()

    private let renderQueue = DispatchQueue(label: "so.saasfactory.sfcast.studio.render", qos: .userInitiated)
    private let videoQueue = DispatchQueue(label: "so.saasfactory.sfcast.studio.video", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "so.saasfactory.sfcast.studio.audio", qos: .userInitiated)

    private var renderTimer: DispatchSourceTimer?
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
    private var systemAudioWanted = true
    private var retryingScreen = false

    var onPreviewSurface: ((IOSurface) -> Void)?   // llega en MAIN thread

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
        onStatusChange?()
        Log.info("Estudio: motor arriba (pantalla=\(screenAvailable) cámara=\(cameraAvailable) canvas=\(Int(canvasSize.width))x\(Int(canvasSize.height))@\(fps))")
    }

    func stop() async {
        guard isRunning else { return }
        isRunning = false
        renderTimer?.cancel()
        renderTimer = nil
        if let s = screenStream {
            try? await Deadline.run(seconds: 8, name: "studio stopCapture") { try await s.stopCapture() }
        }
        screenStream = nil
        screenRecOutput = nil
        screenAvailable = false
        stopCameraTap()
        frames.clear()
        onStatusChange?()
        Log.info("Estudio: motor abajo")
    }

    func setActiveScene(_ scene: StudioScene?) {
        sceneBox.set(scene)
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
        canvasSize = canvasOverride ?? CGSize(width: w, height: h)

        let cfg = SCStreamConfiguration()
        cfg.width = w
        cfg.height = h
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        cfg.showsCursor = true
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.queueDepth = 5
        cfg.capturesAudio = systemAudio
        // La ventana del Estudio lleva sharingType=.none: no hace falta filtrarla.
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: cfg, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        if systemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        }
        try await Deadline.run(seconds: 12, name: "studio startCapture") { try await stream.startCapture() }
        screenStream = stream
        screenAvailable = true
    }

    /// Reintento de pantalla: si el permiso llegó DESPUÉS de abrir el Estudio
    /// (el re-toggle post-rebuild), engancha el tap sin reabrir la ventana.
    /// Lo llama el controller cada ~3s mientras la ventana está abierta.
    func retryScreenIfNeeded() {
        guard isRunning, !screenAvailable, !retryingScreen, Permissions.screenGranted else { return }
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
        do { try stream.removeRecordingOutput(rec) }
        catch { Log.error("Estudio: removeRecordingOutput falló: \(error.localizedDescription)") }
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
        cameraSession.beginConfiguration()
        cameraSession.sessionPreset = .high
        if !cameraSession.inputs.contains(where: { ($0 as? AVCaptureDeviceInput)?.device.hasMediaType(.video) ?? false }),
           let device = Devices.camera(id: AppSettings.load().cameraDeviceID),
           let input = try? AVCaptureDeviceInput(device: device),
           cameraSession.canAddInput(input) {
            cameraSession.addInput(input)
        }
        // Mic en la MISMA sesión: va al raw de cámara (.mov con voz, estilo
        // Screen Studio) y al programa. Solo con permiso YA otorgado (broker).
        if micEnabled, Permissions.micGranted,
           !cameraSession.inputs.contains(where: { ($0 as? AVCaptureDeviceInput)?.device.hasMediaType(.audio) ?? false }),
           let mic = Devices.microphone(id: AppSettings.load().micDeviceID),
           let micInput = try? AVCaptureDeviceInput(device: mic),
           cameraSession.canAddInput(micInput) {
            cameraSession.addInput(micInput)
        }
        if cameraVideoOut == nil {
            let out = AVCaptureVideoDataOutput()
            out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            out.alwaysDiscardsLateVideoFrames = true
            out.setSampleBufferDelegate(self, queue: videoQueue)
            if cameraSession.canAddOutput(out) { cameraSession.addOutput(out); cameraVideoOut = out }
        }
        if cameraAudioOut == nil {
            let out = AVCaptureAudioDataOutput()
            out.setSampleBufferDelegate(self, queue: audioQueue)
            if cameraSession.canAddOutput(out) { cameraSession.addOutput(out); cameraAudioOut = out }
        }
        // El MovieFileOutput se añade AQUÍ (antes de startRunning), NO al grabar:
        // agregar un output a una sesión corriendo reconfigura el grafo de audio
        // y ese pop quedaba GRABADO al inicio (el "estruendo" — feedback v2.3).
        if cameraMovieOut == nil {
            let out = AVCaptureMovieFileOutput()
            if cameraSession.canAddOutput(out) { cameraSession.addOutput(out); cameraMovieOut = out }
        }
        cameraSession.commitConfiguration()
        let session = cameraSession
        DispatchQueue.global().async { if !session.isRunning { session.startRunning() } }
        cameraAvailable = cameraVideoOut != nil
    }

    private func stopCameraTap() {
        let session = cameraSession
        DispatchQueue.global().async { if session.isRunning { session.stopRunning() } }
        cameraAvailable = false
    }

    /// RAW de cámara (salida A): .mov con video+mic, patrón camOnly probado.
    /// El output YA vive en la sesión desde el arranque — aquí solo se escribe
    /// (cero reconfiguración del grafo = cero pop).
    func startCameraMovie(url: URL) {
        guard cameraAvailable, let out = cameraMovieOut, !out.isRecording else { return }
        let del = CamFileDelegate()
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

    private func startRenderLoop() {
        let timer = DispatchSource.makeTimerSource(queue: renderQueue)
        timer.schedule(deadline: .now(), repeating: .init(1.0 / Double(fps)), leeway: .milliseconds(3))
        let comp = compositor
        let frames = frames
        let scenes = sceneBox
        let sink = sink
        let canvas = canvasSize
        timer.setEventHandler { [weak self] in
            guard let scene = scenes.get() else { return }
            let t = CACurrentMediaTime()
            var starved: Set<StudioSourceKind> = []
            guard let pb = comp.compose(scene: scene, canvas: canvas, t: t,
                                        frames: frames, starved: &starved) else { return }
            // preview (main thread; coalescing natural del runloop)
            if let surface = CVPixelBufferGetIOSurface(pb)?.takeUnretainedValue() {
                let s = unsafeBitCast(surface, to: IOSurface.self)
                DispatchQueue.main.async { [weak self] in
                    self?.onPreviewSurface?(s)
                    self?.updateStarved(starved)
                }
            }
            // grabación del programa (salida B) — best-effort, jamás bloquea
            sink.get()?.appendVideo(pb, hostTime: CMClockGetTime(CMClockGetHostTimeClock()))
        }
        timer.resume()
        renderTimer = timer
    }

    private func updateStarved(_ s: Set<StudioSourceKind>) {
        if s != starvedSources {
            starvedSources = s
            onStatusChange?()
        }
    }

    /// QA (--studiotest): compone UN frame del programa con el estado actual,
    /// para evidenciar el compositor/escena sin depender de screenshots del
    /// sistema (la ventana es sharingType=.none). Thread-safe vs el render loop.
    func snapshotProgramFrame() -> CVPixelBuffer? {
        guard let scene = sceneBox.get() else { return nil }
        var starved: Set<StudioSourceKind> = []
        return compositor.compose(scene: scene, canvas: canvasSize,
                                  t: CACurrentMediaTime(), frames: frames, starved: &starved)
    }
}

// MARK: - delegates de captura (corren en videoQueue/audioQueue)

extension StudioEngine: SCStreamOutput {
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .screen:
            guard sb.isValid,
                  let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let statusRaw = attachments.first?[.status] as? Int,
                  SCFrameStatus(rawValue: statusRaw) == .complete,
                  let pb = CMSampleBufferGetImageBuffer(sb) else { return }
            frames.set(pb, for: .screen)
        case .audio:
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
                 frames: LatestFrameStore, starved: inout Set<StudioSourceKind>) -> CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }
        var image = CIImage(color: CIColor(red: 0.04, green: 0.04, blue: 0.05))
            .cropped(to: CGRect(origin: .zero, size: canvas))
        for item in scene.items where item.enabled {
            guard let src = sourceImage(kind: item.kind, t: t, canvas: canvas, frames: frames) else {
                starved.insert(item.kind)   // COMPARADOR: fuente activa sin frames
                continue
            }
            image = place(src, item: item, canvas: canvas).composited(over: image)
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

    /// Coloca la imagen de la fuente en su rect normalizado del canvas
    /// (aspect-fill con recorte centrado, o aspect-fit), máscara circular
    /// opcional (burbuja Loom) y opacidad.
    private func place(_ src: CIImage, item: SceneItem, canvas: CGSize) -> CIImage {
        let target = CGRect(x: item.rect.origin.x * canvas.width,
                            y: item.rect.origin.y * canvas.height,
                            width: item.rect.width * canvas.width,
                            height: item.rect.height * canvas.height)
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

final class LatestFrameStore: @unchecked Sendable {
    private let lock = NSLock()
    private var store: [StudioSourceKind: CVPixelBuffer] = [:]
    func set(_ pb: CVPixelBuffer, for kind: StudioSourceKind) {
        lock.lock(); store[kind] = pb; lock.unlock()
    }
    func get(_ kind: StudioSourceKind) -> CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }; return store[kind]
    }
    func clear() { lock.lock(); store.removeAll(); lock.unlock() }
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
final class AudioLevelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var mic: Float = 0
    private var system: Float = 0
    func setMic(_ v: Float) { lock.lock(); mic = v; lock.unlock() }
    func setSystem(_ v: Float) { lock.lock(); system = v; lock.unlock() }
    func get() -> (mic: Float, system: Float) {
        lock.lock(); defer { lock.unlock() }; return (mic, system)
    }
}

enum AudioMath {
    /// RMS normalizado 0-1 desde un CMSampleBuffer PCM (Int16 o Float32),
    /// mapeado tipo vúmetro (-50dB → 0, 0dB → 1) como el MicLevelMeter.
    static func rms(from sb: CMSampleBuffer) -> Float {
        guard let block = CMSampleBufferGetDataBuffer(sb) else { return 0 }
        var length = 0
        var dataPointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &length, dataPointerOut: &dataPointer) == noErr,
              let data = dataPointer, length > 0 else { return 0 }
        guard let fmt = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee else { return 0 }
        var sum: Double = 0
        var count = 0
        if asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            let n = length / MemoryLayout<Float32>.size
            data.withMemoryRebound(to: Float32.self, capacity: n) { p in
                for i in 0..<n { sum += Double(p[i] * p[i]) }
            }
            count = n
        } else {
            let n = length / MemoryLayout<Int16>.size
            data.withMemoryRebound(to: Int16.self, capacity: n) { p in
                for i in 0..<n {
                    let v = Double(p[i]) / 32768.0
                    sum += v * v
                }
            }
            count = n
        }
        guard count > 0 else { return 0 }
        let rms = sqrt(sum / Double(count))
        let db = 20 * log10(max(rms, 1e-7))
        return Float(max(0, min(1, (db + 50) / 50)))
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
