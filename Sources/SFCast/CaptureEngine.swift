import Foundation
import AppKit
import AVFoundation
import ScreenCaptureKit
import CoreMedia

/// Motor de captura por SEGMENTOS: cada segmento es su propio SCStream +
/// SCRecordingOutput (pausa = cerrar segmento; reanudar = abrir el siguiente).
/// Decisión: más robusto que add/removeRecordingOutput en caliente; el costo
/// (~0.3s de gap al pausar) es irrelevante para el caso de uso.
@MainActor
final class CaptureEngine: NSObject {
    enum Target {
        case display                 // pantalla completa (burbuja quemada)
        case window(SCWindow)        // ventana específica (sin burbuja, v1)
    }

    private var stream: SCStream?
    private var recOutput: SCRecordingOutput?
    private var recDelegate: SegmentDelegate?
    private(set) var segmentURLs: [URL] = []
    private var segIndex = 0

    var sessionDir: URL!
    var excludedWindowNumbers: [Int] = []   // panel de control (NO la burbuja)
    var settings = AppSettings.load()

    func startSegment(target: Target) async throws {
        Log.info("startSegment: pidiendo SCShareableContent…")
        // También con deadline: con tccd atascado esta llamada puede colgarse
        // igual que startCapture (visto en vivo el 14 jul 19:26).
        let content = try await Self.withDeadline(seconds: 12, name: "SCShareableContent") {
            try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }
        Log.info("startSegment: contenido listo (\(content.displays.count) displays)")
        let cfg = SCStreamConfiguration()
        let filter: SCContentFilter

        switch target {
        case .display:
            let mainID = CGMainDisplayID()
            guard let display = content.displays.first(where: { $0.displayID == mainID })
                    ?? content.displays.first else {
                throw NSError(domain: "SFCast", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "Sin permiso de pantalla efectivo. Aprueba «Grabación de pantalla» para SFCast y reintenta; si acabas de aprobar, cierra y reabre la app."])
            }
            let excluded = content.windows.filter {
                excludedWindowNumbers.contains(Int($0.windowID))
            }
            Log.info("exclusión: buscaba \(excludedWindowNumbers), matcheó \(excluded.count) de \(content.windows.count) ventanas")
            filter = SCContentFilter(display: display, excludingWindows: excluded)
            let scale = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
            })?.backingScaleFactor ?? 2.0
            cfg.width = Int(CGFloat(display.width) * scale)
            cfg.height = Int(CGFloat(display.height) * scale)
        case .window(let w):
            filter = SCContentFilter(desktopIndependentWindow: w)
            let scale: CGFloat = 2.0
            cfg.width = Int(w.frame.width * scale)
            cfg.height = Int(w.frame.height * scale)
        }

        // TOPE DE RESOLUCIÓN (10 ago 2026). Ver `AppSettings.captureMaxHeight`
        // para las mediciones: capturar nativo daba 4096x2304 / 23 Mbps y ESE
        // tamaño era la raíz de toda la lentitud del pipeline, no el VPS.
        let capped = Self.cap(width: cfg.width, height: cfg.height,
                              maxHeight: settings.captureMaxHeight)
        if capped != (cfg.width, cfg.height) {
            Log.info("captura: \(cfg.width)x\(cfg.height) → \(capped.0)x\(capped.1) (tope \(settings.captureMaxHeight)p)")
            cfg.width = capped.0
            cfg.height = capped.1
        }
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(settings.fps))
        cfg.showsCursor = true
        cfg.capturesAudio = settings.systemAudioEnabled
        // DEFENSA EN PROFUNDIDAD: capturar mic sin permiso TCC dispara un prompt
        // dentro de startCapture → si hay otro prompt pendiente, tccd serializa y
        // el start se cuelga PARA SIEMPRE (el bug del 14 jul). Si el preflight no
        // consiguió el permiso, se graba sin mic — jamás se arriesga el arranque.
        var micOK = settings.micEnabled
        if micOK && AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            micOK = false
            Log.error("Mic activado pero SIN permiso TCC — este segmento graba sin micrófono")
        }
        cfg.captureMicrophone = micOK
        if micOK, let micID = settings.micDeviceID {
            cfg.microphoneCaptureDeviceID = micID
        }

        let stream = SCStream(filter: filter, configuration: cfg, delegate: nil)
        segIndex += 1
        let url = sessionDir.appendingPathComponent(String(format: "seg-%03d.mp4", segIndex))

        let recCfg = SCRecordingOutputConfiguration()
        recCfg.outputURL = url
        recCfg.outputFileType = .mp4
        // HEVC siempre: esquiva el tope H.264 de 4096x2304 en Retina/5K (gotcha investigado)
        recCfg.videoCodecType = .hevc

        let del = SegmentDelegate()
        let rec = SCRecordingOutput(configuration: recCfg, delegate: del)
        Log.info("startSegment: addRecordingOutput…")
        try stream.addRecordingOutput(rec)      // ANTES de startCapture (primer frame)
        Log.info("startSegment: startCapture…")
        try await Self.startCaptureWithTimeout(stream, seconds: 12)

        self.stream = stream
        self.recOutput = rec
        self.recDelegate = del
        segmentURLs.append(url)
        Log.info("Segmento \(segIndex) capturando \(cfg.width)x\(cfg.height) → \(url.lastPathComponent)")
    }

    /// Cierra el segmento actual y espera a que el MP4 quede finalizado.
    func stopSegment() async {
        guard let stream else { return }
        // CON DEADLINE (v1.5): desde que el stop esconde la UI ANTES de cerrar
        // el segmento, un `stopCapture()` colgado (tccd atascado — pasa, ver
        // startCaptureWithTimeout) dejaría `state` en .stopping PARA SIEMPRE y
        // sin señal visible: grabar de nuevo simplemente "no haría nada".
        let s = stream
        try? await Self.withDeadline(seconds: 10, name: "stopCapture") {
            try await s.stopCapture()
        }
        if let del = recDelegate {
            for _ in 0..<100 where !del.finished {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if !del.finished {
                Log.error("Segmento \(segIndex): didFinish no llegó en 10s (el archivo suele quedar OK igual)")
            }
        }
        self.stream = nil
        self.recOutput = nil
        self.recDelegate = nil
        Log.info("Segmento \(segIndex) cerrado")
    }

    func reset() {
        segmentURLs = []
        segIndex = 0
    }

    /// Reduce a `maxHeight` conservando el aspecto. `maxHeight <= 0` o una
    /// captura que ya es más chica se devuelven intactas (nunca se AGRANDA:
    /// escalar hacia arriba solo inventa píxeles y engorda el archivo).
    ///
    /// GOTCHA: las dimensiones salen PARES a la fuerza. yuv420p submuestrea
    /// croma 2x2, así que un ancho o alto impar hace que el encoder rechace la
    /// configuración y el segmento no arranque.
    static func cap(width: Int, height: Int, maxHeight: Int) -> (Int, Int) {
        guard maxHeight > 0, width > 0, height > 0, height > maxHeight else {
            return (width, height)
        }
        let scale = Double(maxHeight) / Double(height)
        let w = max(2, Int((Double(width) * scale).rounded()) & ~1)
        let h = max(2, maxHeight & ~1)
        return (w, h)
    }

    /// startCapture con RED DE SEGURIDAD real: si en `seconds` no arrancó (tccd
    /// atascado, prompt fantasma), REGRESA con error y la UI se recupera.
    ///
    /// GOTCHA (review adversarial 14 jul): withTaskGroup NO sirve aquí — la
    /// concurrencia estructurada espera a TODAS las child tasks antes de
    /// retornar, así que un startCapture colgado colgaba también al "timeout".
    /// La forma correcta: tasks NO estructuradas + continuation resume-once.
    /// Si el startCapture perdedor despierta tarde con éxito, se auto-apaga.
    private static func startCaptureWithTimeout(_ stream: SCStream, seconds: Double) async throws {
        let once = OnceFlag()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            Task.detached {
                do {
                    try await stream.startCapture()
                    if once.claim() { cont.resume() }
                    else { try? await stream.stopCapture() }   // llegó tarde: apágalo
                } catch {
                    if once.claim() { cont.resume(throwing: error) }
                }
            }
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if once.claim() {
                    cont.resume(throwing: NSError(domain: "SFCast", code: 99, userInfo: [NSLocalizedDescriptionKey:
                        "startCapture no respondió en \(Int(seconds))s (¿prompt de permisos pendiente?). Reinténtalo."]))
                }
            }
        }
    }

    /// Deadline genérico para llamadas de sistema que pueden colgarse con tccd
    /// atascado. Un éxito tardío del perdedor se descarta sin efectos.
    private static func withDeadline<T: Sendable>(seconds: Double, name: String,
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
                    cont.resume(throwing: NSError(domain: "SFCast", code: 98, userInfo: [NSLocalizedDescriptionKey:
                        "\(name) no respondió en \(Int(seconds))s (tccd atascado). Reinténtalo."]))
                }
            }
        }
    }
}

/// Candado resume-once para carreras timeout-vs-operación (thread-safe).
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
    /// Peek NO consumidor: ¿alguien ya reclamó? (para watchdogs que solo miran).
    var isClaimed: Bool {
        lock.lock(); defer { lock.unlock() }
        return fired
    }
}

final class SegmentDelegate: NSObject, SCRecordingOutputDelegate, @unchecked Sendable {
    @objc dynamic private(set) var finished = false

    /// Instante host en que el writer abrió el archivo de verdad. Hermano del
    /// de `CamFileDelegate`, y por el mismo motivo: el offset de una pista se
    /// mide cuando EMPIEZA A ESCRIBIR, no cuando se le pide que empiece.
    private let startLock = NSLock()
    private var _startedHost: Double?
    var startedHost: Double? { startLock.lock(); defer { startLock.unlock() }; return _startedHost }

    func recordingOutputDidStartRecording(_ output: SCRecordingOutput) {
        startLock.lock(); _startedHost = CACurrentMediaTime(); startLock.unlock()
    }

    func recordingOutput(_ output: SCRecordingOutput, didFailWithError error: Error) {
        Log.error("SCRecordingOutput falló: \(error.localizedDescription)")
        finished = true
    }

    func recordingOutputDidFinishRecording(_ output: SCRecordingOutput) {
        finished = true
    }
}
