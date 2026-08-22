/// EL OJO DEL ESTUDIO — mide la imagen real y la publica.
///
/// Por qué existe: "sube el ISO" sin sensor es una intención; con sensor es un
/// resultado. El lazo `sfcam auto` (mide la cara → mueve el ISO → vuelve a
/// medir) necesita que ALGUIEN mida, y esa medición vivía solo en SFCam.app.
/// Ahora la hace el Estudio, que ya tiene el frame en la mano.
///
/// CÓMO NO ROMPE LA CAPTURA — las tres reglas que costaron caro:
///
/// 1. **No toca el delegate.** Lee `frames.get(.camera)`, que es el último
///    frame ya entregado. Medir DENTRO del delegate (bloqueando un buffer de
///    1920×1080) tiró la captura de 60 a 17 fps y no se recuperaba.
/// 2. **No retiene el buffer.** Bloquea de solo-lectura, muestrea y suelta en
///    el mismo alcance. El pool es finito: quedarse con un buffer deja de
///    entregar frames sin que ningún contador se entere.
/// 3. **Muestrea a saltos**, no píxel por píxel. Un paso de 8 sobre 1920×1080
///    deja ~32k muestras: microsegundos, y la estadística no cambia.
///
/// Y una regla del sensor, no del rendimiento: **el ojo dice cuándo NO puede
/// juzgar.** Con el cuadro casi negro, la escena aporta zonas oscuras que se
/// confunden con cualquier cosa. Ahí publica `hayImagen:false` y se calla, en
/// vez de opinar — un lazo que corrige sobre una medición mala oscila hasta
/// romperse (pasó: leyó "cara 0.00" y saltó a ISO 6400 quemando el cuadro).

import Foundation
import CoreVideo
import QuartzCore

struct MedicionOjo {
    var hayImagen = false
    var lum: Double = 0          // luz media de todo el cuadro
    var lumCentro: Double = 0    // luz del tercio central: la cara
    var r: Double = 0, g: Double = 0, b: Double = 0
    var clipAlto: Double = 0     // % de píxeles quemados
    var clipBajo: Double = 0     // % de píxeles aplastados en negro

    var rb: Double { b > 0 ? r / b : 0 }

    /// El veredicto que Daniel lee de reojo. Los rangos salieron de calibrar
    /// contra su luz real, no de una tabla.
    var veredicto: String {
        if !hayImagen { return "sin imagen" }
        if clipAlto > 2 { return "quemada" }
        if lumCentro < 45 { return "muy oscura" }
        if lumCentro < 75 { return "oscura" }
        if lumCentro > 130 { return "muy clara" }
        if lumCentro > 110 { return "clara" }
        return "en rango"
    }
}

enum OjoDelEstudio {
    static let archivo: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".sfcam")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ojo.json")
    }()

    /// Lo último medido, para pintarlo en el panel. Sin esto el ojo sería un
    /// órgano invisible: escribiría un archivo que nadie mira y nadie sabría
    /// si dejó de funcionar.
    private(set) static var ultima = MedicionOjo()
    private(set) static var ultimaAt: Date?

    private static var pulso: Timer?

    /// Arranca el latido. Idempotente: llamarlo dos veces no crea dos timers.
    ///
    /// 1 Hz es de sobra — la luz de un estudio no cambia más rápido que eso, y
    /// el lazo del ISO descarta cualquier medición de más de 8 segundos.
    @MainActor
    static func arrancar(_ dame: @escaping () -> CVPixelBuffer?) {
        guard pulso == nil else { return }
        pulso = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            guard let pb = dame() else {
                // Sin frame no se inventa una medición: se dice que no hay.
                publicar(MedicionOjo(), fuente: "estudio")
                return
            }
            publicar(medir(pb), fuente: "estudio")
        }
    }

    @MainActor
    static func detener() { pulso?.invalidate(); pulso = nil }

    // MARK: medir

    /// BGRA (32) es el formato de todo el pipeline del Estudio.
    static func medir(_ pb: CVPixelBuffer, paso: Int = 8) -> MedicionOjo {
        var m = MedicionOjo()
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        guard w > 0, h > 0 else { return m }

        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return m }
        let stride = CVPixelBufferGetBytesPerRow(pb)
        let px = base.assumingMemoryBound(to: UInt8.self)

        // El tercio central: donde está la cara de quien habla a cámara.
        let x0 = w / 3, x1 = w * 2 / 3, y0 = h / 3, y1 = h * 2 / 3

        var sumaL = 0.0, sumaR = 0.0, sumaG = 0.0, sumaB = 0.0, n = 0.0
        var sumaC = 0.0, nC = 0.0
        var alto = 0.0, bajo = 0.0

        var y = 0
        while y < h {
            let fila = px + y * stride
            var x = 0
            while x < w {
                let p = fila + x * 4
                let b = Double(p[0]), g = Double(p[1]), r = Double(p[2])
                // Luma Rec.709: el ojo humano no pesa igual los tres canales.
                let l = 0.2126 * r + 0.7152 * g + 0.0722 * b
                sumaL += l; sumaR += r; sumaG += g; sumaB += b; n += 1
                if l >= 250 { alto += 1 }
                if l <= 4 { bajo += 1 }
                if x >= x0 && x < x1 && y >= y0 && y < y1 { sumaC += l; nC += 1 }
                x += paso
            }
            y += paso
        }
        guard n > 0 else { return m }

        m.lum = sumaL / n
        m.lumCentro = nC > 0 ? sumaC / nC : m.lum
        m.r = sumaR / n; m.g = sumaG / n; m.b = sumaB / n
        m.clipAlto = alto / n * 100
        m.clipBajo = bajo / n * 100
        // Un cuadro completamente negro NO es "una imagen muy oscura": es la
        // señal caída, o la cámara con el live view apagado atendiendo el USB.
        m.hayImagen = m.lum > 1.0
        return m
    }

    // MARK: publicar

    /// El esquema lo consume `sfcam auto` y `sfcam ojo`. No cambiarlo sin
    /// mirar allá: son dos binarios distintos hablando por un archivo.
    static func publicar(_ m: MedicionOjo, fuente: String) {
        let ahora = Date()
        ultima = m
        ultimaAt = ahora
        let d: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: ahora),
            "fuente": fuente,
            "hayImagen": m.hayImagen,
            "lum": round(m.lum * 100) / 100,
            "lumCentro": round(m.lumCentro * 100) / 100,
            "r": round(m.r * 10) / 10, "g": round(m.g * 10) / 10, "b": round(m.b * 10) / 10,
            "rb": round(m.rb * 1000) / 1000,
            "clipAlto": round(m.clipAlto * 100) / 100,
            "clipBajo": round(m.clipBajo * 100) / 100,
            // Con el cuadro en penumbra no se puede juzgar la geometría.
            "juzgable": m.lum > 20,
            "veredicto": m.veredicto,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys]) else { return }
        let tmp = archivo.appendingPathExtension("tmp")
        try? data.write(to: tmp)
        _ = try? FileManager.default.replaceItemAt(archivo, withItemAt: tmp)
    }
}
