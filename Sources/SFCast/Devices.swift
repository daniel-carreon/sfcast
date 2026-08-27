import AVFoundation
import AppKit

/// Enumeración de dispositivos de cámara y micrófono (id estable = uniqueID).
enum Devices {
    struct Entry: Identifiable, Hashable {
        let id: String      // uniqueID
        let name: String
    }

    static func cameras() -> [Entry] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
            mediaType: .video, position: .unspecified)
        return session.devices.map { Entry(id: $0.uniqueID, name: $0.localizedName) }
    }

    /// Las pantallas conectadas, con su `CGDirectDisplayID` (en texto) como id.
    ///
    /// Va en String y no en UInt32 porque `Entry` —y el popover que la pinta—
    /// hablan Strings: una segunda clase de id por un solo caso seria duplicar
    /// el selector entero para no convertir un numero.
    ///
    /// El nombre lleva la resolucion pegada A PROPOSITO: aqui hay pantallas sin
    /// nombre (25 ago 2026: una de 1280x720 @ 50Hz colgada a la izquierda de
    /// los dos BenQ) y una lista con dos filas mudas no se puede elegir.
    static func pantallas() -> [Entry] {
        NSScreen.screens.map { s in
            let id = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value ?? 0
            let crudo = s.localizedName.trimmingCharacters(in: .whitespaces)
            let nombre = crudo.isEmpty ? "Pantalla sin nombre" : crudo
            let w = Int(s.frame.width * s.backingScaleFactor)
            let h = Int(s.frame.height * s.backingScaleFactor)
            return Entry(id: String(id), name: "\(nombre) · \(w)x\(h)")
        }
    }

    static func microphones() -> [Entry] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio, position: .unspecified)
        return session.devices.map { Entry(id: $0.uniqueID, name: $0.localizedName) }
    }

    static func camera(id: String?) -> AVCaptureDevice? {
        if let id, let d = AVCaptureDevice(uniqueID: id) { return d }
        return AVCaptureDevice.default(for: .video)
    }

    static func microphone(id: String?) -> AVCaptureDevice? {
        if let id, let d = AVCaptureDevice(uniqueID: id) { return d }
        return AVCaptureDevice.default(for: .audio)
    }
}
