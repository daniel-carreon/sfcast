import AppKit
import SwiftUI
import IOSurface
import CoreImage
import CoreVideo
import Carbon.HIToolbox
import WebKit

/// MODO ESTUDIO — vista desktop. Anatomía OBS/Streamlabs (Escenas + Fuentes +
/// Preview/Programa + Mixer + Salidas), piel Screen Studio: oscura, limpia,
/// acento mostaza de marca. La ventana lleva `sharingType = .none` (invisible a
/// cualquier captura — como el pill); SOLO en --studiotest se deja capturable.

/// LOS CONTADORES QUE LATEN — fuera del controller a propósito (9 ago 2026).
///
/// fps de cámara/preview y el cronómetro de grabación cambian ~1 vez por
/// segundo. Vivían como `@Published` del `StudioController`, y en SwiftUI eso
/// significa que CADA latido invalidaba todo lo que observa ese controller:
/// la barra, el panel de escenas y **la lista de fuentes con su menú abierto**.
///
/// El síntoma que lo delató (Daniel, 9 ago): *"es muy difícil clickear el botón
/// porque desaparece bien fácil"*. No era puntería — era que el menú se
/// reconstruía debajo del cursor una vez por segundo.
///
/// Aquí solo lo observan el chip de fps y el cronómetro, que son justo las dos
/// cosas que TIENEN que redibujarse a ese ritmo. Hermano de la cura del vúmetro
/// en v2.8, por el lado de los menús.
final class StudioMeters: ObservableObject {
    @Published var camFPS = -1        // -1 = sin dato aún
    @Published var prevFPS = -1
    @Published var renderStarving = false
    @Published var elapsed: TimeInterval = 0
    /// Marcas por TIPO. Separadas a propósito: un contador que suma los dos no
    /// informa de nada (Daniel, 10 ago: "veo puras tijeras con ambos botones").
    @Published var cortes = 0
    @Published var estrellas = 0
}

@MainActor
final class StudioController: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = StudioController()

    let engine = StudioEngine()
    let recorder = StudioRecorder()
    /// EL ESPEJO: la burbuja del programa proyectada sobre la pantalla que se
    /// captura, para VER (y poder mover) lo que estás tapando. Ver StudioMirror.
    let mirror = StudioMirror()

    @Published var config = StudioConfig.load()
    @Published var selectedItemID: UUID? { didSet { previewView?.refreshOverlay() } }
    @Published var showSettings = false
    /// EL SET a la vista (18 ago 2026): el panel web :8088 embebido como drawer
    /// del Estudio — un solo panel (panel_server.py), cero re-implementación.
    /// Abierto/cerrado y ancho se RECUERDAN (pedido 18 ago pm): el drawer vuelve
    /// como lo dejaste, y el resizer guarda su última posición.
    @Published var showSetPanel = UserDefaults.standard.bool(forKey: "studio.setPanelOpen") {
        didSet { UserDefaults.standard.set(showSetPanel, forKey: "studio.setPanelOpen") }
    }
    @Published var setPanelWidth: CGFloat = {
        let w = UserDefaults.standard.double(forKey: "studio.setPanelWidth")
        return (300...560).contains(w) ? CGFloat(w) : 372
    }() {
        didSet { UserDefaults.standard.set(Double(setPanelWidth), forKey: "studio.setPanelWidth") }
    }
    /// EL CAJÓN DE LA CÁMARA (22 ago 2026): sfcam deja de ser una app aparte y
    /// pasa a ser una feature del set. Vive AL LADO de la imagen a propósito —
    /// cambiar la exposición sin ver el resultado es adivinar.
    @Published var showCameraPanel = UserDefaults.standard.bool(forKey: "studio.cameraPanelOpen") {
        didSet { UserDefaults.standard.set(showCameraPanel, forKey: "studio.cameraPanelOpen") }
    }
    @Published var cameraPanelWidth: CGFloat = {
        let w = UserDefaults.standard.double(forKey: "studio.cameraPanelWidth")
        return (280...520).contains(w) ? CGFloat(w) : 320
    }() {
        didSet { UserDefaults.standard.set(Double(cameraPanelWidth), forKey: "studio.cameraPanelWidth") }
    }
    @Published var isRecording = false

    // Vúmetro SIN @Published — v2.8. Publicar los niveles a 15 Hz invalidaba
    // la jerarquía SwiftUI COMPLETA (todos los paneles observan este objeto):
    // cada pase de layout de la ventana cuesta ~60-70 ms, 30 publicaciones/s
    // saturaban main al 99.7% (medido con `sample`) y el PreviewGate — que
    // tira frames cuando main no consume, por diseño — dejaba el preview a
    // ~3 fps con la cámara y el compositor perfectamente sanos a 30. Los
    // niveles ahora van DIRECTO al CALayer de la barra, igual que el preview.
    private weak var micMeter: MeterBarNSView?
    private weak var sysMeter: MeterBarNSView?
    /// Ya se notificó que la cadencia tocó el suelo EN ESTA TOMA. De flanco, no de
    /// nivel: el governor puede escalonar varias veces en un tramo malo y avisar
    /// en cada uno entrenaría a ignorar el aviso.
    fileprivate var cadenceFloorNotified = false
    private var micSmooth: Float = 0
    private var sysSmooth: Float = 0
    /// SENSOR (invariante 5b): fps medidos de cámara y preview, para VER que
    /// lo que se ve es lo que se graba. Publica ~1 Hz y solo si cambió.
    /// ⚠️ Los contadores que laten CADA SEGUNDO viven en su propio observable
    /// (9 ago 2026). Estaban aquí como `@Published`, y cada latido invalidaba la
    /// jerarquía ENTERA que observa este controller — incluida la lista de
    /// fuentes. Consecuencia que Daniel sufrió: abría el clic derecho de la
    /// Cámara y, al segundo siguiente, `prevFPS` pasaba de 30 a 29 y **el menú
    /// se le cerraba en la cara**, sin importar la puntería del ratón.
    ///
    /// Es la misma lección de v2.8 (el vúmetro re-layouteando la ventana), ahora
    /// por el lado de los menús: nada que cambie ~1 vez por segundo puede vivir
    /// en un objeto que observa media UI.
    let meters = StudioMeters()
    /// true = el compositor NO alcanza a componer (no es la compuerta tirando).
    /// Distinción crítica: esto SÍ le baja los fps al archivo. Ver refreshFlowSensor.

    private var lastFlow: StudioFlowCounts?
    private var lastFlowAt: Double = 0
    @Published var screenOK = false
    @Published var cameraOK = false
    @Published var starved: Set<StudioSourceKind> = []
    // EL ESPEJO (v2.9). Publicados: SOLO booleanos y un texto que cambian de
    // Pascua a Ramos — nada del arrastre ni de la energía cruda pasa por aquí.
    /// Por qué el espejo no se ve estando prendido (nil = se ve). Un espejo que
    /// desaparece en silencio sería el patrón de bug del 25 jul otra vez.
    /// Acuse de marcador para la UI (cuántos van y cuál fue el último).
    @Published var markerCount = 0
    @Published var lastMarkerKind = ""
    @Published var markerFlashUntil = Date.distantPast
    @Published var mirrorNote: String?
    @Published var mirrorLocked = false
    @Published var mirrorXray = false
    @Published var lastSessionDir: URL?
    @Published var recordError: String?
    /// Alarma VISIBLE del Estudio (congelada / disco / reenganche). Es lo que
    /// faltaba el 25 jul: la pantalla se congeló y la app no dijo nada.
    @Published var alert: String?
    @Published var alertCritical = false
    @Published var freeDiskNote: String?

    var testMode = false          // --studiotest: ventana capturable
    /// Internal (no private): el ScreenDoctor necesita saber si el Estudio está
    /// vivo para NO abrir un modal encima — un modal bloquea main y con él todos
    /// los sensores del Estudio, que viven en Timers de RunLoop.
    private(set) var window: NSWindow?
    private var meterTimer: Timer?

    // (El self-view "Burbuja" se ELIMINÓ en v2.3 a pedido de Daniel: el modo
    // Loom vive aparte con su burbuja real; en el Estudio el preview basta.)

    var isStudioRecording: Bool { recorder.isRecording }
    var isOpen: Bool { window?.isVisible ?? false }

    var activeScene: StudioScene? {
        config.scenes.first(where: { $0.id == config.activeSceneID })
    }

    // MARK: - ventana

    /// Coloca el Estudio para el modo rodaje (sfcast://rodaje). **SIN pantalla
    /// completa** (Daniel, 25 ago 2026: "evita que se ponga pantalla completa,
    /// es molesto que lo haga as default"). F4 trae el Estudio al frente y lo
    /// pone donde toca; el fullscreen lo decides tú con el botón verde.
    ///
    /// "IZQUIERDO" SIGNIFICA MONITOR, NO PANTALLA. El 18 ago había dos BenQ y
    /// `min(minX)` bastaba. Hoy macOS lista TRES: entre los dos monitores hay
    /// una pantalla de 1280x720 @ 50Hz, sin nombre, colgada en x = -1280 — o
    /// sea, la más a la izquierda de todas. El Estudio se iba entero a esa
    /// pantalla fantasma y desde la silla parecía que F4 "no abría SFCast":
    /// abría, pero donde nadie mira.
    ///
    /// El filtro no adivina cuál es la buena: DESCARTA lo que no es un monitor
    /// de trabajo (sin nombre en el sistema, o más angosto que 1440 pt). Si el
    /// filtro se quedara vacío, cae al comportamiento viejo en vez de no hacer
    /// nada: elegir raro es mejor que dejar la ventana perdida.
    ///
    /// SI LA VENTANA YA ESTÁ EN EL MONITOR DE RODAJE, NO SE TOCA: F4 no
    /// reacomoda lo que tú acomodaste. Y sin fullscreen ya no hace falta el
    /// respiro de 0.35 s que existía solo para que `toggleFullScreen` no
    /// llegara antes que `makeKeyAndOrderFront` — la ventana aparece en el
    /// mismo hop en que se pide.
    func colocarParaRodaje() {
        guard let w = window, !w.styleMask.contains(.fullScreen) else { return }
        let reales = NSScreen.screens.filter {
            !$0.localizedName.trimmingCharacters(in: .whitespaces).isEmpty
                && $0.frame.width >= 1440
        }
        let candidatas = reales.isEmpty ? NSScreen.screens : reales
        guard let destino = candidatas.min(by: { $0.frame.minX < $1.frame.minX }),
              w.screen !== destino else { return }
        let f = destino.visibleFrame
        let ancho = min(w.frame.width, f.width - 80)
        let alto = min(w.frame.height, f.height - 80)
        w.setFrame(NSRect(x: f.minX + (f.width - ancho) / 2,
                          y: f.minY + (f.height - alto) / 2,
                          width: ancho, height: alto),
                   display: true)
    }

    func open() {
        // El micropanel Loom suelta cámara/mic (su vúmetro tiene sesión propia
        // sobre el mic y competiría con la del Estudio — hallazgo v1.4).
        LauncherPanelController.shared.hide(keepPreview: false)
        RecordingController.shared.bubble.hide()
        if window == nil { buildWindow() }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if !engine.isRunning {
            engine.onStatusChange = { [weak self] in self?.pullEngineStatus() }
            engine.onPreviewSurface = { [weak self] surface in
                guard let self else { return }
                self.previewView?.display(surface: surface)
                // EL ESPEJO LATE AQUÍ, en el mismo hop y con la misma cadencia
                // que el preview del Estudio. No es una optimización: es la
                // definición. Daniel lo dijo mejor que yo — "si en teoría son un
                // espejo debería verse exactamente igual de fluido". Con un
                // timer aparte los dos ritmos podían separarse, y se separaron:
                // primero el Estudio iba a 6 fps y el espejo a 30, luego al
                // revés. Colgados del mismo latido, o van los dos o no va
                // ninguno, y cualquier caída se ve en el chip de fps.
                if self.mirror.isVisible {
                    self.mirror.showFrame(self.engine.frames.get(.camera))
                }
            }
            // EL OJO: mide la imagen real 1 vez por segundo y la publica en
            // ~/.sfcam/ojo.json. Es lo que cierra el lazo del ISO (`sfcam auto`)
            // sin depender de que SFCam.app esté abierta. Lee el último frame ya
            // entregado — NO se mete en el delegate de captura.
            OjoDelEstudio.arrancar { [weak self] in self?.engine.frames.get(.camera) }
            engine.onAlert = { [weak self] msg, critical in
                self?.raiseAlert(msg, critical: critical)
            }
            recorder.onAlert = { [weak self] msg, critical in
                self?.raiseAlert(msg, critical: critical)
            }
            // La cadencia bajó (o volvió). Se avisa SIEMPRE, y encima se manda
            // notificación del sistema cuando pasa GRABANDO: el chip de fps ya
            // existía el 9 ago y no sirvió de nada porque vive en la ventana del
            // Estudio, que está en el otro monitor mientras Daniel presenta. Un
            // sensor que no alcanza al humano en el momento en que importa es un
            // sensor apagado.
            // El daño que los watchdogs detectan VIAJA AL MANIFEST, no se queda
            // en el log: el editor tiene que saber qué segundos son una foto fija.
            engine.onSourceFrozen = { [weak self] source, frozen, reason in
                self?.recorder.noteFrozen(source, frozen: frozen, reason: reason)
            }
            engine.onCadenceChange = { [weak self] efectivo, pedido in
                guard let self else { return }
                // El escalón VIAJA AL MANIFEST (v3.6). Sin esto, un archivo de 15
                // fps rellenados a 30 es indistinguible de uno de 30 reales para
                // quien lo edite después — `achievedFps` mide el relleno.
                self.recorder.cadenceChanged(efectivo, target: pedido)
                // Y si se cae al SUELO de la escalera, esto sale de la ventana:
                // Daniel graba mirando a la cámara, no el banner del otro monitor.
                // De FLANCO, no de nivel: avisar en cada escalón entrenaría a
                // ignorarlo ("un sensor que exagera se deja de leer").
                if self.recorder.isRecording, efectivo <= max(1, pedido / 2),
                   !self.cadenceFloorNotified {
                    self.cadenceFloorNotified = true
                    notify("SFCast — LA GPU NO ALCANZA",
                           "Compongo a \(efectivo) de \(pedido) fps: el archivo sale a \(pedido) "
                           + "pero repitiendo frames. La toma se va a ver a medio movimiento.")
                } else if efectivo >= pedido {
                    self.cadenceFloorNotified = false
                }
                if efectivo < pedido {
                    // OJO con el mensaje: desde el guardián de cadencia, el
                    // ARCHIVO sigue saliendo a los fps pedidos. Lo que baja es
                    // cuántos frames NUEVOS alcanza a componer la GPU. Decirle
                    // "bajé tu grabación" sería mentirle y asustarlo de gratis.
                    self.raiseAlert("La GPU va cargada: compongo a \(efectivo) fps para darle aire. "
                                    + "Tu archivo sigue saliendo a \(pedido) constantes.", critical: false)
                } else {
                    self.raiseAlert("La GPU respira: componiendo otra vez a \(efectivo) fps.",
                                    critical: false)
                }
            }
            recorder.onEmergencyStop = { [weak self] in
                guard let self, self.recorder.isRecording else { return }
                self.toggleRecord()
            }
            wireMirror()
            // El espejo necesita el canvas y la sesión de cámara: hasta que el
            // motor no arranca no hay dónde ni con qué proyectarlo.
            Task { await engine.start(config: config); pullEngineStatus(); syncMirror() }
        }
        if StudioConfig.weightFixJustApplied {
            raiseAlert("Apagué los RAW de pantalla y cámara: nada los usaba y eran ~9x el peso "
                       + "del programa. Están a un clic en Salidas si los quieres.",
                       critical: false, sticky: true)
        }
        if StudioConfig.canvasFixJustApplied {
            raiseAlert("Bajé el lienzo de «nativa del display» a 2560×1440. Medido en esta Mac: "
                       + "4K pedía el doble de memoria por píxeles que YouTube tira igual, y ese "
                       + "margen es lo que faltó el 9 ago. Reversible en Ajustes → Video.",
                       critical: false, sticky: true)
        }
        startMeters()
    }


    // MARK: - MARCADORES EN VIVO (v3.2)

    private var hotkeyRetoma: GlobalHotKey?
    private var hotkeyBueno: GlobalHotKey?
    private var hotkeyDeshacer: GlobalHotKey?
    /// Los dos contadores en la esquina de la pantalla que se graba.
    let markerHUD = MarkerHUD()
    private var cortesMarcados = 0
    private var buenosMarcados = 0

    /// ⌥C = ✂︎ "la regué, **C**orta esto" · ⌥X = ★ "esto estuvo bueno".
    ///
    /// Dos iteraciones con Daniel el 10 ago, y las dos las tenía él:
    /// 1. ⌘⇧X pedía DOS MANOS — "no lo siento práctico". Con las dos manos
    ///    ocupadas nadie marca nada a mitad de una toma.
    /// 2. ⌥X para cortar no significaba nada: *"es fácil atribuir la C a eso,
    ///    y X no entiendo qué hace"*. La mnemónica importa más que la comodidad
    ///    de un centímetro, porque esto se usa BAJO PRESIÓN, hablando a cámara:
    ///    si hay que pensar cuál era, no se usa.
    ///
    /// C de Cortar. Y ⌥X para la estrella: en cuanto la segunda marca dejó de
    /// llamarse "bueno" y pasó a ser un ICONO, la tecla ya no necesita
    /// mnemónica de palabra — le basta con ser la vecina de C.
    ///
    /// GLOBALES: cuando se traba está presentando en SFPoint, no mirando SFCast.
    /// Un atajo que exija traer la app al frente no se usaría nunca.
    ///
    /// ⚠️ **Solo vivos MIENTRAS SE GRABA.** Un hotkey global SE COME la tecla, y
    /// en macOS ⌥C escribe `ç` y ⌥X escribe `≈`: dejarlos puestos siempre le
    /// quitaría esos caracteres en TODAS sus apps a cambio de nada, porque fuera
    /// de una grabación no hay nada que marcar. Se registran al dar REC y se
    /// sueltan al detener.
    func registrarAtajosDeMarcador() {
        guard hotkeyRetoma == nil else { return }
        hotkeyRetoma = GlobalHotKey(key: kVK_ANSI_C, mods: UInt32(optionKey),
                                    descripcion: "⌥C marcar CORTE") { [weak self] in
            self?.marcar("retoma")
        }
        hotkeyBueno = GlobalHotKey(key: kVK_ANSI_X, mods: UInt32(optionKey),
                                   descripcion: "⌥X marcar ESTRELLA") { [weak self] in
            self?.marcar("bueno")
        }
        // ⌥Z = deshacer la última. Una marca puesta por error deja el dato
        // SUCIO, y una drop-list con basura es peor que no tenerla: el editor
        // la obedece. Z de "deshacer" es el idioma que ya tiene en los dedos.
        hotkeyDeshacer = GlobalHotKey(key: kVK_ANSI_Z, mods: UInt32(optionKey),
                                      descripcion: "⌥Z deshacer última marca") { [weak self] in
            self?.desmarcar()
        }
        // Y SI NO SE REGISTRARON, QUE SE ENTERE (26 ago 2026). Hasta hoy esto
        // escribía tres líneas de ERROR al log y seguía como si nada: Daniel
        // pulsaba ⌥X a mitad del curso, no pasaba nada, y se enteraba al editar
        // —o sea, cuando ya no hay remedio—. El 26 ago los tres atajos llevaban
        // TODO EL DÍA sin registrarse (una instancia zombi de SFCast los tenía
        // tomados) y ni una sola vez se lo dijimos.
        //
        // Una vez por corrida, no por toma: avisar en cada REC entrena a ignorar.
        let faltan = [hotkeyRetoma == nil ? "⌥C" : nil,
                      hotkeyBueno == nil ? "⌥X" : nil,
                      hotkeyDeshacer == nil ? "⌥Z" : nil].compactMap { $0 }
        if !faltan.isEmpty, !atajosAvisados {
            atajosAvisados = true
            let cuales = faltan.joined(separator: ", ")
            Log.error("Estudio: los atajos de marcador \(cuales) NO están activos — otra app los tiene")
            raiseAlert("Los marcadores \(cuales) no funcionan: otra app tiene esas teclas. "
                       + "Puedes marcar desde la barra del Estudio.", critical: true, sticky: true)
            notify("SFCast — marcadores sin teclas", "\(cuales) los tiene otra app. Marca desde la barra.")
        }
    }

    /// Ya se avisó en esta corrida que los atajos no se registraron.
    private var atajosAvisados = false

    /// Quita la última marca y actualiza los dos contadores.
    func desmarcar() {
        guard recorder.isRecording, recorder.unmark() != nil else { return }
        let t = recorder.markerTally
        cortesMarcados = t.cortes
        buenosMarcados = t.estrellas
        markerCount = recorder.markerCount
        meters.cortes = t.cortes
        meters.estrellas = t.estrellas
        markerHUD.update(cortes: t.cortes, buenos: t.estrellas, pulso: nil)
    }

    /// Auto-retrato de la ventana del Estudio (QA). La ventana lleva
    /// `sharingType = .none`, así que ninguna captura del sistema la ve: sin
    /// esto no hay forma de revisar su barra con un screenshot.
    @discardableResult
    func snapshotVentana(to path: String) -> Bool {
        guard let v = window?.contentView else { return false }
        let r = v.bounds
        guard let rep = v.bitmapImageRepForCachingDisplay(in: r) else { return false }
        v.cacheDisplay(in: r, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        try? png.write(to: URL(fileURLWithPath: path))
        Log.info("Estudio: retrato de la ventana en \(path)")
        return true
    }

    /// Devuelve las teclas al sistema en cuanto termina la toma.
    func soltarAtajosDeMarcador() {
        guard hotkeyRetoma != nil || hotkeyBueno != nil else { return }
        // desregistrar() ANTES del nil: poner la propiedad en nil no destruye
        // el objeto (el registro estático lo retiene) y la tecla se quedaba
        // tomada toda la vida del proceso. Ver GlobalHotKey.desregistrar().
        hotkeyRetoma?.desregistrar();  hotkeyRetoma = nil
        hotkeyBueno?.desregistrar();   hotkeyBueno = nil
        hotkeyDeshacer?.desregistrar(); hotkeyDeshacer = nil
        Log.info("Atajos de marcador liberados (⌥C y ⌥X vuelven a escribir ç y ≈)")
    }

    /// Anota el marcador y da acuse VISIBLE — sin sonido y sin nada que salga en
    /// la grabación. Si no hay acuse, Daniel no sabe si quedó y va a pulsar dos
    /// veces "por si acaso": un marcador sin confirmación no sirve.
    func marcar(_ kind: String) {
        guard recorder.isRecording else { return }
        let n = recorder.mark(kind)
        markerCount = n
        lastMarkerKind = kind
        if kind == "retoma" { cortesMarcados += 1 } else { buenosMarcados += 1 }
        meters.cortes = cortesMarcados
        meters.estrellas = buenosMarcados
        // ACUSE = ESTADO, no evento (Daniel, 10 ago: "el aro no me convence…
        // yo puedo ver ambas cosas"). El destello confirmaba la última
        // pulsación y se iba; lo que hace falta mientras hablas es saber
        // CUÁNTAS llevas de cada una sin acordarte. El pulso del número sigue
        // diciendo "esta llegó".
        markerHUD.update(cortes: cortesMarcados, buenos: buenosMarcados, pulso: kind)
    }

    /// El modo Loom arranca → el Estudio se hace a un lado (misma regla que el
    /// micropanel: una sola dueña de cámara/mic a la vez). Si el Estudio está
    /// GRABANDO no se llega aquí (los start* del Loom lo guardan antes).
    func closeForLoom() {
        guard isOpen || engine.isRunning else { return }
        // El espejo se va PRIMERO: cuelga de la sesión de cámara del Estudio,
        // que el Loom está a punto de quedarse (una sola dueña a la vez).
        mirror.hide()
        window?.orderOut(nil)
        OjoDelEstudio.detener()
        Task { await engine.stop() }
        stopMeters()
    }

    func windowWillClose(_ notification: Notification) {
        mirror.hide()
        stopMeters()
        if recorder.isRecording {
            Task {
                _ = await recorder.stop(engine: engine, config: config)
                await engine.stop()
            }
        } else {
            Task { await engine.stop() }
        }
        let othersVisible = NSApp.windows.contains {
            $0 !== window && $0.isVisible && $0.styleMask.contains(.titled)
        }
        if !othersVisible { NSApp.setActivationPolicy(.accessory) }
    }

    // MARK: - QA headless (--studiotest N): evidencia sin permisos del sistema
    //
    // Graba N segundos con la config REAL (patrón de prueba garantizado + cámara
    // si hay permiso + pantalla si hay permiso), hace un switch de escena EN VIVO
    // a la mitad (queda en el timeline del manifest), y deja como evidencia:
    // PNG del frame de programa por cada escena (compositor real) + PNG de la
    // ventana (self-render) + el listado de archivos de la sesión.
    func runTest(seconds: Int) async {
        testMode = true
        // La config del usuario NO se toca: backup de scenes.json y restore al
        // salir (selectScene persiste — sin esto el QA pisaba los presets).
        let cfgFile = StudioConfig.file
        let backup = try? Data(contentsOf: cfgFile)
        let restoreConfig = {
            if let backup { try? backup.write(to: cfgFile) }
            else { try? FileManager.default.removeItem(at: cfgFile) }
        }
        var cfg = StudioConfig(scenes: [], activeSceneID: nil)
        let a = StudioScene(name: "QA Patrón", items: [SceneItem(kind: .testPattern)])
        let b = StudioScene(name: "QA Mix", items: [
            SceneItem(kind: .testPattern),
            SceneItem(kind: .screen,
                      rect: CGRect(x: 0.55, y: 0.52, width: 0.42, height: 0.42), fit: .fit),
            SceneItem(kind: .camera,
                      rect: CGRect(x: 0.04, y: 0.06, width: 0.22, height: 0.4),
                      fit: .fill, circleMask: true),
        ])
        cfg.scenes = [a, b]
        cfg.activeSceneID = a.id
        config = cfg
        open()
        try? await Task.sleep(nanoseconds: 2_500_000_000)   // que lleguen frames
        do {
            try recorder.start(engine: engine, config: config, activeScene: activeScene)
            isRecording = true
        } catch {
            print("STUDIOTEST_FAIL start: \(error.localizedDescription)")
            restoreConfig()
            exit(1)
        }
        let flow0 = engine.flowCounts()
        let flowT0 = CACurrentMediaTime()
        let half = UInt64(max(1, seconds / 2)) * 1_000_000_000
        try? await Task.sleep(nanoseconds: half)
        writeFramePNG(name: "studiotest-frame-a.png")
        selectScene(b.id)                                    // switch EN VIVO
        try? await Task.sleep(nanoseconds: half)
        writeFramePNG(name: "studiotest-frame-b.png")
        // FLUJO medido (v2.8): cámara entrando y preview pintado, en fps.
        // Es el sensor del "preview a 3 fps" — sin él, un preview muriendo
        // de hambre pasa cualquier QA porque el archivo sale perfecto.
        let flow = engine.flowCounts()
        let dt = max(CACurrentMediaTime() - flowT0, 0.001)
        print(String(format: "STUDIOTEST_FLOW cam=%.1ffps prev=%.1ffps prevTirados=%d",
                     Double(flow.camera - flow0.camera) / dt,
                     Double(flow.previewDelivered - flow0.previewDelivered) / dt,
                     flow.previewDropped - flow0.previewDropped))
        let dir = await recorder.stop(engine: engine, config: config)
        isRecording = false
        saveWindowShot(to: dir)
        guard let dir else {
            print("STUDIOTEST_FAIL sin sesión")
            restoreConfig()
            exit(1)
        }
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
        print("STUDIOTEST_OK dir=\(dir.path)")
        print("STUDIOTEST_FILES \(files.joined(separator: ","))")
        await engine.stop()
        restoreConfig()
        exit(0)
    }

    /// QA de PESO (`--studiobench N`): graba N segundos con la config REAL de
    /// Daniel (sus escenas, sus salidas, su calidad) y reporta MB y Mbps por
    /// archivo. Existe porque el bug del 25 jul (6 GB donde OBS hace 334 MB) era
    /// invisible sin una medición: la app nunca decía cuánto pesaba lo que
    /// escribía. Ahora el número se mide, no se supone.
    /// QA DEL ARCHIVO (`--rectest N`): graba y verifica el MP4 resultante.
    func runRecTest(seconds: Int) async {
        testMode = true
        open()
        // Respiro para que las fuentes entreguen frames y el store junte
        // muestras de latencia: sin eso el reloj arrancaría sin corrección y el
        // test mediría un caso que no ocurre en la vida real (Daniel abre el
        // Estudio, se acomoda, y luego graba).
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        await StudioRecTest.run(seconds: seconds, engine: engine, recorder: recorder,
                                config: config, scene: activeScene)
    }

    /// QA de TOMAS ENCADENADAS (`--tomas N`): el arnés que faltaba. Ver
    /// StudioTomasTest para el porqué.
    func runTomasTest(tomas: Int, dura: Int, pausa: Int) async {
        testMode = true
        open()
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        await StudioTomasTest.run(tomas: tomas, dura: dura, pausaBase: pausa, engine: engine,
                                  recorder: recorder, config: config, scene: activeScene)
    }

    /// QA de SINCRONÍA (`--synctest N`): abre el motor, deja que las fuentes
    /// entreguen frames, y reporta la latencia MEDIDA de cada una. No graba.
    func runSyncTest(seconds: Int) async {
        testMode = true
        open()
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        await StudioSyncTest.run(seconds: seconds, engine: engine)
        exit(0)
    }

    func runBench(seconds: Int) async {
        testMode = true
        AudioMath.traceAudio = true
        open()
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        print("BENCH canvas=\(Int(engine.canvasSize.width))x\(Int(engine.canvasSize.height))@\(engine.fps) "
              + "calidad=\(config.programQuality.rawValue) cq=\(config.programQuality.usesConstantQuality) "
              + "pantalla=\(engine.screenAvailable) camara=\(engine.cameraAvailable) "
              + "salidas=[raw:\(config.outputs.rawScreen) cam:\(config.outputs.rawCamera) prog:\(config.outputs.program)]")
        guard engine.screenAvailable else {
            print("BENCH_FAIL sin-permiso-de-pantalla")
            exit(3)
        }
        do {
            try recorder.start(engine: engine, config: config, activeScene: activeScene)
            isRecording = true
        } catch {
            print("BENCH_FAIL start: \(error.localizedDescription)")
            exit(1)
        }
        let flow0 = engine.flowCounts()
        let flowT0 = CACurrentMediaTime()
        // Movimiento real en pantalla: sin esto medimos un caso irreal (una
        // pantalla 100% quieta comprime a casi nada en CUALQUIER encoder).
        // De paso muestreamos el vúmetro: el bug de la línea fija solo se ve si
        // uno MIRA el valor crudo a lo largo del tiempo.
        var micMin: Float = 1, micMax: Float = 0, micSum: Float = 0, micN = 0
        let killAt = CommandLine.arguments.contains("--killstream") ? (seconds * 5) / 3 : -1
        for i in 0..<(seconds * 5) {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if i == killAt { await engine.simulateStreamDeath() }
            let l = engine.levels.get().mic
            micMin = min(micMin, l); micMax = max(micMax, l); micSum += l; micN += 1
            if i % 10 == 0 { selectScene(config.scenes[(i / 10) % config.scenes.count].id) }
        }
        print(String(format: "BENCH_MIC min=%.4f max=%.4f avg=%.4f muestras=%d rango=%.4f",
                     micMin, micMax, micSum / Float(max(micN, 1)), micN, micMax - micMin))
        Log.info(String(format: "BENCH_MIC min=%.4f max=%.4f avg=%.4f rango=%.4f",
                        micMin, micMax, micSum / Float(max(micN, 1)), micMax - micMin))
        let beats = engine.screenHealth.beats()
        let silence = engine.screenHealth.silence()
        // FLUJO medido (v2.8): el sensor que le faltaba al "preview a 3 fps".
        let flow = engine.flowCounts()
        let flowDT = max(CACurrentMediaTime() - flowT0, 0.001)
        let benchFlow = String(format: "BENCH_FLOW cam=%.1ffps prev=%.1ffps prevTirados=%d",
                               Double(flow.camera - flow0.camera) / flowDT,
                               Double(flow.previewDelivered - flow0.previewDelivered) / flowDT,
                               flow.previewDropped - flow0.previewDropped)
        print(benchFlow)
        Log.info(benchFlow)
        let dir = await recorder.stop(engine: engine, config: config)
        isRecording = false
        guard let dir else { print("BENCH_FAIL sin-sesion"); exit(1) }
        print(String(format: "BENCH_SALUD latidos video=%d audio=%d silencio=%.2fs reenganches=%d congelada=%@",
                     beats.video, beats.audio, silence, engine.screenRestarts,
                     engine.screenFrozen ? "SI" : "no"))
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
        var total: Int64 = 0
        for f in files where f.hasSuffix(".mp4") || f.hasSuffix(".mov") {
            let p = (dir.path as NSString).appendingPathComponent(f)
            let size = ((try? FileManager.default.attributesOfItem(atPath: p))?[.size] as? NSNumber)?.int64Value ?? 0
            total += size
            print(String(format: "BENCH_FILE %@ %.1f MB %.2f Mbps",
                         f, Double(size) / 1_000_000, Double(size) * 8 / Double(seconds) / 1_000_000))
        }
        print(String(format: "BENCH_TOTAL %.1f MB en %ds = %.2f Mbps → %.2f GB/hora",
                     Double(total) / 1_000_000, seconds,
                     Double(total) * 8 / Double(seconds) / 1_000_000,
                     Double(total) / Double(seconds) * 3600 / 1_000_000_000))
        print("BENCH_DIR \(dir.path)")
        await engine.stop()
        exit(0)
    }

    /// QA VISUAL del aro (`--glowtest`): compone un frame por cada color con la
    /// cámara en burbuja y otro en rectángulo, y deja los PNG. Un aro no se
    /// valida leyendo código: se valida MIRÁNDOLO.
    func runGlowTest() async {
        testMode = true
        let cfgFile = StudioConfig.file
        let backup = try? Data(contentsOf: cfgFile)
        var cfg = StudioConfig(scenes: [], activeSceneID: nil)
        let base = SceneItem(kind: .testPattern)
        var scenes: [StudioScene] = []
        for g in SceneGlow.allCases {
            for circle in [true, false] {
                var cam = SceneItem(kind: .camera,
                                    rect: CGRect(x: 0.62, y: 0.28, width: 0.30, height: 0.45),
                                    fit: .fill, circleMask: circle)
                cam.glow = g
                scenes.append(StudioScene(name: "\(g.rawValue)-\(circle ? "burbuja" : "rect")",
                                          items: [base, cam]))
            }
        }
        cfg.scenes = scenes
        cfg.activeSceneID = scenes.first?.id
        config = cfg
        open()
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        let out = URL(fileURLWithPath: "/tmp/sfcast-glow")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for s in scenes {
            selectScene(s.id)
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let pb = engine.snapshotProgramFrame() else { continue }
            let url = out.appendingPathComponent("\(s.name).png")
            let ctx = CIContext()
            if let cs = CGColorSpace(name: CGColorSpace.sRGB),
               let data = ctx.pngRepresentation(of: CIImage(cvPixelBuffer: pb),
                                                format: .BGRA8, colorSpace: cs) {
                try? data.write(to: url)
                print("GLOWTEST \(url.path)")
            }
        }
        // COSTO por frame. El aro añade trabajo al render loop, así que hay que
        // medirlo, no suponerlo: caso cacheado (lo normal) y peor caso (el item
        // se mueve, o sea cache miss en CADA frame — arrastrarlo en el preview).
        func bench(_ label: String, moving: Bool) {
            guard let s = scenes.first(where: { $0.name.contains("morado") }) else { return }
            selectScene(s.id)
            let t0 = CACurrentMediaTime()
            let n = 120
            for i in 0..<n {
                if moving {
                    updateItem(s.items[1].id) { $0.rect.origin.x = 0.62 + Double(i % 40) * 0.002 }
                    pushActiveSceneNow()
                }
                _ = engine.snapshotProgramFrame()
            }
            let ms = (CACurrentMediaTime() - t0) / Double(n) * 1000
            Log.info(String(format: "GLOWTEST_PERF %@ %.2f ms/frame (presupuesto a 30fps: 33.3)", label, ms))
        }
        if let s = scenes.first(where: { $0.name.contains("nada") }) {
            selectScene(s.id)
            let t0 = CACurrentMediaTime()
            for _ in 0..<120 { _ = engine.snapshotProgramFrame() }
            Log.info(String(format: "GLOWTEST_PERF sin-aro %.2f ms/frame",
                            (CACurrentMediaTime() - t0) / 120 * 1000))
        }
        bench("con-aro-cacheado", moving: false)
        bench("con-aro-moviendose", moving: true)

        // Foto de la VENTANA con la cámara seleccionada: el panel Fuentes mide
        // 235px y le acabo de meter una fila. Un desbordamiento en SwiftUI no
        // avisa — hay que mirarlo.
        if let s = scenes.first(where: { $0.name == "morado-burbuja" }) {
            selectScene(s.id)
            selectedItemID = s.items.last?.id
            try? await Task.sleep(nanoseconds: 900_000_000)
            saveWindowShot(to: out)
        }

        await engine.stop()
        if let backup { try? backup.write(to: cfgFile) } else { try? FileManager.default.removeItem(at: cfgFile) }
        print("GLOWTEST_OK \(out.path)")
        exit(0)
    }

    /// QA DEL ESPEJO (`--mirrortest N`) — lo que lo hace foso y no adorno.
    ///
    /// Mide CUATRO cosas con números, sobre la config REAL (las escenas de
    /// Daniel, su monitor, su cámara):
    ///
    ///  1. **INVISIBILIDAD** — la que de verdad importa. Compara el frame de
    ///     PANTALLA con el espejo apagado y prendido, en el mismísimo recorte
    ///     donde vive la burbuja. Si `sharingType = .none` fallara, ahí saldría
    ///     un aro morado y una cara, y en el video final la cara saldría
    ///     DUPLICADA (el panel real + la burbuja compuesta encima). Es la clase
    ///     de bug que si no se mide, se descubre viendo la grabación al día
    ///     siguiente — o sea, tarde.
    ///  2. **ALINEACIÓN** — dónde dice el espejo que está vs dónde cae la
    ///     burbuja según la geometría del programa, en píxeles.
    ///  3. **ARRASTRE** — ejerce el camino real (dragBegan→dragMoved→dragEnded,
    ///     no el setter) y verifica que el rect de escena Y el panel se
    ///     movieron lo mismo, y que quedó persistido.
    ///  4. **COSTO** — fps de cámara y preview con el espejo encima. Lo que no
    ///     se mide se degrada en silencio (v2.7/v2.8).
    ///
    /// Y de paso imprime el sensor de oclusión en tres posiciones distintas,
    /// para calibrar el umbral con evidencia y no a ojo.
    /// Evidencia del QA a DOS canales: stdout (corrida desde terminal) y el log
    /// de la app. El runbook manda correr el QA con `open` — TCC se atribuye al
    /// proceso responsable, no al binario — y `open` NO reenvía stdout: sin la
    /// segunda vía, los números de la prueba se perdían en el aire.
    private func qa(_ s: String) { print(s); Log.info(s) }

    func runMirrorTest(seconds: Int) async {
        let out = URL(fileURLWithPath: "/tmp/sfcast-espejo")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        // RESPALDO COMPLETO de las escenas, restaurado al salir pase lo que pase.
        // Restaurar solo el rect que el test toca NO basta: el 9 ago varias
        // corridas seguidas le fueron dejando la burbuja de Daniel a 180 px en
        // el centro, porque cada una "restauraba" al valor con el que la anterior
        // la había dejado. Un QA que erosiona la config del usuario es un QA que
        // nadie va a querer correr.
        let cfgFile = StudioConfig.file
        let cfgBackup = try? Data(contentsOf: cfgFile)
        let restoreConfig = { if let cfgBackup { try? cfgBackup.write(to: cfgFile) } }
        // OJO: aquí NO se pone testMode. La ventana del Estudio debe quedarse
        // invisible a la captura, o se metería en el recorte que estamos
        // midiendo y ensuciaría justo la medición que vinimos a hacer.
        open()
        try? await Task.sleep(nanoseconds: 3_500_000_000)
        guard engine.screenAvailable else { restoreConfig(); qa("MIRRORTEST_FAIL sin-permiso-de-pantalla"); exit(3) }
        guard engine.cameraAvailable else { restoreConfig(); qa("MIRRORTEST_FAIL sin-camara"); exit(3) }

        // La escena del caso real: pantalla + cámara en burbuja circular.
        guard let burbuja = config.scenes.first(where: { s in
            s.items.contains(where: { $0.kind == .screen && $0.enabled })
                && s.items.contains(where: { $0.kind == .camera && $0.enabled && $0.circleMask })
        }) else { restoreConfig(); qa("MIRRORTEST_FAIL sin-escena-de-burbuja"); exit(2) }
        selectScene(burbuja.id)
        try? await Task.sleep(nanoseconds: 800_000_000)

        let screen = RecordingController.captureScreen()
        qa("MIRRORTEST escena='\(burbuja.name)' "
              + "canvas=\(Int(engine.canvasSize.width))x\(Int(engine.canvasSize.height)) "
              + "display=\(Int(screen?.frame.width ?? 0))x\(Int(screen?.frame.height ?? 0))pt "
              + "@\(screen?.backingScaleFactor ?? 0)x displays=\(NSScreen.screens.count) "
              + "camara='\(engine.cameraDeviceName ?? "ninguna")'")

        // LÍNEA BASE del flujo, tomada ANTES de que el espejo exista siquiera.
        // Es la referencia contra la que se juzgan las otras dos ventanas.
        func medirFlujo(segundos: Int) async -> (Double, Double, Int) {
            let a = engine.flowCounts()
            let t = CACurrentMediaTime()
            try? await Task.sleep(nanoseconds: UInt64(max(1, segundos)) * 1_000_000_000)
            let b = engine.flowCounts()
            let dt = max(CACurrentMediaTime() - t, 0.001)
            return (Double(b.camera - a.camera) / dt,
                    Double(b.previewDelivered - a.previewDelivered) / dt,
                    b.previewDropped - a.previewDropped)
        }

        // El recorte a vigilar, en px de la FUENTE de pantalla.
        let wasOn = config.mirrorEnabled
        if wasOn { config.mirrorEnabled = false; mirror.hide() }
        syncMirror()
        let (camAntes, prevAntes, _) = await medirFlujo(segundos: 3)
        guard let camItem = burbuja.items.last(where: { $0.kind == .camera && $0.enabled }),
              let scrItem = burbuja.items.first(where: { $0.kind == .screen && $0.enabled }),
              let screen, let geo = MirrorGeometry(canvas: engine.canvasSize,
                                                   screenItem: scrItem, screen: screen)
        else { restoreConfig(); qa("MIRRORTEST_FAIL sin-geometria"); exit(2) }
        let watch = geo.sourceRect(fromCanvas: geo.canvasRect(of: camItem))

        // ── 1. INVISIBILIDAD ──────────────────────────────────────────────
        //
        // Comparar el recorte de la burbuja apagado vs prendido NO basta: la
        // pantalla de abajo es un escritorio VIVO (un chat que escribe, un
        // spinner, el reloj), y en una corrida del 9 ago ese movimiento solo
        // levantó el promedio 0.051 y el test gritó FUGA sin que nada se hubiera
        // colado. Un detector que confunde "cambió la pantalla" con "se coló el
        // panel" no sirve para lo único que tiene que decidir.
        //
        // La cura es una REGIÓN DE CONTROL del mismo tamaño donde el espejo
        // JAMÁS cae. Si las dos regiones se mueven igual, es la pantalla; si
        // solo se mueve la de la burbuja, es fuga. Se mide la DIFERENCIA de
        // diferencias, no un valor absoluto.
        let control = CGRect(x: geo.sourcePixels.width - watch.maxX, y: watch.minY,
                             width: watch.width, height: watch.height)
        func sample(_ n: Int) async -> (bubble: SIMD3<Double>, ctrl: SIMD3<Double>) {
            var b = SIMD3<Double>(), c = SIMD3<Double>()
            var got = 0.0
            for _ in 0..<n {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let pb = engine.frames.get(.screen),
                      let mb = MirrorProbe.meanRGB(of: pb, rect: watch),
                      let mc = MirrorProbe.meanRGB(of: pb, rect: control) else { continue }
                b += SIMD3(mb.r, mb.g, mb.b)
                c += SIMD3(mc.r, mc.g, mc.b)
                got += 1
            }
            let d = max(got, 1)
            return (b / d, c / d)
        }
        // Y aun con región de control, UN ciclo apagado→prendido no basta: si la
        // pantalla se mueve fuerte justo entre las dos muestras (un build
        // scrolleando, por ejemplo: deriva medida de 0.1577 sobre 1.0), el ruido
        // se reparte distinto entre las dos regiones y el neto sale sucio.
        // Por eso se ALTERNA varias veces: una fuga es un desvío del MISMO signo
        // cada vez que el espejo está encendido, mientras que el ruido de la
        // pantalla no está correlacionado con el interruptor y se cancela.
        var netos: [SIMD3<Double>] = []
        var derivas: [Double] = []
        for ciclo in 0..<4 {
            config.mirrorEnabled = false
            syncMirror()
            try? await Task.sleep(nanoseconds: 700_000_000)
            let off = await sample(3)
            if ciclo == 0, let pb = engine.frames.get(.screen) {
                MirrorProbe.writeCrop(pb, rect: watch,
                                      to: out.appendingPathComponent("captura-espejo-apagado.png"))
            }
            config.mirrorEnabled = true
            syncMirror()
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard mirror.isVisible else {
                qa("MIRRORTEST_FAIL el-espejo-no-se-mostro (\(mirror.unavailable?.reason ?? "?"))")
                exit(1)
            }
            let on = await sample(3)
            if ciclo == 0, let pb = engine.frames.get(.screen) {
                MirrorProbe.writeCrop(pb, rect: watch,
                                      to: out.appendingPathComponent("captura-espejo-prendido.png"))
                // Auto-retrato del panel: la ÚNICA forma de VER el espejo,
                // porque por diseño ningún screenshot del sistema lo captura.
                mirror.qaSelfShot(to: out.appendingPathComponent("espejo-panel.png"))
            }
            let dCtrl = on.ctrl - off.ctrl
            netos.append((on.bubble - off.bubble) - dCtrl)
            derivas.append((abs(dCtrl.x) + abs(dCtrl.y) + abs(dCtrl.z)) / 3)
        }
        var suma = SIMD3<Double>()
        for n in netos { suma += n }
        let neto = suma / Double(netos.count)
        let deriva = derivas.reduce(0, +) / Double(derivas.count)
        let leak = max(abs(neto.x), max(abs(neto.y), abs(neto.z)))
        // Si la pantalla se movió MUCHO, la medición no concluye — y lo dice.
        // Un test que grita "fuga" por ruido acabaría ignorado, que es la única
        // forma de que un test de seguridad no sirva para nada.
        let veredicto = leak < 0.02 ? "INVISIBLE" : (deriva > 0.05 ? "INCONCLUSO (pantalla muy movida; repítelo en reposo)" : "FUGA")
        qa(String(format: "MIRRORTEST_INVISIBLE ciclos=%d fuga_neta=(%.4f,%.4f,%.4f) max=%.4f "
                     + "deriva_pantalla=%.4f veredicto=%@",
                     netos.count, neto.x, neto.y, neto.z, leak, deriva, veredicto))

        // ── 2. ALINEACIÓN ─────────────────────────────────────────────────
        let esperado = geo.screenRect(fromCanvas: geo.canvasRect(of: camItem))
        let real = mirror.screenRect ?? .zero
        let dx = abs(real.minX - esperado.minX), dy = abs(real.minY - esperado.minY)
        let dw = abs(real.width - esperado.width), dh = abs(real.height - esperado.height)
        qa(String(format: "MIRRORTEST_ALINEACION esperado=(%.1f,%.1f %.1fx%.1f) real=(%.1f,%.1f %.1fx%.1f) "
                     + "delta=(%.2f,%.2f %.2fx%.2f) veredicto=%@",
                     esperado.minX, esperado.minY, esperado.width, esperado.height,
                     real.minX, real.minY, real.width, real.height, dx, dy, dw, dh,
                     max(max(dx, dy), max(dw, dh)) < 1.0 ? "OK" : "DESALINEADO"))

        // ── 3. ARRASTRE (el camino real, no el setter) ────────────────────
        let antesRect = camItem.rect
        let antesPanel = mirror.screenRect ?? .zero
        writeFramePNG(name: "espejo-programa-antes.png", dir: out)
        let delta = CGSize(width: -220, height: 160)
        mirror.qaDrag(byScreenDelta: delta)
        try? await Task.sleep(nanoseconds: 600_000_000)
        let despuesRect = activeScene?.items.first(where: { $0.id == camItem.id })?.rect ?? .zero
        let despuesPanel = mirror.screenRect ?? .zero
        writeFramePNG(name: "espejo-programa-despues.png", dir: out)
        let panelMovio = CGSize(width: despuesPanel.minX - antesPanel.minX,
                                height: despuesPanel.minY - antesPanel.minY)
        // El rect de escena tiene que haberse movido lo que pide la geometría…
        let esperadoNorm = geo.normalizedDelta(fromScreen: delta)
        let normMovio = CGSize(width: despuesRect.minX - antesRect.minX,
                               height: despuesRect.minY - antesRect.minY)
        let errNorm = max(abs(normMovio.width - esperadoNorm.width),
                          abs(normMovio.height - esperadoNorm.height))
        // …y el panel tiene que haber seguido al rect, no al mouse.
        let errPanel = max(abs(panelMovio.width - delta.width), abs(panelMovio.height - delta.height))
        // ¿Y quedó PERSISTIDO? (soltar el mouse escribe scenes.json una vez)
        let enDisco = (try? JSONDecoder().decode(StudioConfig.self, from: Data(contentsOf: StudioConfig.file)))?
            .scenes.first(where: { $0.id == burbuja.id })?
            .items.first(where: { $0.id == camItem.id })?.rect ?? .zero
        let errDisco = max(abs(enDisco.minX - despuesRect.minX), abs(enDisco.minY - despuesRect.minY))
        qa(String(format: "MIRRORTEST_ARRASTRE pedido=(%.0f,%.0f)pt panel=(%.1f,%.1f)pt err_panel=%.2fpt "
                     + "rect=(%.4f,%.4f)→(%.4f,%.4f) err_norm=%.5f persistido=%@ veredicto=%@",
                     delta.width, delta.height, panelMovio.width, panelMovio.height, errPanel,
                     antesRect.minX, antesRect.minY, despuesRect.minX, despuesRect.minY, errNorm,
                     errDisco < 0.0001 ? "si" : "NO",
                     (errPanel < 1.5 && errNorm < 0.0005 && errDisco < 0.0001) ? "OK" : "FALLA"))
        // ── 3b. TAMAÑOS DEL LOOM ──────────────────────────────────────────
        // Los chips piden un DIÁMETRO en puntos de pantalla (el idioma del
        // Loom) y eso tiene que volver como rect normalizado de escena: es la
        // inversa de la geometría, ejercida en el sentido contrario al del
        // arrastre. Si esta y aquella no cierran, la burbuja crecería distinto
        // de como se mueve.
        var tallas: [String] = []
        var tallasOK = true
        for s in CameraBubble.Size.allCases where s != .full {
            mirror.applySize(s)
            try? await Task.sleep(nanoseconds: 350_000_000)
            let real = mirror.currentDiameter ?? -1
            let err = abs(real - s.diameter)
            if err > 1.0 { tallasOK = false }
            tallas.append(String(format: "%@=%.1f/%.0f", s.rawValue, real, s.diameter))
        }
        mirror.applySize(.full)
        try? await Task.sleep(nanoseconds: 350_000_000)
        // PARIDAD a tamaño completo (Daniel, 9 ago: "en el preview no veo el
        // glow, el que sí tenemos en la cámara"). Se guardan las DOS caras del
        // mismo instante — el frame del programa y el auto-retrato del panel —
        // para poder ponerlas una al lado de la otra.
        writeFramePNG(name: "espejo-completo-programa.png", dir: out)
        mirror.qaSelfShot(to: out.appendingPathComponent("espejo-completo-panel.png"))
        let full = mirror.screenRect ?? .zero
        let fullEsperado = (screen.visibleFrame.width * 0.72)
        let fullErr = abs(full.width - fullEsperado)
        let circuloTrasFull = activeScene?.items.first(where: { $0.id == camItem.id })?.circleMask ?? true
        if fullErr > 1.5 || circuloTrasFull { tallasOK = false }
        qa(String(format: "MIRRORTEST_TAMANOS %@ completo=%.1f/%.0f circuloApagado=%@ veredicto=%@",
                  tallas.joined(separator: " "), full.width, fullEsperado,
                  circuloTrasFull ? "NO" : "si", tallasOK ? "OK" : "FALLA"))

        // ── 3c. VOLVER DE "COMPLETO" A SU SITIO ───────────────────────────
        // "Completo" centra la burbuja por definición. Volver a S/M/L tiene que
        // devolverla a DONDE ESTABA, no dejarla plantada en el centro (Daniel,
        // 9 ago). Se prueba el viaje redondo entero.
        updateItem(camItem.id) { $0.rect = antesRect; $0.circleMask = camItem.circleMask }
        try? await Task.sleep(nanoseconds: 300_000_000)
        let centroAntes = mirror.screenRect.map { CGPoint(x: $0.midX, y: $0.midY) } ?? .zero
        mirror.applySize(.full)
        try? await Task.sleep(nanoseconds: 350_000_000)
        mirror.applySize(.l)
        try? await Task.sleep(nanoseconds: 350_000_000)
        let centroDespues = mirror.screenRect.map { CGPoint(x: $0.midX, y: $0.midY) } ?? .zero
        let errCentro = max(abs(centroDespues.x - centroAntes.x), abs(centroDespues.y - centroAntes.y))
        qa(String(format: "MIRRORTEST_VUELTA centro=(%.0f,%.0f) tras completo→L=(%.0f,%.0f) err=%.1fpt veredicto=%@",
                  centroAntes.x, centroAntes.y, centroDespues.x, centroDespues.y, errCentro,
                  errCentro < 1.5 ? "OK" : "SE-QUEDO-EN-EL-CENTRO"))

        // ── 3d. VOLTEO HORIZONTAL, en el programa Y en el espejo ──────────
        updateItem(camItem.id) { $0.rect = antesRect; $0.circleMask = camItem.circleMask }
        try? await Task.sleep(nanoseconds: 300_000_000)
        writeFramePNG(name: "espejo-sin-voltear.png", dir: out)
        let flipAntes = activeScene?.items.first(where: { $0.id == camItem.id })?.flipH ?? false
        mirror.onFlip?()
        try? await Task.sleep(nanoseconds: 400_000_000)
        let flipDespues = activeScene?.items.first(where: { $0.id == camItem.id })?.flipH ?? false
        writeFramePNG(name: "espejo-volteado.png", dir: out)
        mirror.qaSelfShot(to: out.appendingPathComponent("espejo-volteado-panel.png"))
        let enDiscoFlip = (try? JSONDecoder().decode(StudioConfig.self, from: Data(contentsOf: StudioConfig.file)))?
            .scenes.first(where: { $0.id == burbuja.id })?
            .items.first(where: { $0.id == camItem.id })?.flipH
        qa("MIRRORTEST_VOLTEO \(flipAntes) → \(flipDespues) persistido=\(enDiscoFlip == flipDespues ? "si" : "NO") "
           + "veredicto=\(flipDespues != flipAntes && enDiscoFlip == flipDespues ? "OK" : "FALLA")")
        mirror.onFlip?()   // dejarlo como estaba

        // devolver la burbuja a como estaba: el QA no le mueve las escenas a nadie
        updateItem(camItem.id) { $0.rect = antesRect; $0.circleMask = camItem.circleMask }
        try? await Task.sleep(nanoseconds: 400_000_000)

        // ── 4. COSTO: fps antes / con espejo / después ────────────────────
        // Un "cuesta poco" sin línea base no es una medición, es una opinión.
        // TRES ventanas, en este orden, y el DESPUÉS es tan importante como el
        // durante: prendido → apagado tiene que devolver la cámara a como
        // estaba. Con el preview layer colgado de la sesión y la ventana
        // escondida, ese tercer tramo medía cam=0 (la sesión estrangulada) y el
        // programa se habría quedado con la cara congelada. Sin el tramo
        // "después" el bug era invisible: los dos primeros salían perfectos.
        let secs = max(3, seconds)
        config.mirrorEnabled = true
        syncMirror()
        try? await Task.sleep(nanoseconds: 700_000_000)
        let (camOn, prevOn, tirOn) = await medirFlujo(segundos: secs)
        config.mirrorEnabled = false
        mirror.hide()
        syncMirror()
        try? await Task.sleep(nanoseconds: 700_000_000)
        let (camOff, prevOff, tirOff) = await medirFlujo(segundos: secs)
        let sano = camOff > camAntes * 0.7 && prevOff > prevAntes * 0.7
        qa(String(format: "MIRRORTEST_FLUJO antes: cam=%.1f prev=%.1f | espejo: cam=%.1f prev=%.1f tirados=%d "
                  + "| despues: cam=%.1f prev=%.1f tirados=%d | costo_preview=%.1ffps "
                  + "veredicto=%@",
                  camAntes, prevAntes, camOn, prevOn, tirOn, camOff, prevOff, tirOff,
                  prevAntes - prevOn,
                  sano ? "SIN-SECUELAS" : "LA-CAMARA-NO-VOLVIO"))

        saveWindowShot(to: out)
        mirror.hide()
        await engine.stop()
        restoreConfig()          // las escenas quedan EXACTAMENTE como estaban
        qa("MIRRORTEST_OK \(out.path)")
        exit(0)
    }

    /// QA VISUAL del espejo (`--mirrorlook N`): lo muestra N segundos CAPTURABLE
    /// para poder revisar el diseño con un screenshot, y lo pasea por los cuatro
    /// tamaños del Loom. Existe por el mismo motivo que `--paneltest` para el
    /// pill: lo que es invisible a la captura por diseño también es invisible
    /// para quien quiere mirarlo. No graba nada y no toca las escenas.
    func runMirrorLook(seconds: Int) async {
        StudioMirror.capturableForQA = true
        open()
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        guard let burbuja = config.scenes.first(where: { s in
            s.items.contains(where: { $0.kind == .screen && $0.enabled })
                && s.items.contains(where: { $0.kind == .camera && $0.enabled && $0.circleMask })
        }) else { qa("MIRRORLOOK_FAIL sin-escena-de-burbuja"); exit(2) }
        let cfgBackup = try? Data(contentsOf: StudioConfig.file)
        selectScene(burbuja.id)
        let wasOn = config.mirrorEnabled
        config.mirrorEnabled = true
        syncMirror()
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        qa("MIRRORLOOK visible=\(mirror.isVisible) rect=\(mirror.screenRect.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "-") "
           + "camara='\(engine.cameraDeviceName ?? "ninguna")'")
        // La barra del Estudio CON el espejo prendido: el botón tiene que verse
        // encendido de un vistazo (la ventana es sharingType=.none, así que la
        // única forma de revisarlo es el auto-render).
        let outLook = URL(fileURLWithPath: "/tmp/sfcast-espejo")
        try? FileManager.default.createDirectory(at: outLook, withIntermediateDirectories: true)
        saveWindowShot(to: outLook, name: "barra-espejo-prendido.png")
        config.mirrorEnabled = false
        syncMirror()
        try? await Task.sleep(nanoseconds: 600_000_000)
        saveWindowShot(to: outLook, name: "barra-espejo-apagado.png")
        config.mirrorEnabled = true
        syncMirror()
        try? await Task.sleep(nanoseconds: 600_000_000)
        let paso = UInt64(max(1, seconds)) * 1_000_000_000 / 4
        for s in CameraBubble.Size.allCases {
            mirror.applySize(s)
            qa("MIRRORLOOK tamaño=\(s.rawValue) diametro=\(mirror.currentDiameter.map { String(format: "%.0f", $0) } ?? "-")")
            try? await Task.sleep(nanoseconds: paso)
        }
        config.mirrorEnabled = wasOn
        mirror.hide()
        await engine.stop()
        // Las escenas se devuelven TAL CUAL: el paseo de tamaños las movió.
        if let cfgBackup { try? cfgBackup.write(to: StudioConfig.file) }
        qa("MIRRORLOOK_OK")
        exit(0)
    }

    /// Empuja la escena activa al motor SIN pasar por el ciclo de SwiftUI
    /// (el QA de rendimiento necesita que el cambio llegue en el mismo frame).
    private func pushActiveSceneNow() { engine.setActiveScene(activeScene) }

    private func writeFramePNG(name: String, dir customDir: URL? = nil) {
        guard let pb = engine.snapshotProgramFrame() else {
            print("STUDIOTEST_WARN sin frame de programa para \(name)")
            return
        }
        let img = CIImage(cvPixelBuffer: pb)
        let ctx = CIContext()
        let dir = customDir ?? AppSettings.recordingsDir.appendingPathComponent(recorder.videoID)
        let url = dir.appendingPathComponent(name)
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let data = ctx.pngRepresentation(of: img, format: .BGRA8, colorSpace: cs) else { return }
        try? data.write(to: url)
        print("STUDIOTEST_SHOT \(url.path)")
    }

    private func saveWindowShot(to dir: URL?, name: String = "studiotest-ui.png") {
        guard let w = window, let v = w.contentView,
              let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            let out = (dir ?? FileManager.default.temporaryDirectory)
                .appendingPathComponent(name)
            try? png.write(to: out)
            print("STUDIOTEST_SHOT \(out.path)")
        }
    }

    private weak var previewView: StudioPreviewNSView?

    private func buildWindow() {
        // SIN .fullSizeContentView: el contenido se comía el doble-clic del
        // titlebar y mataba el zoom estándar de macOS (feedback Daniel).
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        w.title = "SFCast Estudio"
        w.titlebarAppearsTransparent = true
        w.center()
        w.isReleasedWhenClosed = false
        w.backgroundColor = NSColor(calibratedRed: 0.043, green: 0.043, blue: 0.055, alpha: 1)
        // Visibilidad en capturas: configurable en Ajustes (default invisible,
        // estilo OBS). --studiotest siempre capturable.
        if !testMode { w.sharingType = config.windowCapturable ? .readOnly : .none }
        w.delegate = self
        let root = StudioRootView().environmentObject(self)
        let hosting = NSHostingView(rootView: root)
        // El zoom se mete ENTRE la ventana y SwiftUI: así ⌘+/⌘− reescalan el
        // Estudio entero (paneles incluidos) con el texto nítido, en vez de
        // estirar una imagen. Ver Zoom.swift.
        let zoomHost = ZoomHost.envolver(hosting)
        // El mínimo de la ventana va en PUNTOS FÍSICOS: con el zoom al 1.8 los
        // 940 lógicos son 1692 reales, y dejar el mínimo quieto permitiría
        // encoger la ventana hasta aplastar la maqueta.
        zoomHost.alCambiar = { [weak self, weak w] z in
            w?.minSize = NSSize(width: 940 * z, height: 620 * z)
            self?.previewView?.afinarNitidez()
        }
        w.minSize = NSSize(width: 940 * ZoomHost.valor, height: 620 * ZoomHost.valor)
        w.contentView = zoomHost
        window = w
        autorretrato = Autorretrato(w)
    }

    private var autorretrato: Autorretrato?

    func registerPreview(_ v: StudioPreviewNSView) { previewView = v }

    // MARK: - estado del motor / meters

    private func pullEngineStatus() {
        screenOK = engine.screenAvailable && !engine.screenFrozen
        // LA CÁMARA SE MIDE IGUAL QUE LA PANTALLA (17 ago 2026).
        //
        // Estas cuatro líneas tenían una asimetría que costó tomas: la pantalla
        // restaba `screenFrozen` de su semáforo Y se insertaba en `starved`; la
        // cámara no hacía ninguna de las dos. `cameraAvailable` se pone en true
        // optimista al montar la sesión y NUNCA vuelve a false, así que el punto
        // se quedaba VERDE con la cámara entregando 0 fps — Daniel lo cazó en un
        // screenshot donde el chip decía `camara 0 · preview 30 fps` con los dos
        // puntos en verde.
        //
        // Es la misma familia que `preflightVoz` sin `preflightImagen`: al
        // micrófono y a la pantalla les cablearon el sensor, a la cámara no.
        cameraOK = engine.cameraAvailable && !engine.cameraFrozen
        starved = engine.starvedSources
        if engine.screenFrozen { starved.insert(.screen) }
        if engine.cameraFrozen { starved.insert(.camera) }
    }

    /// Peso proyectado con la config actual — el número que faltaba.
    var weightHint: String {
        let gbh = WeightEstimate.gbPerHour(config: config,
                                           width: Int(engine.canvasSize.width),
                                           height: Int(engine.canvasSize.height),
                                           fps: engine.fps)
        return String(format: "≈ %.1f GB por hora (%.0f MB por 10 min)", gbh, gbh * 1000 / 6)
    }

    var weightHeavy: Bool {
        WeightEstimate.gbPerHour(config: config,
                                 width: Int(engine.canvasSize.width),
                                 height: Int(engine.canvasSize.height),
                                 fps: engine.fps) > 1.5
    }

    /// Sube una alarma a la UI. Las críticas se quedan hasta que la situación
    /// se cure; las buenas se borran solas.
    func raiseAlert(_ message: String, critical: Bool, sticky: Bool? = nil) {
        // ⛔ LO NO-CRÍTICO NO SE PINTA (27 ago 2026). Regla de Daniel: *"que dejen
        // de salir estas mierdas... si es tan urgente lo sabré"*. Y tiene razón:
        // este panel vive a un palmo de su cara mientras habla a cámara, y un
        // banner que informa de algo que ya se resolvió solo ("la GPU respira",
        // "la pantalla se recuperó", "el micrófono volvió") solo entrena a
        // ignorar el sitio donde SÍ van a salir las cosas graves.
        //
        // Lo crítico sigue gritando, y debe: cámara congelada, micrófono mudo,
        // pantalla caída o cámara equivocada NO se notan hablando —esos avisos
        // existen porque cada uno costó una toma— y ahí el silencio sale caro.
        // El resto queda en el log, que es donde se revisa en frío.
        guard critical else {
            Log.info("Estudio (solo log): \(message)")
            return
        }
        alert = message
        alertCritical = critical
        if !(sticky ?? critical) {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if self.alert == message { self.alert = nil }
            }
        }
    }

    private var tick = 0

    private func startMeters() {
        meterTimer?.invalidate()
        lastFlow = nil               // re-baseline del sensor de fps al reabrir
        MainWatch.shared.start(reason: "Estudio abierto")
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // LATIDO DE MAIN (26 ago 2026). Lo primero del tick, antes de
                // cualquier trabajo: si main se bloquea, esto deja de estamparse
                // y el vigía —que vive FUERA de main— lo declara. Ver MainWatch.
                MainWatch.shared.beat()
                let l = self.engine.levels.get()
                // Vúmetro real: ataque INSTANTÁNEO, caída suave (el valor crudo
                // a 15Hz brincaba feo — feedback Daniel v2.3). DIRECTO al layer:
                // esto corre 15 veces por segundo y NADA de esa frecuencia pasa
                // por @Published (la lección v2.8 — re-layouteaba la ventana
                // entera y el preview quedaba a 3 fps).
                self.micSmooth = max(l.mic, self.micSmooth * 0.80)
                self.sysSmooth = max(l.system, self.sysSmooth * 0.80)
                self.micMeter?.set(level: self.micSmooth)
                self.sysMeter?.set(level: self.sysSmooth)
                // Publicar solo cuando cambia el SEGUNDO mostrado: a 15Hz cada
                // asignación de @Published re-renderiza la jerarquía SwiftUI
                // entera — carga gratuita en main justo mientras se graba.
                if self.isRecording {
                    let e = self.recorder.elapsed
                    if Int(e) != Int(self.meters.elapsed) { self.meters.elapsed = e }
                }
                self.tick += 1
                if self.tick % 15 == 0 {                                        // ~1s
                    self.refreshFlowSensor()
                    // Red de seguridad del espejo: si algo lo movió por fuera
                    // (cambio de monitor, resolución, fin de grabación), aquí se
                    // reconcilia. Es no-op cuando nada cambió.
                    self.syncMirror()
                }
                if self.tick % 45 == 0 { self.engine.retryScreenIfNeeded() }   // ~3s
                // EL PUNTO CIEGO (26 ago 2026): el latido ❤︎ del recorder solo
                // existe MIENTRAS SE GRABA. Esa noche el preview se cayó ANTES
                // de dar REC y el log no tuvo nada que contar — tres minutos y
                // medio mudos. Ahora el Estudio late también en reposo, y late
                // con los MISMOS números que el chip que Daniel está mirando,
                // para que "el chip decía 0" deje de ser un recuerdo y sea un dato.
                if self.tick % 225 == 0 { self.logPreviewBeat() }               // ~15s
                if self.tick % 150 == 0 {                                       // ~10s
                    let free = StudioRecorder.freeBytes()
                    let note = free < StudioRecorder.minFreeBytesToStart
                        ? "Disco: \(StudioRecorder.gb(free)) libres" : nil
                    if note != self.freeDiskNote { self.freeDiskNote = note }
                }
            }
        }
    }

    func registerMeter(_ v: MeterBarNSView, kind: MeterKind) {
        switch kind {
        case .mic: micMeter = v
        case .system: sysMeter = v
        }
    }

    /// SENSOR de flujo (invariante 5b): fps de cámara ENTRANDO y de preview
    /// PINTÁNDOSE, por conteo de frames sobre ~1s. Asigna los @Published solo
    /// si el número mostrado cambió: un 30 estable no invalida la UI nunca.
    private func refreshFlowSensor() {
        let now = CACurrentMediaTime()
        let flow = engine.flowCounts()
        defer { lastFlow = flow; lastFlowAt = now }
        guard let last = lastFlow else { return }
        let dt = now - lastFlowAt
        guard dt > 0.5 else { return }
        let cam = Int((Double(flow.camera - last.camera) / dt).rounded())
        let prev = Int((Double(flow.previewDelivered - last.previewDelivered) / dt).rounded())
        // ¿Los frames que faltan se TIRARON en la compuerta, o nunca se
        // compusieron? No es lo mismo y hasta hoy el chip decía siempre lo
        // primero: tirar en la compuerta afecta SOLO al ojo (el sink drena
        // aparte), pero un render loop lento afecta AL ARCHIVO, porque de ese
        // mismo loop come el writer. Con el espejo encendido sobre un lienzo 5K
        // pasa lo segundo, y el chip tiene que decirlo.
        let dropped = flow.previewDropped - last.previewDropped
        let slow = dropped == 0 && prev + 5 < cam
        if slow != meters.renderStarving { meters.renderStarving = slow }
        if cam != meters.camFPS { meters.camFPS = cam }
        if prev != meters.prevFPS { meters.prevFPS = prev }
    }


    /// Latido del Estudio EN REPOSO (sin grabar). Deliberadamente reporta los
    /// mismos `camFPS`/`prevFPS` que pinta el chip: el objetivo no es una
    /// segunda medición, es dejar ESCRITO lo que el humano vio en pantalla.
    private func logPreviewBeat() {
        guard engine.isRunning, !isRecording else { return }
        let cs = engine.compositorStats()
        let flow = engine.flowCounts()
        Log.info(String(format: "Estudio ◇ reposo — cam:%dfps prev:%dfps(-%d) %@comp:%.1fms sinBuf:%d "
                        + "pantalla:%@ stream:%.1fs-mudo ram:%@ main:%@",
                        max(meters.camFPS, 0), max(meters.prevFPS, 0), flow.previewDropped,
                        meters.renderStarving ? "COMPOSITOR-NO-ALCANZA " : "",
                        cs.composeMsP50, cs.bufferFailures,
                        engine.screenFrozen ? "CONGELADA" : (screenOK ? "ok" : "SIN-SENAL"),
                        engine.screenHealth.silence(),
                        StudioRecorder.gb(StudioRecorder.availableRAM()),
                        MainWatch.shared.stallCount == 0
                            ? "ok"
                            : String(format: "%d bloqueo(s), peor %.0fms",
                                     MainWatch.shared.stallCount, MainWatch.shared.worstStallMs)))
    }

    private func stopMeters() {
        meterTimer?.invalidate()
        meterTimer = nil
        MainWatch.shared.stop()
    }

    // MARK: - escenas (CRUD + switch en vivo)

    func selectScene(_ id: UUID) {
        guard config.activeSceneID != id else { return }
        config.activeSceneID = id
        selectedItemID = nil
        pushActiveScene()
        if let s = activeScene { recorder.sceneSwitched(s) }   // timeline → manifest
        config.save()
    }

    func addScene() {
        let s = StudioScene(name: "Escena \(config.scenes.count + 1)", items: [SceneItem(kind: .screen)])
        config.scenes.append(s)
        selectScene(s.id)
    }

    func duplicateScene() {
        guard var s = activeScene else { return }
        s.id = UUID()
        s.name += " copia"
        s.items = s.items.map { var i = $0; i.id = UUID(); return i }
        config.scenes.append(s)
        selectScene(s.id)
    }

    func deleteScene() {
        guard config.scenes.count > 1, let id = config.activeSceneID else { return }
        config.scenes.removeAll { $0.id == id }
        selectScene(config.scenes.first!.id)
    }

    func renameActiveScene(_ name: String) {
        guard let idx = config.scenes.firstIndex(where: { $0.id == config.activeSceneID }) else { return }
        config.scenes[idx].name = name
        config.save()
    }

    /// Drag & drop de escenas: mueve `id` a la posición de `over` (reorden vivo
    /// durante el drag; el DropDelegate persiste al soltar).
    func moveScene(id: UUID, over: UUID) {
        guard let from = config.scenes.firstIndex(where: { $0.id == id }),
              let to = config.scenes.firstIndex(where: { $0.id == over }), from != to else { return }
        let s = config.scenes.remove(at: from)
        config.scenes.insert(s, at: to)
    }

    /// Atajo "Modo Loom": cierra el Estudio (suelta cámara/pantalla) y abre el
    /// micropanel clásico — la funcionalidad Loom REAL, sin reinventar nada.
    func switchToLoom() {
        window?.performClose(nil)   // windowWillClose apaga motor y burbuja
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            let btn = (NSApp.delegate as? AppDelegate)?.statusBar.button
            LauncherPanelController.shared.show(relativeTo: btn)
        }
    }

    /// Transform desde los controles (sliders, chips, centrar): pasa por
    /// `config` y persiste. Para el ARRASTRE usa `setItemRectLive`.
    func setItemRect(_ id: UUID, _ rect: CGRect, persist: Bool) {
        guard let sIdx = config.scenes.firstIndex(where: { $0.id == config.activeSceneID }),
              let iIdx = config.scenes[sIdx].items.firstIndex(where: { $0.id == id }) else { return }
        config.scenes[sIdx].items[iIdx].rect = rect
        pushActiveScene()
        if persist { config.save() }
    }

    /// Rect VIVO mientras se arrastra (en el canvas del Estudio o en el espejo).
    /// Vive FUERA de `@Published config` A PROPÓSITO: el mouse manda 60-120
    /// eventos por segundo y CADA asignación a `config` invalida la jerarquía
    /// SwiftUI entera. Es exactamente la lección de v2.8 (el vúmetro a 15 Hz ya
    /// dejó el preview a 3 fps con la cámara sana): nada de alta frecuencia pasa
    /// por un `@Published` que observa la ventana completa.
    private var liveDrag: (id: UUID, rect: CGRect)?

    /// Arrastre EN VIVO: alimenta al compositor (sceneBox, thread-safe) y al
    /// espejo con una copia detachada de la escena. `config` no se toca hasta
    /// soltar. Es el camino que usan LOS DOS arrastres — el del preview y el del
    /// espejo — para que no haya dos verdades.
    func setItemRectLive(_ id: UUID, _ rect: CGRect) {
        guard var scene = activeScene,
              let i = scene.items.firstIndex(where: { $0.id == id }) else { return }
        liveDrag = (id, rect)
        scene.items[i].rect = rect
        engine.setActiveScene(scene)
        previewView?.refreshOverlay()
        syncMirror(scene: scene)
    }

    /// El rect que la UI debe pintar para ese item AHORA: el vivo si se está
    /// arrastrando, el persistido si no.
    func liveRect(of id: UUID) -> CGRect? {
        if let d = liveDrag, d.id == id { return d.rect }
        return activeScene?.items.first(where: { $0.id == id })?.rect
    }

    /// Soltar el mouse: AQUÍ (y solo aquí) se escribe `config` y se persiste.
    func commitItemDrag() {
        guard let d = liveDrag else { config.save(); return }
        liveDrag = nil
        setItemRect(d.id, d.rect, persist: true)
    }

    // MARK: - EL ESPEJO (v2.9)

    /// Cablea el espejo con el controller. El arrastre del espejo entra por el
    /// MISMO camino vivo que el del preview; los chips de tamaño entran por
    /// el camino normal, que sí persiste.
    private func wireMirror() {
        mirror.onDragLive = { [weak self] r in
            guard let self, let id = self.mirror.mirroredItemID else { return }
            self.setItemRectLive(id, r)
        }
        mirror.onDragCommit = { [weak self] in self?.commitItemDrag() }
        // Tamaño desde los chips / el menú: entra por el camino normal (persiste
        // de una). `circle` viene puesto solo en el tamaño completo, que igual
        // que en el Loom deja de ser círculo y pasa a rectángulo redondeado.
        mirror.onResize = { [weak self] r, circle in
            guard let self, let id = self.mirror.mirroredItemID else { return }
            self.updateItem(id) {
                $0.rect = r
                if let circle { $0.circleMask = circle }
            }
        }
        // Voltear cae sobre el ITEM: por eso lo ve el programa y el espejo con
        // el mismo valor, sin que nadie tenga que sincronizar nada.
        mirror.onFlip = { [weak self] in
            guard let self, let id = self.mirror.mirroredItemID else { return }
            self.updateItem(id) { $0.flipH.toggle() }
        }
        mirror.onRequestClose = { [weak self] in
            guard let self, self.config.mirrorEnabled else { return }
            self.toggleMirror()
        }
        mirror.onStateChange = { [weak self] in self?.refreshMirrorFlags() }
    }

    /// El botón Espejo del top bar (y el chip de cerrar del propio espejo).
    func toggleMirror() {
        config.mirrorEnabled.toggle()
        config.save()
        if config.mirrorEnabled {
            syncMirror()
            if let why = mirror.unavailable {
                raiseAlert("Espejo prendido, pero \(why.reason).", critical: false)
            }
        } else {
            mirror.hide()
            refreshMirrorFlags()
        }
        Log.info("Espejo: \(config.mirrorEnabled ? "prendido" : "apagado")"
                 + (mirror.unavailable.map { " (\($0.reason))" } ?? ""))
    }

    /// Voltear en horizontal la cámara de la escena activa. Vive en el
    /// controller (no en el espejo) porque el dueño del item es él, y porque
    /// tiene que funcionar con el espejo apagado también.
    func flipMirroredCamera() {
        guard let item = activeScene?.items.last(where: { $0.kind == .camera && $0.enabled })
        else { return }
        updateItem(item.id) { $0.flipH.toggle() }
    }

    var mirroredCameraFlipped: Bool {
        activeScene?.items.last(where: { $0.kind == .camera && $0.enabled })?.flipH ?? false
    }

    /// Reconcilia el espejo con lo que hay AHORA. Idempotente y barata: la
    /// llaman el push de escena, cada tick del arrastre y el timer de 1 Hz.
    func syncMirror(scene: StudioScene? = nil) {
        // La compuerta es el MOTOR, no la ventana: si Daniel minimiza el Estudio
        // (o lo manda al otro monitor) a mitad de una toma, el espejo tiene que
        // seguir ahí. `mirror.sync` ya resuelve el caso de motor abajo.
        guard config.mirrorEnabled else {
            if mirror.isVisible { mirror.hide() }
            refreshMirrorFlags()
            return
        }
        mirror.sync(scene: scene ?? activeScene,
                    canvas: engine.canvasSize,
                    session: engine.cameraCaptureSession,
                    mirrored: engine.cameraMirroredInProgram,
                    engineRunning: engine.isRunning)
        refreshMirrorFlags()
    }

    /// Publica los booleanos del espejo SOLO si cambiaron.
    private func refreshMirrorFlags() {
        let note = config.mirrorEnabled ? mirror.unavailable?.reason : nil
        if note != mirrorNote { mirrorNote = note }
        if mirror.locked != mirrorLocked { mirrorLocked = mirror.locked }
        if mirror.xray != mirrorXray { mirrorXray = mirror.xray }
    }

    /// Ajustes → Aplicar EN CALIENTE, estilo OBS: el motor NO se reinicia (el
    /// stop+start viejo bloqueaba main peleando el lock del AVCaptureSession —
    /// la bolita de arcoíris del 6 ago). No disponible mientras grabas.
    func applySettings() {
        guard !recorder.isRecording else { return }
        config.save()
        Task {
            await engine.applyLive(config: config)
            pullEngineStatus()
        }
    }

    // MARK: - dispositivos (doble clic en Fuentes/Mixer + Ajustes)

    var currentCameraID: String? { AppSettings.load().cameraDeviceID }
    var currentMicID: String? { AppSettings.load().micDeviceID }
    var currentScreenID: String? { AppSettings.load().screenDisplayID }

    /// Cambia la PANTALLA capturada EN CALIENTE (doble clic sobre la fuente
    /// Pantalla, hermano del selector de camara). Reengancha el mismo stream
    /// que ya se remonta solo cuando SCK muere: un camino, no dos.
    ///
    /// El corte a mitad de grabacion NO se permite — no por pudor tecnico:
    /// cambiar de pantalla cambia el lienzo (2560x1440 -> 1920x1080) y el raw
    /// quedaria partido en dos resoluciones dentro del mismo take.
    func setScreenDisplay(id: String?) {
        guard !recorder.isRecording else {
            raiseAlert("No cambio de pantalla a mitad de una grabación", critical: false)
            return
        }
        var s = AppSettings.load()
        s.screenDisplayID = id
        s.save()
        engine.restartScreenTap(reason: "cambio de pantalla")
    }

    /// Cambia la cámara EN CALIENTE (doble clic sobre la fuente Cámara).
    /// AppSettings es la config compartida con el modo Loom (una sola config).
    func setCameraDevice(id: String?) {
        guard !recorder.isRecording else {
            raiseAlert("No cambio de cámara a mitad de una grabación", critical: false)
            return
        }
        var s = AppSettings.load()
        s.cameraDeviceID = id
        s.save()
        engine.applyDeviceSelection(micEnabled: config.micEnabled)
    }

    /// Cambia el micrófono EN CALIENTE (doble clic sobre el mixer del mic).
    func setMicDevice(id: String?) {
        guard !recorder.isRecording else {
            raiseAlert("No cambio de micrófono a mitad de una grabación", critical: false)
            return
        }
        var s = AppSettings.load()
        s.micDeviceID = id
        s.save()
        engine.applyDeviceSelection(micEnabled: config.micEnabled)
    }

    /// Toggle de Ajustes: aplica al instante la visibilidad de la ventana en
    /// capturas/grabaciones (los dos modos que pidió Daniel).
    func applyWindowSharing() {
        guard !testMode else { return }
        window?.sharingType = config.windowCapturable ? .readOnly : .none
    }

    /// Chip "Pantalla" cuando no hay señal: dispara el prompt/pane de permisos.
    func requestScreenPermission() {
        CGRequestScreenCaptureAccess()
        Permissions.openPrivacyPane("ScreenCapture")
    }

    // MARK: - fuentes de la escena activa

    private func mutateActiveScene(_ mutate: (inout StudioScene) -> Void) {
        guard let idx = config.scenes.firstIndex(where: { $0.id == config.activeSceneID }) else { return }
        mutate(&config.scenes[idx])
        pushActiveScene()
        config.save()
    }

    func addItem(_ kind: StudioSourceKind) {
        mutateActiveScene { scene in
            let item = kind == .camera
                ? SceneItem(kind: .camera,
                            rect: CGRect(x: 0.02, y: 0.03, width: 0.16, height: 0.16 * 16.0 / 9.0),
                            fit: .fill, circleMask: true)
                : SceneItem(kind: kind)
            scene.items.append(item)
            selectedItemID = item.id
        }
    }

    func removeSelectedItem() {
        guard let id = selectedItemID else { return }
        mutateActiveScene { $0.items.removeAll { $0.id == id } }
        selectedItemID = nil
    }

    func moveSelectedItem(up: Bool) {
        guard let id = selectedItemID else { return }
        mutateActiveScene { scene in
            guard let i = scene.items.firstIndex(where: { $0.id == id }) else { return }
            let j = up ? i + 1 : i - 1     // arriba en la pila = después en la lista
            guard j >= 0 && j < scene.items.count else { return }
            scene.items.swapAt(i, j)
        }
    }

    func updateSelectedItem(_ mutate: (inout SceneItem) -> Void) {
        guard let id = selectedItemID else { return }
        updateItem(id, mutate)
    }

    /// Muta un item POR ID. El clic derecho no cambia la selección, así que el
    /// menú contextual tiene que actuar sobre la fila donde se hizo clic, no
    /// sobre "lo seleccionado" (sería editar el item equivocado).
    func updateItem(_ id: UUID, _ mutate: (inout SceneItem) -> Void) {
        mutateActiveScene { scene in
            guard let i = scene.items.firstIndex(where: { $0.id == id }) else { return }
            mutate(&scene.items[i])
        }
    }

    var selectedItem: SceneItem? {
        activeScene?.items.first(where: { $0.id == selectedItemID })
    }

    private func pushActiveScene() {
        engine.setActiveScene(activeScene)
        // Punto único por donde pasa TODO cambio de escena/fuente: el espejo se
        // entera aquí y no en cada sitio que muta (que sería donde se olvidaría).
        syncMirror()
    }

    // MARK: - grabación

    func toggleRecord() {
        if recorder.isRecording {
            soltarAtajosDeMarcador()
            markerHUD.hide()
            Task {
                let dir = await recorder.stop(engine: engine, config: config)
                isRecording = false
                meters.elapsed = 0
                lastSessionDir = dir
                if let dir, !testMode {
                    NSWorkspace.shared.activateFileViewerSelecting([dir])
                }
            }
        } else {
            guard recorder.state == .idle else { return }   // anti doble-clic en .stopping
            cadenceFloorNotified = false
            do {
                try recorder.start(engine: engine, config: config, activeScene: activeScene)
                recordError = nil
                isRecording = true
                markerCount = 0
                cortesMarcados = 0
                buenosMarcados = 0
                meters.cortes = 0
                meters.estrellas = 0
                // Las teclas se toman prestadas justo ahora y se devuelven al
                // detener: fuera de la toma no hay nada que marcar, y ⌥C/⌥B
                // escriben caracteres que Daniel debe conservar.
                registrarAtajosDeMarcador()
                markerHUD.show()
                markerHUD.update(cortes: 0, buenos: 0, pulso: nil)
            } catch {
                recordError = error.localizedDescription
            }
        }
    }
}

// MARK: - preview NSView INTERACTIVO (estilo OBS: clic selecciona, drag mueve,
// handles en bordes/esquinas redimensionan — directo sobre el programa)

final class StudioPreviewNSView: NSView {
    weak var controller: StudioController?
    private let borderLayer = CAShapeLayer()   // contorno del item (SIN relleno)
    private let handlesLayer = CAShapeLayer()  // los 8 handles (rellenos)
    static let morado = NSColor(srgbRed: 0.549, green: 0.153, blue: 0.945, alpha: 1) // #8C27F1

    private enum Drag {
        case none
        case move
        case resize(Int)   // 0 bl · 1 br · 2 tl · 3 tr · 4 izq · 5 der · 6 abajo · 7 arriba
    }
    private var drag: Drag = .none
    private var dragItemID: UUID?
    private var dragStartRect = CGRect.zero
    private var dragStartPoint = CGPoint.zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect
        borderLayer.fillColor = nil                       // SOLO contorno
        borderLayer.strokeColor = Self.morado.cgColor
        borderLayer.lineWidth = 1.5
        borderLayer.zPosition = 10
        handlesLayer.fillColor = Self.morado.cgColor
        handlesLayer.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
        handlesLayer.lineWidth = 1
        handlesLayer.zPosition = 11
        layer?.addSublayer(borderLayer)
        layer?.addSublayer(handlesLayer)
    }
    required init?(coder: NSCoder) { fatalError() }

    func display(surface: IOSurface) {
        layer?.contents = surface
        afinarNitidez()
    }

    /// El zoom quita puntos lógicos sin quitar píxeles físicos. Una capa que se
    /// rasteriza sola (esta, y las del contorno del item) tiene que enterarse o
    /// dibuja para el tamaño equivocado y sale suave — justo en la superficie
    /// donde se juzga el encuadre.
    func afinarNitidez() {
        let e = (window?.backingScaleFactor ?? 2) * ZoomHost.valor
        guard layer?.contentsScale != e else { return }
        layer?.contentsScale = e
        borderLayer.contentsScale = e
        handlesLayer.contentsScale = e
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        afinarNitidez()
    }

    // El rect (en coords de la vista) donde vive la imagen aspect-fit del canvas.
    private func fittedRect() -> CGRect {
        guard let cs = controller?.engine.canvasSize, cs.width > 0, cs.height > 0,
              bounds.width > 1, bounds.height > 1 else { return bounds }
        let s = min(bounds.width / cs.width, bounds.height / cs.height)
        let w = cs.width * s, h = cs.height * s
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    private func viewRect(of item: SceneItem) -> CGRect {
        let f = fittedRect()
        // El rect VIVO: durante un arrastre el valor bueno no está en `config`
        // (que solo se escribe al soltar), sino en el camino vivo del
        // controller. Sin esto, arrastrar el ESPEJO movería el programa pero
        // dejaría el recuadro de selección del preview clavado — dos verdades.
        let r = controller?.liveRect(of: item.id) ?? item.rect
        return CGRect(x: f.minX + r.minX * f.width,
                      y: f.minY + r.minY * f.height,
                      width: r.width * f.width,
                      height: r.height * f.height)
    }

    private func handlePoints(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
         CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY),
         CGPoint(x: r.minX, y: r.midY), CGPoint(x: r.maxX, y: r.midY),
         CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.midX, y: r.maxY)]
    }

    override func mouseDown(with event: NSEvent) {
        guard let c = controller else { return }
        let p = convert(event.locationInWindow, from: nil)
        dragStartPoint = p
        // 1) ¿handle del item seleccionado? → resize
        if let sel = c.selectedItem {
            let r = viewRect(of: sel)
            for (i, h) in handlePoints(r).enumerated() where hypot(p.x - h.x, p.y - h.y) < 9 {
                drag = .resize(i)
                dragItemID = sel.id
                dragStartRect = sel.rect
                return
            }
        }
        // 2) ¿clic sobre un item? (el de más arriba en la pila primero) → mover
        let items = c.activeScene?.items ?? []
        for item in items.reversed() where item.enabled && viewRect(of: item).contains(p) {
            c.selectedItemID = item.id
            drag = .move
            dragItemID = item.id
            dragStartRect = item.rect
            refreshOverlay()
            return
        }
        // 3) clic al vacío → deseleccionar
        c.selectedItemID = nil
        drag = .none
        refreshOverlay()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let c = controller, let id = dragItemID else { return }
        let p = convert(event.locationInWindow, from: nil)
        let f = fittedRect()
        guard f.width > 1, f.height > 1 else { return }
        let dx = (p.x - dragStartPoint.x) / f.width
        let dy = (p.y - dragStartPoint.y) / f.height
        var r = dragStartRect
        let minS: CGFloat = 0.04
        switch drag {
        case .move:
            r.origin.x += dx
            r.origin.y += dy
        case .resize(let h):
            switch h {
            case 0: r.origin.x += dx; r.origin.y += dy; r.size.width -= dx; r.size.height -= dy
            case 1: r.origin.y += dy; r.size.width += dx; r.size.height -= dy
            case 2: r.origin.x += dx; r.size.width -= dx; r.size.height += dy
            case 3: r.size.width += dx; r.size.height += dy
            case 4: r.origin.x += dx; r.size.width -= dx
            case 5: r.size.width += dx
            case 6: r.origin.y += dy; r.size.height -= dy
            default: r.size.height += dy
            }
        case .none:
            return
        }
        r.size.width = max(minS, r.size.width)
        r.size.height = max(minS, r.size.height)
        c.setItemRectLive(id, r)   // mismo camino vivo que el arrastre del espejo
        refreshOverlay()
    }

    override func mouseUp(with event: NSEvent) {
        if dragItemID != nil { controller?.commitItemDrag() }
        drag = .none
        dragItemID = nil
    }

    override func layout() {
        super.layout()
        refreshOverlay()
    }

    /// Borde + 8 handles del item seleccionado (solo en la VENTANA — la ventana
    /// es sharingType=.none, jamás contamina la grabación).
    func refreshOverlay() {
        guard let sel = controller?.selectedItem else {
            borderLayer.path = nil
            handlesLayer.path = nil
            return
        }
        let r = viewRect(of: sel)
        let border = CGMutablePath()
        border.addRect(r)
        let handles = CGMutablePath()
        let s: CGFloat = 7
        for h in handlePoints(r) {
            handles.addRect(CGRect(x: h.x - s / 2, y: h.y - s / 2, width: s, height: s))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        borderLayer.path = border
        handlesLayer.path = handles
        CATransaction.commit()
    }
}

/// Agarradera del drawer: arrastra para cambiar el ancho de EL SET (300-560).
/// El ancho persiste en UserDefaults via StudioController.setPanelWidth.
struct SetResizeHandle: View {
    @EnvironmentObject var c: StudioController
    @State private var startWidth: CGFloat? = nil

    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.001))   // zona de agarre invisible
            .frame(width: 9)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .fill(StudioSkin.panelBorder)
                    .frame(width: 3, height: 46)
            )
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { g in
                        let base = startWidth ?? c.setPanelWidth
                        if startWidth == nil { startWidth = base }
                        c.setPanelWidth = min(max(base - g.translation.width, 300), 560)
                    }
                    .onEnded { _ in startWidth = nil }
            )
    }
}

/// EL SET, garantizado por la app (19 ago 2026)
///
/// ANTES: el drawer era un WKWebView desnudo apuntando a :8088. Si el servicio no
/// estaba arriba no había error, ni reintento, ni aviso — quedaba un rectángulo
/// BLANCO. El 18 ago un `estudio off` dejó el job booteado out (bootout ELIMINA el
/// job: el KeepAlive del plist no resucita lo que ya no existe) y el Estudio pasó
/// 22 h enseñando ese blanco. Con el Modo Rodaje, que abre el drawer a la fuerza,
/// ese blanco se HORNEA en el video y encima es una bomba de luz en cámara.
///
/// AHORA: la clase de fallo no existe. El Set no es un servicio con vida propia que
/// el humano arranca desde una terminal — es parte de la app. Si SFCast está abierto,
/// El Set está arriba, y nadie tiene que enterarse de que por debajo hay un puerto.
///
/// Lo que NO hace: matarlo al salir. panel_server.py escucha en 0.0.0.0 a propósito
/// para que el iPhone entre por la LAN (su propio comentario lo dice). Si SFCast lo
/// matara al cerrarse le arrancaría el panel del teléfono a Daniel. Adoptar ≠ poseer:
/// la app garantiza que esté ARRIBA; `estudio off` sigue siendo cómo se baja aposta.
enum SetService {
    static let port = 8088
    static let url = URL(string: "http://127.0.0.1:8088/?embed=sfcast")!

    private static let label = "com.arbrain.panel"
    private static var plist: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    /// Fallback cuando el plist no está instalado: el repo en su ruta convencional.
    private static var repoDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Developer/business-os/entorno-fisico")
    }

    /// ¿Responde? Timeout corto a propósito: esto corre antes de pintar.
    static func isUp(timeout: TimeInterval = 1.0) async -> Bool {
        var r = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
        r.timeoutInterval = timeout
        r.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (_, resp) = try? await URLSession.shared.data(for: r),
              let http = resp as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }

    /// Garantiza que El Set responda. Idempotente y barato cuando ya está arriba
    /// (un probe de ~2 ms). Devuelve false solo si de plano no levantó, que a estas
    /// alturas es un fallo de instalación, no el caso de todos los días.
    @discardableResult
    static func ensureUp() async -> Bool {
        if await isUp() { return true }

        if FileManager.default.fileExists(atPath: plist.path) {
            // launchd primero: reusa el plist real (KeepAlive + logs en panel.log).
            // bootout deja el job INEXISTENTE, así que bootstrap es lo que lo revive.
            run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plist.path], wait: true)
        } else {
            // Sin plist: lo levantamos nosotros. En macOS el hijo de una app GUI no
            // muere con el padre (se re-parenta a launchd), así que el iPhone lo
            // sigue viendo aunque SFCast se cierre. (No hay `setsid` en macOS.)
            let py = repoDir.appendingPathComponent("venv/bin/python3").path
            let server = repoDir.appendingPathComponent("panel_server.py").path
            if FileManager.default.fileExists(atPath: py),
               FileManager.default.fileExists(atPath: server) {
                run(py, ["-u", server], wait: false)
            }
        }

        // Poll: arrancar python tarda ~300 ms, no un frame. Techo ~5 s.
        for _ in 0..<20 {
            if await isUp(timeout: 0.5) { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    private static func run(_ tool: String, _ args: [String], wait: Bool) {
        guard FileManager.default.isExecutableFile(atPath: tool) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return }
        if wait { p.waitUntilExit() }   // al server desprendido no lo esperamos nunca
    }
}

/// EL SET embebido. El panel web sigue siendo la ÚNICA implementación — esto es un
/// espejo, no una copia. Lo que cambió es quién responde por que esté vivo: la app.
struct SetPanelDrawer: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let v = WKWebView()
        v.navigationDelegate = context.coordinator
        // Fondo del Estudio, JAMÁS el blanco por defecto de WKWebView: mientras
        // carga (o si algún día no carga) esto sale en cámara y se hornea en el
        // video. Un fallo puede ser feo, pero no puede ser una lámpara.
        v.setValue(false, forKey: "drawsBackground")
        v.underPageBackgroundColor = NSColor(red: 0.082, green: 0.082, blue: 0.098, alpha: 1)
        context.coordinator.attach(v)
        return v
    }

    func updateNSView(_ v: WKWebView, context: Context) {}

    /// Dueño del ciclo de vida de la carga: garantiza el servicio antes de pedir la
    /// página y reintenta solo si algo falla. El reintento NO puede colgar de
    /// updateNSView — SwiftUI solo lo llama cuando cambia el estado de la vista, y
    /// con el drawer quieto eso no pasa nunca (por eso el blanco duraba para siempre).
    final class Coordinator: NSObject, WKNavigationDelegate {
        private weak var web: WKWebView?
        private var intentos = 0

        func attach(_ v: WKWebView) {
            web = v
            cargar()
        }

        private func cargar() {
            Task { @MainActor in
                await SetService.ensureUp()
                web?.load(URLRequest(url: SetService.url))
            }
        }

        private func reintentar() {
            guard intentos < 5 else { return }   // techo: no martillar para siempre
            intentos += 1
            let espera = UInt64(intentos) * 1_000_000_000   // 1s, 2s, 3s… lineal
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: espera)
                await SetService.ensureUp()
                self.web?.load(URLRequest(url: SetService.url))
            }
        }

        func webView(_ w: WKWebView, didFinish n: WKNavigation!) { intentos = 0 }
        func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { reintentar() }
        func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { reintentar() }
    }
}

struct StudioPreviewView: NSViewRepresentable {
    @EnvironmentObject var controller: StudioController
    func makeNSView(context: Context) -> StudioPreviewNSView {
        let v = StudioPreviewNSView(frame: .zero)
        v.controller = controller
        controller.registerPreview(v)
        return v
    }
    func updateNSView(_ nsView: StudioPreviewNSView, context: Context) {
        nsView.refreshOverlay()   // cualquier cambio de estado re-sincroniza el overlay
    }
}

// MARK: - vúmetro por CALayer (el camino caliente NO pasa por SwiftUI)

enum MeterKind { case mic, system }

/// Barra del vúmetro dibujada con CALayer DIRECTO, gemela del patrón del
/// preview. El nivel llega 15 veces por segundo desde el meterTimer; cuando
/// viajaba por @Published del controller, cada tick re-layouteaba la ventana
/// SwiftUI completa (~60-70 ms el pase) y main quedaba saturado — el "preview
/// a 3 fps" del 7 ago (v2.8). Un CALayer se actualiza en microsegundos.
final class MeterBarNSView: NSView {
    private let fill = CAGradientLayer()
    private var level: Float = 0
    private var hot = false
    private static let mostaza = NSColor(srgbRed: 1.0, green: 0.567, blue: 0.004, alpha: 1)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        layer?.cornerRadius = 3
        layer?.masksToBounds = true
        fill.startPoint = CGPoint(x: 0, y: 0.5)
        fill.endPoint = CGPoint(x: 1, y: 0.5)
        fill.cornerRadius = 3
        applyColors()
        layer?.addSublayer(fill)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func applyColors() {
        fill.colors = [Self.mostaza.withAlphaComponent(0.7).cgColor,
                       (hot ? NSColor.systemRed : Self.mostaza).cgColor]
    }

    func set(level v: Float) {
        level = v
        if (v > 0.85) != hot { hot = v > 0.85; applyColors() }
        relayout()
    }

    override func layout() {
        super.layout()
        relayout()
    }

    private func relayout() {
        // La misma sensación que tenía en SwiftUI: .animation(.linear(0.08)).
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.08)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .linear))
        fill.frame = CGRect(x: 0, y: 0,
                            width: bounds.width * CGFloat(min(level, 1)),
                            height: bounds.height)
        CATransaction.commit()
    }
}

struct MeterBarView: NSViewRepresentable {
    @EnvironmentObject var controller: StudioController
    let kind: MeterKind
    func makeNSView(context: Context) -> MeterBarNSView {
        let v = MeterBarNSView(frame: .zero)
        controller.registerMeter(v, kind: kind)
        return v
    }
    func updateNSView(_ nsView: MeterBarNSView, context: Context) {}
}

// MARK: - piel (Screen Studio: oscuro, limpio, mostaza)

enum StudioSkin {
    static let bg = Color(red: 0.043, green: 0.043, blue: 0.055)
    static let panel = Color(red: 0.082, green: 0.082, blue: 0.098)
    static let panelBorder = Color.white.opacity(0.07)
    static let mostaza = Color(red: 1.0, green: 0.567, blue: 0.004)
    static let text = Color.white.opacity(0.92)
    static let dim = Color.white.opacity(0.45)
}

struct PanelBox<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(StudioSkin.dim)
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(StudioSkin.panel)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(StudioSkin.panelBorder))
    }
}

// MARK: - root

/// Relanza el bundle actual. El hijo sobrevive a nuestra muerte (se re-parenta a
/// launchd) y espera con `kill -0` hasta que el PID desaparece; recién entonces
/// abre. Así el binario que arranca es SIEMPRE el de disco, no el de memoria.
func relanzar() {
    let bundle = Bundle.main.bundleURL.path
    let pid = ProcessInfo.processInfo.processIdentifier
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; open \"\(bundle)\""]
    guard (try? p.run()) != nil else { return }
    NSApp.terminate(nil)   // dispara el guardado normal de scenes.json
}

struct StudioRootView: View {
    @EnvironmentObject var c: StudioController

    var body: some View {
        HStack(spacing: 10) {
            VStack(spacing: 10) {
                topBar
                if let msg = c.alert { alertBanner(msg, critical: c.alertCritical) }
                else if let disk = c.freeDiskNote { alertBanner(disk, critical: true) }
                StudioPreviewView()
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(StudioSkin.panelBorder))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                // SIMETRÍA estilo Streamlabs: 5 columnas de ancho IGUAL, sin huecos.
                HStack(spacing: 10) {
                    ScenesPanel().frame(maxWidth: .infinity)
                    SourcesPanel().frame(maxWidth: .infinity)
                    MixerPanel().frame(maxWidth: .infinity)
                    // La columna de cámara SOLO cuando el cajón está cerrado.
                    // Con el cajón abierto era lo mismo dos veces en pantalla
                    // (Daniel lo cazó al verlo). Cerrando el cajón no se pierde:
                    // la columna vuelve con lo esencial.
                    if !c.showCameraPanel {
                        CameraPanel().frame(maxWidth: .infinity)
                    }
                    OutputsPanel().frame(maxWidth: .infinity)
                }
                .frame(height: 235)
            }
            // EL SET al lado (18 ago): el panel :8088 embebido — ver y mover
            // luces/Pixoo sin salir del Estudio, incluso grabando. En su ancho
            // el panel cae solo en su layout de teléfono (una columna), y el
            // resizer recuerda la última posición.
            if c.showCameraPanel {
                CameraResizeHandle()
                CameraDrawer()
                    .frame(width: c.cameraPanelWidth)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(StudioSkin.panelBorder))
            }
            if c.showSetPanel {
                SetResizeHandle()
                SetPanelDrawer()
                    .frame(width: c.setPanelWidth)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(StudioSkin.panelBorder))
            }
        }
        .padding(12)
        .background(StudioSkin.bg)
        .preferredColorScheme(.dark)
        // EL SET arriba porque el Estudio está abierto (19 ago). No espera a que
        // alguien abra el drawer ni a que alguien se acuerde de `estudio on` en una
        // terminal: cuando Daniel toca 💡 el panel YA está listo, y el iPhone lo ve
        // aunque el drawer nunca se abra. Idempotente y ~2 ms si ya estaba vivo.
        .task { await SetService.ensureUp() }
        .sheet(isPresented: $c.showSettings) {
            StudioSettingsView().environmentObject(c)
        }
        // ⌘D duplica la escena activa desde cualquier lado del Estudio
        .background(
            Button("") { c.duplicateScene() }
                .keyboardShortcut("d", modifiers: .command)
                .hidden()
        )
        // ⌘R RELANZA el Estudio (19 ago). Tras `build-app.sh` + copiar a
        // /Applications, la app en memoria sigue siendo la vieja: cerrar y abrir
        // a mano era el paso manual de cada iteración. El shell espera a que este
        // proceso MUERA antes de abrir el nuevo — sin esa espera, LaunchServices
        // ve la app aún viva y trae al frente la instancia vieja en vez de lanzar
        // el binario nuevo, que es justo el fallo que haría inútil el atajo.
        .background(
            Button("") { relanzar() }
                .keyboardShortcut("r", modifiers: .command)
                .hidden()
        )
        // ⌘⇧F ajusta la fuente seleccionada a PANTALLA COMPLETA, exacta.
        // El preview es interactivo (drag mueve, handles redimensionan) y un
        // pulso de más deja cosas como y=0.00032233 — invisible al ojo, suficiente
        // para que el encuadre no cuadre y para que nadie sepa "en qué momento
        // quedó así". Esto devuelve el rect a [[0,0],[1,1]] sin pelearse con el ratón.
        .background(
            Button("") { c.updateSelectedItem { $0.rect = CGRect(x: 0, y: 0, width: 1, height: 1) } }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .hidden()
        )
    }

    /// Barra de alarma: si la pantalla se congela o el disco se acaba, se ve.
    /// El silencio era el bug de fondo del 25 jul, no un detalle de UI.
    private func alertBanner(_ msg: String, critical: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: critical ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            Text(msg).font(.system(size: 12, weight: .medium))
            Spacer()
            Button {
                c.alert = nil
            } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                .buttonStyle(.plain)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background((critical ? Color.red : Color.green).opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "record.circle")
                .foregroundStyle(StudioSkin.mostaza)
            Text("SFCast Estudio")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(StudioSkin.text)
            Button {
                if !c.screenOK { c.requestScreenPermission() }
            } label: {
                statusChip(c.screenOK ? "Pantalla" : "Pantalla: dar permiso",
                           ok: c.screenOK, starving: c.starved.contains(.screen))
            }
            .buttonStyle(.plain)
            .help(c.screenOK ? "Captura de pantalla activa"
                             : "Clic para aprobar «Grabación de pantalla» (tras un update se re-pide una vez). Se engancha solo al aprobar.")
            statusChip("Cámara", ok: c.cameraOK, starving: c.starved.contains(.camera))
            if c.meters.camFPS >= 0 { fpsChip }
            if let err = c.recordError {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                c.showCameraPanel.toggle()
            } label: {
                Image(systemName: "camera.aperture")
                    .foregroundStyle(c.showCameraPanel ? StudioSkin.mostaza : StudioSkin.dim)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(StudioSkin.panel)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Controles de la cámara: ISO, obturación, apertura, balance, enfoque y formato — sin salir del Estudio")
            Button {
                c.showSetPanel.toggle()
            } label: {
                Image(systemName: "lightbulb.max.fill")
                    .foregroundStyle(c.showSetPanel ? StudioSkin.mostaza : StudioSkin.dim)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(StudioSkin.panel)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("EL SET: luces, Pixoo y cámara del panel :8088, embebido — funciona también grabando")
            Button {
                c.showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .foregroundStyle(StudioSkin.dim)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(StudioSkin.panel)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(c.isRecording)
            .help("Ajustes del Estudio (video · audio · salida)")
            if c.isRecording {
                RecTimer(m: c.meters)
                // Las marcas, a la vista: es el acuse persistente (el destello
                // del espejo dura un segundo). Sin un número que suba, Daniel no
                // sabría si el atajo llegó.
                // Los DOS por separado, como en el HUD de la pantalla. Un solo
                // contador que suma ambos tipos no dice nada: Daniel lo cazó de
                // inmediato ("veo puras tijeras con ambos botones").
                if c.meters.cortes > 0 || c.meters.estrellas > 0 {
                    Text("✂︎ \(c.meters.cortes)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(StudioSkin.mostaza)
                        .help("Cortes marcados con ⌥C. Van al manifest para la edición.")
                    Text("★ \(c.meters.estrellas)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color(red: 0.25, green: 0.85, blue: 0.45))
                        .help("Momentos buenos marcados con ⌥X. Van al manifest para la edición.")
                }
            }
        }
    }

    /// SENSOR a la vista (invariante 5b): fps de cámara entrando vs fps del
    /// preview pintándose. Si el preview va detrás, el chip se pone naranja —
    /// y avisa que la GRABACIÓN no se entera (el sink drena en renderQueue).
    /// El "preview a 3 fps" del 7 ago fue invisible justo por no tener esto.
    private var fpsChip: some View { FPSChip(m: c.meters) }

    private func statusChip(_ label: String, ok: Bool, starving: Bool) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(starving ? Color.orange : (ok ? Color.green.opacity(0.85) : Color.gray))
                .frame(width: 7, height: 7)
            Text(starving ? "\(label): sin señal" : label)
                .font(.system(size: 11))
                .foregroundStyle(StudioSkin.dim)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(StudioSkin.panel)
        .clipShape(Capsule())
    }
}

func timeString(_ t: TimeInterval) -> String {
    let s = Int(t)
    return String(format: "%d:%02d", s / 60, s % 60)
}

// MARK: - panel Escenas

/// El chip de fps, aislado en su PROPIA vista observando solo `StudioMeters`.
/// Así el latido de 1 Hz redibuja este chip y NADA más — antes invalidaba la
/// jerarquía entera y cerraba los menús contextuales abiertos.
struct FPSChip: View {
    @ObservedObject var m: StudioMeters
    var body: some View {
        let lag = m.prevFPS >= 0 && m.prevFPS + 5 < m.camFPS
        let grave = m.renderStarving   // el compositor no alcanza → el ARCHIVO también baja
        return Text("cámara \(max(m.camFPS, 0)) · preview \(max(m.prevFPS, 0)) fps"
                    + (grave ? " · también el archivo" : ""))
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(grave ? Color.red : (lag ? Color.orange : StudioSkin.dim))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(StudioSkin.panel)
            .clipShape(Capsule())
            .help(grave ? "El COMPOSITOR no alcanza a componer, y de ese mismo loop come el writer: el archivo se está grabando a estos fps, no a los configurados. Suele ser el espejo encendido sobre un lienzo grande — apágalo, o baja el lienzo en Ajustes → Video."
                  : lag ? "El preview va detrás de la cámara (main ocupado). La grabación NO se afecta: el programa se compone y escribe fuera de main."
                        : "FPS medidos por conteo de frames: cámara entrando · preview pintado. Lo que ves es lo que se graba.")
    }
}

/// El cronómetro de grabación, por el mismo motivo: cambia cada segundo.
struct RecTimer: View {
    @ObservedObject var m: StudioMeters
    var body: some View {
        let t = Int(m.elapsed)
        return Text(String(format: "%02d:%02d", t / 60, t % 60))
            .font(.system(size: 14, weight: .semibold, design: .monospaced))
            .foregroundStyle(.red)
    }
}

struct ScenesPanel: View {
    @EnvironmentObject var c: StudioController
    @State private var renaming = false
    @State private var newName = ""
    @State private var draggedID: UUID?

    var body: some View {
        PanelBox(title: "Escenas") {
            ScrollView {
                VStack(spacing: 3) {
                    // Drag & drop MANUAL (onDrag/onDrop): List.onMove no jala en
                    // macOS con controles dentro de la fila. Tap selecciona,
                    // arrastrar reordena.
                    ForEach(c.config.scenes) { scene in
                        sceneRow(scene)
                            .onDrag {
                                draggedID = scene.id
                                return NSItemProvider(object: scene.id.uuidString as NSString)
                            }
                            .onDrop(of: [.text], delegate: SceneDropDelegate(
                                target: scene.id, dragged: $draggedID, c: c))
                    }
                }
            }
            loomShortcut
            HStack(spacing: 8) {
                iconBtn("plus") { c.addScene() }
                iconBtn("doc.on.doc") { c.duplicateScene() }
                iconBtn("minus") { c.deleteScene() }
                iconBtn("pencil") {
                    newName = c.activeScene?.name ?? ""
                    renaming = true
                }
            }
            .popover(isPresented: $renaming) {
                TextField("Nombre", text: $newName, onCommit: {
                    c.renameActiveScene(newName)
                    renaming = false
                })
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
                .padding(10)
            }
        }
    }

    private func sceneRow(_ scene: StudioScene) -> some View {
        let active = scene.id == c.config.activeSceneID
        return HStack {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 8))
                .foregroundStyle(StudioSkin.dim.opacity(0.5))
            Text(scene.name)
                .font(.system(size: 12, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? StudioSkin.mostaza : StudioSkin.text)
                .lineLimit(1)
            Spacer()
            if active { Image(systemName: "eye.fill").font(.system(size: 9)).foregroundStyle(StudioSkin.mostaza) }
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
        .background(active ? StudioSkin.mostaza.opacity(0.12) : Color.white.opacity(0.001))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { c.selectScene(scene.id) }
        .contextMenu {
            Button("Renombrar…") {
                c.selectScene(scene.id)
                newName = scene.name
                renaming = true
            }
            Button("Duplicar") {
                c.selectScene(scene.id)
                c.duplicateScene()
            }
            .keyboardShortcut("d", modifiers: .command)
            Divider()
            Button("Eliminar", role: .destructive) {
                c.selectScene(scene.id)
                c.deleteScene()
            }
        }
    }

    /// El atajo que pidió Daniel: presionar "Modo Loom" cierra el Estudio y te
    /// deja en el micropanel clásico (la funcionalidad Loom REAL, no compuesta).
    private var loomShortcut: some View {
        Button { c.switchToLoom() } label: {
            HStack(spacing: 6) {
                Image(systemName: "record.circle.fill")
                Text("Modo Loom").font(.system(size: 12, weight: .semibold))
                Spacer()
                Image(systemName: "arrow.right")
            }
            .foregroundStyle(StudioSkin.mostaza)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(StudioSkin.mostaza.opacity(0.08))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(StudioSkin.mostaza.opacity(0.45)))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help("Cierra el Estudio y abre el modo Loom clásico (un clic, burbuja, link instantáneo)")
    }
}

/// Reordena EN VIVO al pasar el drag por encima de otra fila; persiste al soltar.
struct SceneDropDelegate: DropDelegate {
    let target: UUID
    @Binding var dragged: UUID?
    let c: StudioController

    func dropEntered(info: DropInfo) {
        guard let d = dragged, d != target else { return }
        MainActor.assumeIsolated { c.moveScene(id: d, over: target) }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        dragged = nil
        MainActor.assumeIsolated { c.config.save() }
        return true
    }
}

func iconBtn(_ symbol: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(StudioSkin.text)
            .frame(width: 24, height: 22)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }
    .buttonStyle(.plain)
}

// MARK: - panel Fuentes (+ inspector de transform)

struct SourcesPanel: View {
    @EnvironmentObject var c: StudioController
    /// Item de cámara con el selector de dispositivo abierto (doble clic).
    @State private var cameraPickerItem: UUID?
    @State private var screenPickerItem: UUID?

    var body: some View {
        PanelBox(title: "Fuentes — \(c.activeScene?.name ?? "")") {
            VStack(spacing: 4) {
                ScrollView {
                    VStack(spacing: 3) {
                        // pila al revés: el ÚLTIMO item queda encima en el canvas
                        ForEach(Array((c.activeScene?.items ?? []).enumerated().reversed()), id: \.element.id) { _, item in
                            sourceRow(item)
                        }
                    }
                }
                if let item = c.selectedItem {
                    HStack(spacing: 8) {
                        Picker("", selection: Binding(
                            get: { item.fit },
                            set: { v in c.updateSelectedItem { $0.fit = v } })) {
                            ForEach(StudioFit.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .controlSize(.mini)
                        .frame(width: 110)
                        Toggle(isOn: Binding(
                            get: { item.circleMask },
                            set: { v in c.updateSelectedItem { $0.circleMask = v } })) {
                            Text("Burbuja").font(.system(size: 10)).foregroundStyle(StudioSkin.dim)
                        }
                        .toggleStyle(.checkbox)
                    }
                    // El aro también aquí, no solo en el clic derecho: un menú
                    // contextual es invisible hasta que alguien lo descubre.
                    HStack(spacing: 6) {
                        Text("Aro").font(.system(size: 10)).foregroundStyle(StudioSkin.dim)
                        Picker("", selection: Binding(
                            get: { item.glow },
                            set: { v in c.updateSelectedItem { $0.glow = v } })) {
                            Text("—").tag(SceneGlow.nada)
                            Text("Morado").tag(SceneGlow.morado)
                            Text("Ámbar").tag(SceneGlow.ambar)
                        }
                        .pickerStyle(.segmented)
                        .controlSize(.mini)
                        .frame(width: 150)
                    }
                } else {
                    Text("Mueve y escala directo en el preview ↑")
                        .font(.system(size: 9.5))
                        .foregroundStyle(StudioSkin.dim.opacity(0.7))
                }
                HStack(spacing: 8) {
                    Menu {
                        ForEach(StudioSourceKind.allCases, id: \.self) { kind in
                            Button(kind.label) { c.addItem(kind) }
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 24, height: 22)
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 34)
                    iconBtn("minus") { c.removeSelectedItem() }
                    iconBtn("arrow.up") { c.moveSelectedItem(up: true) }
                    iconBtn("arrow.down") { c.moveSelectedItem(up: false) }
                }
            }
        }
    }

    /// El espejo en el clic derecho de la fuente Cámara — **PLANO, sin submenú**
    /// (9 ago 2026, feedback de Daniel: *"es muy difícil clickear el botón porque
    /// desaparece bien fácil"*).
    ///
    /// Era un `Menu` anidado, y los submenús de SwiftUI en macOS no tienen
    /// "triángulo seguro": el cursor viaja en diagonal desde el renglón padre
    /// hacia el submenú y, en cuanto roza el renglón de abajo, el padre pierde
    /// el hover y todo se cierra. No es algo que se pueda ajustar — es cómo
    /// funciona el control. La cura es no anidar.
    ///
    /// Los cuatro tamaños del Loom NO se pierden: viven en los chips que salen
    /// al pasar el cursor SOBRE el espejo, que es donde se deciden mirándolo
    /// (v2.9). Aquí quedan solo las decisiones de sesión.
    @ViewBuilder private var mirrorMenuItems: some View {
        let on = c.config.mirrorEnabled
        Button { c.toggleMirror() } label: {
            Label(on ? "✓ Espejo en la pantalla" : "Espejo en la pantalla",
                  systemImage: "circle.dashed")
        }
        if on {
            Button { c.mirror.toggleXray() } label: {
                Label(c.mirrorXray ? "Quitar rayos X" : "Rayos X (ver qué hay debajo)",
                      systemImage: c.mirrorXray ? "eye.slash" : "eye")
            }
            Button { c.mirror.setLocked(!c.mirrorLocked) } label: {
                Label(c.mirrorLocked ? "Soltar el espejo (que reciba clics)"
                                     : "Fijar el espejo (que no reciba clics)",
                      systemImage: c.mirrorLocked ? "lock.open" : "lock")
            }
            Button { c.flipMirroredCamera() } label: {
                Label(c.mirroredCameraFlipped ? "Quitar el volteo horizontal"
                                              : "Voltear la cámara en horizontal",
                      systemImage: "arrow.left.arrow.right")
            }
            if let note = c.mirrorNote {
                Text("No se ve: \(note)")
            }
        }
    }

    private func sourceRow(_ item: SceneItem) -> some View {
        let selected = item.id == c.selectedItemID
        return Button {
            c.selectedItemID = item.id
        } label: {
            HStack(spacing: 6) {
                Image(systemName: item.kind.icon)
                    .font(.system(size: 10))
                    .foregroundStyle(selected ? StudioSkin.mostaza : StudioSkin.dim)
                Text(item.kind.label)
                    .font(.system(size: 11.5))
                    .foregroundStyle(item.enabled ? StudioSkin.text : StudioSkin.dim)
                    .lineLimit(1)
                // Punto del color del aro: se VE cuál fuente lo trae puesto sin
                // tener que abrir el menú.
                if let rgb = item.glow.rgb {
                    Circle()
                        .stroke(Color(red: rgb.r, green: rgb.g, blue: rgb.b), lineWidth: 1.6)
                        .frame(width: 8, height: 8)
                        .shadow(color: Color(red: rgb.r, green: rgb.g, blue: rgb.b).opacity(0.9), radius: 3)
                }
                // Sin botón en la barra, el estado del espejo se ve AQUÍ: punteado
                // mostaza cuando está proyectado, ámbar cuando el sensor dice que
                // está tapando contenido. Un modo encendido tiene que verse en
                // algún sitio (invariante 5b) — pero en el sitio que le toca.
                if item.kind == .camera && c.config.mirrorEnabled {
                    Image(systemName: "circle.dashed")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(StudioSkin.mostaza)
                        .help("Espejo proyectado en la pantalla que se graba")
                }
                Spacer()
                Button {
                    c.selectedItemID = item.id
                    c.updateSelectedItem { $0.enabled.toggle() }
                } label: {
                    Image(systemName: item.enabled ? "eye" : "eye.slash")
                        .font(.system(size: 9))
                        .foregroundStyle(StudioSkin.dim)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(selected ? Color.white.opacity(0.07) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(item.kind == .camera ? "Doble clic: elegir la cámara"
              : item.kind == .screen ? "Doble clic: elegir la pantalla"
              : item.kind.label)
        // DOBLE CLIC sobre la fuente: selector de dispositivo, cambia EN
        // CALIENTE (pedido de Daniel 6 ago para la cámara — estilo OBS, sin
        // abrir Ajustes; 25 ago el mismo gesto para la PANTALLA, que era lo
        // único que seguía obligando a ir a Ajustes del sistema).
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            switch item.kind {
            case .camera:
                c.selectedItemID = item.id
                cameraPickerItem = item.id
            case .screen:
                c.selectedItemID = item.id
                screenPickerItem = item.id
            default: break
            }
        })
        .popover(isPresented: Binding(
            get: { cameraPickerItem == item.id },
            set: { if !$0 { cameraPickerItem = nil } }), arrowEdge: .trailing) {
            DevicePickerPopover(title: "Cámara", entries: Devices.cameras(),
                                currentID: c.currentCameraID) { id in
                c.setCameraDevice(id: id)
                cameraPickerItem = nil
            }
        }
        .popover(isPresented: Binding(
            get: { screenPickerItem == item.id },
            set: { if !$0 { screenPickerItem = nil } }), arrowEdge: .trailing) {
            DevicePickerPopover(title: "Pantalla", entries: Devices.pantallas(),
                                currentID: c.currentScreenID,
                                defaultLabel: "La principal del sistema") { id in
                c.setScreenDisplay(id: id)
                screenPickerItem = nil
            }
        }
        // CLIC DERECHO sobre la fuente: el aro neón del Loom, aquí (pedido de
        // Daniel). Actúa sobre ESTA fila por id — el clic derecho no selecciona.
        .contextMenu {
            if item.kind == .screen {
                Button("Cambiar pantalla…") {
                    c.selectedItemID = item.id
                    screenPickerItem = item.id
                }
            }
            if item.kind == .camera {
                Button("Cambiar cámara…") {
                    c.selectedItemID = item.id
                    cameraPickerItem = item.id
                }
                // VOLTEAR EN HORIZONTAL, aquí (pedido de Daniel, 17 ago).
                //
                // El volteo YA existía —`flipH` en el item, el transform en el
                // compositor y en el espejo— pero solo se podía tocar desde el
                // submenú del Espejo, y solo con el espejo ENCENDIDO. O sea que
                // una propiedad de ESTA fuente vivía escondida detrás de otra
                // función. Ahora se voltea desde donde se piensa: la fuente.
                //
                // Cae sobre el ITEM, así que el programa y el espejo lo ven con el
                // mismo valor sin que nadie sincronice nada.
                Button {
                    c.selectedItemID = item.id
                    c.updateItem(item.id) { $0.flipH.toggle() }
                } label: {
                    Label(item.flipH ? "✓ Voltear en horizontal"
                                     : "Voltear en horizontal",
                          systemImage: "arrow.left.arrow.right")
                }
                // EL ESPEJO VIVE AQUÍ, y solo aquí (Daniel, 9 ago: "ya vi que
                // estaba en la cámara, clic derecho… déjala ahí, no es necesario
                // que esté hasta arriba"). El botón del top bar se retiró: la
                // barra es para SENSORES, y el espejo es una propiedad de esta
                // fuente. Lo que sí quedó arriba es nada; el estado se ve en el
                // punto de esta misma fila y en el propio espejo.
                mirrorMenuItems
                Divider()
            }
            ForEach(SceneGlow.allCases, id: \.self) { g in
                Button {
                    c.selectedItemID = item.id
                    c.updateItem(item.id) { $0.glow = g }
                } label: {
                    Label(item.glow == g ? "✓ \(g.label)" : g.label,
                          systemImage: g == .nada ? "circle.dashed" : "circle.circle.fill")
                }
            }
            Divider()
            Button(item.circleMask ? "✓ Burbuja (recorte circular)" : "Burbuja (recorte circular)") {
                c.selectedItemID = item.id
                c.updateItem(item.id) { $0.circleMask.toggle() }
            }
            Button(item.enabled ? "Ocultar fuente" : "Mostrar fuente") {
                c.updateItem(item.id) { $0.enabled.toggle() }
            }
            Divider()
            Button("Eliminar fuente", role: .destructive) {
                c.selectedItemID = item.id
                c.removeSelectedItem()
            }
        }
    }

}

// MARK: - Ajustes del Estudio (80/20 para GRABAR — no streaming)

struct StudioSettingsView: View {
    @EnvironmentObject var c: StudioController
    @State private var cams: [Devices.Entry] = []
    @State private var mics: [Devices.Entry] = []
    @State private var camID = ""
    @State private var micID = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ajustes del Estudio")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(StudioSkin.text)

            section("Video") {
                labeled("FPS") {
                    Picker("", selection: $c.config.fps) {
                        Text("24").tag(24); Text("30").tag(30); Text("60").tag(60)
                    }
                    .pickerStyle(.segmented).frame(width: 140)
                }
                labeled("Canvas") {
                    Picker("", selection: $c.config.canvasMode) {
                        ForEach(StudioCanvasMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .frame(width: 190)
                }
                labeled("Calidad programa") {
                    Picker("", selection: $c.config.programQuality) {
                        ForEach(StudioQuality.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .frame(width: 190)
                }
            }

            section("Audio y dispositivos") {
                labeled("Cámara") {
                    Picker("", selection: $camID) {
                        Text("Default del sistema").tag("")
                        ForEach(cams) { Text($0.name).tag($0.id) }
                    }
                    .frame(width: 220)
                }
                labeled("Micrófono") {
                    Picker("", selection: $micID) {
                        Text("Default del sistema").tag("")
                        ForEach(mics) { Text($0.name).tag($0.id) }
                    }
                    .frame(width: 220)
                }
                Toggle("Micrófono activo", isOn: $c.config.micEnabled)
                    .toggleStyle(.checkbox).font(.system(size: 11.5))
                Toggle("Audio del sistema", isOn: $c.config.systemAudioEnabled)
                    .toggleStyle(.checkbox).font(.system(size: 11.5))
                Text("Cámara y mic son los MISMOS del modo Loom (una sola config).")
                    .font(.system(size: 9.5)).foregroundStyle(StudioSkin.dim)
            }

            section("Salida") {
                HStack {
                    Text("~/Movies/SFCast/{id}/")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(StudioSkin.text)
                    Button("Abrir") {
                        NSWorkspace.shared.activateFileViewerSelecting([AppSettings.recordingsDir])
                    }
                    .controlSize(.small)
                }
                Text("Qué archivos salen (raw pantalla / raw cámara / programa) se elige en el panel Salidas.")
                    .font(.system(size: 9.5)).foregroundStyle(StudioSkin.dim)
            }

            section("Ventana") {
                Toggle("Visible en capturas y grabaciones", isOn: Binding(
                    get: { c.config.windowCapturable },
                    set: { v in
                        c.config.windowCapturable = v
                        c.config.save()
                        c.applyWindowSharing()   // aplica al instante, sin reiniciar
                    }))
                    .toggleStyle(.checkbox).font(.system(size: 11.5))
                Text("OFF (default): el Estudio se auto-excluye de screenshots y de la grabación, estilo OBS. ON: ventana normal.")
                    .font(.system(size: 9.5)).foregroundStyle(StudioSkin.dim)
            }

            HStack {
                // EN CALIENTE (6 ago): nada de "reinicia el motor" — cada cambio
                // viaja por su canal barato (StudioEngine.applyLive), estilo OBS.
                Button("Aplicar") {
                    saveDevices()
                    c.applySettings()
                    c.showSettings = false
                }
                .keyboardShortcut(.defaultAction)
                Button("Cerrar") { c.showSettings = false }
            }
        }
        .padding(20)
        .frame(width: 430)
        .background(StudioSkin.bg)
        .onAppear {
            cams = Devices.cameras()
            mics = Devices.microphones()
            let s = AppSettings.load()
            camID = s.cameraDeviceID ?? ""
            micID = s.micDeviceID ?? ""
        }
    }

    private func saveDevices() {
        var s = AppSettings.load()
        s.cameraDeviceID = camID.isEmpty ? nil : camID
        s.micDeviceID = micID.isEmpty ? nil : micID
        s.save()
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold)).tracking(1.1)
                .foregroundStyle(StudioSkin.mostaza.opacity(0.85))
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StudioSkin.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func labeled<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(label).font(.system(size: 11.5)).foregroundStyle(StudioSkin.text)
                .frame(width: 110, alignment: .leading)
            content()
            Spacer()
        }
    }
}

// MARK: - selector de dispositivo (doble clic en Fuentes/Mixer)

/// Lista de cámaras o micrófonos con el actual marcado. Elegir cambia EN
/// CALIENTE (setCameraDevice/setMicDevice → reconciliación en la cola de
/// sesión) — sin reiniciar el motor, sin abrir Ajustes.
struct DevicePickerPopover: View {
    let title: String
    let entries: [Devices.Entry]
    let currentID: String?
    /// Que dice la fila de "sin elección explícita". Para cámara/mic es el
    /// default del sistema; para pantallas, la principal. Mismo picker.
    var defaultLabel: String = "Default del sistema"
    let pick: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .semibold)).tracking(1.1)
                .foregroundStyle(.secondary)
                .padding(.bottom, 3)
            row(name: defaultLabel, id: nil)
            ForEach(entries) { e in row(name: e.name, id: e.id) }
        }
        .padding(10)
        .frame(minWidth: 210, alignment: .leading)
    }

    private func row(name: String, id: String?) -> some View {
        let current = (currentID ?? "") == (id ?? "")
        return Button {
            pick(id)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: current ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 10))
                    .foregroundStyle(current ? StudioSkin.mostaza : .secondary)
                Text(name).font(.system(size: 11.5)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - panel Mixer

struct MixerPanel: View {
    @EnvironmentObject var c: StudioController
    @State private var showMicPicker = false

    var body: some View {
        PanelBox(title: "Mixer") {
            VStack(alignment: .leading, spacing: 12) {
                meter("Micrófono", kind: .mic, enabled: Binding(
                    get: { c.config.micEnabled },
                    set: { c.config.micEnabled = $0; c.applySettings() }))
                    .help("Doble clic: elegir el micrófono")
                    // Doble clic = selector de mic, gemelo del de la cámara en
                    // Fuentes (pedido de Daniel 6 ago). Cambia en caliente.
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { showMicPicker = true }
                    .popover(isPresented: $showMicPicker, arrowEdge: .trailing) {
                        DevicePickerPopover(title: "Micrófono", entries: Devices.microphones(),
                                            currentID: c.currentMicID) { id in
                            c.setMicDevice(id: id)
                            showMicPicker = false
                        }
                    }
                meter("Sistema", kind: .system, enabled: Binding(
                    get: { c.config.systemAudioEnabled },
                    set: { c.config.systemAudioEnabled = $0; c.applySettings() }))
                Text("Aplican al instante ·\ndoble clic al mic: elegirlo")
                    .font(.system(size: 9))
                    .foregroundStyle(StudioSkin.dim.opacity(0.7))
            }
        }
    }

    private func meter(_ label: String, kind: MeterKind, enabled: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.system(size: 11)).foregroundStyle(StudioSkin.text)
                Spacer()
                Toggle("", isOn: enabled).toggleStyle(.checkbox).labelsHidden()
                    .disabled(c.isRecording)
            }
            // La barra vive FUERA de SwiftUI (v2.8): el nivel a 15 Hz va
            // directo a su CALayer, sin invalidar la jerarquía.
            MeterBarView(kind: kind)
                .frame(height: 7)
        }
    }
}

// MARK: - panel Salidas + botón de grabación

struct OutputsPanel: View {
    @EnvironmentObject var c: StudioController

    var body: some View {
        PanelBox(title: "Salidas") {
            VStack(alignment: .leading, spacing: 7) {
                outputToggle("Pantalla (raw)", "screen.mp4 · pesado", available: c.screenOK, isOn: Binding(
                    get: { c.config.outputs.rawScreen },
                    set: { c.config.outputs.rawScreen = $0; c.config.save() }))
                outputToggle("Cámara (raw)", "camera.mov · pesado", available: c.cameraOK, isOn: Binding(
                    get: { c.config.outputs.rawCamera },
                    set: { c.config.outputs.rawCamera = $0; c.config.save() }))
                outputToggle("Programa", "compuesto + escenas", available: true, isOn: Binding(
                    get: { c.config.outputs.program },
                    set: { c.config.outputs.program = $0; c.config.save() }))
                // EL COSTO A LA VISTA. El bug del 25 jul (6 GB en 50 min) vivió
                // porque nada en la app decía nunca cuánto iba a pesar.
                Text(c.weightHint)
                    .font(.system(size: 9.5))
                    .foregroundStyle(c.weightHeavy ? .orange : StudioSkin.dim)
                Spacer()
                HStack {
                    Button {
                        c.toggleRecord()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: c.isRecording ? "stop.fill" : "record.circle.fill")
                            Text(c.isRecording ? "Detener" : "Grabar")
                                .font(.system(size: 12.5, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(c.isRecording ? Color.red : StudioSkin.mostaza.opacity(0.9))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    if let dir = c.lastSessionDir, !c.isRecording {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([dir])
                        } label: {
                            Image(systemName: "folder")
                                .foregroundStyle(StudioSkin.dim)
                        }
                        .buttonStyle(.plain)
                        .help("Abrir la última sesión")
                    }
                }
            }
        }
    }

    private func outputToggle(_ label: String, _ sub: String, available: Bool, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 6) {
            Toggle("", isOn: isOn)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(c.isRecording)
            VStack(alignment: .leading, spacing: 0) {
                Text(label)
                    .font(.system(size: 11.5))
                    .foregroundStyle(available ? StudioSkin.text : StudioSkin.dim)
                Text(sub)
                    .font(.system(size: 9))
                    .foregroundStyle(StudioSkin.dim.opacity(0.8))
            }
            if !available {
                Text("sin señal")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange.opacity(0.8))
            }
        }
    }
}
