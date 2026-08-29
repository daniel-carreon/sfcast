import Foundation
import AVFoundation
import Accelerate

/// ALINEAR LAS CAPAS POR SU PROPIO SONIDO (28 ago 2026).
///
/// El offset entre `camera.mov` y el programa NO se puede sacar del reloj: se
/// intentaron los cuatro caminos que ofrece AVFoundation y los cuatro fallan,
/// medidos contra una correlación de audio externa en grabaciones reales:
///
/// | camino | error |
/// |---|---|
/// | instante de la LLAMADA a `startRecording` | **52 frames** (la apertura del archivo es asíncrona) |
/// | `didStartRecordingTo` | **6 frames tarde** (el writer ya venía guardando cuando avisa) |
/// | `stopHost − recordedDuration` | **48 frames** (`recordedDuration` cuenta desde la llamada) |
/// | `stopHost − duraciónRealDelArchivo` | **3 frames** (la cola del stop tiene su propia latencia) |
///
/// Pero hay una vara que no depende de nuestro código ni de la API: **el mismo
/// micrófono se escribe en los dos archivos**. Dos grabaciones del mismo sonido
/// se alinean por su envolvente con precisión de milisegundos, y eso es física,
/// no una promesa de framework.
///
/// Por eso el manifest declara ESTE número. Y por eso sigue existiendo el
/// contra-chequeo contra el reloj: si los dos caminos se separan mucho, algo
/// pasó (una pista sin voz, un archivo truncado) y quien componga tiene que
/// enterarse ANTES de alinear mal un video entero.
enum AlineadorDeAudio {

    /// Frecuencia de la envolvente. 200 Hz = 5 ms por celda; con la
    /// interpolación del pico (abajo) la resolución efectiva baja de 1 ms, muy
    /// por debajo del frame (33 ms). A 100 Hz sin interpolar el error medido
    /// contra la vara externa era de 1.4 frames: cuantización pura.
    private static let hz: Double = 200

    /// Cuánto se permite que se separen las pistas. La cabeza que AVFoundation
    /// descarta ronda 1.6 s; 8 s deja margen de sobra sin invitar a un máximo
    /// espurio al otro lado del archivo.
    private static let ventanaSegundos: Double = 8

    /// Segundos que hay que SUMARLE al tiempo de `pista` para llegar al tiempo
    /// de `base`. `nil` = no se pudo medir (sin audio, sin voz, archivos mudos).
    static func offset(base: URL, pista: URL) async -> Double? {
        guard let a = await envolvente(base), let b = await envolvente(pista) else { return nil }
        guard let lag = correlacionar(base: a.env, pista: b.env) else { return nil }
        Log.info(String(format: "Alineador: lag=%.4f  t0base=%.4f  t0pista=%.4f  (celdas %d/%d)",
                        lag, a.t0, b.t0, a.env.count, b.env.count))
        // El desplazamiento de cada pista DENTRO de su contenedor entra aquí,
        // en segundos exactos. Antes se metía rellenando la envolvente con
        // ceros, y ese relleno se redondeaba a celdas enteras: 46 ms de sesgo
        // (1.4 frames) que solo se vieron al correr el MISMO algoritmo en otro
        // lenguaje y comparar. Rejilla fuera; aritmética dentro.
        return lag + a.t0 - b.t0
    }

    /// Envolvente de energía a 100 Hz, en TIEMPO DEL ARCHIVO (el PTS de cada
    /// buffer manda: si la pista de audio arranca desplazada dentro del
    /// contenedor, ese desplazamiento tiene que estar en el resultado, no
    /// perderse por leer las muestras en fila).
    private static func envolvente(_ url: URL) async -> (env: [Float], t0: Double)? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        // SIN REMUESTREO, A PROPÓSITO (28 ago 2026). Pedir 8 kHz metía la
        // latencia de grupo del resampler de AVFoundation, y como cada archivo
        // llega por una cadena distinta (el mic es mono, el programa estéreo)
        // las dos latencias NO se cancelaban: 43 ms de sesgo constante, 1.3
        // frames, invisible hasta correr el mismo algoritmo en otro lenguaje.
        // A tasa nativa no hay filtro que atrase nada; la decimación la hacemos
        // nosotros contando muestras, que no tiene fase.
        let rateNativo = (try? await track.load(.formatDescriptions))?
            .compactMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mSampleRate }
            .first ?? 48000
        let ajustes: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
        ]
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: ajustes)
        guard reader.canAdd(out) else { return nil }
        reader.add(out)
        guard reader.startReading() else { return nil }

        let porCelda = max(1, Int(rateNativo / hz))   // muestras por celda de envolvente
        var env: [Float] = []
        env.reserveCapacity(8192)
        var acumulado: [Float] = []
        acumulado.reserveCapacity(porCelda * 2)
        var t0: Double?

        while let sb = out.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sb)
            if t0 == nil, pts.isValid, pts.isNumeric {
                // Dónde empieza esta pista dentro de su contenedor. Se DEVUELVE
                // en segundos y se aplica como aritmética al final; meterlo aquí
                // como relleno lo condenaba a la rejilla de la envolvente.
                t0 = max(0, CMTimeGetSeconds(pts))
            }
            guard let bl = CMSampleBufferGetDataBuffer(sb) else { continue }
            var largo = 0
            var ptr: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(bl, atOffset: 0, lengthAtOffsetOut: nil,
                                              totalLengthOut: &largo, dataPointerOut: &ptr) == noErr,
                  let p = ptr, largo >= 4 else { continue }
            p.withMemoryRebound(to: Float.self, capacity: largo / 4) { fp in
                acumulado.append(contentsOf: UnsafeBufferPointer(start: fp, count: largo / 4))
            }
            while acumulado.count >= porCelda {
                var rms: Float = 0
                acumulado.withUnsafeBufferPointer { bp in
                    vDSP_rmsqv(bp.baseAddress!, 1, &rms, vDSP_Length(porCelda))
                }
                env.append(rms)
                acumulado.removeFirst(porCelda)
            }
        }
        reader.cancelReading()
        // Una pista muda no alinea nada, y devolver "0.000 s" sobre silencio
        // sería inventarse un dato. Un cero en un sensor significa "no se midió".
        guard env.count > Int(hz), env.max() ?? 0 > 1e-5 else { return nil }
        return (env, t0 ?? 0)
    }

    /// Correlación cruzada de las dos envolventes, centrada y acotada.
    private static func correlacionar(base: [Float], pista: [Float]) -> Double? {
        let n = min(base.count, pista.count)
        guard n > Int(hz * 2) else { return nil }
        var x = Array(pista[0..<n]), y = Array(base[0..<n])
        var mx: Float = 0, my: Float = 0
        vDSP_meanv(x, 1, &mx, vDSP_Length(n)); vDSP_meanv(y, 1, &my, vDSP_Length(n))
        mx = -mx; my = -my
        vDSP_vsadd(x, 1, &mx, &x, 1, vDSP_Length(n))
        vDSP_vsadd(y, 1, &my, &y, 1, vDSP_Length(n))

        let maxLag = Int(ventanaSegundos * hz)
        var mejor = -Float.greatestFiniteMagnitude
        var mejorLag = 0
        var vecinos: [Int: Float] = [:]
        for lag in -maxLag...maxLag {
            let iniX = max(0, -lag), iniY = max(0, lag)
            let largo = n - abs(lag)
            guard largo > Int(hz) else { continue }
            var s: Float = 0
            x.withUnsafeBufferPointer { xb in
                y.withUnsafeBufferPointer { yb in
                    vDSP_dotpr(xb.baseAddress! + iniX, 1, yb.baseAddress! + iniY, 1,
                               &s, vDSP_Length(largo))
                }
            }
            // Normalizado por el solape: si no, los lags chicos ganan siempre
            // por tener más términos que sumar.
            let sn = s / Float(largo)
            if sn > mejor { mejor = sn; mejorLag = lag }
            vecinos[lag] = sn
        }
        guard mejor > 0 else { return nil }
        // INTERPOLACIÓN PARABÓLICA DEL PICO. La correlación está muestreada
        // cada 5 ms, pero el máximo real casi nunca cae justo en una muestra:
        // el vértice de la parábola que pasa por el pico y sus dos vecinos lo
        // localiza con precisión de milisegundo. Sin esto, el número heredaba
        // el escalón de la rejilla y se iba un frame largo.
        var ajuste = 0.0
        if let iz = vecinos[mejorLag - 1], let de = vecinos[mejorLag + 1] {
            let denom = Double(iz - 2 * mejor + de)
            if abs(denom) > 1e-12 {
                let d = 0.5 * Double(iz - de) / denom
                if abs(d) <= 1 { ajuste = d }
            }
        }
        return (Double(mejorLag) + ajuste) / hz
    }
}
