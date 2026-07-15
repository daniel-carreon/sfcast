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

    private(set) var state: State = .idle { didSet { onStateChange?() } }
    private(set) var mode: Mode = .screen
    private(set) var videoID = ""
    private var sessionDir: URL!
    private var startedAt = Date()
    private var windowTarget: SCWindow?
    private var generation = 0           // candado anti-resurrección (ver header)

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
        guard state == .idle, let screen = Self.captureScreen() else { return }
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
        guard state == .idle, let screen = Self.captureScreen() else { return }
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
        guard state == .idle, let screen = Self.captureScreen() else { return }
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
        if !wasPaused {
            if mode == .camOnly { stopCamSegment() } else { await engine.stopSegment() }
        }

        // Snapshot de la sesión ANTES de liberar el estado (una grabación nueva
        // puede pisar las properties mientras el upload sigue en vuelo).
        let duration = panel.elapsed
        let url = publicURL
        let id = videoID
        let dir = sessionDir!
        let segments = currentSegments().map { $0.lastPathComponent }
        let began = startedAt
        let modeRaw = mode.rawValue
        let uploaderSettings = settings

        // ⚡ EL MOMENTO MÁGICO: link al portapapeles ANTES de subir nada.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        notify("SFCast — link copiado 🔗", "Subiendo video… te aviso cuando esté listo.")
        Log.info("Link copiado al portapapeles: \(url)")

        bubble.hide()
        panel.hide()
        state = .idle

        var entry = History.Entry(
            id: id, url: url,
            date: ISO8601DateFormatter().string(from: began),
            durationSeconds: duration, mode: modeRaw, status: "uploading", title: nil)
        History.upsert(entry)

        var ok = true
        if noUpload {
            Log.info("(--no-upload) sesión queda en \(dir.path)")
        } else {
            let uploader = Uploader(settings: uploaderSettings)
            // Página "Procesando…" instantánea + abrir el navegador AHÍ (petición
            // Daniel 14 jul: "cuando termine me envíe a la url donde se grabó").
            // El worker la reemplaza con el viewer real al terminar el pipeline.
            do {
                try await uploader.publishPlaceholder(id: id)
                if let u = URL(string: url + "/") { NSWorkspace.shared.open(u) }
            } catch {
                Log.error("Placeholder no se pudo publicar (sigo con el upload): \(error.localizedDescription)")
            }
            let meta = Uploader.Meta(
                id: id, mode: modeRaw,
                startedAt: ISO8601DateFormatter().string(from: began),
                stoppedAt: ISO8601DateFormatter().string(from: Date()),
                durationSeconds: duration,
                segments: segments)
            do {
                try await uploader.upload(sessionDir: dir, meta: meta)
                entry.status = "done"
                notify("SFCast — video listo ✓", "Procesando transcript y resumen en el VPS.")
            } catch {
                ok = false
                entry.status = "failed"
                // que la página abierta no gire para siempre: pisa el placeholder
                try? await uploader.publishFailurePage(id: id)
                notify("SFCast — upload falló ⚠️", "El video quedó en ~/Movies/SFCast/\(id)")
                Log.error("Upload definitivamente falló: \(error.localizedDescription)")
            }
            History.upsert(entry)
        }
        return (url, ok)
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
            try? FileManager.default.removeItem(at: sessionDir)
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

    private func prepareSession(mode: Mode) {
        // TODO arranque pasa por aquí (botón del micropanel, ⌘⇧L, menú clásico):
        // cerrar el micropanel y apagar su vúmetro SIEMPRE — el meter tiene su
        // propia AVCaptureSession sobre el mic y competiría con SCStream o con
        // el session de la burbuja (hallazgo CONFIRMADO del review v1.4).
        LauncherPanelController.shared.hide(keepPreview: true)
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
}

final class CamFileDelegate: NSObject, AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        if let error { Log.error("camOnly segmento: \(error.localizedDescription)") }
    }
}
