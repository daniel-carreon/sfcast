import AppKit
import AVFoundation
import ScreenCaptureKit

/// Orquestador central: preflight de permisos → countdown → captura →
/// burbuja/panel → stop → link AL INSTANTE al portapapeles + navegador →
/// upload en background.
///
/// CONCURRENCIA (review adversarial 14 jul): todo corre en @MainActor, así que
/// las carreras solo ocurren en los puntos de `await`. Dos candados las cierran:
/// 1. `generation` — cada sesión tiene un número; tras CADA await se verifica
///    que ni cancel() ni una sesión nueva lo hayan movido (un éxito tardío de
///    startCapture tras cancelar se apaga solo, no "resucita" la grabación).
/// 2. `.stopping` es estado CERRADO: pause/resume/stop/cancel lo ignoran, así
///    un doble-clic en Detener no borra la sesión que se está subiendo.
@MainActor
final class RecordingController {
    static let shared = RecordingController()

    enum Mode: String { case screen, window, camOnly }
    enum State { case idle, countdown, recording, paused, stopping }

    let bubble = CameraBubble()
    let panel = ControlPanel()
    let engine = CaptureEngine()
    var settings = AppSettings.load()
    var noUpload = false                 // modo --demo --no-upload

    private(set) var state: State = .idle {
        didSet {
            onStateChange?()
            liveSyncFollow(from: oldValue, to: state)
            // Mientras rueda, El Set no se repinta solo. Ver MarcaDeRodaje.
            MarcaDeRodaje.set(state != .idle || StudioController.shared.isRecording)
        }
    }
    private(set) var mode: Mode = .screen
    private(set) var videoID = ""
    private var sessionDir: URL!
    private var startedAt = Date()
    private var windowTarget: SCWindow?
    private var generation = 0           // candado anti-resurrección (ver header)
    private var liveSyncTask: Task<Void, Never>?

    // camOnly: grabación directa de la cámara (mismo session de la burbuja)
    private var movieOutput: AVCaptureMovieFileOutput?
    private var camDelegate: CamFileDelegate?
    private var camSegments: [URL] = []
    private var camSegIndex = 0

    var onStateChange: (() -> Void)?

    init() {
        panel.onPauseToggle = { [weak self] in
            guard let self else { return }
            Task { self.state == .paused ? await self.resume() : await self.pause() }
        }
        // Detener/cancelar funcionan desde CUALQUIER estado no-cerrado: si el
        // arranque quedó a medias (countdown), detener degrada a cancelar en
        // vez de rebotar en un guard (el "presiono y nada pasa" del 14 jul).
        panel.onStop = { [weak self] in
            guard let self else { return }
            Task {
                if self.state == .recording || self.state == .paused { _ = await self.stopAndWait() }
                else { await self.cancel() }
            }
        }
        panel.onCancel = { [weak self] in Task { await self?.cancel() } }
        panel.onRestart = { [weak self] in Task { await self?.restart() } }
    }

    /// Reiniciar (el ↺ del pill, estilo Loom): tira lo grabado y arranca de
    /// cero en el MISMO modo. Sale por cancel() para no duplicar limpieza.
    func restart() async {
        guard state == .recording || state == .paused else { return }
        let m = mode
        let w = windowTarget
        await cancel()
        switch m {
        case .screen: await startScreen()
        case .window: if let w { await startWindow(w) }
        case .camOnly: await startCamOnly()
        }
    }

    var publicURL: String { "\(settings.baseURL)/v/\(videoID)" }

    /// La pantalla que se CAPTURA (CGMainDisplayID). La burbuja, el panel, el
    /// countdown y la coreografía deben vivir AQUÍ — con 2 displays,
    /// NSScreen.main (foco) puede ser OTRA pantalla y la burbuja quedaría
    /// fuera del video (bug encontrado en la evidencia E2E).
    static func captureScreen() -> NSScreen? {
        let mainID = CGMainDisplayID()
        return NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == mainID
        }) ?? NSScreen.main
    }

    // MARK: - arranques

    func startScreen() async {
        guard state == .idle, !studioBlocks, let screen = Self.captureScreen() else { return }
        settings = AppSettings.load()   // PRIMERO: recoge glow/tamaño/cámara/mic del hub
        prepareSession(mode: .screen)
        let gen = generation
        let dir = sessionDir!
        state = .countdown

        // PANTALLA primero: macOS 26 liga la aprobación al build (cdhash) — tras
        // un update de SFCast pide re-aprobar UNA vez. Mejor guiarlo aquí que
        // reventar tarde con la burbuja ya en pantalla.
        if !Permissions.screenGranted && Permissions.canPrompt {
            CGRequestScreenCaptureAccess()   // dispara el prompt del sistema
            notify("SFCast — permiso de pantalla",
                   "Aprueba «Grabación de pantalla y audio del sistema» y dale Grabar otra vez.")
            abortStart(); return
        }

        // Los permisos NO bloquean el arranque (Daniel 15 jul: "tarda mucho en
        // empezar a grabar"). La pantalla arranca YA; la cámara se pide en
        // segundo plano y la burbuja se enciende cuando el permiso llegue. El mic
        // se toma sólo si ya está concedido (el engine degrada solo si falta).
        if settings.micEnabled && !Permissions.micGranted {
            notify("SFCast — sin micrófono", "Grabo sin tu voz. Actívalo en el hub (Activar permisos) para el próximo.")
        }

        // Burbuja solo si la cámara está habilitada (toggle del micropanel v1.4).
        if settings.cameraEnabled {
            bubble.show(size: CameraBubble.Size(rawValue: settings.bubbleSize) ?? .m,
                        glow: CameraBubble.Glow(rawValue: settings.bubbleGlow) ?? .ambar, on: screen)
            // Cámara en background: enciende la burbuja en cuanto se conceda, sin
            // frenar un solo frame de la grabación de pantalla.
            Task { @MainActor in
                // Solo enciende la cámara si la burbuja SIGUE en pantalla: si el
                // usuario canceló/detuvo antes de conceder, no queremos prender la
                // cámara (luz on) sin burbuja ni grabación (fuga detectada en review).
                if await PermissionBroker.shared.request(.video), self.bubble.isVisible {
                    self.bubble.reloadCamera()
                }
            }
        } else {
            bubble.hide()   // por si el preview del micropanel la dejó encendida
        }
        await Countdown.run(seconds: settings.countdownSeconds, on: screen)
        guard gen == generation, state == .countdown else { return }

        panel.show(on: screen)
        engine.excludedWindowNumbers = []   // sharingType=.none ya oculta el panel; excluir via filtro COLGABA startCapture
        engine.sessionDir = dir
        engine.settings = settings
        engine.reset()
        do {
            try await engine.startSegment(target: .display)
            guard gen == generation, state == .countdown else {
                // éxito TARDÍO tras cancelar: apagar el stream y tirar los restos
                await engine.stopSegment()
                try? FileManager.default.removeItem(at: dir)
                return
            }
            state = .recording
            Log.info("Grabando pantalla → \(videoID)")
        } catch {
            if gen == generation { await failStart(error) }
        }
    }

    func startWindow(_ window: SCWindow) async {
        guard state == .idle, !studioBlocks, let screen = Self.captureScreen() else { return }
        settings = AppSettings.load()
        prepareSession(mode: .window)
        let gen = generation
        let dir = sessionDir!
        windowTarget = window
        state = .countdown
        if !Permissions.screenGranted && Permissions.canPrompt {
            CGRequestScreenCaptureAccess()
            notify("SFCast — permiso de pantalla",
                   "Aprueba «Grabación de pantalla y audio del sistema» y dale Grabar otra vez.")
            abortStart(); return
        }
        if settings.micEnabled && !Permissions.micGranted {
            notify("SFCast — sin micrófono", "Grabo sin tu voz. Actívalo en el hub (Activar permisos) para el próximo.")
        }
        await Countdown.run(seconds: settings.countdownSeconds, on: screen)
        guard gen == generation, state == .countdown else { return }
        panel.show(on: screen)
        engine.excludedWindowNumbers = []
        engine.sessionDir = dir
        engine.settings = settings
        engine.reset()
        do {
            try await engine.startSegment(target: .window(window))
            guard gen == generation, state == .countdown else {
                await engine.stopSegment()
                try? FileManager.default.removeItem(at: dir)
                return
            }
            state = .recording
            Log.info("Grabando ventana '\(window.title ?? "?")' → \(videoID)")
        } catch {
            if gen == generation { await failStart(error) }
        }
    }

    func startCamOnly() async {
        guard state == .idle, !studioBlocks, let screen = Self.captureScreen() else { return }
        settings = AppSettings.load()
        prepareSession(mode: .camOnly)
        let gen = generation
        state = .countdown
        // camOnly graba la cámara: la pedimos en background y encendemos la
        // burbuja al conceder (sin bloquear el countdown).
        if settings.micEnabled && !Permissions.micGranted {
            notify("SFCast — sin micrófono", "Grabo sin tu voz. Actívalo en el hub (Activar permisos).")
        }
        Task { @MainActor in
            // Solo enciende la cámara si la burbuja SIGUE en pantalla: si el
            // usuario canceló/detuvo antes de conceder, no queremos prender la
            // cámara (luz on) sin burbuja ni grabación (fuga detectada en review).
            if await PermissionBroker.shared.request(.video), self.bubble.isVisible {
                self.bubble.reloadCamera()
            }
        }
        bubble.show(size: .full,
                    glow: CameraBubble.Glow(rawValue: settings.bubbleGlow) ?? .ambar, on: screen)
        await Countdown.run(seconds: settings.countdownSeconds, on: screen)
        guard gen == generation, state == .countdown else { return }
        panel.show(on: screen)
        camSegments = []; camSegIndex = 0
        startCamSegment()
        state = .recording
        Log.info("Grabando solo cámara → \(videoID)")
    }

    // MARK: - pausa / stop / cancel

    func pause() async {
        guard state == .recording else { return }
        let gen = generation
        state = .stopping                       // candado: nadie más toca la sesión
        if mode == .camOnly { stopCamSegment() } else { await engine.stopSegment() }
        guard gen == generation, state == .stopping else { return }
        panel.enterPaused()
        state = .paused
        Log.info("Pausado")
    }

    func resume() async {
        guard state == .paused else { return }
        let gen = generation
        state = .stopping                       // candado anti doble-tap en ▶
        if mode == .camOnly {
            startCamSegment()
            panel.enterRecording()
            state = .recording
        } else {
            do {
                if mode == .window, let w = windowTarget {
                    try await engine.startSegment(target: .window(w))
                } else {
                    try await engine.startSegment(target: .display)
                }
                guard gen == generation, state == .stopping else {
                    await engine.stopSegment()
                    return
                }
                panel.enterRecording()
                state = .recording
            } catch {
                Log.error("No se pudo reanudar: \(error.localizedDescription)")
                if gen == generation { state = .paused }
            }
        }
    }

    /// Detiene, copia el link AL INSTANTE, abre el navegador en la página del
    /// video ("Procesando…") y sube en background. El estado vuelve a .idle en
    /// cuanto la UI se esconde: puedes grabar el siguiente video mientras este
    /// sube (los datos de la sesión van capturados en locales).
    func stopAndWait() async -> (url: String, uploadOK: Bool) {
        guard state == .recording || state == .paused else { return (publicURL, false) }
        let wasPaused = state == .paused
        state = .stopping

        // Snapshot de la sesión ANTES de tocar nada (una grabación nueva puede
        // pisar las properties mientras el upload sigue en vuelo).
        let duration = panel.elapsed
        let url = publicURL
        let id = videoID
        let dir = sessionDir!
        let began = startedAt
        let modeRaw = mode.rawValue
        let uploaderSettings = settings
        // Destino (toggle del micropanel): true = sube al VPS al instante (lo de
        // siempre); false = SOLO guarda en ~/Movies/SFCast/{id}. --no-upload
        // (demo) también fuerza local. La grabación queda en local en AMBOS casos.
        let willUpload = !noUpload && uploaderSettings.autoUpload

        // ⚡ EL MOMENTO MÁGICO, AHORA INSTANTÁNEO (Daniel 15 jul: "se tarda unos
        // segundos y se pierde la experiencia"): link al portapapeles y pill
        // fuera ANTES de cerrar el MP4 — cerrar el segmento tarda ~0.3-1s
        // esperando el didFinish del writer, y ese era TODO el lag percibido.
        NSPasteboard.general.clearContents()
        if willUpload {
            NSPasteboard.general.setString(url, forType: .string)
            notify("SFCast — link copiado 🔗", "Subiendo video… te aviso cuando esté listo.")
            Log.info("Link copiado al portapapeles: \(url)")
        } else {
            // Modo local: aún no hay link del VPS — copio la RUTA local para que
            // puedas pegarla o arrastrarla (al editor, etc.) al instante.
            NSPasteboard.general.setString(dir.path, forType: .string)
            Log.info("Modo local: la sesión queda en \(dir.path)")
        }
        panel.hide()

        if wasPaused {
            bubble.hide()
        } else if mode == .camOnly {
            // OJO camOnly: la burbuja ES la fuente del video (el movieOutput
            // cuelga de SU sesión). Apagarla antes de que el archivo cierre lo
            // truncaría → primero el stop, luego la burbuja.
            stopCamSegment()
            // 10s, no 3: el usuario YA tiene su link y la UI ya se fue, así que
            // esperar sale gratis. Cortar a los 3s podía truncar el .mov con
            // disco lento (Time Machine, USB) — justo lo que este orden evita.
            await waitCamFinished(timeout: 10)
            bubble.hide()
        } else {
            // Burn-in: esconder la burbuja ~1s antes de cortar el stream solo
            // recorta el último instante del video. Imperceptible, y el pill
            // desaparece al toque.
            bubble.hide()
            await engine.stopSegment()
        }

        let segments = currentSegments().map { $0.lastPathComponent }
        state = .idle

        var entry = History.Entry(
            id: id, url: url,
            date: ISO8601DateFormatter().string(from: began),
            durationSeconds: duration, mode: modeRaw,
            status: willUpload ? "uploading" : "local", title: nil)
        History.upsert(entry)

        var ok = true
        if !willUpload {
            // SOLO local: se guarda SIN comprimir (calidad completa, útil para
            // editar) y NO se sube. Se empuja al VPS luego desde el Historial
            // ("↑ subir"). Dejamos meta.json escrito para ese push y abrimos el
            // Finder en la carpeta (queda a la mano para arrastrar al editor).
            await liveSyncSettle()
            writeMeta(to: dir, id: id, modeRaw: modeRaw, began: began,
                      duration: duration, segments: segments)
            notify("SFCast — guardado en tu Mac 💾",
                   "En ~/Movies/SFCast/\(id). Lo subes al VPS desde el Historial cuando quieras.")
            NSWorkspace.shared.activateFileViewerSelecting([dir])
        } else {
            // Petición Daniel 14 jul: "cuando termine me envíe a la url donde se
            // grabó" → performUpload publica el placeholder, abre el navegador,
            // comprime (v1.6) y sube. El worker pisa el placeholder al terminar.
            let meta = Uploader.Meta(
                id: id, mode: modeRaw,
                startedAt: ISO8601DateFormatter().string(from: began),
                stoppedAt: ISO8601DateFormatter().string(from: Date()),
                durationSeconds: duration,
                segments: segments)
            // ANTES del rsync final: deja cerrar el pre-sync en vuelo.
            await liveSyncSettle()
            ok = await performUpload(id: id, dir: dir, url: url,
                                     uploaderSettings: uploaderSettings, meta: meta,
                                     openBrowser: true)
            entry.status = ok ? "done" : "failed"
            History.upsert(entry)
        }
        return (url, ok)
    }

    /// Prende y apaga la pre-subida siguiendo el estado, sin que ninguna ruta de
    /// arranque o de cancelación tenga que acordarse de hacerlo a mano.
    ///
    /// Vive solo mientras se GRABA: en pausa se apaga (no hay nada creciendo) y
    /// al reanudar vuelve. Al entrar a `.stopping` se corta ANTES de que arranque
    /// el rsync final, que es la razón de ser de todo esto: dos rsync escribiendo
    /// el mismo archivo remoto a la vez es justo lo que no queremos.
    private func liveSyncFollow(from old: State, to new: State) {
        guard old != new else { return }
        if new == .recording {
            guard settings.liveSyncWhileRecording, !noUpload, settings.autoUpload,
                  liveSyncTask == nil, let dir = sessionDir else { return }
            let uploader = Uploader(settings: settings)
            let id = videoID
            liveSyncTask = Task { await uploader.liveSync(sessionDir: dir, id: id) }
        } else if old == .recording {
            liveSyncTask?.cancel()
        }
    }

    /// Espera a que la pre-subida termine de verdad. `cancel()` solo pide la
    /// salida; si hay un rsync EN VUELO hay que dejarlo cerrar antes de lanzar
    /// el final, o los dos escriben el mismo archivo remoto.
    private func liveSyncSettle() async {
        guard let t = liveSyncTask else { return }
        t.cancel()
        await t.value
        liveSyncTask = nil
    }

    /// El tail de subida al VPS: placeholder → navegador → comprime → rsync →
    /// notifica. Compartido por stopAndWait y por "↑ Subir al VPS" del Historial.
    /// Devuelve true si el upload llegó al servidor.
    private func performUpload(id: String, dir: URL, url: String,
                               uploaderSettings: AppSettings, meta: Uploader.Meta,
                               openBrowser: Bool) async -> Bool {
        let uploader = Uploader(settings: uploaderSettings)
        do {
            try await uploader.publishPlaceholder(id: id)
            if openBrowser, let u = URL(string: url + "/") { NSWorkspace.shared.open(u) }
        } catch {
            Log.error("Placeholder no se pudo publicar (sigo con el upload): \(error.localizedDescription)")
        }
        // Comprimir antes de subir (v1.6): ~5x más chico ⇒ ~5x más rápido, que es
        // donde estaba TODA la espera real. En el push desde el Historial esto
        // viene APAGADO (uploaderSettings.compressBeforeUpload = false) para no
        // tocar el master local que guardaste a propósito en calidad completa.
        if uploaderSettings.compressBeforeUpload {
            await Transcoder.compressSegments(in: dir, bitrateKbps: uploaderSettings.videoBitrateKbps)
        }
        do {
            try await uploader.upload(sessionDir: dir, meta: meta)
            notify("SFCast — video listo ✓", "Procesando transcript y resumen en el VPS.")
            return true
        } catch {
            // que la página abierta no gire para siempre: pisa el placeholder
            try? await uploader.publishFailurePage(id: id)
            notify("SFCast — upload falló ⚠️", "El video quedó en ~/Movies/SFCast/\(id)")
            Log.error("Upload definitivamente falló: \(error.localizedDescription)")
            return false
        }
    }

    /// Escribe meta.json en el sessionDir (lo que lee el worker del VPS). En modo
    /// local lo dejamos listo para que el push posterior no tenga que rearmarlo.
    private func writeMeta(to dir: URL, id: String, modeRaw: String, began: Date,
                           duration: Double, segments: [String]) {
        let meta = Uploader.Meta(
            id: id, mode: modeRaw,
            startedAt: ISO8601DateFormatter().string(from: began),
            stoppedAt: ISO8601DateFormatter().string(from: Date()),
            durationSeconds: duration, segments: segments)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(meta).write(to: dir.appendingPathComponent("meta.json"))
    }

    /// "↑ Subir al VPS" del Historial: empuja una grabación que quedó en local
    /// (status "local", o un "failed" que sigue en disco). Reconstruye la sesión
    /// desde ~/Movies/SFCast/{id}. NO comprime en sitio: respeta el master local.
    func uploadExisting(id: String) async {
        guard state == .idle else {
            notify("SFCast", "Termina la grabación en curso antes de subir otra.")
            return
        }
        let dir = AppSettings.recordingsDir.appendingPathComponent(id)
        let segs = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix("seg-") && ($0.hasSuffix(".mp4") || $0.hasSuffix(".mov")) }
            .sorted()
        guard !segs.isEmpty else {
            notify("SFCast — no está en tu Mac", "No encontré segmentos en ~/Movies/SFCast/\(id).")
            return
        }
        var s = AppSettings.load()
        s.compressBeforeUpload = false          // el master local se queda intacto
        let url = "\(s.baseURL)/v/\(id)"

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        notify("SFCast — subiendo 🔗", "Link copiado. Te aviso cuando esté listo.")

        var entry = History.load().first { $0.id == id } ?? History.Entry(
            id: id, url: url, date: ISO8601DateFormatter().string(from: Date()),
            durationSeconds: 0, mode: "screen", status: "uploading", title: nil)
        entry.url = url
        entry.status = "uploading"
        History.upsert(entry)

        let meta = Uploader.Meta(
            id: id, mode: entry.mode, startedAt: entry.date,
            stoppedAt: ISO8601DateFormatter().string(from: Date()),
            durationSeconds: entry.durationSeconds, segments: segs)
        let ok = await performUpload(id: id, dir: dir, url: url,
                                     uploaderSettings: s, meta: meta, openBrowser: true)
        entry.status = ok ? "done" : "failed"
        History.upsert(entry)
    }

    func cancel() async {
        switch state {
        case .idle, .stopping:
            // .stopping = transición/stop en curso, ELLA es dueña de la limpieza.
            return
        case .countdown:
            // Aborta el arranque en vuelo: los guards de generation en start*
            // ven el cambio y, si startCapture despierta tarde, se auto-apaga.
            generation += 1
            state = .idle
            bubble.hide()
            panel.hide()
            try? FileManager.default.removeItem(at: sessionDir)
            Log.info("Arranque cancelado durante countdown/preflight")
        case .recording, .paused:
            let wasPaused = state == .paused
            generation += 1
            state = .stopping
            if !wasPaused {
                if mode == .camOnly { stopCamSegment() } else { await engine.stopSegment() }
            }
            bubble.hide()
            panel.hide()
            let discardedID = videoID
            let discardSettings = settings
            try? FileManager.default.removeItem(at: sessionDir)
            // La pre-subida pudo dejar bytes arriba: sin UPLOAD_DONE el poller
            // ni los mira, así que se quedarían de basura invisible en el VPS.
            await liveSyncSettle()
            Task { await Uploader(settings: discardSettings).discardRemote(id: discardedID) }
            Log.info("Grabación cancelada y descartada")
            state = .idle
        }
    }

    // MARK: - helpers

    /// Limpieza cuando el arranque aborta ANTES de cualquier await (gate de
    /// pantalla). Para aborts post-await el dueño de la limpieza es cancel().
    private func abortStart() {
        bubble.hide()
        panel.hide()
        try? FileManager.default.removeItem(at: sessionDir)
        if state != .idle { state = .idle }
    }

    /// Cross-guard con el Modo Estudio: si el Estudio está GRABANDO, el Loom no
    /// arranca (compartirían cámara/mic/SCK). Con el Estudio solo en preview,
    /// prepareSession lo cierra — misma regla que el micropanel.
    var studioBlocks: Bool {
        if StudioController.shared.isStudioRecording {
            notify("SFCast", "El Estudio está grabando. Deténlo antes de grabar en modo Loom.")
            return true
        }
        return false
    }

    private func prepareSession(mode: Mode) {
        // TODO arranque pasa por aquí (botón del micropanel, ⌘⇧L, menú clásico):
        // cerrar el micropanel y apagar su vúmetro SIEMPRE — el meter tiene su
        // propia AVCaptureSession sobre el mic y competiría con SCStream o con
        // el session de la burbuja (hallazgo CONFIRMADO del review v1.4).
        LauncherPanelController.shared.hide(keepPreview: true)
        // El Estudio (si está abierto en preview) suelta cámara/pantalla aquí.
        StudioController.shared.closeForLoom()
        self.mode = mode
        generation += 1
        videoID = makeVideoID()
        startedAt = Date()
        sessionDir = AppSettings.recordingsDir.appendingPathComponent(videoID)
        try? FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
    }

    private func currentSegments() -> [URL] {
        mode == .camOnly ? camSegments : engine.segmentURLs
    }

    private func failStart(_ error: Error) async {
        Log.error("No se pudo iniciar captura: \(error.localizedDescription)")
        notify("SFCast — no pude arrancar", String(error.localizedDescription.prefix(120)))
        bubble.hide()
        panel.hide()
        try? FileManager.default.removeItem(at: sessionDir)
        state = .idle
    }

    // MARK: - camOnly (AVCaptureMovieFileOutput sobre el session de la burbuja)

    private func startCamSegment() {
        let session = bubble.captureSession
        if movieOutput == nil {
            let out = AVCaptureMovieFileOutput()
            if session.canAddOutput(out) { session.addOutput(out) }
            movieOutput = out
        }
        // Mic ELEGIDO en el hub (no el default a ciegas) y solo con permiso ya
        // otorgado — crear el input sin permiso dispara prompts fuera de secuencia.
        if settings.micEnabled, Permissions.micGranted,
           !session.inputs.contains(where: { ($0 as? AVCaptureDeviceInput)?.device.hasMediaType(.audio) ?? false }),
           let micDevice = Devices.microphone(id: settings.micDeviceID),
           let micInput = try? AVCaptureDeviceInput(device: micDevice),
           session.canAddInput(micInput) {
            session.addInput(micInput)
        }
        camSegIndex += 1
        let url = sessionDir.appendingPathComponent(String(format: "seg-%03d.mov", camSegIndex))
        let del = CamFileDelegate()
        camDelegate = del
        movieOutput?.startRecording(to: url, recordingDelegate: del)
        camSegments.append(url)
    }

    private func stopCamSegment() {
        movieOutput?.stopRecording()
    }

    /// Espera a que el .mov de camOnly quede FINALIZADO antes de apagar la
    /// sesión de la burbuja (si no, el archivo se trunca).
    private func waitCamFinished(timeout: Double) async {
        guard let del = camDelegate else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while !del.finished && Date() < deadline {
            try? await Task.sleep(nanoseconds: 60_000_000)
        }
        if !del.finished {
            Log.error("camOnly: didFinish no llegó en \(Int(timeout))s (el archivo suele quedar OK igual)")
        }
    }
}

final class CamFileDelegate: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _finished = false
    private var _error: String?
    /// El Estudio también usa este delegate: sin etiqueta, sus errores se
    /// loggeaban como "camOnly" y mandaban el diagnóstico al lado equivocado
    /// (el `Disk Full` del 25 jul era del raw de cámara del ESTUDIO).
    private let label: String
    init(label: String = "camOnly") { self.label = label }

    var finished: Bool { lock.lock(); defer { lock.unlock() }; return _finished }
    var failure: String? { lock.lock(); defer { lock.unlock() }; return _error }

    /// CUÁNDO EMPEZÓ DE VERDAD (28 ago 2026). `startRecording` es ASÍNCRONO:
    /// medido, el archivo tarda ~1.65 s en abrirse de verdad después de la
    /// llamada. Anclar el offset al instante de la LLAMADA daba −0.09 s donde
    /// el real era +1.655 (52 frames a 30 fps), y solo lo cazó contrastar
    /// contra una correlación de audio independiente. Este callback es el
    /// único que sabe el instante bueno.
    private var _startedHost: Double?
    var startedHost: Double? { lock.lock(); defer { lock.unlock() }; return _startedHost }

    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection]) {
        lock.lock(); _startedHost = CACurrentMediaTime(); lock.unlock()
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        if let error {
            Log.error("\(label) — \(outputFileURL.lastPathComponent): \(error.localizedDescription)")
        }
        lock.lock(); _finished = true; _error = error?.localizedDescription; lock.unlock()
    }
}
