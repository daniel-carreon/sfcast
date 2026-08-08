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
        // SCShareableContent puede fallar TRANSITORIAMENTE (cero displays en
        // hipos de WindowServer — 7 ago 19:39: cinco reintentos y enganchó).
        // Tres sondas antes de declarar muerto el permiso: resetear la fila
        // por un hipo costaría un prompt innecesario a Daniel.
        for sonda in 1...3 {
            if await screenEffective() {
                Log.info("Doctor pantalla: permiso efectivo OK (\(razon), sonda \(sonda))")
                return
            }
            if sonda < 3 { try? await Task.sleep(nanoseconds: 4_000_000_000) }
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
            p.waitUntilExit()
            Log.info("Doctor pantalla: tccutil reset → exit \(p.terminationStatus)")
        } catch {
            Log.error("Doctor pantalla: tccutil no corrió: \(error.localizedDescription)")
        }
    }

    /// macOS solo aplica el permiso de pantalla a un proceso NUEVO. Un clic,
    /// jamás automático: si hubiera una grabación viva, Daniel decide.
    private static func offerRelaunch() {
        Log.info("Doctor pantalla: permiso aprobado — ofreciendo reabrir")
        let a = NSAlert()
        a.messageText = "Permiso de pantalla aprobado"
        a.informativeText = "macOS lo aplica al reabrir la app. ¿Reabro SFCast ahora?"
        a.addButton(withTitle: "Reabrir ahora")
        a.addButton(withTitle: "Luego")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn {
            let path = Bundle.main.bundlePath
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "sleep 0.6; /usr/bin/open \"\(path)\""]
            try? p.run()
            NSApp.terminate(nil)
        }
    }
}
