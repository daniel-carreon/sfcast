import AppKit
import AVFoundation
import CoreGraphics

/// Permisos TCC pedidos UNO POR UNO y ANTES de arrancar la captura.
///
/// GOTCHA RAÍZ (14 jul, el cuelgue de Daniel): si startCapture dispara el prompt
/// de micrófono mientras el de cámara sigue pendiente, tccd los serializa y
/// startCapture se queda esperando PARA SIEMPRE (estado zombie: la UI viva,
/// los botones muertos). La cura: preflight secuencial aquí + timeout en el engine.
@MainActor
enum Permissions {
    /// Los prompts de TCC solo se PINTAN si la app corre bundleada y lanzada por
    /// launchd (Finder/Spotlight/open). Desde terminal, tccd se atasca sin pintar.
    static var canPrompt: Bool {
        Bundle.main.bundleIdentifier == "so.saasfactory.sfcast" && getppid() == 1
    }

    static var cameraGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }
    static var micGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }
    static var screenGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Pide cámara y mic en SERIE, delegando en `PermissionBroker` (serialización
    /// total + self-heal de UserNotificationCenter + activación de la app). Este
    /// método queda como fachada fina para los call-sites existentes; toda la
    /// lógica anti-ráfaga y anti-prompt-zombie vive en el broker.
    @discardableResult
    static func preflight(needCamera: Bool, needMic: Bool, timeout: Double = 45) async -> (camera: Bool, mic: Bool) {
        var cam = !needCamera
        var mic = !needMic
        if needCamera { cam = await PermissionBroker.shared.request(.video, hardTimeout: timeout) }
        if needMic { mic = await PermissionBroker.shared.request(.audio, hardTimeout: timeout) }
        Log.info("Preflight permisos: cámara=\(cam) mic=\(mic) pantalla=\(screenGranted) canPrompt=\(canPrompt)")
        return (cam, mic)
    }

    /// Abre el pane exacto de Privacidad en Ajustes del Sistema.
    /// anchor: "ScreenCapture" | "Camera" | "Microphone"
    static func openPrivacyPane(_ anchor: String) {
        let raw = "x-apple.systempreferences:com.apple.preference.security?Privacy_\(anchor)"
        if let url = URL(string: raw) { NSWorkspace.shared.open(url) }
    }
}
