import AppKit
import AVFoundation

/// El BROKER de permisos: una sola puerta para TODAS las peticiones de cámara y
/// micrófono. Nació del incidente del 14-15 jul (Daniel: "no me aparecen los
/// permisos"), donde conspiraban:
///
///  1. **Ráfaga concurrente.** Varias rutas (arranque de la app, botón Grabar,
///     Reparar) disparaban `requestAccess` a la vez. tccd las encola y deja
///     diálogos HUÉRFANOS que ya no responden. → El broker SERIALIZA: jamás hay
///     dos `requestAccess` del mismo tipo vivas; los que llegan tarde se cuelgan
///     del mismo resultado (coalescing).
///
///  2. **Diálogo en la pantalla equivocada.** Con 2 monitores, el diálogo salía
///     en el display secundario. → El broker ACTIVA la app y sube el hub como
///     ventana clave antes de pedir, para sesgar el diálogo a la pantalla activa.
///
/// LO QUE APRENDIMOS Y **NO** HACEMOS (14-15 jul): reiniciar UserNotificationCenter
/// (el proceso que RENDERIZA los diálogos) para "destrabar" un prompt zombie. En
/// una máquina con la cola de tccd ya atascada, matar UNC cerca de la petición la
/// ENVENENA: tccd la resuelve como diálogo descartado = DENEGADO. La cola de tccd
/// solo se limpia reiniciando tccd, y en macOS 26.2 eso está bloqueado por SIP
/// (`killall tccd`, `launchctl kickstart -k`, `bootout` — todos fallan) salvo
/// reiniciar la Mac. Por eso el broker JAMÁS toca UNC: pide con paciencia y, si el
/// sistema está atascado, el hub le dice a Daniel que reinicie una vez. En un tccd
/// sano (arranque normal / tras reinicio) el diálogo pinta solo a la primera.
@MainActor
final class PermissionBroker {
    static let shared = PermissionBroker()

    /// Continuaciones que esperan el resultado de una petición ya en vuelo
    /// (coalescing: N llamadas → 1 solo `requestAccess`).
    private var waiters: [AVMediaType: [CheckedContinuation<Bool, Never>]] = [:]
    private var inFlight: Set<AVMediaType> = []

    // MARK: - API pública

    /// Pide UN tipo de media, serializado. Idempotente:
    /// - si ya está resuelto (autorizado/denegado), regresa sin promptear.
    /// - si hay una petición viva del mismo tipo, se suma a ella.
    @discardableResult
    func request(_ media: AVMediaType, hardTimeout: Double = 45) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: media) {
        case .authorized: return true
        case .denied, .restricted: return false
        case .notDetermined: break
        @unknown default: break
        }
        guard Permissions.canPrompt else { return false }

        // Coalescing: si ya hay una petición viva, espera SU resultado.
        if inFlight.contains(media) {
            return await withCheckedContinuation { cont in
                waiters[media, default: []].append(cont)
            }
        }
        inFlight.insert(media)

        let granted = await promptPatiently(media, hardTimeout: hardTimeout)

        // Resolver a todos los que esperaban el mismo tipo.
        let pending = waiters[media] ?? []
        waiters[media] = nil
        inFlight.remove(media)
        for w in pending { w.resume(returning: granted) }

        let label = (media == .video) ? "cámara" : "micrófono"
        Log.info("Broker: \(label) → \(granted ? "concedido" : "sin permiso")")
        return granted
    }

    /// Rutina que usa el arranque de la app y el botón "Activar permisos":
    /// activa la app, sube el hub como ventana clave en la pantalla activa y pide
    /// cámara y micrófono EN SERIE. Ya NO se reinicia UserNotificationCenter:
    /// probado en vivo el 15 jul, matar UNC cerca de la petición (aunque sea
    /// "antes") ENVENENA el prompt y tccd lo deniega al instante. En un tccd sano
    /// (arranque normal / tras un reinicio del sistema) el diálogo pinta solo.
    func ensureCameraAndMic() async {
        activateForPrompt()
        try? await Task.sleep(nanoseconds: 500_000_000)   // que la ventana sea key y el display quede fijo
        _ = await request(.video)
        _ = await request(.audio)
    }

    /// Reset TCC de la app + re-pide (el botón "Reparar"). El `tccutil` corre
    /// FUERA del hilo principal: habla por XPC con tccd, que es justo lo que
    /// puede estar atascado — bloquear el MainActor con `waitUntilExit()` colgaría
    /// toda la app (el botón que existe para repararla).
    func resetAndReRequest() {
        Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            p.arguments = ["reset", "All", "so.saasfactory.sfcast"]
            do { try p.run(); p.waitUntilExit() } catch { return }
            await self.ensureCameraAndMic()
        }
    }

    // MARK: - motor

    /// Dispara `requestAccess` UNA vez y espera con PACIENCIA (nunca se toca UNC).
    /// El hard-timeout solo evita quedarse colgado para siempre si tccd nunca
    /// responde; el botón "Activar permisos" del hub reintenta.
    private func promptPatiently(_ media: AVMediaType, hardTimeout: Double) async -> Bool {
        let label = (media == .video) ? "CÁMARA" : "MICRÓFONO"
        Log.info("Broker: pidiendo permiso de \(label) (espera paciente \(Int(hardTimeout))s)…")
        let once = OnceFlag()
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            // La petición sale desde el hilo principal: la atribución del prompt
            // al proceso responsable es más confiable así.
            AVCaptureDevice.requestAccess(for: media) { granted in
                if once.claim() { cont.resume(returning: granted) }
            }
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(hardTimeout * 1_000_000_000))
                if once.claim() {
                    Task { @MainActor in
                        Log.error("Broker: \(label) sin respuesta en \(Int(hardTimeout))s — me rindo (usa 'Activar permisos' en el hub o reinicia la Mac)")
                    }
                    cont.resume(returning: false)
                }
            }
        }
    }

    /// Activa la app y sube el hub como ventana clave, para que el diálogo TCC
    /// salga en la pantalla donde Daniel está mirando (no en el monitor de al lado).
    private func activateForPrompt() {
        NSApp.activate(ignoringOtherApps: true)
        HubWindowController.shared.show()
    }
}
