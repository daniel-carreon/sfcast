import Foundation
import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import CoreGraphics
import QuartzCore

/// QA DE COSTO DEL COMPOSITOR (`--compbench`) — headless, sin TCC.
///
/// Existe porque la pregunta "¿por qué se traba?" se contestó dos veces con
/// teoría (v2.7 el preview, v2.8 el vúmetro) y la tercera hay que contestarla
/// con la CURVA: cuántos milisegundos cuesta componer un frame en ESTA Mac, a
/// cada tamaño de lienzo, con la escena que Daniel usa de verdad.
///
/// No toca cámara ni pantalla: fabrica pixel buffers del tamaño exacto de las
/// fuentes reales y los mete al mismo `LatestFrameStore` que usa el motor. Lo
/// que mide es el compositor puro — que es justo el hilo que alimenta el
/// ARCHIVO (`StudioEngine.startRenderLoop` → `ProgramSink.appendVideo`).
enum StudioCompBench {

    /// Presupuesto por frame a 30 fps. Si compose() lo pasa, el archivo baja de
    /// fps: no hay cola donde esconder el atraso, el timer simplemente pierde
    /// disparos.
    static let budget30ms = 1000.0 / 30.0

    static func run(iterations: Int = 90) {
        checkCaptureSize()
        print("COMPBENCH — costo de componer un frame, en esta Mac")
        print(String(repeating: "─", count: 78))

        // Fuentes del tamaño REAL del setup de Daniel: el BenQ nativo y la
        // ZV-E10 por UVC. El tamaño de la FUENTE importa aunque el lienzo baje:
        // escalar 4096→1920 cuesta, y ese costo es justo lo que se decide aquí.
        let screenSrc = CGSize(width: 4096, height: 2304)
        let camSrc = CGSize(width: 1920, height: 1080)

        guard let screenPB = synthBuffer(screenSrc, seed: 1),
              let camPB = synthBuffer(camSrc, seed: 2) else {
            print("no pude fabricar los buffers sintéticos"); return
        }

        let frames = LatestFrameStore()
        frames.set(screenPB, for: .screen)
        frames.set(camPB, for: .camera)

        // La escena real de la grabación del 9 ago: pantalla completa + burbuja
        // circular con halo morado a la derecha.
        let burbuja = StudioScene(name: "Burbuja derecha", items: [
            SceneItem(kind: .screen),
            {
                var it = SceneItem(kind: .camera,
                                   rect: CGRect(x: 0.8369, y: 0.0298, width: 0.1641, height: 0.2917),
                                   fit: .fill, circleMask: true)
                it.glow = .morado
                return it
            }(),
        ])
        // Y la otra que usó: cámara a pantalla completa.
        let camFull = StudioScene(name: "Mi cámara solo", items: [
            SceneItem(kind: .camera, rect: CGRect(x: 0, y: 0, width: 1, height: 1), fit: .fill),
        ])

        let canvases: [(String, CGSize)] = [
            ("4096×2304  (nativa)", CGSize(width: 4096, height: 2304)),
            ("2560×1440  (1440p)", CGSize(width: 2560, height: 1440)),
            ("1920×1080  (1080p)", CGSize(width: 1920, height: 1080)),
        ]

        for (sceneName, scene) in [("Burbuja derecha", burbuja), ("Mi cámara solo", camFull)] {
            print("\nESCENA: \(sceneName)")
            print("  lienzo                  p50 ms    p95 ms   fps máx   (presupuesto 33.3 ms)")
            for (label, canvas) in canvases {
                let c = Compositor()
                let ms = measure(compositor: c, scene: scene, canvas: canvas,
                                 frames: frames, iterations: iterations)
                guard !ms.isEmpty else { print("  \(label)   sin muestras"); continue }
                let p50 = percentile(ms, 0.50), p95 = percentile(ms, 0.95)
                let fpsMax = p50 > 0 ? 1000.0 / p50 : 0
                let veredicto = p95 <= budget30ms * 0.7 ? "holgado"
                              : p95 <= budget30ms ? "AL FILO" : "NO ALCANZA"
                let pad = String(repeating: " ", count: max(0, 22 - label.count))
                print("  \(label)\(pad) "
                      + String(format: "%8.2f  %8.2f  %8.1f", p50, p95, fpsMax)
                      + "   \(veredicto)")
            }
        }
        print("\n" + String(repeating: "─", count: 78))
        print("Nota: arriba mide SOLO compose() con el buffer libre al instante.")

        // ── LOS MODOS DE CONTEXTO, medidos en vez de elegidos por gusto ──
        // CoreImage por default convierte cada entrada a un espacio de trabajo
        // lineal y vuelve a convertir a la salida. Aquí el compositor solo PEGA
        // imágenes: ese peaje no compra NADA. Esto lo cuantifica.
        print("\nMODOS DE CONTEXTO (escena Burbuja derecha, lienzo 2560×1440)")
        print("  modo                       p50 ms    p95 ms    vs clásico")
        let canvas1440 = CGSize(width: 2560, height: 1440)
        var base = 0.0
        for modo in Compositor.Modo.allCases {
            let c = Compositor(modo: modo)
            let ms = measure(compositor: c, scene: burbuja, canvas: canvas1440,
                             frames: frames, iterations: iterations)
            guard !ms.isEmpty else { continue }
            let p50 = percentile(ms, 0.50), p95 = percentile(ms, 0.95)
            if modo == .clasico { base = p50 }
            let rel = base > 0 ? String(format: "%.2fx", base / p50) : "—"
            let pad = String(repeating: " ", count: max(0, 24 - modo.rawValue.count))
            print("  \(modo.rawValue)\(pad) "
                  + String(format: "%8.2f  %8.2f    %@", p50, p95, rel))
        }

        // FASE 2 — el pipeline COMPLETO, que es lo que de verdad predice una
        // grabación: timer real a 30 Hz + compose + writer HEVC de verdad +
        // buffers RETENIDOS como los retienen el encoder, el preview y el
        // espejo. La fase 1 mentía por omisión: medía el compositor con el pool
        // siempre fresco, y el pool es justo lo que se agota en vivo.
        runPipeline(scene: burbuja, frames: frames, canvases: canvases, seconds: 6)
    }

    // MARK: - SOAK: resistencia con la escena REAL, sin permisos

    /// `--soak <minutos>` — el pipeline completo con la escena compuesta
    /// (pantalla 4K + burbuja de cámara), corriendo N minutos y reportando cada
    /// minuto. Existe porque las dos pruebas largas que sí se pueden hacer con
    /// la app tienen un hueco cada una: la de 25 min tuvo la escena real pero
    /// el permiso de pantalla se cayó a mitad, y la de 50 min corre con cámara
    /// sola porque ese permiso, tras un rebuild, necesita un gesto humano.
    /// Headless y sintética, esta no depende de TCC y aguanta lo que se le pida.
    static func soak(minutes: Int) {
        let screenSrc = CGSize(width: 4096, height: 2304)
        let camSrc = CGSize(width: 1920, height: 1080)
        guard let screenPB = synthBuffer(screenSrc, seed: 7),
              let camPB = synthBuffer(camSrc, seed: 8) else { print("SOAK_FAIL buffers"); return }
        let frames = LatestFrameStore()
        frames.set(screenPB, for: .screen)
        frames.set(camPB, for: .camera)
        let escena = StudioScene(name: "Burbuja derecha", items: [
            SceneItem(kind: .screen),
            {
                var it = SceneItem(kind: .camera,
                                   rect: CGRect(x: 0.8369, y: 0.0298, width: 0.1641, height: 0.2917),
                                   fit: .fill, circleMask: true)
                it.glow = .morado
                return it
            }(),
        ])
        let canvas = CGSize(width: 2560, height: 1440)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sfcast-soak.mp4")
        try? FileManager.default.removeItem(at: url)
        let sink = ProgramSink(url: url, width: 2560, height: 1440, fps: 30, quality: .media)
        guard sink.prepare() else { print("SOAK_FAIL writer"); return }

        let comp = Compositor()
        let cad = CadenceKeeper()
        let clock = ProgramClock()
        clock.begin()
        let q = DispatchQueue(label: "sfcast.soak", qos: .userInteractive)
        let timer = DispatchSource.makeTimerSource(queue: q)
        timer.schedule(deadline: .now(), repeating: .init(1.0 / 30.0), leeway: .milliseconds(3))
        let contador = Contador()
        timer.setEventHandler {
            var st: Set<StudioSourceKind> = []
            var sl: Set<StudioSourceKind> = []
            let hostNow = CMClockGetTime(CMClockGetHostTimeClock())
            guard let listo = comp.composePipelined(scene: escena, canvas: canvas,
                                                    t: CACurrentMediaTime(), hostNow: hostNow,
                                                    frames: frames, starved: &st, stale: &sl)
            else { return }
            for ts in cad.timestamps(for: listo.hostTime, fps: 30) {
                sink.appendVideo(listo.buffer, hostTime: clock.stamp(hostNow: ts, target: nil))
                contador.tick()
            }
        }
        print("SOAK — \(minutes) min · escena Burbuja derecha (pantalla 4K + cámara) · lienzo 2560×1440")
        print("  min   fps    compose p50/p95   sin-buffer  repetidos   RAM")
        let t0 = CACurrentMediaTime()
        let base = footprint()
        timer.resume()
        for m in 1...minutes {
            Thread.sleep(forTimeInterval: 60)
            let el = CACurrentMediaTime() - t0
            let s = comp.stats()
            let sub = comp.subFases()
            print(String(format: "  %3d  %5.2f   %6.2f / %6.2f ms   %8d   %8d   %5.0f MB",
                         m, Double(contador.total) / el, s.composeMsP50, sub.render,
                         s.bufferFailures, cad.repeatedFrames,
                         Double(footprint() - base) / 1_000_000))
            fflush(stdout)   // sin esto, redirigido a archivo no se ve nada hasta el final
        }
        timer.cancel()
        let el = CACurrentMediaTime() - t0
        let sem = DispatchSemaphore(value: 0)
        var stats = ProgramSink.Stats()
        Task.detached { stats = await sink.finish(); sem.signal() }
        sem.wait()
        comp.drainPipeline()
        let fps = Double(stats.videoFrames) / el
        let pct = stats.videoFrames > 0
            ? Double(cad.repeatedFrames) / Double(stats.videoFrames) * 100 : 0
        let peor = stats.worstWindow(20)
        print(String(format: "\nSOAK RESULTADO: %.2f fps · %d frames · %.1f%% repetidos · %d drops · %d sin-buffer",
                     fps, stats.videoFrames, pct, stats.droppedFrames, comp.stats().bufferFailures))
        if let peor {
            print(String(format: "  peor ventana de 20s: %.2f fps (minuto %d:%02d)",
                         peor.fps, peor.startSec / 60, peor.startSec % 60))
        }
        let ok = fps >= 29.0 && pct < 15 && stats.droppedFrames == 0
                 && (peor?.fps ?? 30) >= 27.0
        print(ok ? "SOAK_OK" : "SOAK_FAIL")
        try? FileManager.default.removeItem(at: url)
    }

    private final class Contador: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        func tick() { lock.lock(); n += 1; lock.unlock() }
        var total: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    // MARK: - FASE 2: pipeline completo (timer + compose + encoder + retención)

    private static func runPipeline(scene: StudioScene, frames: LatestFrameStore,
                                    canvases: [(String, CGSize)], seconds: Int) {
        print("\nPIPELINE COMPLETO — timer 30 Hz + compose + writer HEVC + retención")
        print("  lienzo                  fps   compose50  composeMAX  falloBuf  drops    RAM")
        for (label, canvas) in canvases {
            let baseMem = footprint()
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("compbench-\(Int(canvas.width)).mp4")
            try? FileManager.default.removeItem(at: url)
            let sink = ProgramSink(url: url, width: Int(canvas.width), height: Int(canvas.height),
                                   fps: 30, quality: .media)
            guard sink.prepare() else { print("  \(label)  writer no arrancó"); continue }

            let comp = Compositor()
            let box = BenchBox()
            let q = DispatchQueue(label: "compbench.render", qos: .userInitiated)
            let timer = DispatchSource.makeTimerSource(queue: q)
            timer.schedule(deadline: .now(), repeating: .init(1.0 / 30.0), leeway: .milliseconds(3))
            timer.setEventHandler {
                var starved: Set<StudioSourceKind> = []
                var stale: Set<StudioSourceKind> = []
                let t0 = CACurrentMediaTime()
                let pb = comp.compose(scene: scene, canvas: canvas, t: t0,
                                      frames: frames, starved: &starved, stale: &stale)
                let t1 = CACurrentMediaTime()
                guard let pb else { box.noBuffer(); return }
                box.composed((t1 - t0) * 1000)
                sink.appendVideo(pb, hostTime: CMClockGetTime(CMClockGetHostTimeClock()))
                // RETENCIÓN: en vivo el encoder, el PreviewGate y el espejo
                // sostienen buffers de este mismo pool. Sin simularlo, el pool
                // recicla uno solo y el bench sale bonito y falso.
                box.hold(pb, max: 4)
            }
            let t0 = CACurrentMediaTime()
            timer.resume()
            Thread.sleep(forTimeInterval: Double(seconds))
            timer.cancel()
            let elapsed = CACurrentMediaTime() - t0
            let sem = DispatchSemaphore(value: 0)
            var stats = ProgramSink.Stats()
            Task.detached { stats = await sink.finish(); sem.signal() }
            sem.wait()
            box.release()
            try? FileManager.default.removeItem(at: url)

            let s = box.snapshot()
            let cs = comp.stats()
            let fps = Double(stats.videoFrames) / elapsed
            let pad = String(repeating: " ", count: max(0, 22 - label.count))
            print("  \(label)\(pad) "
                  + String(format: "%6.1f  %7.2fms  %7.2fms  %8d  %5d  %5.0f MB",
                           fps, cs.composeMsP50, cs.composeMsMax,
                           cs.bufferFailures + s.bufferFails, stats.droppedFrames,
                           Double(footprint() - baseMem) / 1_000_000))
        }
        print("\n  fps < 30 aquí = el archivo saldría a esos fps.")
    }

    /// Caja de estadísticas + retención de buffers, thread-safe.
    private final class BenchBox: @unchecked Sendable {
        private let lock = NSLock()
        private var compose: [Double] = []
        private var makeBuf: [Double] = []
        private var fails = 0
        private var held: [CVPixelBuffer] = []
        func composed(_ ms: Double) { lock.lock(); compose.append(ms); lock.unlock() }
        func madeBuffer(_ ms: Double) { lock.lock(); makeBuf.append(ms); lock.unlock() }
        func noBuffer() { lock.lock(); fails += 1; lock.unlock() }
        func hold(_ pb: CVPixelBuffer, max n: Int) {
            lock.lock(); held.append(pb); if held.count > n { held.removeFirst() }; lock.unlock()
        }
        func release() { lock.lock(); held.removeAll(); lock.unlock() }
        func snapshot() -> (composeP50: Double, makeBufP50: Double, bufferFails: Int) {
            lock.lock(); defer { lock.unlock() }
            return (percentile(compose, 0.5), percentile(makeBuf, 0.5), fails)
        }
    }

    // MARK: - motor de medición

    private static func measure(compositor: Compositor, scene: StudioScene, canvas: CGSize,
                                frames: LatestFrameStore, iterations: Int) -> [Double] {
        var starved: Set<StudioSourceKind> = []
        var stale: Set<StudioSourceKind> = []
        // Calentamiento: la primera composición paga la compilación de los
        // kernels de CoreImage y la creación del pool. Medirla sería medir el
        // arranque, no el régimen.
        for _ in 0..<12 {
            _ = compositor.compose(scene: scene, canvas: canvas, t: 0,
                                   frames: frames, starved: &starved, stale: &stale)
        }
        var out: [Double] = []
        out.reserveCapacity(iterations)
        for i in 0..<iterations {
            let t0 = CACurrentMediaTime()
            let pb = compositor.compose(scene: scene, canvas: canvas, t: Double(i) / 30.0,
                                        frames: frames, starved: &starved, stale: &stale)
            let dt = (CACurrentMediaTime() - t0) * 1000
            if pb != nil { out.append(dt) }
        }
        return out
    }

    /// Verifica la MATEMÁTICA de `StudioEngine.captureSize` sin necesitar
    /// permiso de pantalla. Existe porque ese cálculo decide cuántos píxeles
    /// pide la captura, y equivocarse ahí deforma la imagen o despega el espejo
    /// del programa — pero probarlo E2E exige TCC de pantalla, que tras cada
    /// rebuild está muerto. La aritmética sí se puede probar siempre.
    private static func checkCaptureSize() {
        let casos: [(String, CGSize, CGSize, CGSize)] = [
            ("4K nativo → lienzo 1440p",
             CGSize(width: 4096, height: 2304), CGSize(width: 2560, height: 1440),
             CGSize(width: 2560, height: 1440)),
            ("4K nativo → lienzo 1080p",
             CGSize(width: 4096, height: 2304), CGSize(width: 1920, height: 1080),
             CGSize(width: 1920, height: 1080)),
            ("UHD → lienzo 1440p",
             CGSize(width: 3840, height: 2160), CGSize(width: 2560, height: 1440),
             CGSize(width: 2560, height: 1440)),
            // NUNCA hacia arriba: inventar píxeles cuesta y no añade detalle.
            ("pantalla chica → lienzo grande (no upscale)",
             CGSize(width: 1440, height: 900), CGSize(width: 2560, height: 1440),
             CGSize(width: 1440, height: 900)),
            // 16:10 contra 16:9: manda el lado que primero topa, sin deformar.
            ("16:10 → lienzo 16:9 (preserva aspecto)",
             CGSize(width: 2560, height: 1600), CGSize(width: 1920, height: 1080),
             CGSize(width: 1728, height: 1080)),
        ]
        var fallos = 0
        for (nombre, nativo, lienzo, esperado) in casos {
            let got = StudioEngine.captureSize(native: nativo, canvas: lienzo)
            let ok = abs(got.width - esperado.width) < 1 && abs(got.height - esperado.height) < 1
            let par = got.width.truncatingRemainder(dividingBy: 2) == 0
                   && got.height.truncatingRemainder(dividingBy: 2) == 0
            if !ok || !par {
                fallos += 1
                print("  ✗ \(nombre): dio \(Int(got.width))×\(Int(got.height)), "
                      + "esperaba \(Int(esperado.width))×\(Int(esperado.height))\(par ? "" : " [IMPAR]")")
            }
        }
        print(fallos == 0
              ? "CAPTURESIZE ✓ \(casos.count)/\(casos.count) (aspecto preservado, sin upscale, pares)"
              : "CAPTURESIZE ✗ \(fallos) de \(casos.count) fallaron")
        print("")
    }

    /// Huella de memoria REAL del proceso (lo que macOS cobra y lo que dispara
    /// la compresión/swap). Con 16 GB y dos monitores 4K, este número es el que
    /// decide si el sistema entero se pone lento — no el uso de CPU.
    static func footprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size
                                           / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }

    private static func percentile(_ xs: [Double], _ p: Double) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        let idx = min(s.count - 1, max(0, Int((Double(s.count - 1) * p).rounded())))
        return s[idx]
    }

    /// Un buffer BGRA con contenido NO trivial. Un buffer en negro se comprime y
    /// se escala distinto que una pantalla con texto: medir sobre negro daría un
    /// número bonito y falso.
    private static func synthBuffer(_ size: CGSize, seed: UInt64) -> CVPixelBuffer? {
        let w = Int(size.width), h = Int(size.height)
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        guard CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA,
                                  attrs as CFDictionary, &pb) == kCVReturnSuccess,
              let buf = pb else { return nil }
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        guard let base = CVPixelBufferGetBaseAddress(buf) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(buf)
        var rng = seed &* 6364136223846793005 &+ 1442695040888963407
        let px = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h {
            let row = px + y * rowBytes
            var x = 0
            while x < w * 4 {
                rng = rng &* 6364136223846793005 &+ 1442695040888963407
                let n = UInt8(truncatingIfNeeded: rng >> 33)
                row[x] = n                                            // B
                row[x + 1] = UInt8(truncatingIfNeeded: x / 4 &+ y)    // G (gradiente)
                row[x + 2] = n / 2 &+ 40                              // R
                row[x + 3] = 255
                x += 4
            }
        }
        return buf
    }
}
