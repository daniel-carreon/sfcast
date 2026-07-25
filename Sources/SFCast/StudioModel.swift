import Foundation
import CoreGraphics

/// MODO ESTUDIO — modelo de escenas y fuentes (estilo OBS/Streamlabs).
/// Una ESCENA es un arreglo ordenado de items (fuente + layout normalizado).
/// Las FUENTES son globales (registro); la escena las referencia con transform.
/// Persistencia: ~/Library/Application Support/SFCast/scenes.json (decode
/// tolerante, mismo patrón que AppSettings — agregar campos no resetea nada).

enum StudioSourceKind: String, Codable, CaseIterable {
    case screen        // display completo (ScreenCaptureKit)
    case camera        // cámara (AVCaptureSession propia del Estudio)
    case testPattern   // fuente sintética: QA/headless sin permisos TCC

    var label: String {
        switch self {
        case .screen: return "Pantalla"
        case .camera: return "Cámara"
        case .testPattern: return "Patrón de prueba"
        }
    }
    var icon: String {
        switch self {
        case .screen: return "display"
        case .camera: return "video.fill"
        case .testPattern: return "checkerboard.rectangle"
        }
    }
}

/// Cómo se acomoda el video de la fuente dentro de su rect en el canvas.
enum StudioFit: String, Codable, CaseIterable {
    case fill   // llena el rect recortando (aspect-fill) — el default de estudio
    case fit    // entra completo con barras (aspect-fit)
    var label: String { self == .fill ? "Llenar" : "Ajustar" }
}

/// Un item DENTRO de una escena: qué fuente, dónde y cómo.
/// `rect` es NORMALIZADO (0-1, origen abajo-izquierda como AppKit) sobre el
/// canvas del programa — así el layout sobrevive cambios de resolución.
struct SceneItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: StudioSourceKind
    var rect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    var fit: StudioFit = .fill
    var circleMask = false      // burbuja estilo Loom (recorte circular)
    var enabled = true
    var opacity: Double = 1.0

    init(kind: StudioSourceKind, rect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1),
         fit: StudioFit = .fill, circleMask: Bool = false) {
        self.kind = kind
        self.rect = rect
        self.fit = fit
        self.circleMask = circleMask
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decodeIfPresent(StudioSourceKind.self, forKey: .kind) ?? .screen
        rect = try c.decodeIfPresent(CGRect.self, forKey: .rect) ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        fit = try c.decodeIfPresent(StudioFit.self, forKey: .fit) ?? .fill
        circleMask = try c.decodeIfPresent(Bool.self, forKey: .circleMask) ?? false
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1.0
    }
}

/// Una escena nombrada. `items` en orden de PILA: el índice 0 se pinta primero
/// (fondo); el último queda encima (como OBS al revés visual — documentado en UI).
struct StudioScene: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var items: [SceneItem]

    init(name: String, items: [SceneItem]) {
        self.name = name
        self.items = items
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Escena"
        items = try c.decodeIfPresent([SceneItem].self, forKey: .items) ?? []
    }
}

/// Config de SALIDAS por grabación (la doble salida del spec):
/// - raw de pantalla y cámara = caso A (Screen Studio "extract raw files")
/// - programa compuesto = caso B (OBS Source Record)
struct StudioOutputs: Codable, Equatable {
    /// Los RAW arrancan APAGADOS (25 jul): son la opción "capas estilo Screen
    /// Studio" para reeditar, pero NADA en el pipeline los lee todavía y cuestan
    /// casi 9x lo que el programa. Se prenden cuando haya quien los use.
    var rawScreen = false
    var rawCamera = false
    var program = true

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rawScreen = try c.decodeIfPresent(Bool.self, forKey: .rawScreen) ?? false
        rawCamera = try c.decodeIfPresent(Bool.self, forKey: .rawCamera) ?? false
        program = try c.decodeIfPresent(Bool.self, forKey: .program) ?? true
    }
}

/// Resolución del canvas del programa (Ajustes → Video). `native` = la del
/// display capturado; fijas = canvas estable aunque cambies de monitor.
enum StudioCanvasMode: String, Codable, CaseIterable {
    case native, p1080, p1440
    var label: String {
        switch self {
        case .native: return "Nativa del display"
        case .p1080: return "1920 × 1080"
        case .p1440: return "2560 × 1440"
        }
    }
    var size: CGSize? {
        switch self {
        case .native: return nil
        case .p1080: return CGSize(width: 1920, height: 1080)
        case .p1440: return CGSize(width: 2560, height: 1440)
        }
    }
}

/// Calidad del programa compuesto.
///
/// ⚠️ El default (`media`) es CALIDAD CONSTANTE, como OBS/Streamlabs — NO
/// bitrate promedio. Es la diferencia entre 334 MB y 6 GB por la misma hora de
/// grabación (medición del 25 jul, mismo contenido, ambas apps a la vez). En
/// captura de pantalla el bitrate promedio es el peor modo posible: paga el
/// mismo precio por una pantalla quieta que por una llena de movimiento.
/// `master` queda como escape para quien SÍ quiera el bitrate fijo alto.
enum StudioQuality: String, Codable, CaseIterable {
    case alta, media, baja
    var label: String {
        switch self {
        case .alta: return "Alta (master)"
        case .media: return "Media (recomendada)"
        case .baja: return "Ligera (YouTube)"
        }
    }
    /// true = CQ (calidad constante, el archivo pesa según lo que pasa en
    /// pantalla); false = bitrate promedio fijo.
    var usesConstantQuality: Bool { self != .alta }
    /// 0-1 para `AVVideoQualityKey`. 0.62 ≈ CQP ~23 de OBS en pantalla.
    var constantQuality: Double {
        switch self {
        case .alta: return 0.80
        case .media: return 0.62
        case .baja: return 0.48
        }
    }
    /// Solo se usa cuando `usesConstantQuality == false`.
    var bitsPerPxFrame: Double {
        switch self {
        case .alta: return 0.10
        case .media: return 0.04
        case .baja: return 0.025
        }
    }
    /// Bitrate del RAW de cámara (camera.mov). Antes NO se fijaba: el
    /// AVCaptureMovieFileOutput con preset `.high` escribe a lo que se le antoja
    /// (decenas de Mbps con una cámara buena) y era el segundo tragón del disco.
    var cameraRawKbps: Int {
        switch self {
        case .alta: return 10_000
        case .media: return 5_000    // HEVC 1080p30 a 5 Mbps = master de sobra
        case .baja: return 3_000
        }
    }

    /// Mbps MEDIDOS del programa a 1080p30 (bench 25 jul, pantalla con texto en
    /// movimiento — el peor caso). Sirve para ESTIMAR el peso antes de grabar:
    /// que el costo se vea ANTES, no cuando el disco truena.
    var programMbpsAt1080p30: Double {
        switch self {
        case .alta: return 2.40
        case .media: return 0.90
        case .baja: return 0.55
        }
    }
}

/// Estimación de peso de una sesión. No es exacta (el encoder es de calidad
/// constante: gasta según lo que pase en pantalla), pero pone un número donde
/// antes no había ninguno.
enum WeightEstimate {
    /// SCRecordingOutput no expone bitrate; 1.42 Mbps @1080p30 es lo MEDIDO.
    static let screenRawMbpsAt1080p30: Double = 1.42

    static func mbps(config: StudioConfig, width: Int, height: Int, fps: Int) -> Double {
        let scale = (Double(width * height) / (1920.0 * 1080.0)) * (Double(fps) / 30.0)
        var total = 0.16   // audio (2 pistas AAC 160k)
        if config.outputs.program { total += config.programQuality.programMbpsAt1080p30 * scale }
        if config.outputs.rawScreen { total += screenRawMbpsAt1080p30 * scale }
        if config.outputs.rawCamera { total += Double(config.programQuality.cameraRawKbps) / 1000.0 }
        return total
    }

    static func gbPerHour(config: StudioConfig, width: Int, height: Int, fps: Int) -> Double {
        mbps(config: config, width: width, height: height, fps: fps) * 3600 / 8 / 1000
    }
}

/// Documento raíz del Estudio (persiste completo).
struct StudioConfig: Codable {
    var scenes: [StudioScene]
    var activeSceneID: UUID?
    var outputs = StudioOutputs()
    var micEnabled = true
    var systemAudioEnabled = true
    var fps = 30
    var canvasMode = StudioCanvasMode.native
    var programQuality = StudioQuality.media
    /// false = la ventana del Estudio es INVISIBLE en capturas/grabaciones
    /// (estilo OBS, default); true = ventana normal, sale en screenshots.
    var windowCapturable = false
    /// Migración única del 25 jul: apagar los RAW por default. Motivo: NADA los
    /// consumía (el worker del VPS solo glob-ea `seg-*.mp4`, SFStudio y la skill
    /// de edición no los tocan) y entre los dos costaban ~6.9 Mbps de los ~7.8
    /// que pesaba una sesión. Se avisa en la UI y siguen a un clic en Salidas.
    var weightFixApplied = false

    static let file = AppSettings.dir.appendingPathComponent("scenes.json")

    init(scenes: [StudioScene], activeSceneID: UUID?) {
        self.scenes = scenes
        self.activeSceneID = activeSceneID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scenes = try c.decodeIfPresent([StudioScene].self, forKey: .scenes) ?? []
        activeSceneID = try c.decodeIfPresent(UUID.self, forKey: .activeSceneID)
        outputs = try c.decodeIfPresent(StudioOutputs.self, forKey: .outputs) ?? StudioOutputs()
        micEnabled = try c.decodeIfPresent(Bool.self, forKey: .micEnabled) ?? true
        systemAudioEnabled = try c.decodeIfPresent(Bool.self, forKey: .systemAudioEnabled) ?? true
        fps = try c.decodeIfPresent(Int.self, forKey: .fps) ?? 30
        canvasMode = try c.decodeIfPresent(StudioCanvasMode.self, forKey: .canvasMode) ?? .native
        programQuality = try c.decodeIfPresent(StudioQuality.self, forKey: .programQuality) ?? .media
        windowCapturable = try c.decodeIfPresent(Bool.self, forKey: .windowCapturable) ?? false
        weightFixApplied = try c.decodeIfPresent(Bool.self, forKey: .weightFixApplied) ?? false
    }

    /// true si `load()` acaba de aplicar la migración de peso (la UI lo avisa
    /// UNA vez: apagar salidas del usuario en silencio sería peor que el bug).
    static private(set) var weightFixJustApplied = false

    static func load() -> StudioConfig {
        if let data = try? Data(contentsOf: file),
           var cfg = try? JSONDecoder().decode(StudioConfig.self, from: data),
           !cfg.scenes.isEmpty {
            if cfg.activeSceneID == nil || !cfg.scenes.contains(where: { $0.id == cfg.activeSceneID }) {
                cfg.activeSceneID = cfg.scenes.first?.id
            }
            if !cfg.weightFixApplied {
                cfg.weightFixApplied = true
                if cfg.outputs.rawScreen || cfg.outputs.rawCamera {
                    cfg.outputs.rawScreen = false
                    cfg.outputs.rawCamera = false
                    Self.weightFixJustApplied = true
                    Log.info("Estudio: migración de peso — RAW de pantalla y cámara apagados "
                             + "(nada los consumía; eran ~6.9 de los ~7.8 Mbps). Reactivables en Salidas.")
                }
                cfg.save()
            }
            return cfg
        }
        let cfg = defaultConfig()
        cfg.save()
        return cfg
    }

    func save() {
        try? FileManager.default.createDirectory(at: AppSettings.dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(self) {
            try? data.write(to: Self.file)
        }
    }

    /// Presets de fábrica — las escenas que Daniel ya usa en Streamlabs, más la
    /// gemela del modo Loom POR COMPOSICIÓN (pantalla + burbuja circular, sin
    /// burn-in: la cámara sigue siendo pista separada y editable).
    static func defaultConfig() -> StudioConfig {
        let completa = StudioScene(name: "Completa", items: [
            SceneItem(kind: .screen),
        ])
        // Burbuja abajo-izquierda, proporción de la burbuja M del Loom.
        let loom = StudioScene(name: "Loom", items: [
            SceneItem(kind: .screen),
            SceneItem(kind: .camera,
                      rect: CGRect(x: 0.02, y: 0.03, width: 0.16, height: 0.16 * 16.0 / 9.0),
                      fit: .fill, circleMask: true),
        ])
        let camSolo = StudioScene(name: "Mi cámara solo", items: [
            SceneItem(kind: .camera),
        ])
        let ladoALado = StudioScene(name: "Lado a lado", items: [
            SceneItem(kind: .screen, rect: CGRect(x: 0, y: 0, width: 0.62, height: 1), fit: .fit),
            SceneItem(kind: .camera, rect: CGRect(x: 0.62, y: 0.15, width: 0.38, height: 0.7)),
        ])
        var cfg = StudioConfig(scenes: [completa, loom, camSolo, ladoALado],
                               activeSceneID: nil)
        cfg.activeSceneID = loom.id
        return cfg
    }
}

// MARK: - Manifest de sesión (el contrato con la edición agéntica / SFStudio)

/// manifest.json: TODO lo que un agente editor necesita mañana para editar con
/// cámara y pantalla separadas — inventario de archivos con ROL, timeline de
/// switches de escena y el snapshot de escenas usado. Ver spec §CONEXIÓN.
struct StudioManifest: Codable {
    struct OutputFile: Codable {
        var role: String        // "screen" | "camera" | "program"
        var file: String        // nombre relativo dentro del sessionDir
        var durationSeconds: Double?
        var width: Int?
        var height: Int?
    }
    struct SceneSwitch: Codable {
        var t: Double           // segundos desde el inicio de la grabación
        var sceneID: UUID
        var sceneName: String
    }

    var schemaVersion = 1
    var id: String
    var kind = "studio"
    var startedAt: String
    var endedAt: String
    var canvasWidth: Int
    var canvasHeight: Int
    var fps: Int
    var outputs: [OutputFile]
    var sceneTimeline: [SceneSwitch]
    var scenes: [StudioScene]
    var micEnabled: Bool
    var systemAudioEnabled: Bool

    func write(to dir: URL) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(self) {
            try? data.write(to: dir.appendingPathComponent("manifest.json"))
        }
    }
}
