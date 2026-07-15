import AppKit

/// Modo --demo N: graba N segundos moviendo la burbuja por ≥3 posiciones y sus
/// 4 tamaños, con pausa/reanuda a la mitad. Es el driver de la evidencia E2E
/// (sin manos) Y una demo honesta de lo que la app hace en vivo.
@MainActor
enum DemoChoreography {
    static func run(totalSeconds: Int, noUpload: Bool) async {
        let rc = RecordingController.shared
        rc.noUpload = noUpload
        rc.settings.countdownSeconds = 1

        guard let screen = RecordingController.captureScreen() else { exit(2) }
        let vf = screen.visibleFrame
        func origin(_ x: CGFloat, _ y: CGFloat, d: CGFloat) -> NSPoint {
            NSPoint(x: vf.minX + (vf.width - d) * x, y: vf.minY + (vf.height - d) * y)
        }

        print("DEMO: iniciando grabación de \(totalSeconds)s con coreografía de burbuja")
        await rc.startScreen()
        guard rc.state == .recording else {
            print("DEMO_FAIL: no arrancó la grabación")
            exit(2)
        }
        print("DEMO: id=\(rc.videoID) url=\(rc.publicURL)")

        let t = Double(totalSeconds)
        // Presupuesto de tiempo: fracciones del total (pausa fija de 3s aparte).
        let slice = { (f: Double) in UInt64(t * f * 1_000_000_000) }

        // posición inicial: M abajo-derecha (default). Coreografía:
        try? await Task.sleep(nanoseconds: slice(0.10))
        print("DEMO: mover → arriba-izquierda (tamaño M)")
        rc.bubble.move(to: origin(0.02, 0.95, d: CameraBubble.Size.m.diameter))

        try? await Task.sleep(nanoseconds: slice(0.10))
        print("DEMO: tamaño → CHICA (S)")
        rc.bubble.setSize(.s)

        try? await Task.sleep(nanoseconds: slice(0.10))
        print("DEMO: mover → arriba-derecha (S)")
        rc.bubble.move(to: origin(0.98, 0.95, d: CameraBubble.Size.s.diameter))

        try? await Task.sleep(nanoseconds: slice(0.10))
        print("DEMO: tamaño → GRANDE (L)")
        rc.bubble.setSize(.l)

        try? await Task.sleep(nanoseconds: slice(0.10))
        print("DEMO: mover → abajo-izquierda (L)")
        rc.bubble.move(to: origin(0.02, 0.05, d: CameraBubble.Size.l.diameter))

        try? await Task.sleep(nanoseconds: slice(0.12))
        print("DEMO: tamaño → PANTALLA COMPLETA (full)")
        rc.bubble.setSize(.full)

        try? await Task.sleep(nanoseconds: slice(0.12))
        print("DEMO: volver a MEDIANA (M) abajo-derecha")
        rc.bubble.setSize(.m)
        rc.bubble.move(to: origin(0.98, 0.05, d: CameraBubble.Size.m.diameter))

        try? await Task.sleep(nanoseconds: slice(0.08))
        print("DEMO: PAUSA (3s)")
        await rc.pause()
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        print("DEMO: REANUDAR")
        await rc.resume()

        try? await Task.sleep(nanoseconds: slice(0.28))
        print("DEMO: STOP — link al portapapeles + upload")
        let result = await rc.stopAndWait()
        let clip = NSPasteboard.general.string(forType: .string) ?? "(vacío)"
        print("DEMO_CLIPBOARD: \(clip)")
        print("DEMO_URL: \(result.url)")
        print(result.uploadOK || noUpload ? "DEMO_OK" : "DEMO_UPLOAD_FAIL")
        try? await Task.sleep(nanoseconds: 500_000_000)
        exit(result.uploadOK || noUpload ? 0 : 3)
    }
}
