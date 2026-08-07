import Foundation
import AVFoundation
import CoreMedia
import CoreVideo

/// MODO ESTUDIO — grabación de sesión: orquesta la DOBLE SALIDA y escribe el
/// manifest (el contrato con SFStudio / edición agéntica).
///
/// Salida A (raw, Screen Studio):  screen.mp4 (SCRecordingOutput del stream de
///   preview) + camera.mov (MovieFileOutput de la sesión de cámara, con mic).
/// Salida B (programa, OBS Source Record):  seg-001.mp4 vía ProgramSink
///   (AVAssetWriter alimentado por el compositor). Se llama seg-001 A PROPÓSITO:
///   una sesión de Estudio queda 100% compatible con el Historial → "↑ subir" →
///   worker del VPS (concat de 1 segmento) → viewer, sin tocar ese pipeline.
@MainActor
final class StudioRecorder {
    enum State { case idle, recording, stopping }
    private(set) var state: State = .idle
    private(set) var videoID = ""
    private(set) var startedAt = Date()
    private var sessionDir: URL!
    private var sink: ProgramSink?
    private var timeline: [StudioManifest.SceneSwitch] = []
    private var activeOutputs = StudioOutputs()
    private var wroteScreen = false
    private var wroteCamera = false
    /// Archivos extra de raw de pantalla si hubo que reenganchar a mitad.
    private var screenRawFiles: [String] = []
    private var health: Task<Void, Never>?
    private var lowDiskWarned = false

    var isRecording: Bool { state == .recording }
    var elapsed: TimeInterval { state == .recording ? Date().timeIntervalSince(startedAt) : 0 }

    /// Avisos hacia la UI (disco, congelada, auto-stop).
    var onAlert: ((String, Bool) -> Void)?
    /// Lo llama el health monitor si el disco se acaba: hay que DETENER.
    var onEmergencyStop: (() -> Void)?

    // MARK: - guardias de disco

    /// Sin esto, "Disk Full" mata los writers a mitad y te quedas con archivos
    /// truncados sin una sola advertencia (lo que pasó el 25 jul: 6 GB en 50
    /// min llenaron el disco y camera.mov murió con `Disk Full` a los 43 min).
    static let minFreeBytesToStart: Int64 = 5 * 1_000_000_000    // 5 GB
    static let warnFreeBytes: Int64 = 3 * 1_000_000_000          // 3 GB
    static let stopFreeBytes: Int64 = 1_200_000_000              // 1.2 GB

    static func freeBytes() -> Int64 {
        let url = AppSettings.recordingsDir
        if let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let b = v.volumeAvailableCapacityForImportantUsage { return b }
        if let a = try? FileManager.default.attributesOfFileSystem(forPath: url.path),
           let b = (a[.systemFreeSize] as? NSNumber)?.int64Value { return b }
        return .max
    }

    static func gb(_ bytes: Int64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
    }

    /// Arranca la grabación con el set de salidas configurado. Devuelve error
    /// legible si NINGUNA salida pudo activarse (jamás grabar "nada" en silencio).
    func start(engine: StudioEngine, config: StudioConfig, activeScene: StudioScene?) throws {
        guard state == .idle else { return }
        // Cross-guard: el modo Loom no puede estar grabando (compartirían cámara).
        guard RecordingController.shared.state == .idle else {
            throw NSError(domain: "SFCast", code: 10, userInfo: [
                NSLocalizedDescriptionKey: "Hay una grabación Loom en curso. Deténla antes de grabar en el Estudio."])
        }
        // PREFLIGHT de disco: mejor no arrancar que morir a los 43 minutos.
        let free = Self.freeBytes()
        guard free >= Self.minFreeBytesToStart else {
            throw NSError(domain: "SFCast", code: 12, userInfo: [
                NSLocalizedDescriptionKey:
                    "Solo quedan \(Self.gb(free)) libres en el disco. Libera espacio antes de grabar "
                    + "(mínimo \(Self.gb(Self.minFreeBytesToStart)))."])
        }
        videoID = makeVideoID()
        startedAt = Date()
        sessionDir = AppSettings.recordingsDir.appendingPathComponent(videoID)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        activeOutputs = config.outputs
        timeline = []
        if let s = activeScene {
            timeline.append(.init(t: 0, sceneID: s.id, sceneName: s.name))
        }

        var activated: [String] = []
        screenRawFiles = []
        lowDiskWarned = false
        if config.outputs.rawScreen && engine.screenAvailable {
            do {
                try engine.attachScreenRecording(url: sessionDir.appendingPathComponent("screen.mp4"))
                wroteScreen = true
                screenRawFiles = ["screen.mp4"]
                activated.append("screen.mp4")
            } catch {
                Log.error("Estudio: raw de pantalla no arrancó: \(error.localizedDescription)")
            }
        }
        // Si el motor reengancha la pantalla a mitad, el raw sigue en un archivo
        // NUEVO. El corte queda en el manifest — no se pierde ni se disimula.
        engine.onNeedNewScreenRawURL = { [weak self] in
            guard let self, let dir = self.sessionDir else { return nil }
            let name = String(format: "screen-%03d.mp4", self.screenRawFiles.count + 1)
            self.screenRawFiles.append(name)
            return dir.appendingPathComponent(name)
        }
        if config.outputs.rawCamera && engine.cameraAvailable {
            engine.setCameraRawBitrate(kbps: config.programQuality.cameraRawKbps)
            engine.startCameraMovie(url: sessionDir.appendingPathComponent("camera.mov"))
            wroteCamera = true
            activated.append("camera.mov")
        }
        if config.outputs.program {
            let s = ProgramSink(url: sessionDir.appendingPathComponent("seg-001.mp4"),
                                width: Int(engine.canvasSize.width),
                                height: Int(engine.canvasSize.height),
                                fps: engine.fps,
                                quality: config.programQuality)
            if s.prepare() {
                sink = s
                engine.sink.set(s)
                activated.append("seg-001.mp4 (programa)")
            } else {
                Log.error("Estudio: el writer del programa no arrancó")
            }
        }
        guard !activated.isEmpty else {
            try? FileManager.default.removeItem(at: sessionDir)
            throw NSError(domain: "SFCast", code: 11, userInfo: [
                NSLocalizedDescriptionKey: "Ninguna salida pudo activarse (¿permisos de pantalla/cámara?)."])
        }
        state = .recording
        Log.info("Estudio: grabando \(videoID) → [\(activated.joined(separator: ", "))] "
                 + "calidad=\(config.programQuality.rawValue) libre=\(Self.gb(free))")
        startHealthMonitor(engine: engine)
    }

    // MARK: - health monitor (el latido que faltaba)

    /// Cada 15s: deja rastro en el log de si la cosa está VIVA (frames de
    /// pantalla nuevos, audio fresco, disco) y actúa cuando no. El 25 jul una
    /// sesión grabó 50 minutos congelada y el log no dijo NADA hasta el cierre.
    private func startHealthMonitor(engine: StudioEngine) {
        health?.cancel()
        health = Task { @MainActor [weak self] in
            var ticks = 0
            // Baseline del FLUJO (v2.8): cam/preview en fps por delta de
            // contadores entre latidos. El "preview a 3 fps" del 7 ago habría
            // sido visible aquí al primer ❤︎ — en su lugar, degradó en silencio.
            var lastFlow = engine.flowCounts()
            var lastFlowAt = CACurrentMediaTime()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self, self.state == .recording else { return }
                ticks += 1
                let free = Self.freeBytes()
                let fresh = engine.levels.fresh()
                let st = self.sink?.snapshot()
                let beats = engine.screenHealth.beats()
                let flow = engine.flowCounts()
                let now = CACurrentMediaTime()
                let dt = max(now - lastFlowAt, 0.001)
                let camFPS = Double(flow.camera - lastFlow.camera) / dt
                let prevFPS = Double(flow.previewDelivered - lastFlow.previewDelivered) / dt
                let prevDrops = flow.previewDropped - lastFlow.previewDropped
                lastFlow = flow
                lastFlowAt = now
                Log.info(String(format: "Estudio ❤︎ %ds — stream:%.1fs-mudo (v=%d a=%d) imagen:%@ "
                                + "mic:%@ sys:%@ frames:%d drops:%d cam:%.0ffps prev:%.0ffps(-%d) libre:%@",
                                Int(self.elapsed), engine.screenHealth.silence(),
                                beats.video, beats.audio,
                                engine.screenFrozen ? "CONGELADA" : "ok",
                                fresh.mic ? "ok" : "MUDO", fresh.system ? "ok" : "mudo",
                                st?.videoFrames ?? 0, st?.droppedFrames ?? 0,
                                camFPS, prevFPS, prevDrops, Self.gb(free)))
                if free < Self.stopFreeBytes {
                    Log.error("Estudio: DISCO CASI LLENO (\(Self.gb(free))) — deteniendo para salvar lo grabado")
                    self.onAlert?("Disco casi lleno (\(Self.gb(free))) — detuve la grabación para no corromperla", true)
                    notify("SFCast", "Disco casi lleno: detuve la grabación para salvarla.")
                    self.onEmergencyStop?()
                    return
                }
                if free < Self.warnFreeBytes && !self.lowDiskWarned {
                    self.lowDiskWarned = true
                    Log.error("Estudio: disco bajo (\(Self.gb(free)))")
                    self.onAlert?("Disco bajo: \(Self.gb(free)) libres", true)
                    notify("SFCast", "Disco bajo (\(Self.gb(free))). Considera detener y liberar espacio.")
                }
            }
        }
    }

    /// El switch de escena EN VIVO queda en el timeline (va al manifest).
    func sceneSwitched(_ scene: StudioScene) {
        guard state == .recording else { return }
        timeline.append(.init(t: Date().timeIntervalSince(startedAt),
                              sceneID: scene.id, sceneName: scene.name))
    }

    /// Detiene TODO, espera los cierres (con deadline), escribe manifest.json +
    /// meta.json (compat VPS) y registra en el Historial. Devuelve el sessionDir.
    func stop(engine: StudioEngine, config: StudioConfig) async -> URL? {
        guard state == .recording else { return nil }
        state = .stopping
        health?.cancel(); health = nil
        engine.onNeedNewScreenRawURL = nil
        let duration = Date().timeIntervalSince(startedAt)
        let dir = sessionDir!
        let id = videoID

        // 1) programa: soltar el sink primero (el render loop deja de alimentarlo)
        engine.sink.set(nil)
        var programStats: ProgramSink.Stats?
        if let s = sink {
            programStats = await s.finish()
            sink = nil
        }
        // 2) raw de pantalla y cámara (cierres con deadline adentro)
        if wroteScreen { await engine.detachScreenRecording() }
        if wroteCamera { await engine.stopCameraMovie() }

        // 3) manifest con probe real de cada archivo (duración/dimensiones)
        var outputs: [StudioManifest.OutputFile] = []
        var probe: [(String, String)] = screenRawFiles.map { ("screen", $0) }
        if probe.isEmpty { probe = [("screen", "screen.mp4")] }
        probe += [("camera", "camera.mov"), ("program", "seg-001.mp4")]
        for (role, name) in probe {
            let url = dir.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            var out = StudioManifest.OutputFile(role: role, file: name)
            let asset = AVURLAsset(url: url)
            if let d = try? await asset.load(.duration) { out.durationSeconds = d.seconds }
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let size = try? await track.load(.naturalSize) {
                out.width = Int(size.width)
                out.height = Int(size.height)
            }
            outputs.append(out)
        }
        let iso = ISO8601DateFormatter()
        let manifest = StudioManifest(
            id: id,
            startedAt: iso.string(from: startedAt),
            endedAt: iso.string(from: Date()),
            canvasWidth: Int(engine.canvasSize.width),
            canvasHeight: Int(engine.canvasSize.height),
            fps: engine.fps,
            outputs: outputs,
            sceneTimeline: timeline,
            scenes: config.scenes,
            micEnabled: config.micEnabled,
            systemAudioEnabled: config.systemAudioEnabled)
        manifest.write(to: dir)

        // meta.json de compat: si hay programa, el push "↑ subir" del Historial y
        // el worker del VPS lo tratan como un video normal de 1 segmento.
        if outputs.contains(where: { $0.role == "program" }) {
            let meta = Uploader.Meta(
                id: id, mode: "studio",
                startedAt: iso.string(from: startedAt),
                stoppedAt: iso.string(from: Date()),
                durationSeconds: duration,
                segments: ["seg-001.mp4"])
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? enc.encode(meta).write(to: dir.appendingPathComponent("meta.json"))
        }

        let entry = History.Entry(
            id: id, url: "\(AppSettings.load().baseURL)/v/\(id)",
            date: iso.string(from: startedAt),
            durationSeconds: duration, mode: "studio",
            status: "local", title: nil)
        History.upsert(entry)

        if let st = programStats {
            Log.info("Estudio: programa cerró — \(st.videoFrames) frames, \(st.droppedFrames) drops, mic=\(st.micSamples) sys=\(st.systemSamples)")
        }
        state = .idle
        wroteScreen = false
        wroteCamera = false
        // Contabilidad de PESO en el log: sin esto no hay forma de notar que una
        // grabación pesa 15x lo que debería hasta que el disco truena.
        var total: Int64 = 0
        var parts: [String] = []
        for out in outputs {
            let p = dir.appendingPathComponent(out.file).path
            let size = ((try? FileManager.default.attributesOfItem(atPath: p))?[.size] as? NSNumber)?.int64Value ?? 0
            total += size
            let mbps = duration > 1 ? Double(size) * 8 / duration / 1_000_000 : 0
            parts.append(String(format: "%@ %.0f MB (%.2f Mbps)", out.file, Double(size) / 1_000_000, mbps))
        }
        let totalMbps = duration > 1 ? Double(total) * 8 / duration / 1_000_000 : 0
        Log.info(String(format: "Estudio: PESO %.1f min → %.0f MB total (%.2f Mbps) — %@",
                        duration / 60, Double(total) / 1_000_000, totalMbps, parts.joined(separator: " · ")))
        if engine.screenRestarts > 0 {
            Log.error("Estudio: hubo \(engine.screenRestarts) reenganche(s) de pantalla en esta sesión")
        }
        Log.info("Estudio: sesión \(id) guardada en \(dir.path)")
        return dir
    }
}

// MARK: - ProgramSink (salida B): AVAssetWriter del programa compuesto

/// Recibe frames del render loop y audio de los taps (queues de captura) y los
/// escribe a mp4 HEVC. TODO best-effort: un append fallido se cuenta y se sigue
/// — el audio jamás puede matar el video (invariante "una grabación no se pierde").
/// Reloj: host time (el mismo de AVCapture y SCK) — startSession en el PRIMER
/// frame de video; el writer recorta el audio anterior a ese instante.
final class ProgramSink: @unchecked Sendable {
    struct Stats {
        var videoFrames = 0
        var droppedFrames = 0
        var micSamples = 0
        var systemSamples = 0
    }

    private let lock = NSLock()
    private let url: URL
    private let width: Int
    private let height: Int
    private let fps: Int
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var micInput: AVAssetWriterInput?
    private var systemInput: AVAssetWriterInput?
    private var sessionStarted = false
    private var sessionStartTime = CMTime.zero
    private var stopped = false
    private var stats = Stats()
    private var audioErrorLogged = false

    private let quality: StudioQuality

    init(url: URL, width: Int, height: Int, fps: Int, quality: StudioQuality = .media) {
        self.url = url
        // dimensiones pares (HEVC lo exige)
        self.width = width - (width % 2)
        self.height = height - (height % 2)
        self.fps = fps
        self.quality = quality
    }

    /// Crea el writer con video HEVC + 2 pistas AAC: track 1 mic (voz), track 2
    /// audio del sistema. Separadas a propósito (estilo Screen Studio):
    /// editables por separado; los players tocan la 1.
    ///
    /// ⚠️ CALIDAD CONSTANTE, NO BITRATE FIJO (fix 25 jul). Antes se fijaba
    /// `AVVideoAverageBitRateKey = w·h·fps·0.12` ⇒ 7.5 Mbps a 1080p30 y el
    /// encoder GASTA ESOS BITS aunque la pantalla esté quieta. Medición real del
    /// mismo contenido a la misma hora: OBS 41.7 min = 334 MB (0.93 Mbps) vs
    /// SFCast ≈ 6 GB. OBS no usa bitrate promedio: usa CQP/CRF. Aquí lo mismo,
    /// vía `AVVideoQualityKey` (calidad constante HEVC, Apple silicon) + GOP
    /// largo: una pantalla quieta pasa a costar casi nada y una con movimiento
    /// sube sola. Sin esto, cualquier otro ahorro es maquillaje.
    func prepare() -> Bool {
        do {
            try? FileManager.default.removeItem(at: url)
            let w = try AVAssetWriter(outputURL: url, fileType: .mp4)
            var compression: [String: Any] = [
                AVVideoExpectedSourceFrameRateKey: fps,
                // GOP largo: el default de AVAssetWriter mete keyframes muy
                // seguido y en captura de pantalla eso solo son bytes tirados.
                AVVideoMaxKeyFrameIntervalKey: fps * 5,
                AVVideoMaxKeyFrameIntervalDurationKey: 5.0,
                AVVideoAllowFrameReorderingKey: false,
            ]
            if quality.usesConstantQuality {
                compression[AVVideoQualityKey] = quality.constantQuality
            } else {
                compression[AVVideoAverageBitRateKey] =
                    Int(Double(width * height * fps) * quality.bitsPerPxFrame)
            }
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: compression,
            ]
            let vin = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            vin.expectsMediaDataInRealTime = true
            guard w.canAdd(vin) else { return false }
            w.add(vin)
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: vin,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: width,
                    kCVPixelBufferHeightKey as String: height,
                ])
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 160_000,
            ]
            let mic = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            mic.expectsMediaDataInRealTime = true
            if w.canAdd(mic) { w.add(mic); micInput = mic }
            let sys = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            sys.expectsMediaDataInRealTime = true
            if w.canAdd(sys) { w.add(sys); systemInput = sys }
            guard w.startWriting() else {
                Log.error("ProgramSink: startWriting falló: \(w.error?.localizedDescription ?? "?")")
                return false
            }
            self.writer = w
            self.videoInput = vin
            self.adaptor = adaptor
            return true
        } catch {
            Log.error("ProgramSink: no pude crear writer: \(error.localizedDescription)")
            return false
        }
    }

    /// Llamado desde el render loop a cada frame compuesto.
    func appendVideo(_ pb: CVPixelBuffer, hostTime: CMTime) {
        lock.lock(); defer { lock.unlock() }
        guard let writer, let videoInput, let adaptor, !stopped, writer.status == .writing else { return }
        if !sessionStarted {
            writer.startSession(atSourceTime: hostTime)
            sessionStartTime = hostTime
            sessionStarted = true
        }
        guard videoInput.isReadyForMoreMediaData else {
            stats.droppedFrames += 1
            if stats.droppedFrames % 120 == 1 {
                Log.error("ProgramSink: encoder atrás — \(stats.droppedFrames) frames tirados")
            }
            return
        }
        if adaptor.append(pb, withPresentationTime: hostTime) {
            stats.videoFrames += 1
        } else {
            stats.droppedFrames += 1
        }
    }

    func appendMicAudio(_ sb: CMSampleBuffer) {
        appendAudio(sb, to: micInput) { self.stats.micSamples += 1 }
    }

    func appendSystemAudio(_ sb: CMSampleBuffer) {
        appendAudio(sb, to: systemInput) { self.stats.systemSamples += 1 }
    }

    private func appendAudio(_ sb: CMSampleBuffer, to input: AVAssetWriterInput?, count: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard let writer, let input, !stopped, writer.status == .writing,
              sessionStarted, input.isReadyForMoreMediaData else { return }
        // Warmup: los primeros ~150ms de audio se tiran — el writer recortaba a
        // MITAD de buffer en el arranque y eso truena (parte del "estruendo").
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        if CMTimeGetSeconds(CMTimeSubtract(pts, sessionStartTime)) < 0.15 { return }
        if input.append(sb) {
            count()
        } else if !audioErrorLogged {
            audioErrorLogged = true
            Log.error("ProgramSink: append de audio falló (\(writer.error?.localizedDescription ?? "?")) — el video sigue")
        }
    }

    /// Stats en vivo para el health monitor.
    func snapshot() -> Stats {
        lock.lock(); defer { lock.unlock() }; return stats
    }

    /// Snapshot síncrono para finish() (NSLock no debe cruzar contexto async).
    private func markStoppedAndSnapshot() -> (AVAssetWriter?, Bool, Stats) {
        lock.lock(); defer { lock.unlock() }
        stopped = true
        return (writer, sessionStarted, stats)
    }

    /// Cierra el archivo (deadline 15s — invariante #5) y devuelve stats.
    func finish() async -> Stats {
        let (writerOpt, started, s) = markStoppedAndSnapshot()
        guard let writer = writerOpt, writer.status == .writing else { return s }
        videoInput?.markAsFinished()
        micInput?.markAsFinished()
        systemInput?.markAsFinished()
        if !started {
            writer.cancelWriting()   // jamás hubo frames: no dejar un mp4 zombie
            try? FileManager.default.removeItem(at: url)
            return s
        }
        try? await Deadline.run(seconds: 15, name: "ProgramSink finishWriting") {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                writer.finishWriting { cont.resume() }
            }
        }
        if writer.status != .completed {
            Log.error("ProgramSink: cierre en estado \(writer.status.rawValue): \(writer.error?.localizedDescription ?? "?")")
        }
        return s
    }
}
