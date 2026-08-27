import Foundation
import AVFoundation
import CoreMedia

/// QA DE TOMAS ENCADENADAS (`--tomas N [--dura S] [--pausa S]`).
///
/// **Por qué existe.** Las dos rondas de rendimiento anteriores (v3.0 y v3.1)
/// cerraron en verde y el fallo volvió. Las dos midieron lo mismo: UNA toma, en
/// una máquina limpia. Pero Daniel no graba una toma: graba, se equivoca, para,
/// respira, y vuelve a dar REC — seis, diez, veinte veces por video.
///
/// Y ahí vivía el bug del 26 ago 2026: `CadenceKeeper.lastEmitted` sobrevivía a
/// la toma anterior, así que **cada grabación abría su línea de tiempo tantos
/// segundos en el pasado como hubiera durado la pausa**. La primera toma de
/// cada sesión salía perfecta —no había toma anterior que la envenenara— y por
/// eso ningún test de una sola toma lo vio nunca.
///
/// La lección que este arnés sostiene: *un test que solo prueba el primer
/// intento prueba el caso más fácil que existe.* Las pausas se varían a
/// propósito (1, 2, 4, 7, 10 s…) porque el daño era proporcional a la pausa.
@MainActor
enum StudioTomasTest {

    /// Hueco de cabeza que se tolera. 250 ms es holgado: la alineación de las
    /// dos pistas cuesta ~150 ms de cabeza por diseño (fix del 9 ago) y eso es
    /// legítimo. Lo que buscamos son los segundos.
    static let maxHuecoSec = 0.25

    struct Toma {
        var n = 0
        var id = ""
        var pausaAntes = 0
        var frames = 0
        var primerPTS = 0.0
        var duracion = 0.0
        var fps = 0.0
    }

    static func run(tomas: Int, dura: Int, pausaBase: Int, engine: StudioEngine,
                    recorder: StudioRecorder, config: StudioConfig, scene: StudioScene?) async {
        Log.info("TOMAS — \(tomas) grabaciones de \(dura)s con pausas crecientes entre ellas")
        Log.info("TOMAS canvas=\(Int(engine.canvasSize.width))x\(Int(engine.canvasSize.height))"
                 + "@\(engine.fps) pantalla=\(engine.screenAvailable) cámara=\(engine.cameraAvailable)")
        guard engine.screenAvailable || engine.cameraAvailable else {
            Log.error("TOMAS_FAIL sin fuentes (ni pantalla ni cámara)")
            exit(3)
        }

        // Pausas VARIADAS: el daño del 26 ago era proporcional a la pausa, así
        // que una pausa fija habría medido un solo punto de la curva.
        let pausas = [0, 1, 2, 4, 7, 10, 3, 6, 12, 5]
        var out: [Toma] = []

        for i in 0..<tomas {
            let pausa = i == 0 ? 0 : pausas[min(i, pausas.count - 1)] + pausaBase
            if pausa > 0 {
                Log.info("TOMAS: pausa de \(pausa)s antes de la toma \(i + 1)")
                try? await Task.sleep(nanoseconds: UInt64(pausa) * 1_000_000_000)
            }
            do {
                try recorder.start(engine: engine, config: config, activeScene: scene)
                StudioController.shared.isRecording = true
            } catch {
                Log.error("TOMAS_FAIL start toma \(i + 1): \(error.localizedDescription)")
                exit(1)
            }
            try? await Task.sleep(nanoseconds: UInt64(dura) * 1_000_000_000)
            StudioController.shared.isRecording = false
            // ⚠️ `stop()` devuelve nil TAMBIÉN cuando un guard ya detuvo la toma
            // solo (cadencia, voz, disco): esos llaman a `stop()` por su cuenta y
            // dejan `state` en `.idle`, así que el nuestro rebota contra su propio
            // `guard state == .recording`. La carpeta SÍ existe y la grabación SÍ
            // está bien — es el arnés el que perdió el control del sujeto.
            //
            // Confundir las dos cosas es la lección del 25 jul, textual en este
            // repo: *"un gate que confunde 'el test perdió el control del sujeto'
            // con 'el sujeto falló' enseña a ignorar los rojos"*. Así que se busca
            // la carpeta por el otro camino antes de declarar nada.
            var dirOpt = await recorder.stop(engine: engine, config: config)
            if dirOpt == nil, let ultima = recorder.lastDir {
                Log.info("TOMAS: la toma \(i + 1) la detuvo un guard"
                         + (recorder.lastAutoStopReason.map { " (\($0))" } ?? "")
                         + " — sigo con su archivo, que existe")
                dirOpt = ultima
            }
            guard let dir = dirOpt else {
                Log.error("TOMAS_FAIL la toma \(i + 1) no dejó carpeta")
                exit(1)
            }
            var t = Toma(n: i + 1, id: dir.lastPathComponent, pausaAntes: pausa)
            await medir(dir.appendingPathComponent("seg-001.mp4"), objetivo: engine.fps, into: &t)
            out.append(t)
            Log.info(String(format: "TOMAS #%d %@ pausa=%ds → %d frames, primer PTS %.3fs, %.2f fps",
                            t.n, t.id, t.pausaAntes, t.frames, t.primerPTS, t.fps))
        }

        veredicto(out, objetivo: engine.fps)
    }

    /// Se le pregunta AL ARCHIVO, no al recorder: el sensor de la app vive
    /// aguas abajo de su propio actuador y no puede delatar esta falla.
    private static func medir(_ url: URL, objetivo: Int, into t: inout Toma) async {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return }
        t.duracion = (try? await asset.load(.duration).seconds) ?? 0
        guard let reader = try? AVAssetReader(asset: asset) else { return }
        let outp = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(outp) else { return }
        reader.add(outp)
        guard reader.startReading() else { return }
        var n = 0
        while outp.copyNextSampleBuffer() != nil { n += 1 }
        t.frames = n
        t.fps = t.duracion > 0 ? Double(n) / t.duracion : 0
        // ⚠️ EL HUECO NO SE PUEDE LEER DEL PRIMER PTS, y esto costó una vuelta
        // entera de QA el 26 ago: `AVAssetReader` respeta el edit list y
        // devuelve la pista ya normalizada, así que con DIEZ SEGUNDOS de vacío
        // al principio su primer PTS sigue diciendo 0.000. El arnés marcaba ✓
        // mientras ffprobe veía 10.1 s de nada — un medidor que mide su propia
        // normalización, no el archivo.
        //
        // Lo que el vacío SÍ mueve es la duración: el asset dura desde donde el
        // writer abrió la sesión, y los frames solo ocupan `n / fps`. La resta
        // de esas dos cosas es el hueco, y no depende de ningún edit list.
        t.primerPTS = max(0, t.duracion - Double(n) / Double(max(objetivo, 1)))
    }

    private static func veredicto(_ tomas: [Toma], objetivo: Int) {
        Log.info("── TOMAS: veredicto ──")
        var fallos: [String] = []
        for t in tomas {
            let marca = t.primerPTS > maxHuecoSec ? "✗ HUECO" : "✓"
            Log.info(String(format: "  %@ toma %d (pausa %2ds): hueco de cabeza %6.3f s · %d frames · %.2f fps",
                            marca, t.n, t.pausaAntes, t.primerPTS, t.frames, t.fps))
            if t.primerPTS > maxHuecoSec {
                fallos.append(String(format: "toma %d abrió con %.2f s de vacío (pausa previa %d s)",
                                     t.n, t.primerPTS, t.pausaAntes))
            }
            if t.fps < Double(objetivo) * 0.9 {
                fallos.append(String(format: "toma %d salió a %.2f fps de %d", t.n, t.fps, objetivo))
            }
        }
        // LA COMPARACIÓN QUE IMPORTA: la última tan buena como la primera. Ese
        // es el caso que ninguna ronda anterior probó.
        if let primera = tomas.first, let ultima = tomas.last, tomas.count > 1 {
            let caida = primera.fps > 0 ? (primera.fps - ultima.fps) / primera.fps * 100 : 0
            Log.info(String(format: "  primera %.2f fps → última %.2f fps (caída %.1f%%)",
                            primera.fps, ultima.fps, caida))
            if caida > 5 { fallos.append(String(format: "la última toma cayó %.1f%% respecto a la primera", caida)) }
        }
        if fallos.isEmpty {
            Log.info("TOMAS_OK — las \(tomas.count) tomas arrancan limpias y sostienen la cadencia")
            print("TOMAS_OK n=\(tomas.count)")
            exit(0)
        }
        for f in fallos { Log.error("TOMAS_FAIL — \(f)") }
        print("TOMAS_FAIL \(fallos.count) problema(s)")
        exit(2)
    }
}
