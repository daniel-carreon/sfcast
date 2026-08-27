import AppKit
import CoreGraphics
import ScreenCaptureKit

/// El DOCTOR del permiso de pantalla (8 ago 2026).
///
/// POR QUÉ EXISTE: la fila de TCC de «Grabación de pantalla» puede quedar
/// MUERTA-EN-VIDA — Ajustes la muestra concedida pero el sistema ya no la
/// aplica a este binario (fila anclada a una firma anterior, o el re-permiso
/// periódico de macOS que caduca). El síntoma tramposo: CGPreflight puede
/// decir que sí y SCShareableContent regresa CERO displays; la app solo
/// pintaba un banner pidiéndole a Daniel el trabajo («aprueba y reabre»).
///
/// EL CONTRATO (pedido de Daniel, 8 ago): la app se repara SOLA al abrir y
/// Daniel solo APRUEBA el diálogo del sistema. El doctor:
///   1. mide el permiso EFECTIVO (SCShareableContent, el sensor real — jamás
///      solo el preflight, que miente con filas stale),
///   2. si está muerto: resetea SU PROPIA fila (`tccutil reset ScreenCapture`,
///      user-level, sin sudo) y dispara el prompt del sistema — con la fila
///      fresca, CGRequestScreenCaptureAccess SÍ pinta el diálogo; con la fila
///      stale macOS «cree» que ya está concedido y no pregunta jamás,
///   3. sondea hasta que la aprobación aterrice y ofrece REABRIR con un clic
///      (macOS solo aplica el permiso de pantalla a un proceso NUEVO).
///
/// ANTI-RACE: cuando el preflight dice false, primero se pide por el camino
/// normal (puede haber un prompt legítimo pendiente) y solo si en 30s no
/// aterriza nada se resetea — resetear a ciegas podría borrar una aprobación
/// recién dada. Corre UNA vez por lanzamiento (anti-bucle si el diálogo se
/// cancela) y JAMÁS relanza sin un clic explícito de Daniel.
@MainActor
enum ScreenDoctor {
    private static var ran = false

    /// Permiso EFECTIVO: ¿ScreenCaptureKit entrega displays? Este es el
    /// sensor real; el preflight solo lee la fila de TCC y no sabe si el
    /// sistema de verdad la va a honrar para ESTE binario.
    static func screenEffective() async -> Bool {
        let content = try? await Deadline.run(seconds: 12, name: "doctor SCShareableContent") {
            try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }
        return content.map { !$0.displays.isEmpty } ?? false
    }

    /// ¿Está bloqueada la pantalla? Con la sesión bloqueada macOS deniega la
    /// captura SIEMPRE, con un error que se lee igual que un permiso revocado
    /// ("El usuario rechazó la configuración de TCC"). Distinguirlos es la
    /// diferencia entre no hacer nada y borrarle a Daniel una aprobación buena.
    static func sesionBloqueada() -> Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (d["CGSSessionScreenIsLocked"] as? Bool) == true
    }

    /// Chequeo + auto-reparación. Se llama al ARRANQUE (rutas interactivas) y
    /// desde los sitios de fallo del Estudio; el candado `ran` hace gratis a
    /// los llamadores duplicados.
    static func checkAndRepair(razon: String) async {
        guard !ran else { return }
        ran = true
        guard Permissions.canPrompt else {
            Log.info("Doctor pantalla: sin canPrompt (lanzada de terminal) — no reparo")
            return
        }
        // ⛔⛔ LA SESIÓN BLOQUEADA NO ES UN PERMISO ROTO (26 ago 2026, 22:51).
        //
        // Este doctor destruyó esa noche un permiso que estaba PERFECTAMENTE
        // SANO. La Mac llevaba media hora sola, la pantalla se bloqueó, y macOS
        // —que deniega la captura en sesión bloqueada, por diseño— devolvió
        // "El usuario rechazó la configuración de TCC". El doctor leyó eso como
        // fila muerta, corrió `tccutil reset` y borró la aprobación buena.
        //
        // Es el peor fallo posible en este archivo: un reparador que rompe. Y es
        // silencioso, porque de noche no hay nadie mirando — justo cuando la
        // pantalla está bloqueada y la trampa está armada.
        //
        // Con la sesión bloqueada NO se diagnostica y NO se repara. No hay nada
        // que arreglar y no hay nadie a quien preguntarle.
        if sesionBloqueada() {
            Log.info("Doctor pantalla: la sesión está BLOQUEADA (\(razon)) — macOS deniega la captura "
                     + "por diseño, no es un permiso roto. No toco nada.")
            ran = false   // que vuelva a mirar cuando Daniel desbloquee
            return
        }

        // SCShareableContent puede fallar TRANSITORIAMENTE (cero displays en
        // hipos de WindowServer — 7 ago 19:39: cinco reintentos y enganchó).
        // Tres sondas antes de declarar muerto el permiso: resetear la fila
        // por un hipo costaría un prompt innecesario a Daniel.
        // SIN FILA, SIN SONDEO (26 ago 2026). Las tres sondas existen para el caso
        // STALE —Ajustes dice que sí y la captura falla igual— y cuestan 8-12 s.
        // Cuando el preflight dice que NO hay permiso, no hay nada que sondear:
        // se sabe la respuesta y esos doce segundos son Daniel esperando delante
        // de la app a las 05:30. Se va directo a pedirlo.
        if !Permissions.screenGranted {
            Log.info("Doctor pantalla: no hay permiso de pantalla (\(razon)) — lo pido ya, sin sondear")
            CGRequestScreenCaptureAccess()
            if await pollGranted(seconds: 120) { offerRelaunch(); return }
            Log.error("Doctor pantalla: nadie aprobó el permiso en 120 s")
            if !grabandoAhora, !estudioVivo {
                let a = NSAlert()
                a.messageText = "Falta aprobar «Grabación de pantalla»"
                a.informativeText = "Apruébala en Ajustes → Privacidad y seguridad → Grabación de pantalla."
                a.addButton(withTitle: "Abrir Ajustes")
                a.addButton(withTitle: "Luego")
                NSApp.activate(ignoringOtherApps: true)
                if a.runModal() == .alertFirstButtonReturn { Permissions.openPrivacyPane("ScreenCapture") }
            } else if !grabandoAhora {
                avisarSinBloquear("Falta aprobar «Grabación de pantalla»",
                                  "Ajustes → Privacidad y seguridad → Grabación de pantalla, y reabre SFCast.")
            }
            return
        }

        for sonda in 1...3 {
            if await screenEffective() {
                Log.info("Doctor pantalla: permiso efectivo OK (\(razon), sonda \(sonda))")
                return
            }
            if sonda < 3 { try? await Task.sleep(nanoseconds: 4_000_000_000) }
        }
        // Segunda red: la sesión pudo bloquearse DURANTE las tres sondas (son 8-12
        // segundos). Se vuelve a preguntar justo antes de tocar nada irreversible.
        if sesionBloqueada() {
            Log.info("Doctor pantalla: se bloqueó la sesión mientras sondeaba — no reparo")
            ran = false
            return
        }
        let preflight = Permissions.screenGranted
        Log.error("Doctor pantalla: permiso de pantalla MUERTO (\(razon), preflight=\(preflight)) — reparando")
        if preflight {
            // Fila STALE (Ajustes dice sí, el sistema no la aplica a este
            // binario): sin reset NUNCA habrá prompt. Resetear y re-pedir.
            resetOwnTCCRow()
        }
        CGRequestScreenCaptureAccess()
        if await pollGranted(seconds: 30) { offerRelaunch(); return }
        if !preflight {
            // 30s sin aterrizar por el camino normal: la fila está atorada
            // (negada vieja o anclada a otra firma). Chequeo final anti-race
            // antes de borrar — una aprobación fresca no se toca.
            if Permissions.screenGranted { offerRelaunch(); return }
            resetOwnTCCRow()
            CGRequestScreenCaptureAccess()
        }
        if await pollGranted(seconds: 150) { offerRelaunch(); return }

        // Sin aprobación en la ventana: guía explícita, cero bucles.
        // Mismo candado que arriba — un modal jamás cae sobre una toma viva.
        guard !grabandoAhora else {
            Log.error("Doctor pantalla: sin permiso, pero HAY GRABACIÓN VIVA — "
                      + "no interrumpo la toma; se lo digo al terminar")
            return
        }
        guard !estudioVivo else {
            avisarSinBloquear("Falta aprobar «Grabación de pantalla»",
                              "Ajustes → Privacidad y seguridad → Grabación de pantalla, y reabre SFCast.")
            return
        }
        let a = NSAlert()
        a.messageText = "Falta aprobar «Grabación de pantalla»"
        a.informativeText = "Apruébala en Ajustes → Privacidad y seguridad → Grabación de pantalla, y reabre SFCast."
        a.addButton(withTitle: "Abrir Ajustes")
        a.addButton(withTitle: "Luego")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn {
            Permissions.openPrivacyPane("ScreenCapture")
        }
    }

    /// Sondea el preflight hasta que la aprobación aterrice (el diálogo del
    /// sistema o el toggle de Ajustes lo voltean para el proceso VIVO, aunque
    /// la captura real siga necesitando relanzar).
    private static func pollGranted(seconds: Int) async -> Bool {
        for _ in 0..<(seconds / 2) {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if Permissions.screenGranted { return true }
        }
        return Permissions.screenGranted
    }

    /// `tccutil reset ScreenCapture so.saasfactory.sfcast` — borra SOLO la
    /// fila propia, en el dominio del usuario, sin sudo. tccutil es rápido
    /// (<100 ms); el waitUntilExit en main es aceptable.
    private static func resetOwnTCCRow() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        p.arguments = ["reset", "ScreenCapture", Bundle.main.bundleIdentifier ?? "so.saasfactory.sfcast"]
        do {
            try p.run()
            // NO SE ESPERA EN MAIN, NI CON TECHO (26 ago 2026, dos vueltas).
            //
            // El comentario de arriba decía "<100 ms, el waitUntilExit en main es
            // aceptable" y es verdad casi siempre; ese "casi" es una app colgada.
            // El primer arreglo fue un `while p.isRunning` con techo de 2 s — que
            // sigue siendo bloquear main hasta dos segundos, justo lo que esta
            // noche se propuso eliminar, y encima por debajo del umbral del vigía,
            // o sea invisible.
            //
            // Nadie usa el código de salida para decidir nada: se lanza y se
            // reporta desde fuera. Main no espera a nadie.
            Task.detached {
                p.waitUntilExit()
                Log.info("Doctor pantalla: tccutil reset → exit \(p.terminationStatus)")
            }
        } catch {
            Log.error("Doctor pantalla: tccutil no corrió: \(error.localizedDescription)")
        }
    }

    /// ¿Hay una grabación viva ahora mismo? Un `NSAlert` es MODAL: bloquea el
    /// main thread hasta que alguien lo cierre. Si eso pasa mientras Daniel
    /// habla a cámara, el pill y el preview se congelan y el Detener no
    /// responde — el peor momento posible para pedirle una decisión.
    /// (El render loop vive en `renderQueue` y seguiría escribiendo, pero la
    /// app se ve muerta y el humano no sabe si sigue grabando.)
    @MainActor
    private static var grabandoAhora: Bool {
        StudioController.shared.recorder.isRecording
            || RecordingController.shared.state != .idle
    }

    /// ⛔ AMPLIADO EL 26 AGO 2026: tampoco con el Estudio simplemente ABIERTO.
    ///
    /// El guard de arriba solo cubría "hay grabación viva", y el cuelgue que
    /// Daniel reportó esa noche pasó **en el preview, antes de dar REC**: abrió
    /// el Estudio a las 19:18:17 y a las 19:21:46 lo cerró, con el chip de fps
    /// clavado y la ventana sin responder — y el log mudo los tres minutos y
    /// medio de en medio, porque los sensores viven en `Timer` de RunLoop y un
    /// modal los para a todos.
    ///
    /// Y este doctor se dispara **2.5 s después de cada apertura del Estudio**,
    /// siempre. Un modal que puede aparecer detrás de la ventana del Estudio, o
    /// en el monitor que Daniel no está mirando, es una app colgada desde la
    /// silla. Con el Estudio vivo el aviso va por donde no bloquea a nadie: la
    /// barra de la propia ventana y una notificación del sistema.
    @MainActor
    private static var estudioVivo: Bool {
        StudioController.shared.window?.isVisible == true
    }

    /// Aviso que NO bloquea. Misma información, cero modales.
    @MainActor
    private static func avisarSinBloquear(_ titulo: String, _ cuerpo: String) {
        Log.error("Doctor pantalla: \(titulo) — \(cuerpo) (aviso sin modal: el Estudio está vivo)")
        StudioController.shared.raiseAlert("\(titulo). \(cuerpo)", critical: true, sticky: true)
        notify("SFCast — \(titulo)", cuerpo)
    }

    /// macOS solo aplica el permiso de pantalla a un proceso NUEVO. Un clic,
    /// jamás automático: si hubiera una grabación viva, Daniel decide.
    private static func offerRelaunch() {
        // ⛔ Nunca un modal encima de una toma. El permiso ya quedó aprobado:
        // se aplica al siguiente arranque, y eso puede esperar a que termine.
        guard !grabandoAhora else {
            Log.info("Doctor pantalla: permiso aprobado, pero HAY GRABACIÓN VIVA — "
                     + "no interrumpo la toma; aplica al reabrir")
            return
        }
        // CON EL ESTUDIO ABIERTO Y SIN GRABACIÓN: SE REABRE SOLA (26 ago 2026).
        //
        // macOS solo aplica el permiso de pantalla a un proceso NUEVO, así que
        // tras aprobarlo hay que relanzar. Pedírselo a Daniel convertía UN clic
        // ("Permitir") en tres: permitir, cerrar, abrir. Y aquí no hay nada que
        // proteger — el guard de `grabandoAhora` ya se cumplió arriba, así que
        // no hay ninguna toma viva que un relanzamiento pueda costar.
        //
        // Es el único caso donde reabrir solo es claramente lo que él quiere:
        // acaba de aprobar el permiso PARA poder capturar, y la app no puede
        // capturar hasta reabrirse. No hay decisión que tomar.
        guard !estudioVivo else {
            Log.info("Doctor pantalla: permiso aprobado y sin grabación viva — REABRIENDO sola")
            notify("SFCast", "Permiso concedido. Me reabro para aplicarlo.")
            relanzar()
            return
        }
        Log.info("Doctor pantalla: permiso aprobado — ofreciendo reabrir")
        let a = NSAlert()
        a.messageText = "Permiso de pantalla aprobado"
        a.informativeText = "macOS lo aplica al reabrir la app. ¿Reabro SFCast ahora?"
        a.addButton(withTitle: "Reabrir ahora")
        a.addButton(withTitle: "Luego")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn { relanzar() }
    }

    /// Cierra y vuelve a abrir este mismo bundle. macOS solo aplica el permiso
    /// de pantalla a procesos nuevos, así que esto es el último paso obligatorio
    /// de cualquier aprobación.
    private static func relanzar() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 0.6; /usr/bin/open \"\(path)\""]
        try? p.run()
        NSApp.terminate(nil)
    }
}
