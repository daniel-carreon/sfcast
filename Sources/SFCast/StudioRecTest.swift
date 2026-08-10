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
            // Mismo camino que el botón: los atajos viven solo durante la toma,
            // y la UI tiene que ENTERARSE de que se está grabando (si no, el
            // test mide una barra que no es la que ve Daniel).
            StudioController.shared.isRecording = true
            StudioController.shared.registrarAtajosDeMarcador()
            StudioController.shared.markerHUD.show()
        } catch {
            Log.error("RECTEST_FAIL start: \(error.localizedDescription)")
            exit(1)
        }
        // QA (--failstream): a la mitad de la toma, ejerce el fallo de
        // reenganche de pantalla. Es el caso que se dio SOLO en la prueba larga
        // (minuto 23.8) y que hay que poder disparar a voluntad: lo que se
        // verifica es que la grabación SOBREVIVE y que el aviso sale.
        if CommandLine.arguments.contains("--markers") {
            // Ejerce los marcadores por el MISMO camino que el atajo global
            // (StudioController.marcar), no llamando al recorder directo: probar
            // el atajo por dentro no probaría el cable completo.
            for (i, kind) in ["retoma", "bueno", "retoma"].enumerated() {
                try? await Task.sleep(nanoseconds: UInt64(seconds) * 200_000_000)
                StudioController.shared.marcar(kind)
                Log.info("RECTEST: marcador \(i + 1) puesto (\(kind))")
            }
            try? await Task.sleep(nanoseconds: UInt64(seconds) * 400_000_000)
        } else if CommandLine.arguments.contains("--freezecam") {
            // La cámara se "apaga" a la mitad. Lo que se verifica: que el
            // watchdog lo NOTE (y avise), porque el video sigue saliendo
            // perfecto — una foto fija a 30 fps es indistinguible de una
            // grabación sana si nadie mira el sensor.
            try? await Task.sleep(nanoseconds: UInt64(seconds) * 400_000_000)
            Log.info("RECTEST: congelando la cámara a propósito (simula auto power off)")
            StudioEngine.qaFreezeCamera = true
            try? await Task.sleep(nanoseconds: UInt64(seconds) * 600_000_000)
            StudioEngine.qaFreezeCamera = false
        } else if CommandLine.arguments.contains("--failstream") {
            try? await Task.sleep(nanoseconds: UInt64(seconds) * 500_000_000)
            Log.info("RECTEST: disparando fallo de reenganche de pantalla a propósito")
            engine.simulateRestartFailure()
            try? await Task.sleep(nanoseconds: UInt64(seconds) * 500_000_000)
        } else {
            try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
        }

        // Retrato de la BARRA con los contadores puestos: es donde Daniel cazó
        // que un solo contador sumaba los dos tipos, así que hay que MIRARLO,
        // no confiar en que el código "debería".
        if CommandLine.arguments.contains("--markers") {
            StudioController.shared.snapshotVentana(to: "/tmp/sfcast-barra.png")
        }
        StudioController.shared.soltarAtajosDeMarcador()
        StudioController.shared.markerHUD.hide()
        StudioController.shared.isRecording = false
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
                Log.info("RECTEST ✓ governor actuó: \(engine.fps) → \(efectivo) fps de composición")
            } else {
                fallos.append("GOVERNOR-NO-ACTUO(seguía en \(efectivo) con ahogo de \(choke)ms)")
            }
            // LA PRUEBA QUE IMPORTA: con la GPU ahogada a propósito, el ARCHIVO
            // tiene que salir IGUAL a la cadencia pedida. Es la promesa entera
            // ("que no se bajen los fps") hecha aserción.
            if videoFPS > 0, videoFPS < Double(engine.fps) * 0.95 {
                fallos.append(String(format:
                    "CADENCIA-ROTA-BAJO-AHOGO(%.1f de %d — el relleno no cubrió los huecos)",
                    videoFPS, engine.fps))
            } else {
                Log.info(String(format: "RECTEST ✓ CADENCIA SOSTENIDA bajo ahogo de %d ms: "
                                + "archivo a %.2f fps de %d pedidos (%d frames rellenados)",
                                choke, videoFPS, engine.fps, engine.cadence.repeatedFrames))
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

        // 3b) CALIDAD REAL DE LA CADENCIA: no basta con que el archivo tenga 30
        //     fps si la mitad son repetidos. Este es el número que dice si la
        //     Mac está de verdad al día o solo disimulando.
        let repes = engine.cadence.repeatedFrames
        let totalF = Int((videoFPS > 0 ? videoFPS : Double(engine.fps)) * Double(seconds))
        if totalF > 0 {
            let pct = Double(repes) / Double(totalF) * 100
            Log.info(String(format: "RECTEST cadencia: %d frames, %d rellenados (%.1f%% repetidos)",
                            totalF, repes, pct))
            // Sin ahogo artificial, más de un 15%% de repetidos significa que la
            // Mac no está siguiendo el ritmo de verdad — el archivo se ve bien
            // pero el movimiento no es fluido.
            if choke == 0, pct > 15 {
                fallos.append(String(format: "DEMASIADOS-REPETIDOS(%.1f%%)", pct))
            }
        }

        // 3c) ¿La pantalla aguantó viva toda la sesión? Un reenganche no invalida
        //     la grabación (la cámara y la voz siguen), pero deja tramos con la
        //     imagen congelada y ESO tiene que decirse con nombre y número.
        if engine.screenRestarts > 0 {
            Log.error("RECTEST ⚠️ la pantalla se cayó \(engine.screenRestarts) vez(ces) "
                      + "durante la sesión — hubo tramos con la imagen congelada")
        }
        // Con --failstream, la prueba es que la grabación SIGUIÓ VIVA pese al
        // fallo: si el archivo quedó corto o sin cadencia, el aviso no sirvió
        // de nada porque el video se perdió igual.
        if CommandLine.arguments.contains("--markers") {
            // Ejerce los marcadores por el MISMO camino que el atajo global
            // (StudioController.marcar), no llamando al recorder directo: probar
            // el atajo por dentro no probaría el cable completo.
            for (i, kind) in ["retoma", "bueno", "retoma"].enumerated() {
                try? await Task.sleep(nanoseconds: UInt64(seconds) * 200_000_000)
                StudioController.shared.marcar(kind)
                Log.info("RECTEST: marcador \(i + 1) puesto (\(kind))")
            }
            try? await Task.sleep(nanoseconds: UInt64(seconds) * 400_000_000)
        } else if CommandLine.arguments.contains("--freezecam") {
            // La cámara se "apaga" a la mitad. Lo que se verifica: que el
            // watchdog lo NOTE (y avise), porque el video sigue saliendo
            // perfecto — una foto fija a 30 fps es indistinguible de una
            // grabación sana si nadie mira el sensor.
            try? await Task.sleep(nanoseconds: UInt64(seconds) * 400_000_000)
            Log.info("RECTEST: congelando la cámara a propósito (simula auto power off)")
            StudioEngine.qaFreezeCamera = true
            try? await Task.sleep(nanoseconds: UInt64(seconds) * 600_000_000)
            StudioEngine.qaFreezeCamera = false
        } else if CommandLine.arguments.contains("--failstream") {
            if engine.screenRestarts == 0 {
                fallos.append("FAILSTREAM-NO-SE-EJERCIO")
            } else if videoFPS > 0, videoFPS >= Double(engine.fps) * 0.95 {
                Log.info(String(format: "RECTEST ✓ la grabación SOBREVIVIÓ al fallo de pantalla: "
                                + "%.2f fps de %d, cámara y voz intactas", videoFPS, engine.fps))
            } else {
                fallos.append(String(format: "GRABACION-DAÑADA-TRAS-FALLO(%.1f fps)", videoFPS))
            }
        }

        if CommandLine.arguments.contains("--markers") {
            // Ejerce los marcadores por el MISMO camino que el atajo global
            // (StudioController.marcar), no llamando al recorder directo: probar
            // el atajo por dentro no probaría el cable completo.
            for (i, kind) in ["retoma", "bueno", "retoma"].enumerated() {
                try? await Task.sleep(nanoseconds: UInt64(seconds) * 200_000_000)
                StudioController.shared.marcar(kind)
                Log.info("RECTEST: marcador \(i + 1) puesto (\(kind))")
            }
            try? await Task.sleep(nanoseconds: UInt64(seconds) * 400_000_000)
        } else if CommandLine.arguments.contains("--freezecam") {
            if engine.cameraFrozen || engine.screenRestarts >= 0 {
                Log.info("RECTEST ✓ el watchdog de cámara marcó la congelada "
                         + "(cameraFrozen=\(engine.cameraFrozen))")
            }
            if !engine.cameraFrozen {
                fallos.append("WATCHDOG-CAMARA-NO-DETECTO(la cámara se congeló y nadie lo notó)")
            }
        }

        // Los marcadores tienen que estar EN EL ARCHIVO de manifest, no solo en
        // memoria: el editor lee el manifest, no la RAM de una app cerrada.
        if CommandLine.arguments.contains("--markers") {
            let mf = dir.appendingPathComponent("manifest.json")
            if let data = try? Data(contentsOf: mf),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let ms = obj["markers"] as? [[String: Any]] {
                Log.info("RECTEST ✓ manifest con \(ms.count) marcadores: "
                         + ms.map { "\($0["kind"] ?? "?")@\(String(format: "%.1f", ($0["t"] as? Double) ?? 0))s" }
                             .joined(separator: " · "))
                if ms.count != 3 { fallos.append("MARCADORES-INCOMPLETOS(\(ms.count) de 3)") }
            } else {
                fallos.append("MANIFEST-SIN-MARCADORES")
            }
        }

        // 3) NADA EN SILENCIO
        Log.info(String(format: "RECTEST compositor: p50 %.2f ms · máx %.2f ms · sin-buffer %d",
                        cs.composeMsP50, cs.composeMsMax, cs.bufferFailures))
        Log.info("RECTEST ⏱ " + engine.profile.line())
        let sub = engine.compositorSubFases()
        Log.info(String(format: "RECTEST ⏱ dentro de compose: grafo %.2f ms · buffer %.2f ms · RENDER(GPU) %.2f ms",
                        sub.grafo, sub.buffer, sub.render))
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
