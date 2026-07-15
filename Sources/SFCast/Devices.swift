import AVFoundation

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
