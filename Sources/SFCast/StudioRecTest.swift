import Foundation
import AVFoundation
import CoreMedia

/// QA DEL ARCHIVO (`--rectest N [--chokems M]`) — graba de verdad y le pregunta
/// al MP4 si quedó bien, en vez de confiar en que el código "debería".
///
/// Verifica las tres cosas que el 9 ago salieron mal y nadie vio hasta abrir el
/// archivo al día siguiente:
///
///  1. **Las dos pistas arrancan juntas.** Antes: video en 0.000, audio en
///     0.152 — un hueco sistemático en TODAS las grabaciones, que cualquier
///     consumidor que ignore el `start_time` convierte en 152 ms de labios
///     desincronizados.
///  2. **La cadencia se sostiene**, y si no, baja PAREJA (governor) en vez de
///     romperse en saltos irregulares.
///  3. **Nada se pierde en silencio**: frames sin buffer, drops del encoder y
///     el peor tramo se reportan con nombre y número.
///
/// `--chokems M` ahoga el render loop M milisegundos por frame a propósito. Es
/// la única forma de ejercer el governor: un mecanismo de recuperación que
/// nunca se disparó no es un fix, es una intención (regla del 25 jul, cuando
/// `--killstream` se escribió por lo mismo).
@MainActor
enum StudioRecTest {

    static func run(seconds: Int, engine: StudioEngine, recorder: StudioRecorder,
                    config: StudioConfig, scene: StudioScene?) async {
        let choke = chokeMs
        Log.info("RECTEST — grabando \(seconds)s"
                 + (choke > 0 ? " con ahogo de \(choke) ms/frame (para ejercer el governor)" : ""))
        Log.info("RECTEST canvas=\(Int(engine.canvasSize.width))x\(Int(engine.canvasSize.height))"
                 + "@\(engine.fps) pantalla=\(engine.screenAvailable) cámara=\(engine.cameraAvailable)")

        guard engine.screenAvailable || engine.cameraAvailable else {
            Log.error("RECTEST_FAIL sin fuentes (ni pantalla ni cámara)")
            exit(3)
        }
        do {
            try recorder.start(engine: engine, config: config, activeScene: scene)
        } catch {
            Log.error("RECTEST_FAIL start: \(error.localizedDescription)")
            exit(1)
        }
        try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)

        let sync = engine.syncReport()
        let cs = engine.compositorStats()
        let efectivo = engine.effectiveFPS
        guard let dir = await recorder.stop(engine: engine, config: config) else {
            Log.error("RECTEST_FAIL la grabación no dejó carpeta")
            exit(1)
        }

        // ── verificación contra el ARCHIVO, no contra la intención ──
        let url = dir.appendingPathComponent("seg-001.mp4")
        guard FileManager.default.fileExists(atPath: url.path) else {
            Log.error("RECTEST_FAIL no se escribió seg-001.mp4")
            exit(1)
        }
        let asset = AVURLAsset(url: url)
        var fallos: [String] = []
        var videoStart: Double = -1
        var audioStarts: [Double] = []
        var videoFPS: Double = 0

        if let vt = try? await asset.loadTracks(withMediaType: .video).first {
            let r = (try? await vt.load(.timeRange)) ?? .invalid
            videoStart = CMTimeGetSeconds(r.start)
            let n = (try? await vt.load(.nominalFrameRate)) ?? 0
            let dur = CMTimeGetSeconds(r.duration)
            videoFPS = Double(n)
            Log.info(String(format: "RECTEST video: start=%.3fs dur=%.2fs fps≈%.2f",
                            videoStart, dur, videoFPS))
        } else {
            fallos.append("SIN-PISTA-DE-VIDEO")
        }
        for at in (try? await asset.loadTracks(withMediaType: .audio)) ?? [] {
            let r = (try? await at.load(.timeRange)) ?? .invalid
            let s = CMTimeGetSeconds(r.start)
            audioStarts.append(s)
            Log.info(String(format: "RECTEST audio[%d]: start=%.3fs dur=%.2fs",
                            at.trackID, s, CMTimeGetSeconds(r.duration)))
        }

        // 1) LA PRUEBA DEL HUECO. Antes de hoy esto salía 0.152 siempre.
        let maxSkew = audioStarts.map { abs($0 - max(videoStart, 0)) }.max() ?? 0
        if audioStarts.isEmpty {
            Log.info("RECTEST: sin pistas de audio (¿mic apagado?) — no se evalúa la alineación")
        } else if maxSkew > 0.030 {
            fallos.append(String(format: "PISTAS-DESALINEADAS(%.0f ms)", maxSkew * 1000))
        } else {
            Log.info(String(format: "RECTEST ✓ pistas alineadas (desfase de arranque %.0f ms)",
                            maxSkew * 1000))
        }

        // 2) LA CADENCIA. Con ahogo se espera que el governor haya BAJADO el
        //    objetivo: eso es éxito, no fallo. Sin ahogo se espera sostener.
        if choke > 0 {
            if efectivo < engine.fps {
                Log.info("RECTEST ✓ governor actuó: \(engine.fps) → \(efectivo) fps")
            } else {
                fallos.append("GOVERNOR-NO-ACTUO(seguía en \(efectivo) con ahogo de \(choke)ms)")
            }
        } else if videoFPS > 0, videoFPS < Double(engine.fps) * 0.9 {
            // Distinguir las DOS causas, porque piden acciones opuestas: si el
            // governor bajó la cadencia, el código hizo su trabajo y la culpa es
            // de la máquina (cierra apps / baja el lienzo); si NO bajó teniendo
            // que hacerlo, entonces sí es el governor el que está roto.
            if efectivo < engine.fps {
                fallos.append(String(format:
                    "MAQUINA-SATURADA(%.1f de %d; el governor SÍ actuó: bajó a %d — "
                    + "no es el código, es que esta Mac no daba el ritmo ahora)",
                    videoFPS, engine.fps, efectivo))
            } else {
                fallos.append(String(format:
                    "CADENCIA-BAJA(%.1f de %d y el governor NUNCA bajó — eso sí es un bug)",
                    videoFPS, engine.fps))
            }
        }

        // 3) NADA EN SILENCIO
        Log.info(String(format: "RECTEST compositor: p50 %.2f ms · máx %.2f ms · sin-buffer %d",
                        cs.composeMsP50, cs.composeMsMax, cs.bufferFailures))
        if let cam = sync.camera {
            Log.info(String(format: "RECTEST sync: latencia cámara %.0f ms · corrección aplicada %.0f ms",
                            cam * 1000, sync.appliedMs))
            if sync.appliedMs < 1 {
                fallos.append("RELOJ-SIN-CORREGIR(latencia medida pero corrección en 0)")
            }
        } else {
            Log.info("RECTEST sync: sin latencia de cámara medida (sin cámara o relojes distintos)")
        }

        if fallos.isEmpty {
            Log.info("RECTEST_OK \(dir.lastPathComponent)")
            exit(0)
        } else {
            Log.error("RECTEST_FAIL " + fallos.joined(separator: " "))
            exit(2)
        }
    }

    /// Milisegundos de ahogo por frame (`--chokems N`). Lo lee el render loop.
    static var chokeMs: Int {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--chokems"), i + 1 < a.count else { return 0 }
        return Int(a[i + 1]) ?? 0
    }
}
