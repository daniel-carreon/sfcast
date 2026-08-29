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
/// LA CADENCIA REAL DE UN ARCHIVO (v3, 28 ago 2026).
///
/// Lee SOLO las referencias de muestra (no decodifica un píxel) y devuelve lo
/// que de verdad quedó escrito. Existe porque hasta hoy el manifest hablaba de
/// los fps del PROGRAMA y callaba los de las capas: el 28 ago `camera.mov` salió
/// a 19 fps de una fuente que mandaba 25 limpios, y nada en el archivo lo decía.
struct CadenciaArchivo {
    var frames = 0
    var effectiveFps: Double = 0
    /// Cadencia de la FUENTE, del intervalo modal (1/moda).
    var sourceFps: Double = 0
    /// Fracción de intervalos que caen en la moda (±1 ms). <0.95 = se perdieron frames.
    var health: Double = 0
    var variable = false

    static func medir(url: URL) async -> CadenciaArchivo? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let out = AVAssetReaderSampleReferenceOutput(track: track)
        guard reader.canAdd(out) else { return nil }
        reader.add(out)
        guard reader.startReading() else { return nil }
        var ts: [Double] = []
        ts.reserveCapacity(4096)
        while let sb = out.copyNextSampleBuffer() {
            let t = CMSampleBufferGetPresentationTimeStamp(sb)
            if t.isValid, t.isNumeric { ts.append(CMTimeGetSeconds(t)) }
        }
        reader.cancelReading()
        guard ts.count > 2 else { return nil }
        ts.sort()
        let span = ts[ts.count - 1] - ts[0]
        guard span > 0.2 else { return nil }
        var r = CadenciaArchivo()
        r.frames = ts.count
        r.effectiveFps = Double(ts.count - 1) / span
        // LA CADENCIA SE MIDE CON LA MEDIANA, NO CON LA MODA AL MILISEGUNDO
        // (28 ago 2026, corregido en el acto). El primer intento agrupaba
        // intervalos al ms exacto y marcó VFR al programa, que es CFR: sus PTS
        // salen del RELOJ HOST y traen jitter natural (33.3 · 31.7 · 35.0 ms).
        // Un clasificador que llama variable a un archivo constante es un sensor
        // que miente, y aquí ya se pagó caro creerle a uno.
        //
        // La mediana es robusta a los huecos (aunque falte un cuarto de los
        // frames, la mediana sigue siendo el intervalo de la fuente) y la
        // tolerancia RELATIVA absorbe el jitter sin absorber un frame perdido:
        // un hueco es 2x la mediana, muy lejos del ±25%.
        var deltas: [Double] = []
        deltas.reserveCapacity(ts.count)
        for (a, b) in zip(ts, ts.dropFirst()) {
            let d = b - a
            if d > 0, d < 2 { deltas.append(d) }
        }
        guard !deltas.isEmpty else { return r }
        let ord = deltas.sorted()
        let mediana = ord[ord.count / 2]
        guard mediana > 0 else { return r }
        let dentro = deltas.filter { abs($0 - mediana) <= mediana * 0.25 }.count
        r.sourceFps = 1.0 / mediana
        r.health = Double(dentro) / Double(deltas.count)
        // VFR = ni siquiera la mayoría de los intervalos se parecen entre sí.
        // Se separa de "perdió frames" a propósito: el raw de pantalla es
        // legítimamente irregular (SCK no manda frames si nada cambió) y NO se
        // le debe gritar por eso; una cámara al 80% de salud sí es una avería.
        r.variable = r.health < 0.60
        return r
    }
}

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
    /// Reenganches de pantalla que YA existían al empezar esta toma. Sin esto el
    /// aviso reportaba el acumulado del motor: las 15 grabaciones del 26 ago
    /// dijeron "hubo 7 reenganche(s) EN ESTA SESIÓN" cuando los 7 habían pasado
    /// a las 06:15 y 07:02 de la mañana. Un contador que no se resetea es un
    /// sensor que miente, y un sensor que miente se deja de leer.
    private var screenRestartsAtStart = 0
    /// Mientras se graba, la pantalla NO se duerme. Ver PowerAssertion.
    private let energia = PowerAssertion(motivo: "SFCast está grabando")
    /// Lo que Daniel marcó en vivo y los tramos con imagen congelada. Los dos
    /// viajan al manifest: son el cable entre lo que pasó AL GRABAR y lo que el
    /// editor necesita saber DESPUÉS (v3.2).
    private var markers: [StudioManifest.Marker] = []
    /// ENVOLVENTE DEL MICRÓFONO — nivel cada 100 ms, para el corte de silencios.
    ///
    /// La app ya mide esto 15 veces por segundo para pintar el vúmetro… y lo
    /// tira. Guardarlo cuesta 10 números por segundo (36 KB en 45 minutos) y le
    /// ahorra al editor re-analizar el audio entero para encontrar los silencios.
    /// Es el dato más barato de todo el sistema: ya está medido.
    private var envelope: [Float] = []
    private var envelopeTask: Task<Void, Never>?
    private var voiceTask: Task<Void, Never>?
    /// Guard de cadencia: detiene la toma si la Mac no sostiene el piso de fps.
    private var cadenceTask: Task<Void, Never>?
    private var programTask: Task<Void, Never>?
    /// POR QUÉ se detuvo sola la última toma (nil = la detuvo Daniel).
    ///
    /// Existe para que el QA no confunda "el sujeto se protegió" con "el sujeto
    /// falló". El caso del guard de voz ya estaba resuelto a mano con un
    /// `--mutemic` especial; esto lo generaliza a cualquier guard, incluido el de
    /// cadencia, que dispara sin ninguna bandera de CLI.
    private(set) var lastAutoStopReason: String?
    /// Dispositivo de micrófono que quedó DE VERDAD en la sesión (va al
    /// manifest). El Shure cambia de formato entre arranques y sin registrar
    /// qué entrada se usó, el próximo diagnóstico vuelve a ser a ciegas.
    private var micDeviceName: String?
    /// Receta de la escena con la que arrancó la toma (va al manifest).
    private var presetActivo: String?
    private var deadZones: [StudioManifest.DeadZone] = []
    private var frozenSince: [String: Double] = [:]
    /// CADA ESCALÓN DEL GOVERNOR durante la toma (v3.6). El evento ya existía
    /// (`engine.onCadenceChange`) y solo pintaba un banner que se pierde en el
    /// otro monitor. Guardarlo cuesta tres números por escalón y es lo único que
    /// permite distinguir, después, "30 fps de verdad" de "15 fps rellenados a 30".
    private var cadenceLog: [StudioManifest.CadencePoint] = []

    var isRecording: Bool { state == .recording }
    /// Última carpeta escrita (la usa el QA cuando el auto-stop cerró la sesión
    /// antes de que el test pidiera el stop).
    private(set) var lastDir: URL?
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
        presetActivo = activeScene?.receta?.preset.isEmpty == false ? activeScene?.receta?.preset : nil
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
        // TODO lo que es POR SESIÓN se limpia aquí.
        //
        // `markers` y `deadZones` no se limpiaban nunca (bug encontrado el 17 ago
        // con los propios archivos de Daniel): la marca que puso en el segundo
        // 103.1 de la sesión de 48 min (u760h7xic9kv, 07:26) aparece IDÉNTICA, en
        // el mismo t=103.1, en el manifest de la toma siguiente (dw0w7tu0rea1,
        // 08:19). El puente a la edición lee "retoma" como "tira la toma que
        // ACABA aquí", así que una marca heredada tira material bueno de otra
        // grabación. Igual de grave al revés: una zona muerta vieja marca como
        // inservible un tramo sano.
        markers = []
        deadZones = []
        frozenSince.removeAll()
        cadenceLog = []
        lastAutoStopReason = nil
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
            screenRestartsAtStart = engine.screenRestarts
            // Y EL GUARDIÁN DE CADENCIA TAMBIÉN (fix 26 ago 2026). Estaban a una
            // línea de distancia y solo uno se reiniciaba: `programClock.begin()`
            // aquí, `cadence.reset()` allá arriba en `startRenderLoop()`, o sea
            // UNA VEZ POR MOTOR, no por toma.
            //
            // Lo que costaba: `lastEmitted` sobrevivía a la toma anterior, así que
            // el primer tick de la nueva creía que llevaba N segundos sin emitir y
            // devolvía frames de relleno fechados en la toma PASADA. El primero de
            // ellos fijaba `firstVideoPTS`, y el writer abría la sesión ahí — SEGUNDOS
            // EN EL PASADO. Resultado medido en las 9 tomas del 26 ago: **cada
            // grabación empezaba con un hueco exactamente igual de largo que la
            // pausa desde la anterior** (1.07 s, 1.20 s, 2.07 s, 6.77 s, 9.47 s…),
            // y la primera toma de cada sesión salía perfecta porque no había
            // toma anterior que la envenenara.
            //
            // De ahí venían las alarmas de la noche: "PEOR TRAMO 19.9 fps" y "EL
            // MATERIAL SE MUEVE A 57%" no mentían — medían el hueco.
            // `--sincadencereset` REVIVE el bug a propósito. Un fix que no se
            // puede volver a romper no se puede volver a probar, y este repo ya
            // aprendió que "un mecanismo que nunca se disparó no es un fix, es
            // una intención" (regla del 25 jul, de donde salió --killstream).
            if !QAFlags.revivirHuecoDeCabeza {
                engine.cadence.reset()
            } else {
                Log.error("QA: --bug26ago — revivo el hueco de cabeza del 26 ago a propósito")
            }
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
                // ⛔ ANTES ESTO ERA SÓLO UN Log.error (fix 28 ago 2026): pediste el programa, no
                //    se pudo abrir, y la única señal quedaba en un archivo de log que nadie mira
                //    mientras graba. Te enterabas al editar, buscando un `seg-001.mp4` que no
                //    existe. Si una salida que PEDISTE no arranca, se dice en pantalla.
                Log.error("Estudio: el writer del programa no arrancó")
                onAlert?("Pediste la salida «Programa» y su archivo NO se pudo abrir. "
                         + "Las capas crudas sí están grabando.", true)
                notify("SFCast — EL PROGRAMA NO ARRANCÓ",
                       "No se pudo abrir seg-001.mp4. Las capas crudas siguen grabando.")
            }
        }
        guard !activated.isEmpty else {
            try? FileManager.default.removeItem(at: sessionDir)
            throw NSError(domain: "SFCast", code: 11, userInfo: [
                NSLocalizedDescriptionKey: "Ninguna salida pudo activarse (¿permisos de pantalla/cámara?)."])
        }
        // El trinquete del governor arranca LIMPIO con cada toma.
        //
        // Hasta el 17 ago `governor.reset` solo se llamaba en `startRenderLoop()`
        // —o sea al ABRIR la ventana de Estudio, no al dar REC— así que el estado
        // del trinquete (incluido un `upRequirement` ya escalado a 180 ventanas)
        // se heredaba del preview en reposo y de la toma anterior. Medido: la
        // sesión dw0w7tu0rea1 (15 ago 08:19) ya reportaba `cadencia:19/30` en su
        // PRIMER heartbeat a los 15 s — no se degradó en 15 segundos, arrancó
        // degradada, heredando el 15 fps de la sesión de 48 min que cerró a las
        // 08:15. Una toma se juzga por lo que pasa DENTRO de ella.
        engine.governor.reset(target: engine.fps, now: CACurrentMediaTime())
        state = .recording
        // EL CANDADO DE ENERGÍA SE TOMA AQUÍ Y EN NINGÚN OTRO SITIO — segunda
        // corrección de la misma línea en una noche, y las dos por revisión.
        //
        // Primero vivía dentro de `if config.outputs.program`: una grabación con
        // el programa apagado se quedaba sin candado. Lo saqué de la rama… y lo
        // puse ANTES del `guard !activated.isEmpty`, que es peor: si ninguna
        // salida arranca, `start()` lanza, `state` se queda en `.idle`, y `stop()`
        // —que empieza con `guard state == .recording`— no hace nada. El candado
        // quedaba tomado PARA SIEMPRE y la pantalla de Daniel no volvía a dormirse
        // hasta cerrar la app, sin un solo aviso.
        //
        // Aquí, pegado a `state = .recording`, la toma y la suelta son simétricas
        // por construcción: si este punto se alcanzó, `stop()` va a correr.
        energia.tomar()
        Log.info("Estudio: grabando \(videoID) → [\(activated.joined(separator: ", "))] "
                 + "calidad=\(config.programQuality.rawValue) libre=\(Self.gb(free))")
        preflightRitmo(engine: engine)
        preflightVoz(engine: engine, micEnabled: config.micEnabled)
        preflightImagen(engine: engine)
        micDeviceName = engine.micDeviceName
        startEnvelope(engine: engine)
        startVoiceGuard(engine: engine, micEnabled: config.micEnabled)
        startCadenceGuard(engine: engine)
        startProgramGuard(engine: engine, programOn: config.outputs.program)
        startHealthMonitor(engine: engine)
    }

    // MARK: - preflight de RITMO (avisar antes, no después de 45 minutos)

    /// El motor lleva componiendo desde que se abrió el Estudio, así que al dar
    /// REC ya hay evidencia de si esta Mac sostiene la cadencia AHORA MISMO. La
    /// alarma del 9 ago llegó cuando el video ya estaba grabado; ésta llega
    /// antes de hablar. AVISA, jamás bloquea: la grabación es de Daniel.
    /// PREFLIGHT DE VOZ — el aviso que llega ANTES de hablar.
    ///
    /// El motor lleva corriendo desde que se abrió el Estudio, así que al dar
    /// REC ya se sabe si el micrófono entrega. Avisar aquí cuesta cero y es la
    /// diferencia entre perder 3 segundos y perder 35 minutos.
    private func preflightVoz(engine: StudioEngine, micEnabled: Bool) {
        guard micEnabled else { return }
        let fresco = engine.levels.fresh().mic
        if !fresco {
            Log.error("Estudio: PREFLIGHT DE VOZ — el micrófono NO está entregando audio")
            onAlert?("⚠️ El micrófono no está dando señal. Compruébalo ANTES de hablar "
                     + "(el vúmetro del Mixer debe moverse).", true)
            notify("SFCast — REVISA EL MICRÓFONO", "No está entrando audio al empezar a grabar.")
        } else {
            Log.info(String(format: "Estudio: preflight de voz OK — mic entregando (nivel %.4f)",
                            engine.levels.get().mic))
        }
    }

    /// PREFLIGHT DE IMAGEN — el espejo de `preflightVoz`, que faltaba.
    ///
    /// Al micrófono se le preguntaba "¿estás vivo?" antes de grabar. A la cámara
    /// NO: su vigilancia (`checkCameraHealth`) es de FLANCO — `if dead !=
    /// cameraFrozen` — así que si la cámara ya estaba muerta al dar REC, la
    /// transición nunca ocurría: cero alarma, cero notificación, y `noteFrozen`
    /// jamás se llamaba, por lo que `deadZones` salía VACÍO en una sesión que era
    /// 100% zona muerta.
    ///
    /// Costó una toma real: la sesión hpa3ky02t5ss (15 ago 06:13) grabó 3:52 de
    /// UNA imagen fija con la ZV-E10 sin entregar un solo frame, y se archivó
    /// reportando `achievedFps: 29.96`. El puente a la edición leyó ese número y
    /// le dijo al editor que le metiera "capa rica, captions y zoom" a una foto.
    ///
    /// Esto AVISA y REGISTRA; jamás bloquea (la grabación es de Daniel).
    private func preflightImagen(engine: StudioEngine) {
        guard engine.cameraAvailable else { return }
        let age = engine.frames.age(.camera)
        let muerta = (age ?? .greatestFiniteMagnitude) > StudioEngine.deadAfter
        guard muerta else {
            Log.info(String(format: "Estudio: preflight de imagen OK — cámara entregando "
                            + "(último frame hace %.2fs)", age ?? 0))
            return
        }
        let cuanto = age.map { String(format: "%.1fs sin imagen nueva", $0) }
            ?? "nunca entregó un frame"
        Log.error("Estudio: PREFLIGHT DE IMAGEN — la cámara NO está dando imagen (\(cuanto))")
        onAlert?("⚠️ La cámara no está dando imagen (\(cuanto)). Vas a grabar un frame "
                 + "CONGELADO. Revísala ANTES de hablar (las Sony se apagan solas).", true)
        notify("SFCast — REVISA LA CÁMARA",
               "No está entrando imagen al empezar a grabar: sería un video de una foto.")
        // El tramo se registra desde el segundo 0: `stop()` cierra los que sigan
        // abiertos, así que la zona muerta queda en el manifest aunque la cámara
        // no vuelva nunca — que es justo el caso que antes no dejaba rastro.
        noteFrozen("camera", frozen: true, reason: "sin imagen desde el inicio de la toma")
    }

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
        // LA COLA, que era el punto ciego (v3.6, 17 ago).
        //
        // Este preflight solo miraba el p50 de `composeMs`, y `composeMs` arranca
        // DESPUÉS de esperar a la GPU del frame anterior. O sea: miraba la mediana
        // del único tramo que nunca se atasca. El 15 ago pasó en verde con p50 =
        // 8.1 ms mientras la vuelta completa iba a p95 = 97 ms y máx = 232 ms
        // contra 33.3 de presupuesto, y la toma salió con 12.8 fps de movimiento.
        //
        // La falla es de COLA: p50 sano + p95 catastrófico es la firma de una
        // espera, no de un cálculo caro. Se mira el p95 del loop COMPLETO, que sí
        // incluye la espera, y se mira ANTES de hablar.
        let loop = engine.profile.snapshot()
        if loop.n >= 60, loop.total.p95 > presupuesto {
            motivos.append(String(format: "la vuelta del loop se va a %.0f ms en su p95 "
                                  + "(presupuesto %.0f) — es espera de GPU",
                                  loop.total.p95, presupuesto))
        }
        // Y el estado que NADIE miraba: cuánto lleva la app abierta.
        //
        // Medido en el propio log: el compositor de esta app pasa de 1.1-2.2 ms
        // recién abierta a 5.1-8.1 ms tras ~3 días, con el mismo lienzo y la misma
        // escena, porque su working set se va quedando fuera de RAM (22% de sus
        // regiones escribibles estaban swapeadas el 17 ago, con 93 MB libres en la
        // máquina). La prueba de v3.1 —44.8 min a 30.00 fps— era válida Y el bug
        // era real: la variable que nadie controlaba era el UPTIME de la app.
        let horas = Date().timeIntervalSince(Self.launchedAt) / 3600
        if horas >= 12 {
            motivos.append(String(format: "SFCast lleva %.0f h abierta (el compositor se degrada; "
                                  + "ciérrala y reábrela antes de la toma buena)", horas))
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
            Log.info(String(format: "Estudio: preflight OK — compositor %.1f ms de %.1f "
                            + "(loop p95 %.1f, n=%d), RAM libre %@, app abierta %.1f h",
                            cs.composeMsP50, presupuesto, loop.total.p95, loop.n,
                            Self.gb(ram), horas))
        }
    }

    // MARK: - GUARD DE CADENCIA — "prohibido bajar los fps" (17 ago 2026)

    /// Orden de Daniel, verbatim:
    ///
    ///   "Queda prohibido bajar los frames por segundo. Prefiero que antes de eso
    ///    se pause y me diga algo, pero mantener estables los frames. 30 frames,
    ///    mínimo 24, pero no menos. Prefiero que se pause si es así y yo arreglar
    ///    otros detalles."
    ///
    /// El governor ahora tiene UN escalón de gracia y un piso duro (24, ver
    /// `RenderGovernor.hardFloorFPS`). Este guard vigila el piso: si la Mac no lo
    /// aguanta de forma sostenida, la toma se DETIENE en vez de seguir grabando
    /// material a medio movimiento que se ve fluido en el contenedor y tirón en la
    /// pantalla.
    ///
    /// ⚠️ No es una pausa que reanuda: el recorder solo tiene idle/recording/
    /// stopping, así que esto DETIENE y conserva lo grabado hasta ese punto. Una
    /// pausa reanudable de verdad es una feature aparte (segmentos), no un arreglo.
    ///
    /// Mismo patrón que el guard de voz, que ya detiene a los 20 s sin micrófono:
    /// avisa temprano (4 s) y detiene si no se arregla (12 s). El governor ya
    /// necesita ~4 s de mala evidencia para llegar al piso, así que detener a los
    /// 12 s de piso fallando son ~16 s de cadencia sostenidamente bajo 24: eso no
    /// es un tropiezo, es que esta Mac no puede con esta toma AHORA.
    private static let cadenceWarnAfter: Double = 4
    private static let cadenceStopAfter: Double = 12

    private func startCadenceGuard(engine: StudioEngine) {
        cadenceTask?.cancel()
        // `--chokems` ahoga el loop A PROPÓSITO para ejercer el governor: es el
        // único instrumento que tenemos para probar la recuperación. Si el guard
        // detuviera esa corrida, mataríamos justamente la prueba que protege todo
        // lo demás. El ahogo artificial no es un problema real de la Mac.
        guard StudioRecTest.chokeMs == 0 else {
            Log.info("Estudio: guard de cadencia OFF (--chokems activo: es QA del governor)")
            return
        }
        cadenceTask = Task { @MainActor [weak self] in
            var aviso = false
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, self.state == .recording else { return }
                let fallando = engine.governor.floorFailingFor(now: CACurrentMediaTime())
                let piso = engine.governor.effective
                let logrado = engine.governor.floorAchieved
                if fallando == 0 { aviso = false; continue }

                if fallando >= Self.cadenceWarnAfter, !aviso {
                    aviso = true
                    Log.error(String(format: "Estudio: CADENCIA BAJO EL PISO — %.1f fps contra un piso "
                                     + "de %d, lleva %.0fs. Si no se arregla, detengo la toma.",
                                     logrado, piso, fallando))
                    self.onAlert?(String(format: "⚠️ La Mac no sostiene %d fps (va a %.1f). Cierra lo que "
                                         + "esté cargando el sistema AHORA: si sigue así detengo la toma "
                                         + "en %.0fs, porque grabar bajo el piso es grabar tirones.",
                                         piso, logrado, Self.cadenceStopAfter - fallando), true)
                    notify("SFCast — LA CADENCIA SE ESTÁ CAYENDO",
                           String(format: "%.1f fps contra un piso de %d. Libera la Mac o detengo la toma.",
                                  logrado, piso))
                }
                if fallando >= Self.cadenceStopAfter {
                    Log.error(String(format: "Estudio: DETENIENDO — %.0fs bajo el piso de %d fps (a %.1f). "
                                     + "Prohibido seguir bajando: mejor detener que entregar tirones.",
                                     fallando, piso, logrado))
                    self.onAlert?(String(format: "Detuve la toma: la Mac no sostenía %d fps (iba a %.1f). "
                                         + "Lo grabado hasta aquí está a salvo. Cierra apps o reinicia "
                                         + "SFCast y vuelve a empezar.", piso, logrado), true)
                    notify("SFCast — TOMA DETENIDA",
                           String(format: "No se sostenían %d fps (iba a %.1f). Lo grabado está a salvo.",
                                  piso, logrado))
                    self.lastAutoStopReason = String(format: "el guard de CADENCIA la detuvo "
                                                     + "(%.1f fps contra un piso de %d)", logrado, piso)
                    self.onEmergencyStop?()
                    return
                }
            }
        }
    }

    /// Cuándo arrancó ESTE proceso. El preflight lo usa porque el costo del
    /// compositor crece con las horas que la app lleva abierta (medido: 1.1-2.2 ms
    /// recién abierta → 5.1-8.1 ms a los ~3 días) y ese era el factor que ninguna
    /// medición registraba. Un benchmark de rendimiento sin el uptime del proceso
    /// al lado no es reproducible.
    private static let launchedAt = Date()

    /// Muestrea el nivel del mic a 10 Hz mientras se graba.
    private func startEnvelope(engine: StudioEngine) {
        envelope.removeAll()
        envelopeTask?.cancel()
        envelopeTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self, self.state == .recording else { return }
                self.envelope.append(engine.levels.get().mic)
            }
        }
    }

    /// Escribe `levels.json` junto al video: `{hz, mic:[…]}`. Formato tonto a
    /// propósito — que el editor no tenga que aprender nada para usarlo.
    private func writeEnvelope(to dir: URL) {
        guard !envelope.isEmpty else { return }
        let payload: [String: Any] = [
            "hz": 10,
            "mic": envelope.map { Double(round(1000 * $0) / 1000) },
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            try? data.write(to: dir.appendingPathComponent("levels.json"))
            Log.info("Estudio: envolvente de audio → levels.json (\(envelope.count) muestras a 10 Hz)")
        }
    }

    // MARK: - GUARD DE VOZ — el sensor que faltaba y costó 35 minutos

    /// El 10 ago Daniel grabó **35 minutos sin una sola muestra de voz**. El
    /// sensor EXISTÍA: el latido escribió `mic:MUDO` **140 veces seguidas**,
    /// desde el segundo 15. Nadie hizo nada con esa información.
    ///
    /// Es la quinta repetición del patrón órgano-sin-sensor de este sistema, y
    /// la más cara: la imagen se regraba, una toma sin voz es basura. La noche
    /// anterior se construyeron alarmas para pantalla, cámara, fps, memoria y
    /// disco — y se dejó fuera justo la del audio, que es lo único irrecuperable.
    ///
    /// Cubre los tres modos de fallo, que piden avisos distintos:
    ///  1. **Nunca llega audio** (lo de hoy: cable, el micro apagado, MOTIV
    ///     tomándolo). Aviso a los 3 s y **auto-stop a los 20** — a los 20
    ///     segundos no has perdido nada; a los 35 minutos lo has perdido todo.
    ///  2. **Llegan buffers pero en silencio digital** (muteado, ganancia a
    ///     cero). `fresh()` diría que sí llega: hay que mirar el NIVEL.
    ///  3. **Enmudece a mitad de la toma** — el caso que más duele porque ya
    ///     llevas media hora hablando.
    private func startVoiceGuard(engine: StudioEngine, micEnabled: Bool) {
        voiceTask?.cancel()
        guard micEnabled else {
            Log.info("Estudio: guard de voz OFF (grabación sin micrófono, a propósito)")
            return
        }
        // ⛔⛔ LA LÍNEA BASE SE TOMA AQUÍ, ANTES DEL PRIMER TICK (fix 28 ago 2026).
        //     El guard pregunta "¿entró audio DESDE QUE ARRANCÓ ESTA TOMA?", y eso es la
        //     diferencia contra este número, no un valor absoluto.
        let micBase = engine.levels.micArrivals()
        voiceTask = Task { @MainActor [weak self] in
            var pico: Float = 0
            var avisoSinAudio = false, avisoSilencio = false, avisoCaida = false
            var mudoDesde: Double?
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, self.state == .recording else { return }
                let el = self.elapsed
                // ⛔⛔ EL SENSOR ES EL MICRÓFONO, NO EL ARCHIVO DEL PROGRAMA (fix 28 ago 2026).
                //
                //     Antes esta línea era:
                //         let samples = self.sink?.snapshot().micSamples ?? 0
                //
                //     `sink` es el writer de la salida «Programa» y sólo existe dentro de
                //     `if config.outputs.program`. Con esa salida APAGADA, `sink` es nil, el `?? 0`
                //     devuelve 0 para siempre, y las dos ramas de abajo disparaban sí o sí: banner
                //     a los 3 s y AUTO-STOP a los 20. Daniel perdió CINCO tomas seguidas el 28 ago
                //     — hablando, con el vúmetro del MIXER marcando nivel sano — la primera vez que
                //     apagó esa salida. Medido después sobre los archivos: `micSamples` = 0 en las
                //     cinco, y `levels.json` con 85% de muestras CON VOZ en la última.
                //
                //     Y no era una puerta, eran tres. `micSamples` también se queda clavado en 0 si
                //     `ProgramSink.prepare()` falla, o si el compositor se atasca y `appendVideo()`
                //     nunca arranca la sesión del writer — o sea que el guard podía culpar al
                //     micrófono de un fallo del compositor, con el mic perfecto.
                //
                //     `engine.levels` se alimenta desde el delegate de captura, en su propia cola,
                //     SIN pasar por el compositor ni por ningún writer. Es el mismo dato que pinta
                //     el vúmetro que Daniel estaba mirando mientras la app le decía que no había
                //     voz. Ese desacuerdo entre lo que la pantalla muestra y lo que el guard cree
                //     era, él solo, la prueba de que el guard miraba la cosa equivocada.
                //
                //     Regla de la casa incumplida DENTRO de la app: un cero en un sensor significa
                //     "no se midió", no "vale cero".
                let entroAudio = engine.levels.micArrivals() > micBase
                let fresco = engine.levels.fresh().mic
                pico = max(pico, engine.levels.get().mic)

                // 1) NUNCA llegó audio
                if !entroAudio, el >= 3, !avisoSinAudio {
                    avisoSinAudio = true
                    Log.error("Estudio: SIN VOZ — 3s de grabación y CERO muestras de micrófono")
                    self.onAlert?("⚠️ NO ESTÁ ENTRANDO TU VOZ. Revisa el micrófono AHORA "
                                  + "(¿encendido? ¿cable? ¿otra app lo tomó?).", true)
                    notify("SFCast — NO SE OYE TU VOZ",
                           "Llevas 3 segundos grabando y no entra audio del micrófono.")
                }
                if !entroAudio, el >= 20 {
                    Log.error("Estudio: SIN VOZ a los 20s — DETENIENDO para no perder media hora")
                    self.onAlert?("Detuve la grabación: no entraba tu voz. Arregla el micrófono "
                                  + "y vuelve a empezar.", true)
                    notify("SFCast — GRABACIÓN DETENIDA", "No entraba tu voz. Revisa el micrófono.")
                    self.lastAutoStopReason = "el guard de VOZ la detuvo (cero buffers de mic en 20s)"
                    self.onEmergencyStop?()
                    return
                }
                // 2) llegan buffers, pero es silencio digital
                if entroAudio, el >= 15, pico < 0.002, !avisoSilencio {
                    avisoSilencio = true
                    Log.error(String(format: "Estudio: MIC EN SILENCIO — llegan datos pero el pico "
                                     + "en 15s es %.5f (¿muteado? ¿ganancia en cero?)", pico))
                    self.onAlert?("El micrófono entrega datos pero NO capta sonido: ¿está muteado "
                                  + "o con la ganancia en cero?", true)
                    notify("SFCast — EL MICRÓFONO NO CAPTA", "Llega señal pero está en silencio.")
                }
                // 3) enmudeció a mitad
                // ⛔ Antes esta rama colgaba de `samples > 0`, así que con «Programa» apagado
                //    quedaba MUDA justo en la configuración donde el guard más se equivocaba.
                if entroAudio {
                    if fresco { mudoDesde = nil } else if mudoDesde == nil { mudoDesde = el }
                    if let d = mudoDesde, el - d > 8, !avisoCaida {
                        avisoCaida = true
                        Log.error(String(format: "Estudio: LA VOZ SE CAYÓ en el minuto %.1f", el / 60))
                        self.onAlert?("Tu voz dejó de entrar. Sigo grabando imagen, pero revisa "
                                      + "el micrófono.", true)
                        notify("SFCast — SE CAYÓ TU VOZ",
                               "Dejó de entrar audio del micrófono. La imagen sigue grabando.")
                    }
                }
            }
        }
    }

    // MARK: - GUARD DEL PROGRAMA — el fallo que se disfrazaba de micrófono

    /// Hermano del guard de voz, y nació del mismo bug (28 ago 2026).
    ///
    /// `micSamples` del programa se queda clavado en 0 por TRES motivos distintos: la salida
    /// «Programa» apagada, un `ProgramSink.prepare()` que falla, o el compositor atascado —
    /// `appendVideo()` es lo único que pone `sessionStarted = true`, y sin eso `appendAudio()`
    /// descarta cada buffer. El guard de voz usaba ese contador y por eso acusaba al micrófono
    /// de los tres. Ahora mira su propio sensor y este guard se queda con lo que de verdad le
    /// tocaba: **¿la salida que pediste está escribiendo?**
    ///
    /// ⛔ Sólo corre si el usuario PIDIÓ el programa. Con la salida apagada no hay nada que
    ///    vigilar, y ese fue justamente el error original: un guard opinando sobre un archivo
    ///    que nadie pidió.
    /// ⛔ AVISA, NO DETIENE. La imagen y el audio crudos siguen grabándose bien; matar la toma
    ///    por esto sería repetir el daño que estamos arreglando.
    private func startProgramGuard(engine: StudioEngine, programOn: Bool) {
        programTask?.cancel()
        guard programOn else { return }
        programTask = Task { @MainActor [weak self] in
            var avisado = false
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, self.state == .recording else { return }
                guard !avisado, self.elapsed >= 10 else { continue }
                let st = self.sink?.snapshot()
                guard (st?.videoFrames ?? 0) == 0 else { return }   // escribe: nada que vigilar
                avisado = true
                let causa = self.sink == nil ? "el writer del programa no arrancó"
                                             : "el compositor no está entregando cuadros"
                Log.error("Estudio: PROGRAMA SIN ESCRIBIR a los \(Int(self.elapsed))s — \(causa)")
                self.onAlert?("El archivo del programa no se está escribiendo (\(causa)). "
                              + "Las capas crudas SÍ siguen grabando.", true)
                notify("SFCast — EL PROGRAMA NO ESCRIBE", causa)
            }
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

    /// MARCADOR EN VIVO. Devuelve el total para que la UI lo enseñe.
    ///
    /// No valida ni "corrige" el instante: Daniel pulsa cuando se da cuenta, y
    /// esa señal cruda es más útil que un rango inventado — el editor tiene el
    /// transcript con tiempos por palabra para encontrar la frontera de la frase.
    @discardableResult
    func mark(_ kind: String, label: String? = nil) -> Int {
        guard state == .recording else { return markers.count }
        let t = Date().timeIntervalSince(startedAt)
        markers.append(.init(t: t, kind: kind, label: label))
        Log.info(String(format: "Estudio: MARCADOR '%@' en %.1fs (total %d)", kind, t, markers.count))
        return markers.count
    }

    var markerCount: Int { markers.count }

    /// DESHACER la última marca (⌥Z). Si te equivocas al marcar, hoy el dato
    /// quedaba sucio para siempre — y una drop-list con basura es peor que no
    /// tenerla, porque el editor la obedece.
    @discardableResult
    func unmark() -> StudioManifest.Marker? {
        guard state == .recording, let ultima = markers.popLast() else { return nil }
        Log.info(String(format: "Estudio: marca DESHECHA ('%@' en %.1fs) — quedan %d",
                        ultima.kind, ultima.t, markers.count))
        return ultima
    }

    /// Cuántas de cada tipo (la UI las muestra por separado).
    var markerTally: (cortes: Int, estrellas: Int) {
        (markers.filter { $0.kind == "retoma" }.count,
         markers.filter { $0.kind != "retoma" }.count)
    }

    /// Una fuente se congeló o volvió. El tramo se cierra cuando vuelve (o al
    /// detener), y va al manifest para que el editor no use esos segundos.
    func noteFrozen(_ source: String, frozen: Bool, reason: String) {
        guard state == .recording else { return }
        let t = Date().timeIntervalSince(startedAt)
        if frozen {
            if frozenSince[source] == nil { frozenSince[source] = t }
        } else if let desde = frozenSince.removeValue(forKey: source) {
            deadZones.append(.init(from: desde, to: t, source: source, reason: reason))
            Log.error(String(format: "Estudio: TRAMO CONGELADO de %@ — %.1fs a %.1fs (%@)",
                             source, desde, t, reason))
        }
    }

    /// EL ESCALÓN DEL GOVERNOR queda en el manifest (v3.6).
    ///
    /// El evento ya existía y solo pintaba un banner. Ahora el dato sobrevive a la
    /// toma: es la única forma de que después se pueda distinguir un archivo de 30
    /// fps REALES de uno de 15 fps rellenados a 30 — porque `achievedFps` mide el
    /// relleno y por construcción no puede delatarse.
    func cadenceChanged(_ effective: Int, target: Int) {
        guard state == .recording else { return }
        cadenceLog.append(.init(t: Date().timeIntervalSince(startedAt),
                                effectiveFps: effective, targetFps: target))
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
        envelopeTask?.cancel(); envelopeTask = nil
        voiceTask?.cancel(); voiceTask = nil
        cadenceTask?.cancel(); cadenceTask = nil
        programTask?.cancel(); programTask = nil
        engine.onNeedNewScreenRawURL = nil
        let duration = Date().timeIntervalSince(startedAt)
        // Un tramo congelado que seguía abierto al detener se cierra AQUÍ: si no,
        // el daño más grave (la fuente que nunca volvió) sería justo el que no
        // quedaría registrado.
        for (source, desde) in frozenSince {
            deadZones.append(.init(from: desde, to: duration, source: source,
                                   reason: "seguía congelada al detener"))
            Log.error(String(format: "Estudio: TRAMO CONGELADO de %@ — %.1fs al final (%.1fs)",
                             source, desde, duration - desde))
        }
        frozenSince.removeAll()
        let dir = sessionDir!
        let id = videoID

        // 1) programa: soltar el sink primero (el render loop deja de alimentarlo)
        engine.sink.set(nil)
        var programStats: ProgramSink.Stats?
        if let s = sink {
            programStats = await s.finish()
            sink = nil
        }
        // ⚠️ LOS INSTANTES DE ARRANQUE SE LEEN **ANTES** DE CERRAR: los cierres
        // nilean los delegates, que son justo quienes los saben. Leerlos después
        // devolvía el respaldo en silencio y el manifest declaraba un offset
        // equivocado por 52 frames — con el número puesto, que es la peor forma
        // de estar mal.
        let camFirst = engine.camRawFirstFrameHost
        let screenFirst = engine.screenRawFirstFrameHost
        engine.disarmRawStarts()
        // 2) raw de pantalla y cámara (cierres con deadline adentro)
        if wroteScreen { await engine.detachScreenRecording() }
        if wroteCamera { await engine.stopCameraMovie() }

        // 3) manifest con probe real de cada archivo (duración/dimensiones)
        var outputs: [StudioManifest.OutputFile] = []
        var probe: [(String, String)] = screenRawFiles.map { ("screen", $0) }
        if probe.isEmpty { probe = [("screen", "screen.mp4")] }
        probe += [("camera", "camera.mov"), ("program", "seg-001.mp4")]
        // EL ORIGEN COMÚN de las tres pistas: el t=0 del programa en reloj host.
        let t0 = programStats?.sessionStartHost ?? 0
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
            // LA VERDAD DE ESTA PISTA (v3): desfase MEDIDO + cadencia real.
            if t0 > 0 {
                switch role {
                case "program": out.startOffsetSeconds = 0; out.startOffsetMethod = "origen"
                case "camera":
                    // POR EL SONIDO, no por el reloj: el mismo micrófono está en
                    // los dos archivos. Ver AlineadorDeAudio para los cuatro
                    // caminos de reloj que se probaron y por qué fallan.
                    let prog = dir.appendingPathComponent("seg-001.mp4")
                    if FileManager.default.fileExists(atPath: prog.path),
                       let off = await AlineadorDeAudio.offset(base: prog, pista: url) {
                        out.startOffsetSeconds = off
                        out.startOffsetMethod = "audio"
                        out.startOffsetUncertaintySeconds = 0.05
                    } else if let stop = engine.camRawStopHost, let d = out.durationSeconds {
                        out.startOffsetSeconds = (stop - d) - t0
                        out.startOffsetMethod = "reloj"
                        out.startOffsetUncertaintySeconds = 0.12
                    } else if let f = camFirst {
                        out.startOffsetSeconds = f - t0
                        out.startOffsetMethod = "reloj"
                    }
                case "screen":
                    // La pantalla se queda con el reloj: su audio es el del
                    // SISTEMA, casi siempre mudo, y correlacionar silencio es
                    // inventar. Aquí el reloj SÍ sirve — medido, coincide con
                    // la derivación del cierre dentro de un frame.
                    if let f = screenFirst { out.startOffsetSeconds = f - t0; out.startOffsetMethod = "reloj" }
                default: break
                }
            }
            if let c = await CadenciaArchivo.medir(url: url) {
                out.effectiveFps = c.effectiveFps
                out.sourceFps = c.sourceFps
                out.variableFrameRate = c.variable
                out.cadenceHealth = c.health
                Log.info(String(format: "Estudio: pista %@ — %.2f fps efectivos (fuente %.2f · salud %.0f%%%@)%@",
                                name, c.effectiveFps, c.sourceFps, c.health * 100,
                                c.variable ? " · VFR" : "",
                                out.startOffsetSeconds.map { String(format: " · offset %+.3f s", $0) } ?? ""))
                // LA ALARMA QUE FALTABA. El 28 ago la cámara escribió 19 fps de
                // una fuente que mandaba 25 clavados durante toda la grabación,
                // y ni el log ni el manifest dijeron una palabra. Un órgano sin
                // sensor se ve igual de sano que uno vivo (invariante 5b).
                if !c.variable, c.health < 0.95, c.sourceFps > 0 {
                    let perdidos = (1 - c.effectiveFps / c.sourceFps) * 100
                    Log.error(String(format: "Estudio: ⚠️ %@ PERDIÓ FRAMES — %.0f%% de los que mandó la fuente "
                                     + "(%.2f de %.2f fps). La capa no sirve para componer sin saberlo.",
                                     name, max(0, perdidos), c.effectiveFps, c.sourceFps))
                    onAlert?("La pista \(name) perdió frames: \(Int(max(0, perdidos)))% de los que mandó la fuente.", true)
                }
            }
            outputs.append(out)
        }
        // CONTRA-CHEQUEO DEL OFFSET (28 ago 2026 — nació de que este código se
        // equivocó y lo cazó una correlación de audio externa).
        //
        // El offset declarado se compara contra el que se DERIVARÍA de que
        // todas las pistas cierran juntas. Los dos métodos son independientes:
        // si coinciden, la cifra es confiable; si no, uno de los dos miente y
        // quien vaya a componer las capas tiene que enterarse ANTES, no después
        // de alinear mal un video entero. Un sensor sin un segundo sensor con
        // qué contrastarse es exactamente lo que este repo ya aprendió a no
        // creerle (v2.4: el vúmetro que nunca se contrastó).
        if let prog = outputs.first(where: { $0.role == "program" }),
           let dProg = prog.durationSeconds {
            for out in outputs where out.role != "program" {
                guard let decl = out.startOffsetSeconds, let d = out.durationSeconds else { continue }
                let derivado = dProg - d
                let dif = abs(derivado - decl)
                if dif > 1.0 / Double(max(engine.fps, 1)) {
                    Log.error(String(format: "Estudio: ⚠️ OFFSET DUDOSO en %@ — declarado %+.3f s, "
                                     + "derivado del cierre %+.3f s (difieren %.0f frames). "
                                     + "No compongas las capas sin verificar a mano.",
                                     out.file, decl, derivado, dif * Double(engine.fps)))
                } else {
                    Log.info(String(format: "Estudio: offset de %@ confirmado por dos caminos (%+.3f vs %+.3f s)",
                                    out.file, decl, derivado))
                }
            }
        }
        // FPS REALES del programa, ANTES de armar el manifest: lo conseguido
        // tiene que quedar escrito junto a lo pedido (ver el aviso más abajo).
        let realFPS = (programStats.map { duration > 0.5 ? Double($0.videoFrames) / duration : 0 }) ?? 0
        achievedFPS = realFPS
        // FPS DE CONTENIDO ÚNICO — el número que el ojo percibe.
        //
        // `realFPS` cuenta frames ESCRITOS. CadenceKeeper rellena los huecos
        // repitiendo el último frame para que el archivo salga CFR (los NLE
        // sufren con VFR, y eso se queda así a propósito). Pero entonces
        // `realFPS` mide la salida del actuador, no el movimiento: el 15 ago
        // dijo 29.61 sobre un archivo con 12.8 fps de contenido nuevo.
        // `repeatedFrames` ya se contaba exacto y nadie lo restaba.
        let repetidos = engine.cadence.repeatedFrames
        let unicosFPS: Double? = programStats.flatMap { st -> Double? in
            guard duration > 0.5 else { return nil }
            return Double(max(0, st.videoFrames - repetidos)) / duration
        }
        let compStats = engine.compositorStats()
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
            systemAudioEnabled: config.systemAudioEnabled,
            markers: markers,
            deadZones: deadZones,
            micDevice: micDeviceName,
            preset: presetActivo,
            micSamples: programStats?.micSamples ?? 0,
            repeatedFrames: repetidos,
            uniqueContentFps: unicosFPS,
            bufferFailures: compStats.bufferFailures,
            cadenceTimeline: cadenceLog)
        manifest.write(to: dir)
        writeEnvelope(to: dir)

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
                // …Y EL MOVIMIENTO, que es otra cosa (v3.6, 17 ago).
                //
                // La línea de arriba mide la CADENCIA del archivo. Esta mide el
                // MOVIMIENTO. El 15 ago la primera dijo "29.61 (99%)" sobre una
                // toma con 12.8 fps de contenido nuevo: 53.6% de los frames eran
                // repetición. Streamlabs, la misma toma minutos después: 27.3.
                // El aviso va sobre ESTE número, porque es el que se ve.
                if let unicos = unicosFPS {
                    let pctU = unicos / objetivo
                    let repPct = real > 0 ? Double(repetidos) / (real * duration) * 100 : 0
                    // ⚠️ ESTE NÚMERO NO MIRA PÍXELES, Y HAY QUE DECIRLO (26 ago 2026).
                    //
                    // `uniqueContentFps` cuenta los frames que el compositor
                    // produjo menos los que rellenó `CadenceKeeper`. Eso es una
                    // medida honesta de LA APP, pero no del contenido: si la
                    // pantalla está quieta y la cámara apagada, el compositor
                    // compone 30 frames idénticos por segundo y este contador
                    // dice 100% tan feliz. Medido esa noche: 96% aquí contra 48%
                    // real con `mpdecimate` sobre el mismo archivo.
                    //
                    // El repo ya lo sabía y no estaba escrito donde se lee: el
                    // sensor está cableado a la salida de su propio actuador. El
                    // veredicto sobre PÍXELES lo da `scripts/qa-unique-fps.sh`.
                    // Así que el log lo etiqueta por lo que es y dice dónde está
                    // el juez de verdad; un número que promete más de lo que mide
                    // es la forma más cara de tener razón.
                    Log.info(String(format: "Estudio: FRAMES NUEVOS %.2f fps compuestos sin relleno "
                                    + "(%.0f%% de lo pedido · %.0f%% eran repetición). OJO: cuenta frames, "
                                    + "no píxeles — para el movimiento real corre scripts/qa-unique-fps.sh",
                                    unicos, pctU * 100, repPct))
                    if pctU < 0.9 {
                        Log.error(String(format: "Estudio: SOLO %.0f%% DE FRAMES NUEVOS — el archivo dice "
                                         + "%.1f fps y solo %.1f se compusieron de cero", pctU * 100,
                                         real, unicos))
                        onAlert?(String(format: "⚠️ El archivo dice %.0f fps pero se MUEVE a %.1f: %.0f%% de "
                                        + "los frames son repetidos. Cierra y reabre SFCast antes de la "
                                        + "toma buena (el compositor se degrada con las horas abierto) y "
                                        + "libera RAM.", real, unicos, repPct), true)
                        notify("SFCast — LA TOMA SE MUEVE A LA MITAD",
                               String(format: "%.1f fps de movimiento real (el archivo dice %.0f). "
                                      + "Reinicia SFCast antes de volver a grabar.", unicos, real))
                    }
                }
                // EL AVISO SE DECIDE POR TRAMO, NO POR PROMEDIO (fix 9 ago).
                // Ese día el promedio salió 92% —por encima del umbral del 90%,
                // así que NO avisó— mientras seis minutos del archivo estaban a
                // 10 fps con congelamientos de 750 ms. El promedio de una
                // grabación larga es justo el estadístico que oculta un colapso
                // corto: hay que mirar el PEOR tramo.
                // EL HUECO DE CABEZA (sensor nuevo, 26 ago 2026). Mide los
                // segundos entre el instante en que el writer abrió la sesión y
                // el primer frame que de verdad se escribió. Debe ser ~0: si no,
                // el archivo EMPIEZA CONGELADO y todo lo que se calcule sobre su
                // duración (fps reales, movimiento, peor tramo) sale deprimido
                // por un hueco que no es material, es contabilidad.
                //
                // Nace con su alarma, como manda el invariante: un sensor sin
                // actuador no es un sensor.
                if st.headVoidSec > 0.5 {
                    Log.error(String(format: "Estudio: HUECO DE CABEZA de %.2f s — el archivo abre su "
                                     + "línea de tiempo %.2f s antes del primer frame. Todo lo que se "
                                     + "mida sobre la duración sale castigado por ese hueco.",
                                     st.headVoidSec, st.headVoidSec))
                    onAlert?(String(format: "La toma abrió con %.1f s de vacío al principio. Revísala "
                                    + "antes de subirla.", st.headVoidSec), true)
                } else if st.videoFrames > 0 {
                    Log.info(String(format: "Estudio: arranque limpio — hueco de cabeza %.0f ms",
                                    st.headVoidSec * 1000))
                }
                if st.preSessionDrops > 0 {
                    Log.error("Estudio: \(st.preSessionDrops) frame(s) llegaron ANTES del arranque de "
                              + "sesión y se tiraron (antes esto no lo contaba nadie)")
                }
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
                // LOS DOS NÚMEROS DEL COMPOSITOR, etiquetados (v3.6, 17 ago).
                //
                // Parecían contradecirse: el cierre decía "máx 37.4 ms" mientras
                // las muestras por minuto de la MISMA sesión decían "máx 232 ms".
                // No se contradicen: son dos mediciones distintas con la misma
                // etiqueta. `Compositor.composeMs` arranca su cronómetro DESPUÉS
                // del `task.waitUntilCompleted()` del frame anterior, así que
                // excluye la espera de GPU; el cronómetro del render loop la
                // incluye. Esa diferencia ES el diagnóstico: cuando el total se va
                // a 232 ms con compose en 12, la Mac no está calculando de más,
                // está ESPERANDO a la GPU. Ahora se dicen las dos, con su nombre.
                let bud = 1000.0 / objetivo
                let loop = engine.profile.snapshot()
                Log.info(String(format: "Estudio: compositor (solo render, sin esperar GPU) "
                                + "p50 %.1f ms · máx %.1f — de un presupuesto de %.1f ms",
                                cs.composeMsP50, cs.composeMsMax, bud))
                Log.info(String(format: "Estudio: vuelta COMPLETA del loop (incluye la espera de GPU) "
                                + "p50 %.1f ms · p95 %.1f · máx %.1f (n=%d)",
                                loop.total.p50, loop.total.p95, loop.total.max, loop.n))
                if loop.total.p95 > bud {
                    Log.error(String(format: "Estudio: la COLA es el problema — p95 %.1f ms contra %.1f de "
                                     + "presupuesto (p50 va bien en %.1f). Es espera de GPU, no cálculo.",
                                     loop.total.p95, bud, loop.total.p50))
                }
            }
        }
        state = .idle
        energia.soltar()
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
        let reenganchesDeEstaToma = engine.screenRestarts - screenRestartsAtStart
        if reenganchesDeEstaToma > 0 {
            Log.error("Estudio: hubo \(reenganchesDeEstaToma) reenganche(s) de pantalla en esta toma "
                      + "(\(engine.screenRestarts) desde que abrió el Estudio)")
        }
        Log.info("Estudio: sesión \(id) guardada en \(dir.path)")
        lastDir = dir
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
        /// Frames tirados por llegar ANTES del arranque de sesión. Ver appendVideo.
        var preSessionDrops = 0
        /// EL t=0 DE LA SESIÓN en reloj host (v3, 28 ago). Es el origen contra
        /// el que se miden los offsets de los raws: sin un origen común, las
        /// tres pistas son tres relojes sueltos.
        var sessionStartHost: Double = 0
        /// Segundos de NADA al principio del archivo: del instante en que el
        /// writer abrió la sesión al primer frame que de verdad se escribió.
        /// Debe ser ~0. Cuando no lo es, el archivo empieza congelado.
        var headVoidSec: Double = 0
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
            stats.sessionStartHost = CMTimeGetSeconds(start)
            sessionStarted = true
            Log.info(String(format: "ProgramSink: sesión alineada en t=%.3f (video y audio arrancan juntos)",
                            CMTimeGetSeconds(start)))
        }
        // Un frame anterior al arranque de sesión rompería el orden del writer.
        // SE CUENTA (26 ago 2026): esto era un `return` mudo en el camino
        // caliente, y un frame que se va sin contarse es un frame que desaparece
        // del mundo — la misma lección del 9 ago, en el otro extremo del pipe.
        if CMTimeCompare(hostTime, sessionStartTime) < 0 { stats.preSessionDrops += 1; return }
        guard videoInput.isReadyForMoreMediaData else {
            stats.droppedFrames += 1
            if stats.droppedFrames % 120 == 1 {
                Log.error("ProgramSink: encoder atrás — \(stats.droppedFrames) frames tirados")
            }
            return
        }
        if adaptor.append(pb, withPresentationTime: hostTime) {
            if stats.videoFrames == 0 {
                stats.headVoidSec = CMTimeGetSeconds(CMTimeSubtract(hostTime, sessionStartTime))
            }
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
            // ⚠️ AQUÍ SE ARRANCA EN `now`, NO EN `firstVideoPTS` (fix 26 ago 2026).
            //
            // `firstVideoPTS` es el primer frame que se VIO, y todos los frames
            // entre él y este instante YA SE DESCARTARON esperando al audio: no
            // existen en ningún lado. Anclar la sesión ahí no los recupera —
            // solo abre la línea de tiempo del archivo en un punto donde no hay
            // nada, y el resultado es un video que EMPIEZA CONGELADO.
            //
            // En el caso benigno eso costaba los 0.6 s de la espera, sistemático
            // y en silencio. En el maligno —cuando `firstVideoPTS` venía de un
            // frame de relleno fechado en la TOMA ANTERIOR— costaba tantos
            // segundos como hubiera durado la pausa: medido el 26 ago, 1.07 s,
            // 1.20 s, 2.07 s, 6.77 s, 9.47 s.
            //
            // Si renunciamos al audio, la sesión empieza en el frame que estamos
            // a punto de escribir. No se pierde nada y no se inventa un hueco.
            return QAFlags.revivirHuecoDeCabeza ? firstVideoPTS : now
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
