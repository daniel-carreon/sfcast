import Foundation
import AVFoundation
import CoreMedia
import QuartzCore

/// QA DE SINCRONÍA (`--synctest N`) — mide la latencia REAL de cada fuente.
///
/// Nació porque el desfase de labios del 9 ago NO se pudo medir desde el
/// archivo: correlacionar audio contra movimiento de boca dio r≈0.1 y lags
/// contradictorios en 14 ventanas. La señal no daba para afirmar nada.
///
/// Esta es la vía determinista: preguntarle a cada fuente CUÁNDO dice que
/// capturó el frame, y compararlo con el reloj del host en el instante en que
/// nos llegó. Esa resta es la deuda que el `ProgramClock` tiene que pagar, y
/// aquí se ve en milisegundos en vez de inferirse.
///
/// También responde la pregunta que hay que hacerse ANTES de corregir nada:
/// ¿los PTS de la cámara, de la pantalla y del audio están en el MISMO dominio
/// de reloj? Si no lo estuvieran, "compensar" haría el daño peor.
@MainActor
enum StudioSyncTest {

    static func run(seconds: Int, engine: StudioEngine) async {
        Log.info("SYNCTEST — latencia real de cada fuente (\(seconds)s)")
        Log.info(String(repeating: "─", count: 74))
        Log.info("Cámara: \(engine.cameraDeviceName ?? "ninguna")")

        // Dejar correr el motor: cada frame que entra deja su muestra en el
        // LatestFrameStore. No hace falta grabar nada.
        let deadline = Date().addingTimeInterval(Double(seconds))
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        let r = engine.syncReport()
        Log.info("")
        Log.info("  fuente     latencia medida    qué significa")
        Log.info("  " + String(repeating: "─", count: 68))
        line("cámara", r.camera)
        line("pantalla", r.screen)

        let audio = AudioMath.lastLatencyMs
        if let a = audio {
            Log.info(String(format: "SYNC  %-10@ %10.1f ms      PTS del mic contra el reloj del host",
                         "mic" as NSString, a))
        } else {
            Log.info("  mic               sin muestras      (¿mic apagado?)")
        }

        Log.info("")
        if let cam = r.camera {
            let ms = cam * 1000
            Log.info(String(format: "  DESFASE QUE SE CORRIGE: %.0f ms", ms))
            Log.info("  Sin la corrección, la cara iba \(Int(ms)) ms detrás de la voz.")
            if let a = audio {
                let neto = ms - a
                Log.info(String(format: "  Neto contra el mic: %.0f ms (lo que se veía en pantalla).", neto))
            }
            if ms > 250 {
                Log.info("  ⚠️  Es mucho para una cámara. Si sube más, revisa el cable/hub USB.")
            }
        } else {
            Log.info("  Sin muestras de cámara válidas: o no hay cámara, o sus PTS")
            Log.info("  vienen en otro dominio de reloj (ahí NO se corrige nada — es")
            Log.info("  preferible no tocar el timestamp que empeorarlo a ciegas).")
        }
        Log.info(String(format: "\n  corrección aplicándose ahora: %.1f ms", r.appliedMs))
        Log.info(String(repeating: "─", count: 74))
    }

    private static func line(_ name: String, _ v: Double?) {
        guard let v else {
            Log.info("  \(name)\(String(repeating: " ", count: max(0, 10 - name.count))) sin muestras")
            return
        }
        let nota = v < 0.030 ? "prácticamente inmediata"
                 : v < 0.120 ? "normal para USB"
                 : "ALTA — es la que desincroniza los labios"
        Log.info(String(format: "  %-10@ %10.1f ms      %@", name as NSString, v * 1000, nota as NSString))
    }
}
