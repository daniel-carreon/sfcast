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

    // Transporte de CoreAudio/CMIO, medido el 16 sep 2026 en la MacBook:
    // OBS Virtual Camera = 'virt', cámara y mic integrados = 'bltn'.
    private static let transporteVirtual: Int32 = 0x76697274     // 'virt'
    private static let transporteIntegrado: Int32 = 0x626C746E   // 'bltn'

    /// La cámara ELEGIDA, si está conectada: por uniqueID y, si no, por nombre.
    /// El uniqueID de una capturadora UVC (la Cam Link) lleva el puerto USB
    /// dentro: cambiarla de puerto la "desconectaba" para SFCast (16 sep 2026).
    /// nil = no hay elegida o no está; esta función jamás cae a otra cámara.
    static func cameraElegida(id: String?) -> AVCaptureDevice? {
        guard let id else { return nil }
        if let d = AVCaptureDevice(uniqueID: id) { return d }
        guard let nombre = AppSettings.load().cameraDeviceName else { return nil }
        return videoDevices().first { $0.localizedName == nombre }
    }

    /// La cámara para la sesión: la elegida, o el default del sistema SALVO que
    /// sea virtual. Con la Cam Link desconectada el default era "OBS Virtual
    /// Camera", un cuadro fijo que se ve como cámara viva (9 ago y 16 sep 2026):
    /// mejor sin cámara que con una falsa.
    static func camera(id: String?) -> AVCaptureDevice? {
        if let d = cameraElegida(id: id) { return d }
        guard let d = AVCaptureDevice.default(for: .video),
              d.transportType != transporteVirtual else { return nil }
        return d
    }

    /// El micrófono ELEGIDO, si está conectado (uniqueID, luego nombre).
    static func microphoneElegido(id: String?) -> AVCaptureDevice? {
        guard let id else { return nil }
        if let d = AVCaptureDevice(uniqueID: id) { return d }
        guard let nombre = AppSettings.load().micDeviceName else { return nil }
        return audioDevices().first { $0.localizedName == nombre }
    }

    /// El micrófono para la sesión: el elegido; si hay uno elegido pero no está
    /// (la MacBook fuera del escritorio, sin el Shure), el integrado de la Mac
    /// antes que el default — el default suele ser un audífono Bluetooth y abrir
    /// su mic lo tira a modo llamada. Sin elegido, el default de siempre.
    static func microphone(id: String?) -> AVCaptureDevice? {
        if let d = microphoneElegido(id: id) { return d }
        if id != nil, let d = audioDevices().first(where: { $0.transportType == transporteIntegrado }) {
            return d
        }
        return AVCaptureDevice.default(for: .audio)
    }

    /// Nombre actual de un dispositivo por uniqueID (nil si no está conectado).
    static func nombre(uniqueID: String?) -> String? {
        uniqueID.flatMap { AVCaptureDevice(uniqueID: $0)?.localizedName }
    }

    private static func videoDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
            mediaType: .video, position: .unspecified).devices
    }

    private static func audioDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio, position: .unspecified).devices
    }
}
