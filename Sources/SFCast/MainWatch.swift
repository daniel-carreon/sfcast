import Foundation
import QuartzCore

/// EL LATIDO DE MAIN — el sensor que faltó la noche del 26 ago 2026.
///
/// Esa noche el preview marcó 0 fps y la ventana dejó de responder. El log no
/// escribió **una sola línea** entre `motor arriba 19:18:17` y `motor abajo
/// 19:21:46`: tres minutos y medio de silencio absoluto. No fue que el sensor
/// fallara — es que **todos los sensores del Estudio viven en `Timer` de
/// RunLoop, y un `Timer` de RunLoop deja de dispararse exactamente cuando main
/// se bloquea**. El chip de fps se quedó clavado en su último valor, el vúmetro
/// se congeló, el watchdog de 1 Hz dejó de mirar. El instrumento se apagaba
/// junto con el paciente, y por eso el incidente no dejó rastro.
///
/// Es la quinta vez que este proyecto tropieza con la misma forma: *el sensor
/// existía y no alcanzó al humano*. Aquí ni siquiera existía.
///
/// Por eso este vigía **no vive en main**. Main solo estampa la hora —una
/// escritura con lock, 15 veces por segundo, nada en el camino de los frames—
/// y una cola aparte la mira desde afuera. Cuando main deja de estampar, el
/// vigía sigue vivo: escribe al log, avisa al sistema y **dispara `sample`
/// contra sí mismo**, que es lo que convierte "se trabó" en "se trabó AQUÍ".
///
/// Invariante: nada de lo que hace este archivo puede correr en main. Si algún
/// día alguien mete un `DispatchQueue.main.sync` aquí dentro, el vigía se
/// bloquea con el paciente y volvemos a agosto.
final class MainWatch: @unchecked Sendable {
    static let shared = MainWatch()

    /// Cuánto silencio de main declara un bloqueo. 3 s es holgado a propósito:
    /// un pase de layout de SwiftUI en esta app cuesta 60-70 ms y un hipo de
    /// medio segundo no es noticia. Lo que buscamos son los tres minutos.
    private let stallThreshold = 3.0
    /// Techo de volcados por corrida. Un vigía que llena el disco de `sample`s
    /// durante una toma sería peor que el bug que vigila.
    private let maxSamples = 3

    private let lock = NSLock()
    private var lastBeat = CACurrentMediaTime()
    private var armed = false
    private var stallStart: Double?
    private var samplesTaken = 0
    private var _worstStallMs: Double = 0
    private var _stallCount = 0
    /// Se leen desde MAIN (el latido en reposo) y se escriben desde la cola del
    /// vigía: pasan por el lock como todo lo demás. Sin esto era una carrera de
    /// libro — benigna en la práctica, pero un vigía con una carrera dentro es
    /// mal ejemplo para lo único que vigila.
    var worstStallMs: Double { lock.lock(); defer { lock.unlock() }; return _worstStallMs }
    var stallCount: Int { lock.lock(); defer { lock.unlock() }; return _stallCount }

    private let queue = DispatchQueue(label: "so.saasfactory.sfcast.mainwatch", qos: .utility)
    private var timer: DispatchSourceTimer?

    /// Main sigue vivo. Se llama desde el tick del `meterTimer` (15 Hz).
    func beat() {
        lock.lock()
        lastBeat = CACurrentMediaTime()
        lock.unlock()
    }

    /// Empieza a vigilar. `reason` sale en el log para saber qué lo armó.
    func start(reason: String) {
        queue.async { [self] in
            guard timer == nil else { return }
            lock.lock(); lastBeat = CACurrentMediaTime(); armed = true; lock.unlock()
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 1.0, repeating: .milliseconds(500), leeway: .milliseconds(100))
            t.setEventHandler { [weak self] in self?.check() }
            t.resume()
            timer = t
            Log.info("Estudio: vigía de main ARRIBA (\(reason)) — umbral \(String(format: "%.1f", stallThreshold))s")
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            lock.lock(); armed = false; let stalled = stallStart != nil; stallStart = nil; lock.unlock()
            if stalled { Log.error("Estudio: el vigía se apagó CON MAIN BLOQUEADO — la app se cerró colgada") }
            if _stallCount > 0 {
                Log.error(String(format: "Estudio: vigía abajo — %d bloqueo(s) de main, el peor de %.0f ms",
                                 _stallCount, _worstStallMs))
            } else {
                Log.info("Estudio: vigía de main abajo — 0 bloqueos")
            }
        }
    }

    // MARK: - el ojo, desde afuera

    private func check() {
        let now = CACurrentMediaTime()
        lock.lock()
        let armedNow = armed
        let silence = now - lastBeat
        let inStall = stallStart != nil
        lock.unlock()
        guard armedNow else { return }

        if silence >= stallThreshold && !inStall {
            lock.lock(); stallStart = now - silence; _stallCount += 1; lock.unlock()
            Log.error(String(format: "Estudio: MAIN BLOQUEADO — %.1fs sin latido. "
                             + "El preview y el chip de fps están CONGELADOS (no es que la app vaya lenta: no responde).",
                             silence))
            // EL MENSAJE IMPORTA MÁS QUE LA DETECCIÓN. Con main bloqueado el
            // render loop SIGUE escribiendo (vive en `renderQueue`, ajeno al
            // RunLoop): la toma se está salvando aunque la ventana parezca
            // muerta. Forzar el cierre ahí es lo único que la pierde de verdad,
            // porque el MP4 se queda sin finalizar. Así que el aviso no dice
            // "se trabó" a secas: dice qué NO hacer.
            notify("SFCast se trabó — NO la fuerces a cerrar",
                   "Sigue grabando por dentro. Espera; si la matas ahora, el video queda sin cerrar.")
            dumpStack(silence: silence)
            return
        }

        if silence < stallThreshold, inStall {
            lock.lock()
            let began = stallStart ?? now
            stallStart = nil
            let ms = (now - silence - began) * 1000
            if ms > _worstStallMs { _worstStallMs = ms }
            lock.unlock()
            Log.error(String(format: "Estudio: main VOLVIÓ tras %.0f ms bloqueado (bloqueo #%d de esta sesión)",
                             ms, stallCount))
            return
        }

        // Bloqueo largo en curso: una línea por cada 15 s para que el log
        // muestre la DURACIÓN mientras pasa, no solo al final.
        if inStall, Int(silence) % 15 == 0 {
            Log.error(String(format: "Estudio: main sigue bloqueado — %.0fs", silence))
        }
    }

    /// El volcado que convierte "se trabó" en "se trabó AQUÍ". `sample` sobre
    /// el propio proceso: no pide permisos y no toca main (corre fuera, en otro
    /// binario). Se escribe al lado del log, con la hora en el nombre.
    private func dumpStack(silence: Double) {
        lock.lock(); let n = samplesTaken; if n < maxSamples { samplesTaken += 1 }; lock.unlock()
        guard n < maxSamples else {
            Log.error("Estudio: no vuelco la pila (ya van \(maxSamples) en esta corrida)")
            return
        }
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let out = NSString(string: "~/Library/Logs/sfcast-cuelgue-\(f.string(from: Date())).txt")
            .expandingTildeInPath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        p.arguments = [String(ProcessInfo.processInfo.processIdentifier), "3", "-file", out]
        do {
            try p.run()
            Log.error("Estudio: volcando la pila del cuelgue → \(out)")
        } catch {
            Log.error("Estudio: no pude correr `sample` (\(error.localizedDescription)) — sin pila del cuelgue")
        }
    }
}


/// Palancas de QA que REVIVEN bugs ya arreglados. Existen porque en este repo
/// "un mecanismo de recuperación que nunca se disparó no es un fix, es una
/// intención" (regla del 25 jul, de donde salió `--killstream`). Sin poder
/// romperlo a voluntad, un arreglo no se puede volver a probar nunca.
enum QAFlags {
    /// `--bug26ago` — revive las TRES condiciones del hueco de cabeza del
    /// 26 ago 2026: el guardián de cadencia que no se reinicia entre tomas, su
    /// red de seguridad contra huecos absurdos, y el arranque de sesión que se
    /// ancla en un timestamp viejo cuando el audio no llega a tiempo.
    static let revivirHuecoDeCabeza = CommandLine.arguments.contains("--bug26ago")
        || CommandLine.arguments.contains("--sincadencereset")
}
