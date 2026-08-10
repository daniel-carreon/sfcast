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
    /// FPS que de verdad quedaron en el archivo de la última grabación
    /// (frames escritos ÷ duración). -1 = todavía no se midió.
    private(set) var achievedFPS: Double = -1
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

    /// Memoria del sistema que se puede usar sin empezar a comprimir/swapear.
    /// No es un lujo de telemetría: el 9 ago la Mac tenía 15 de 16 GB ocupados
    /// y 675 MB de swap, y ESA es la condición bajo la que el pool de buffers
    /// se vuelve caro y el compositor pierde el ritmo. Grabar a 4K pide ~550 MB
    /// entre pool de captura y programa; a 1440p, la mitad.
    static func availableRAM() -> Int64 {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size
                                           / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return .max }
        let page = Int64(vm_kernel_page_size)
        // Libre + inactiva + purgable: lo que macOS puede entregar sin pelear.
        return (Int64(stats.free_count) + Int64(stats.inactive_count)
                + Int64(stats.purgeable_count)) * page
    }

    /// Por debajo de esto, grabar a lienzo grande es pedir el colapso.
    static let lowRAMBytes: Int64 = 1_500_000_000

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
            // El reloj arranca con la grabación: ancla la corrección de latencia
            // con las muestras que el motor lleva midiendo desde que se abrió el
            // Estudio (para el REC ya hay decenas), sin rampa audible.
            engine.programClock.begin()
            engine.resetCompositorWindow()
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
        preflightRitmo(engine: engine)
        startHealthMonitor(engine: engine)
    }

    // MARK: - preflight de RITMO (avisar antes, no después de 45 minutos)

    /// El motor lleva componiendo desde que se abrió el Estudio, así que al dar
    /// REC ya hay evidencia de si esta Mac sostiene la cadencia AHORA MISMO. La
    /// alarma del 9 ago llegó cuando el video ya estaba grabado; ésta llega
    /// antes de hablar. AVISA, jamás bloquea: la grabación es de Daniel.
    private func preflightRitmo(engine: StudioEngine) {
        let objetivo = Double(engine.fps)
        guard objetivo > 0 else { return }
        let presupuesto = 1000.0 / objetivo
        let cs = engine.compositorStats()
        let ram = Self.availableRAM()
        var motivos: [String] = []
        if cs.composed >= 45, cs.composeMsP50 > presupuesto * 0.6 {
            motivos.append(String(format: "el compositor va a %.0f%% de su presupuesto",
                                  cs.composeMsP50 / presupuesto * 100))
        }
        if ram < Self.lowRAMBytes, ram != .max {
            motivos.append("quedan \(Self.gb(ram)) de RAM libre")
        }
        let px = Int(engine.canvasSize.width * engine.canvasSize.height)
        if !motivos.isEmpty {
            let sugerencia = px > 1920 * 1080
                ? " Baja el lienzo en Ajustes → Video (o cierra apps) antes de la toma buena."
                : " Cierra lo que esté cargando la Mac antes de la toma buena."
            let msg = "Ojo: " + motivos.joined(separator: " y ") + "." + sugerencia
            Log.error("Estudio: PREFLIGHT — " + msg)
            onAlert?(msg, true)
        } else {
            Log.info(String(format: "Estudio: preflight OK — compositor %.1f ms de %.1f, RAM libre %@",
                            cs.composeMsP50, presupuesto, Self.gb(ram)))
        }
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
                let cs = engine.compositorStats()
                let sync = engine.syncReport()
                Log.info(String(format: "Estudio ❤︎ %ds — stream:%.1fs-mudo (v=%d a=%d) imagen:%@ "
                                + "mic:%@ sys:%@ frames:%d drops:%d cam:%.0ffps prev:%.0ffps(-%d) libre:%@ "
                                + "| comp:%.1fms sinBuf:%d cadencia:%d/%d sync:%+.0fms ram:%@",
                                Int(self.elapsed), engine.screenHealth.silence(),
                                beats.video, beats.audio,
                                engine.screenFrozen ? "CONGELADA" : "ok",
                                fresh.mic ? "ok" : "MUDO", fresh.system ? "ok" : "mudo",
                                st?.videoFrames ?? 0, st?.droppedFrames ?? 0,
                                camFPS, prevFPS, prevDrops, Self.gb(free),
                                cs.composeMsP50, cs.bufferFailures,
                                engine.effectiveFPS, engine.fps, sync.appliedMs,
                                Self.gb(Self.availableRAM()))
                 + String(format: " rellenados:%d", engine.cadence.repeatedFrames))
                // PERFIL POR FASE cada 4 latidos (1 min): con un solo numero
                // agregado no se puede distinguir GPU de encoder de pool, y son
                // curas opuestas.
                if ticks % 4 == 0 { Log.info("Estudio ⏱ " + engine.profile.line()) }
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
        // FPS REALES del programa, ANTES de armar el manifest: lo conseguido
        // tiene que quedar escrito junto a lo pedido (ver el aviso más abajo).
        let realFPS = (programStats.map { duration > 0.5 ? Double($0.videoFrames) / duration : 0 }) ?? 0
        achievedFPS = realFPS
        let iso = ISO8601DateFormatter()
        let manifest = StudioManifest(
            id: id,
            startedAt: iso.string(from: startedAt),
            endedAt: iso.string(from: Date()),
            canvasWidth: Int(engine.canvasSize.width),
            canvasHeight: Int(engine.canvasSize.height),
            fps: engine.fps,
            achievedFps: realFPS > 0 ? realFPS : nil,
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
            // FPS REALES DEL ARCHIVO (9 ago). Hasta hoy, una grabación a 21.75
            // fps se veía IDÉNTICA a una de 30 hasta que alguien la abría con
            // ffprobe: el manifest declaraba 30 porque 30 es lo CONFIGURADO, no
            // lo conseguido. Daniel grabó dos videos así sin que nada se lo
            // dijera (21.75 y 24.86 fps, medidos en sus archivos).
            //
            // El número existía —`videoFrames` ya se contaba— y nadie lo
            // dividía entre la duración. Ahora se divide, se guarda en el
            // manifest y, si se quedó corto, se AVISA. Invariante 5b: lo que no
            // se mide se degrada en silencio, y esto se degradó en silencio.
            let real = realFPS
            let objetivo = Double(engine.fps)
            if real > 0, objetivo > 0 {
                let pct = real / objetivo
                Log.info(String(format: "Estudio: fps REALES del archivo %.2f de %.0f pedidos (%.0f%%)",
                                real, objetivo, pct * 100))
                // EL AVISO SE DECIDE POR TRAMO, NO POR PROMEDIO (fix 9 ago).
                // Ese día el promedio salió 92% —por encima del umbral del 90%,
                // así que NO avisó— mientras seis minutos del archivo estaban a
                // 10 fps con congelamientos de 750 ms. El promedio de una
                // grabación larga es justo el estadístico que oculta un colapso
                // corto: hay que mirar el PEOR tramo.
                let peor = st.worstWindow(20)
                if let peor, peor.fps < objetivo * 0.9 {
                    let m = peor.startSec / 60, s = peor.startSec % 60
                    Log.error(String(format: "Estudio: PEOR TRAMO %.1f fps en el minuto %d:%02d "
                                     + "(promedio %.1f — por eso el promedio no sirve de alarma)",
                                     peor.fps, m, s, real))
                    onAlert?(String(format: "Hubo un tramo a %.0f fps (minuto %d:%02d) aunque el promedio "
                                    + "salió %.0f. La Mac no alcanzó a componer ahí. Baja el lienzo en "
                                    + "Ajustes → Video o cierra lo que esté cargando el sistema.",
                                    peor.fps, m, s, real), true)
                } else if pct < 0.9 {
                    onAlert?(String(format: "La grabación quedó a %.1f fps, no a %.0f: la Mac no alcanzó a "
                                    + "componer. Baja el lienzo en Ajustes → Video, o cierra lo que esté "
                                    + "cargando el sistema.", real, objetivo), true)
                }
                // Los frames que NO llegaron a existir por falta de buffer no
                // aparecían en ningún contador: `drops:0` mientras el archivo se
                // caía. Ahora se dicen.
                let cs = engine.compositorStats()
                if cs.bufferFailures > 0 {
                    Log.error("Estudio: \(cs.bufferFailures) frames sin buffer (el pool no dio memoria) — "
                              + "señal de presión de RAM, no de CPU")
                }
                Log.info(String(format: "Estudio: compositor p50 %.1f ms (máx %.1f) de un presupuesto de %.1f ms",
                                cs.composeMsP50, cs.composeMsMax, 1000.0 / objetivo))
            }
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
        /// Frames escritos por segundo de grabación. Es lo que permite hablar
        /// de TRAMOS en vez de promedios: el 9 ago el archivo promedió 92% del
        /// objetivo (por eso no saltó ninguna alarma) mientras seis minutos
        /// estaban a 10 fps. Un promedio de 45 minutos esconde un colapso de 6.
        var perSecond: [Int] = []

        /// La PEOR ventana continua de `w` segundos: (fps, segundo en que empieza).
        func worstWindow(_ w: Int = 20) -> (fps: Double, startSec: Int)? {
            guard perSecond.count >= w else { return nil }
            var best: (Double, Int)?
            var sum = perSecond[0..<w].reduce(0, +)
            best = (Double(sum) / Double(w), 0)
            for i in w..<perSecond.count {
                sum += perSecond[i] - perSecond[i - w]
                let fps = Double(sum) / Double(w)
                if fps < best!.0 { best = (fps, i - w + 1) }
            }
            return best
        }
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

    // MARK: - arranque ALINEADO de las dos pistas (fix 9 ago)
    //
    // Antes la sesión arrancaba en el PRIMER frame de video, y el audio además
    // se tiraba durante 150 ms de warmup. Resultado medido en TODAS las
    // grabaciones: `video start_time = 0.000` y `audio start_time = 0.152`.
    //
    // Un reproductor que respeta el start_time lo compensa; medio mundo (y
    // varios editores) lo IGNORA y pega ambas pistas en cero — y entonces la
    // voz va 152 ms ADELANTADA. Sumado a la latencia de cámara, eso ya es un
    // desfase de labios que se ve a simple vista con la cara en pantalla.
    //
    // La cura: no arrancar la sesión hasta poder arrancar las dos pistas en el
    // MISMO instante. Se pagan ~150 ms de cabeza (invisibles: es justo después
    // del countdown) y los dos tracks salen con start_time 0.
    private var firstVideoPTS = CMTime.invalid
    private var firstAudioSeen = CMTime.invalid
    private var firstAudioUsable = CMTime.invalid
    private var startDeadline = CMTime.invalid
    /// Warmup del audio: los primeros buffers de una sesión traen el arranque
    /// del grafo (el "estruendo" del feedback v2.3).
    private let audioWarmup: Double = 0.15
    /// Si el mic no entrega (apagado, mudo, permiso), la grabación NO puede
    /// quedarse esperando: pasado esto arranca solo con video.
    private let audioWaitLimit: Double = 0.6

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
            if !firstVideoPTS.isValid {
                firstVideoPTS = hostTime
                startDeadline = CMTimeAdd(hostTime, CMTime(seconds: audioWaitLimit, preferredTimescale: 1000))
            }
            guard let start = resolveSessionStart(now: hostTime) else {
                // Todavía no se pueden arrancar las DOS pistas juntas: este
                // frame se descarta a propósito. Son milésimas del arranque, no
                // contenido — y a cambio el archivo sale sin hueco de audio.
                return
            }
            writer.startSession(atSourceTime: start)
            sessionStartTime = start
            sessionStarted = true
            Log.info(String(format: "ProgramSink: sesión alineada en t=%.3f (video y audio arrancan juntos)",
                            CMTimeGetSeconds(start)))
        }
        // Un frame anterior al arranque de sesión rompería el orden del writer.
        if CMTimeCompare(hostTime, sessionStartTime) < 0 { return }
        guard videoInput.isReadyForMoreMediaData else {
            stats.droppedFrames += 1
            if stats.droppedFrames % 120 == 1 {
                Log.error("ProgramSink: encoder atrás — \(stats.droppedFrames) frames tirados")
            }
            return
        }
        if adaptor.append(pb, withPresentationTime: hostTime) {
            stats.videoFrames += 1
            let sec = Int(CMTimeGetSeconds(CMTimeSubtract(hostTime, sessionStartTime)))
            if sec >= 0, sec < 60 * 60 * 6 {
                if stats.perSecond.count <= sec {
                    stats.perSecond.append(contentsOf: repeatElement(0, count: sec - stats.perSecond.count + 1))
                }
                stats.perSecond[sec] += 1
            }
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
        guard let writer, let input, !stopped, writer.status == .writing else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        guard pts.isValid, pts.isNumeric else { return }

        // El warmup se mide desde el PRIMER audio de la sesión, no desde el
        // primer video: son dos relojes de arranque distintos y mezclarlos es
        // lo que producía el hueco de 152 ms.
        if !firstAudioSeen.isValid { firstAudioSeen = pts }
        guard CMTimeGetSeconds(CMTimeSubtract(pts, firstAudioSeen)) >= audioWarmup else { return }
        if !firstAudioUsable.isValid { firstAudioUsable = pts }

        // Antes de que la sesión arranque no hay dónde escribir; el buffer se
        // pierde, pero ya dejó su marca (`firstAudioUsable`) que es lo que hace
        // arrancar las dos pistas juntas.
        guard sessionStarted, input.isReadyForMoreMediaData else { return }
        if CMTimeCompare(pts, sessionStartTime) < 0 { return }
        if input.append(sb) {
            count()
        } else if !audioErrorLogged {
            audioErrorLogged = true
            Log.error("ProgramSink: append de audio falló (\(writer.error?.localizedDescription ?? "?")) — el video sigue")
        }
    }

    /// ¿Ya se pueden arrancar las DOS pistas en el mismo instante?
    /// - con mic vivo: en cuanto hay un audio pasado el warmup (el máximo de
    ///   los dos primeros PTS, para que ninguna pista tenga que escribir en
    ///   negativo);
    /// - sin mic (apagado/mudo/sin permiso): tras `audioWaitLimit`, con video
    ///   solo. Una grabación JAMÁS se queda esperando al audio (invariante #5).
    private func resolveSessionStart(now: CMTime) -> CMTime? {
        guard firstVideoPTS.isValid else { return nil }
        if firstAudioUsable.isValid {
            return CMTimeMaximum(firstVideoPTS, firstAudioUsable)
        }
        if startDeadline.isValid, CMTimeCompare(now, startDeadline) >= 0 {
            Log.info("ProgramSink: sin audio en \(audioWaitLimit)s — arranco solo con video")
            return firstVideoPTS
        }
        return nil
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
