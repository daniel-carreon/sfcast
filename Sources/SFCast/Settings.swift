import Foundation

struct AppSettings: Codable {
    var sshHost = "hermes-vps"
    var remoteIncoming = "/opt/sfcast/incoming"
    var baseURL = "https://livekit.saasfactory.so"
    var bubbleSize = "m"            // s | m | l | full
    var bubbleGlow = "ambar"        // ambar | morado | nada
    var cameraDeviceID: String? = nil   // uniqueID; nil = default del sistema
    var micDeviceID: String? = nil      // uniqueID; nil = default del sistema
    var cameraEnabled = true            // burbuja de cámara (toggle del micropanel)
    var micEnabled = true
    var systemAudioEnabled = true
    var countdownSeconds = 3
    var fps = 30

    init() {}

    /// Decode TOLERANTE: cualquier campo ausente cae a su default. Sin esto,
    /// agregar un campo nuevo (p. ej. cameraEnabled en v1.4) invalidaba el
    /// settings.json viejo completo y reseteaba en silencio la config de Daniel.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sshHost = try c.decodeIfPresent(String.self, forKey: .sshHost) ?? sshHost
        remoteIncoming = try c.decodeIfPresent(String.self, forKey: .remoteIncoming) ?? remoteIncoming
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? baseURL
        bubbleSize = try c.decodeIfPresent(String.self, forKey: .bubbleSize) ?? bubbleSize
        bubbleGlow = try c.decodeIfPresent(String.self, forKey: .bubbleGlow) ?? bubbleGlow
        cameraDeviceID = try c.decodeIfPresent(String.self, forKey: .cameraDeviceID)
        micDeviceID = try c.decodeIfPresent(String.self, forKey: .micDeviceID)
        cameraEnabled = try c.decodeIfPresent(Bool.self, forKey: .cameraEnabled) ?? cameraEnabled
        micEnabled = try c.decodeIfPresent(Bool.self, forKey: .micEnabled) ?? micEnabled
        systemAudioEnabled = try c.decodeIfPresent(Bool.self, forKey: .systemAudioEnabled) ?? systemAudioEnabled
        countdownSeconds = try c.decodeIfPresent(Int.self, forKey: .countdownSeconds) ?? countdownSeconds
        fps = try c.decodeIfPresent(Int.self, forKey: .fps) ?? fps
    }

    static let dir = URL(fileURLWithPath: NSString(
        string: "~/Library/Application Support/SFCast").expandingTildeInPath)
    static let file = dir.appendingPathComponent("settings.json")
    static let recordingsDir = URL(fileURLWithPath: NSString(
        string: "~/Movies/SFCast").expandingTildeInPath)

    static func load() -> AppSettings {
        if let data = try? Data(contentsOf: file),
           let s = try? JSONDecoder().decode(AppSettings.self, from: data) {
            return s
        }
        let s = AppSettings()
        s.save()
        return s
    }

    func save() {
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(self) {
            try? data.write(to: Self.file)
        }
    }
}
