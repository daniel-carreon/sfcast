import Foundation

struct AppSettings: Codable {
    var sshHost = "hermes-vps"
    var remoteIncoming = "/opt/sfcast/incoming"
    var baseURL = "https://videos.saasfactory.so"
    var bubbleSize = "m"            // s | m | l | full
    var bubbleGlow = "ambar"        // ambar | morado | nada
    var cameraDeviceID: String? = nil   // uniqueID; nil = default del sistema
    var micDeviceID: String? = nil      // uniqueID; nil = default del sistema
    var cameraEnabled = true            // burbuja de cámara (toggle del micropanel)
    var micEnabled = true
    var systemAudioEnabled = true
    var countdownSeconds = 3
    var fps = 30
    /// Tope de ALTURA de la captura, en píxeles (0 = sin tope, graba nativo).
    ///
    /// POR QUÉ EXISTE (medido el 10 ago 2026): capturar a nativo Retina daba
    /// 4096x2304 y con eso el archivo NACÍA a 23 Mbps — 778.9 MB por 4:28 de
    /// video. Ese tamaño era la raíz de toda la lentitud del pipeline: el
    /// compresor escalaba su objetivo por píxeles hasta 5461 kbps y el encoder
    /// por hardware, que a 1080p corre a ~7x tiempo real, a 4K cae a 0.55x
    /// (147s de compresión para 268s de video).
    ///
    /// 1440 conserva el texto legible, que es EL caso de uso (grabar código), y
    /// deja el archivo ~3-4x más chico desde el origen. Loom graba a 1080p.
    var captureMaxHeight = 1440
    /// Re-encode por hardware antes de subir.
    ///
    /// APAGADO desde el 10 ago 2026. Se construyó el 15 jul sobre una premisa
    /// MEDIDA entonces: la subida iba a ~0.5 Mbps y comprimir 5x era comprimir
    /// la espera 5x. Esa premisa murió con la mudanza a Morelia: hoy la subida
    /// mide 106 Mbps (13.3 MB/s reales con el mismo rsync que usa la app), y
    /// entonces comprimir CUESTA — 147s de encode para ahorrar 43s de subida,
    /// 104s netos en contra, y encima degradando la imagen.
    ///
    /// Además es incompatible con `liveSyncWhileRecording`: no puedes pre-subir
    /// bytes que vas a reescribir al terminar.
    ///
    /// Se conserva como break-glass: si algún día grabas desde una red lenta,
    /// prenderlo vuelve a tener sentido. El Transcoder sigue intacto.
    var compressBeforeUpload = false
    /// 1200 kbps medido sobre grabación real de pantalla 1080p: 5x más chico y
    /// se leen los menús y la barra lateral. Subir a 2000 si algún día se nota.
    var videoBitrateKbps = 1200
    /// Sube el segmento en curso MIENTRAS grabas, para que al detener quede solo
    /// la cola por subir (es el truco por el que Loom se siente instantáneo).
    /// Ver `Uploader.LiveSync` para la garantía de correctitud.
    var liveSyncWhileRecording = true
    /// Destino al detener: true = sube al VPS al instante (lo de siempre);
    /// false = SOLO guarda en ~/Movies/SFCast/{id} y NO sube (lo empujas luego
    /// desde el Historial). La grabación queda en local en AMBOS casos
    /// (invariante #5); esto solo decide si además viaja al VPS al terminar.
    var autoUpload = true

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
        captureMaxHeight = try c.decodeIfPresent(Int.self, forKey: .captureMaxHeight) ?? captureMaxHeight
        compressBeforeUpload = try c.decodeIfPresent(Bool.self, forKey: .compressBeforeUpload) ?? compressBeforeUpload
        liveSyncWhileRecording = try c.decodeIfPresent(Bool.self, forKey: .liveSyncWhileRecording) ?? liveSyncWhileRecording
        videoBitrateKbps = try c.decodeIfPresent(Int.self, forKey: .videoBitrateKbps) ?? videoBitrateKbps
        autoUpload = try c.decodeIfPresent(Bool.self, forKey: .autoUpload) ?? autoUpload
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
