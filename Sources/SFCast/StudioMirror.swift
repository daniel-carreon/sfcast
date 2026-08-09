import AppKit
import AVFoundation
import CoreGraphics

/// EL ESPEJO — la burbuja del programa, proyectada sobre la pantalla que se captura.
///
/// El problema (Daniel, 9 ago, dos monitores, a punto de grabar YouTube): en
/// Modo Estudio la cámara NUNCA toca la pantalla física — la pega el compositor
/// sobre el canvas. Así que el texto le queda debajo de la burbuja y **no hay
/// forma de enterarse mientras graba**. El modo Loom sí la enseña, pero porque
/// allá la burbuja ES un panel real que se quema en el video.
///
/// El espejo trae esa evidencia al Estudio SIN quemar nada:
///
///  1. Es un `NSPanel` con `sharingType = .none` → **invisible a cualquier
///     captura**, el mismo mecanismo del pill y de la ventana del Estudio. Si
///     esto falla sale la cara DUPLICADA en el video (el panel real, más la
///     burbuja compuesta encima). Por eso `--mirrortest` MIDE el frame de
///     pantalla con el espejo apagado y prendido y compara: la invisibilidad se
///     prueba, no se supone.
///  2. Se coloca por la **INVERSA de la colocación de la fuente Pantalla**
///     (`MirrorGeometry`), no por una fórmula paralela. Si `Compositor.place`
///     cambia de regla, esto cambia con él — no puede desalinearse por deriva.
///  3. Se arrastra: mueve el rect del item de escena EN VIVO y el preview del
///     Estudio lo sigue en el mismo frame.
///
/// El video sale del `AVCaptureSession` que **ya tiene el Estudio** (una sola
/// dueña de cámara/mic — invariante heredado del micropanel Loom): ni una sesión
/// nueva, ni un frame extra a main, ni tráfico por `@Published`.
@MainActor
final class StudioMirror: NSObject {

    /// Por qué el espejo NO se está mostrando. Se enseña en la UI: un espejo que
    /// desaparece en silencio sería justo el patrón que costó los bugs del 25
    /// jul (invariante 5b — nada degrada sin decirlo).
    enum Unavailable: Equatable {
        case sinCamara, sinPantalla, noSeSolapan, ocupaTodo, sinDisplay, motorAbajo

        var reason: String {
            switch self {
            case .sinCamara:   return "esta escena no tiene cámara"
            case .sinPantalla: return "esta escena no tiene pantalla"
            case .noSeSolapan: return "aquí la cámara no tapa la pantalla"
            case .ocupaTodo:   return "la cámara ocupa casi todo el cuadro"
            case .sinDisplay:  return "no ubico la pantalla capturada"
            case .motorAbajo:  return "el motor del Estudio está abajo"
            }
        }
    }

    /// Una cámara que cubre más que esto del display no es una burbuja: es la
    /// toma. Proyectarla taparía la pantalla entera y sería estorbo, no ayuda.
    static let maxCoverage: Double = 0.55

    /// SOLO `--mirrorlook`: deja el espejo capturable para poder revisar el
    /// diseño con un screenshot. Existe por el mismo motivo que `--paneltest`
    /// para el pill: lo que es invisible a la captura por diseño es también
    /// invisible para quien quiere mirarlo, y el auto-retrato por `cacheDisplay`
    /// no sabe pintar ni la capa de video ni la sombra del halo. En cualquier
    /// otro arranque esto es `false` y el espejo es invisible, punto.
    static var capturableForQA = false

    // MARK: - estado

    private(set) var panel: MirrorPanel?
    private var content: MirrorContentView?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var chips: MirrorChipsPanel?
    private var chipHideTimer: Timer?
    private var placeholder: NSTextField?

    /// Último layout aplicado — `sync` compara y no toca el panel si nada
    /// cambió (la llama el timer de 1 Hz como red de seguridad).
    private var applied: MirrorLayout?
    /// Geometría y rect normalizado vigentes, cacheados en `sync`. Son lo que
    /// el arrastre necesita para traducir píxeles de mouse a rect de escena.
    private(set) var geometry: MirrorGeometry?
    private(set) var itemNormRect: CGRect?
    private(set) var mirroredItemID: UUID?
    private var dragAnchor: CGRect?

    private(set) var unavailable: Unavailable?

    /// FIJADO: el panel deja de recibir clics (`ignoresMouseEvents`). Existe
    /// porque un círculo de ~400 pt comiéndose los clics de una esquina en plena
    /// toma sería peor que el bug que vinimos a arreglar. Se suelta desde el
    /// menú del botón Espejo (fijado, los chips ya no se pueden tocar).
    private(set) var locked = false
    /// RAYOS X: baja la opacidad para ver QUÉ hay debajo. Cero heurística, cero
    /// falsos positivos — el complemento honesto del sensor de oclusión.
    private(set) var xray = false
    /// El sensor de oclusión encendió el aviso (aro punteado ámbar por fuera).
    private(set) var occluding = false

    var isVisible: Bool { panel?.isVisible ?? false }
    var windowNumber: Int { panel?.windowNumber ?? -1 }
    /// El rect que ocupa el espejo en pt de pantalla (QA y sensor lo usan).
    var screenRect: CGRect? { applied?.rect }

    // MARK: - enganches con el controller

    /// Arrastre EN VIVO: rect normalizado nuevo para el item. El controller lo
    /// manda al `sceneBox` del compositor, JAMÁS al `@Published config` (a
    /// 60-120 Hz de mouse sería el bug del vúmetro del 7 ago otra vez).
    var onDragLive: ((CGRect) -> Void)?
    /// Soltar el mouse: aquí sí se persiste, una sola vez.
    var onDragCommit: (() -> Void)?
    /// Chips de tamaño. Segundo parámetro = nuevo `circleMask` (nil = déjalo
    /// como está); el tamaño completo, igual que en el Loom, deja de ser
    /// círculo y pasa a rectángulo redondeado.
    var onResize: ((CGRect, Bool?) -> Void)?
    /// El chip de cerrar pide apagar el espejo (el toggle vive en el controller).
    var onRequestClose: (() -> Void)?
    /// Cambió algo que la UI del Estudio debe reflejar (fijado / rayos X).
    var onStateChange: (() -> Void)?

    // MARK: - reconciliación

    /// Deja el panel exactamente como la escena pide AHORA. Idempotente: se
    /// puede llamar en cada cambio de escena, cada tick del arrastre y cada
    /// segundo del timer sin costo si nada se movió.
    @discardableResult
    func sync(scene: StudioScene?, canvas: CGSize, session: AVCaptureSession?,
              mirrored: Bool, engineRunning: Bool) -> Bool {
        guard engineRunning else { return teardown(.motorAbajo) }
        guard let scene else { return teardown(.sinCamara) }
        guard let screen = RecordingController.captureScreen() else { return teardown(.sinDisplay) }
        // El item de cámara de MÁS ARRIBA en la pila: es el que se ve.
        guard let cam = scene.items.last(where: { $0.kind == .camera && $0.enabled }) else {
            return teardown(.sinCamara)
        }
        guard let scr = scene.items.first(where: { $0.kind == .screen && $0.enabled }) else {
            return teardown(.sinPantalla)
        }
        guard let geo = MirrorGeometry(canvas: canvas, screenItem: scr, screen: screen) else {
            return teardown(.sinDisplay)
        }
        // ¿La burbuja cae ENCIMA de lo que se ve de la pantalla? En "Lado a
        // lado" la cámara vive FUERA del recuadro de la pantalla: no tapa nada,
        // y un espejo ahí mentiría sobre lo que hace.
        let camCanvas = geo.canvasRect(of: cam)
        guard camCanvas.intersects(geo.screenTarget) else { return teardown(.noSeSolapan) }
        let rect = geo.screenRect(fromCanvas: camCanvas)
        let coverage = (rect.width * rect.height) / max(screen.frame.width * screen.frame.height, 1)
        guard coverage < Self.maxCoverage else { return teardown(.ocupaTodo) }

        geometry = geo
        itemNormRect = cam.rect
        mirroredItemID = cam.id
        unavailable = nil

        let layout = MirrorLayout(itemID: cam.id, rect: rect, circle: cam.circleMask,
                                  glow: cam.glow, opacity: cam.opacity,
                                  screenNumber: screen.displayNumber,
                                  screenMinSide: min(screen.frame.width, screen.frame.height))
        if panel == nil { build(session: session, mirrored: mirrored) }
        if applied != layout {
            applied = layout
            apply(layout)
        }
        if !(panel?.isVisible ?? false) { panel?.orderFrontRegardless() }
        return true
    }

    func hide() { _ = teardown(nil) }

    /// Baja el panel y recuerda POR QUÉ (la UI lo enseña).
    ///
    /// ⚠️ DESMONTA de verdad, no solo esconde. Un `AVCaptureVideoPreviewLayer`
    /// que sigue colgado de la sesión con su ventana fuera de pantalla ESTRANGULA
    /// la sesión entera: medido el 9 ago con `--mirrortest`, la cámara pasaba de
    /// 60 fps a **0** al apagar el espejo — y ese cero se lo come el PROGRAMA,
    /// que se quedaría con la cara congelada mientras graba. Es el mismo patrón
    /// de la pantalla congelada del 25 jul, ahora por el lado de la cámara: la
    /// única cura fiable es soltar la sesión, no esconder la ventana.
    @discardableResult
    private func teardown(_ why: Unavailable?) -> Bool {
        unavailable = why
        applied = nil
        geometry = nil
        itemNormRect = nil
        mirroredItemID = nil
        dragAnchor = nil
        hideChips()
        chips = nil
        if let l = previewLayer {
            l.session = nil            // <- lo que de verdad libera la sesión
            l.removeFromSuperlayer()
        }
        previewLayer = nil
        content?.videoLayer = nil
        placeholder = nil
        content = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        return false
    }

    // MARK: - construcción

    private func build(session: AVCaptureSession?, mirrored: Bool) {
        let p = MirrorPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        // INVARIANTE DEL ESPEJO: invisible a la captura. Sin esto sale la cara
        // duplicada en el video. `--mirrortest` lo mide con el frame real.
        p.sharingType = Self.capturableForQA ? .readOnly : .none
        if Self.capturableForQA { Log.error("Espejo: CAPTURABLE (--mirrorlook) — solo para revisar el diseño") }
        p.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 3)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false                 // el halo lo pinta la capa, como en el Loom
        p.hidesOnDeactivate = false
        p.ignoresMouseEvents = locked
        p.alphaValue = xray ? 0.18 : 1.0

        let view = MirrorContentView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        view.mirror = self
        if let session {
            let l = AVCaptureVideoPreviewLayer(session: session)
            l.videoGravity = .resizeAspectFill
            // El programa NO espejea (el compositor pega los frames crudos del
            // data-output). Si aquí espejeáramos "porque se ve más natural", el
            // espejo mentiría sobre el encuadre: se copia lo que trae la
            // conexión real, no lo que se sienta bonito.
            if let conn = l.connection, conn.isVideoMirroringSupported {
                conn.automaticallyAdjustsVideoMirroring = false
                conn.isVideoMirrored = mirrored
            }
            view.videoLayer = l
            previewLayer = l
        }
        p.contentView = view
        content = view
        panel = p

        view.addTrackingArea(NSTrackingArea(rect: view.bounds,
                                            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                            owner: view, userInfo: nil))
        if session == nil { setPlaceholder("sin cámara") }
        Log.info("Espejo: panel creado (sharingType=.none, espejeado=\(mirrored))")
    }

    private func apply(_ l: MirrorLayout) {
        guard let p = panel, let view = content else { return }
        let frame = l.rect.insetBy(dx: -l.pad, dy: -l.pad)
        p.setFrame(frame, display: true)
        view.frame = NSRect(origin: .zero, size: frame.size)
        view.applyLayout(l)
        placeholder?.frame = view.bounds.insetBy(dx: l.pad + 10, dy: l.pad + 10)
        repositionChips()
    }

    private func setPlaceholder(_ text: String?) {
        guard let view = content else { return }
        if let text {
            if placeholder == nil {
                let lbl = NSTextField(labelWithString: "")
                lbl.alignment = .center
                lbl.textColor = NSColor(calibratedWhite: 0.75, alpha: 1)
                lbl.font = .systemFont(ofSize: 12, weight: .semibold)
                lbl.maximumNumberOfLines = 2
                view.addSubview(lbl)
                placeholder = lbl
            }
            placeholder?.stringValue = text
            placeholder?.isHidden = false
        } else {
            placeholder?.isHidden = true
        }
    }

    // MARK: - modos (fijar / rayos X / aviso de oclusión)

    func setLocked(_ on: Bool) {
        locked = on
        panel?.ignoresMouseEvents = on
        if on { hideChips() }
        onStateChange?()
        Log.info("Espejo: \(on ? "fijado (no recibe clics)" : "suelto (arrastrable)")")
    }

    func setXray(_ on: Bool) {
        xray = on
        panel?.alphaValue = on ? 0.18 : 1.0
        onStateChange?()
    }

    func toggleXray() { setXray(!xray) }

    /// Aviso del SENSOR de oclusión: aro punteado ámbar POR FUERA del aro real.
    /// A propósito NO se repinta el aro del programa de otro color — el espejo
    /// tiene que seguir enseñando cómo se ve el video, y la alarma debe leerse
    /// como lo que es: UI, no programa.
    func setOccluding(_ on: Bool) {
        guard occluding != on else { return }
        occluding = on
        content?.setWarning(on)
    }

    // MARK: - arrastre (lo que pidió Daniel: muevo aquí, se mueve el programa)

    /// QA (`--mirrortest`): auto-retrato del panel. El espejo es
    /// `sharingType = .none`, o sea que NINGÚN screenshot del sistema puede
    /// enseñarlo — que es justo lo que queremos para el video, y justo lo que
    /// impide revisar cómo quedó el aro. `cacheDisplay` renderiza la jerarquía
    /// de vistas por su cuenta y salta ese muro (mismo truco que
    /// `saveWindowShot`). Un aro neón no se valida leyendo código: se mira.
    @discardableResult
    func qaSelfShot(to url: URL) -> Bool {
        guard let v = panel?.contentView,
              let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return false }
        v.cacheDisplay(in: v.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        try? png.write(to: url)
        return true
    }

    /// QA (`--mirrortest`): ejerce el camino REAL del arrastre (dragBegan →
    /// dragMoved → dragEnded). Probar el arrastre llamando al setter no prueba
    /// el arrastre: prueba el setter.
    func qaDrag(byScreenDelta d: CGSize) {
        dragBegan()
        dragMoved(byScreenDelta: d)
        dragEnded()
    }

    fileprivate func dragBegan() { dragAnchor = itemNormRect }

    fileprivate func dragMoved(byScreenDelta d: CGSize) {
        guard let geo = geometry, let anchor = dragAnchor else { return }
        let dn = geo.normalizedDelta(fromScreen: d)
        var r = anchor
        r.origin.x += dn.width
        r.origin.y += dn.height
        onDragLive?(r)
    }

    fileprivate func dragEnded() {
        guard dragAnchor != nil else { return }
        dragAnchor = nil
        onDragCommit?()
    }

    // MARK: - tamaños (los MISMOS cuatro de la burbuja del Loom)

    /// El diámetro actual de la burbuja en PUNTOS de pantalla — el número con el
    /// que habla el Loom, no el rect normalizado con el que habla la escena.
    var currentDiameter: CGFloat? {
        guard let l = applied else { return nil }
        return l.circle ? l.minSide : max(l.rect.width, l.rect.height)
    }

    /// Pone la burbuja en uno de los cuatro tamaños de `CameraBubble.Size`.
    /// Se REUSA el enum del Loom a propósito: son los mismos tamaños por
    /// definición, no una escala paralela que se despegaría con el tiempo.
    func applySize(_ size: CameraBubble.Size) {
        guard let geo = geometry, let l = applied,
              let screen = RecordingController.captureScreen() else { return }
        if size == .full {
            // Igual que el Loom: rectángulo 16:9 centrado al 72% del ancho útil,
            // y deja de ser círculo (allá el `corner` pasa a 24 pt).
            let vf = screen.visibleFrame
            let w = vf.width * 0.72
            let h = w * 9.0 / 16.0
            let r = CGRect(x: vf.midX - w / 2, y: vf.midY - h / 2, width: w, height: h)
            onResize?(geo.normalizedRect(fromScreen: r), false)
            return
        }
        // Cuadrado del diámetro pedido, centrado donde ya estaba: con recorte
        // circular el círculo es el INSCRITO, así que un rect cuadrado hace que
        // el diámetro sea exactamente el pedido.
        let d = size.diameter
        let c = CGPoint(x: l.rect.midX, y: l.rect.midY)
        let r = CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)
        onResize?(geo.normalizedRect(fromScreen: r), true)
    }

    /// El tamaño actual, como uno de los CUATRO del Loom: el más cercano por
    /// diámetro. Lo necesita `cycleSize` para saber de dónde parte cuando la
    /// burbuja viene de un arrastre a mano.
    var currentSize: CameraBubble.Size {
        guard let d = currentDiameter else { return .m }
        if let l = applied, !l.circle, l.rect.width > CameraBubble.Size.l.diameter { return .full }
        var best = CameraBubble.Size.m
        var gap = CGFloat.greatestFiniteMagnitude
        for s in CameraBubble.Size.allCases where s != .full {
            let g = abs(s.diameter - d)
            if g < gap { gap = g; best = s }
        }
        return best
    }

    /// Doble clic = siguiente tamaño, EXACTAMENTE como la burbuja del Loom
    /// (`CameraBubble.cycleSize`). Mismo gesto, mismo orden, misma escalera.
    fileprivate func cycleSize() {
        let all = CameraBubble.Size.allCases
        let idx = all.firstIndex(of: currentSize) ?? 0
        applySize(all[(idx + 1) % all.count])
    }

    // MARK: - chips al hover (el mismo idioma que los del Loom)

    fileprivate func showChips() {
        guard !locked, applied != nil else { return }
        chipHideTimer?.invalidate()
        if chips == nil { chips = MirrorChipsPanel() }
        chips?.attach(to: self)
        repositionChips()
        chips?.orderFrontRegardless()
    }

    fileprivate func scheduleHideChips() {
        chipHideTimer?.invalidate()
        chipHideTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.hideChips() }
        }
    }

    private func hideChips() { chips?.orderOut(nil) }

    private func repositionChips() {
        guard let p = panel, let c = chips, let l = applied else { return }
        let x = l.rect.midX - c.frame.width / 2
        // Debajo del círculo; si no cabe, arriba. Las esquinas de ABAJO son el
        // sitio favorito de Daniel para la burbuja: ahí siempre se sale por abajo.
        let below = l.rect.minY - c.frame.height - 8
        let vf = (p.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let y = below < vf.minY ? l.rect.maxY + 8 : below
        c.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Los chips de la burbuja llevan SOLO lo que se hace mirando la burbuja:
    /// tamaño y apagar. Rayos X y fijar viven en el botón Espejo del Estudio —
    /// son decisiones de sesión, no gestos sobre el círculo (pedido de Daniel,
    /// 9 ago: "el ojo pensaba verlo en el studio, no en el círculo").
    @objc fileprivate func chipTapped(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        if id == "close" { onRequestClose?(); return }
        if let s = CameraBubble.Size(rawValue: id) { applySize(s) }
    }
}

// MARK: - layout resuelto (lo que el panel tiene que pintar)

/// Todo lo que define el aspecto del espejo en un instante. `Equatable` a
/// propósito: `sync` compara y no toca nada si no cambió.
struct MirrorLayout: Equatable {
    let itemID: UUID
    /// Rect del item en PUNTOS de pantalla, coords globales de AppKit.
    let rect: CGRect
    let circle: Bool
    let glow: SceneGlow
    let opacity: Double
    let screenNumber: CGDirectDisplayID

    /// Lado menor de la PANTALLA capturada, en pt. Entra en el layout porque el
    /// halo se topa contra el lienzo, no solo contra el item (ver `SceneGlow`):
    /// sin este dato el espejo y el compositor darían halos distintos y se
    /// acabaría la paridad.
    let screenMinSide: CGFloat

    var minSide: CGFloat { min(rect.width, rect.height) }
    /// EXACTAMENTE la misma cuenta que el compositor. Sin anillo (Daniel, 9 ago).
    var halo: CGFloat {
        SceneGlow.halo(itemMinSide: minSide, canvasMinSide: screenMinSide)
    }
    var pad: CGFloat { halo * 3 + 6 }

    /// El recorte, en coordenadas locales del contenido. Con `circle` es el
    /// círculo INSCRITO y CENTRADO — igual que `Compositor.place`, que recorta
    /// al lado menor. Con el rect completo el espejo saldría más gordo que el
    /// video y el aro quedaría despegado del recorte.
    func shapePath(in local: CGRect) -> CGPath {
        if circle {
            let d = min(local.width, local.height)
            let box = CGRect(x: local.midX - d / 2, y: local.midY - d / 2, width: d, height: d)
            return CGPath(roundedRect: box, cornerWidth: d / 2, cornerHeight: d / 2, transform: nil)
        }
        let r = minSide * 0.035
        return CGPath(roundedRect: local, cornerWidth: r, cornerHeight: r, transform: nil)
    }
}

// MARK: - geometría: canvas del programa ⇄ pantalla física

/// La INVERSA de cómo `Compositor.place` coloca la fuente Pantalla.
///
/// Es la única fuente de verdad de dónde va el espejo. Se deriva del MISMO
/// contrato que el compositor (rect normalizado + aspect fill/fit centrado), y
/// por eso no puede despegarse del programa aunque cambie la resolución, el
/// canvas fijo (1080/1440) o el monitor.
struct MirrorGeometry {
    /// px del canvas del programa.
    let canvas: CGSize
    /// px que entrega el stream de pantalla (nativo del display capturado).
    let sourcePixels: CGSize
    /// Marco del display capturado en PUNTOS, coords globales de AppKit.
    let screenFrame: CGRect
    let backing: CGFloat
    /// Dónde cae la fuente Pantalla dentro del canvas, en px.
    let screenTarget: CGRect
    /// px de canvas por cada px de la fuente.
    let scale: CGFloat

    init?(canvas: CGSize, screenItem: SceneItem, screen: NSScreen,
          sourcePixels: CGSize? = nil) {
        guard canvas.width > 1, canvas.height > 1 else { return nil }
        let backing = screen.backingScaleFactor
        let src = sourcePixels ?? CGSize(width: screen.frame.width * backing,
                                         height: screen.frame.height * backing)
        guard src.width > 1, src.height > 1, backing > 0 else { return nil }
        let target = CGRect(x: screenItem.rect.origin.x * canvas.width,
                            y: screenItem.rect.origin.y * canvas.height,
                            width: screenItem.rect.width * canvas.width,
                            height: screenItem.rect.height * canvas.height)
        guard target.width > 1, target.height > 1 else { return nil }
        let s = screenItem.fit == .fill
            ? max(target.width / src.width, target.height / src.height)
            : min(target.width / src.width, target.height / src.height)
        guard s > 0 else { return nil }
        self.canvas = canvas
        self.sourcePixels = src
        self.screenFrame = screen.frame
        self.backing = backing
        self.screenTarget = target
        self.scale = s
    }

    /// El rect de un item en px del canvas (igual que `Compositor.targetRect`).
    func canvasRect(of item: SceneItem) -> CGRect {
        CGRect(x: item.rect.origin.x * canvas.width,
               y: item.rect.origin.y * canvas.height,
               width: item.rect.width * canvas.width,
               height: item.rect.height * canvas.height)
    }

    /// Punto del canvas (px) → punto de pantalla (pt, global). Los dos sistemas
    /// tienen el origen ABAJO-IZQUIERDA (CoreImage y AppKit coinciden), así que
    /// en todo este camino no hay un solo volteo de Y.
    func screenPoint(fromCanvas p: CGPoint) -> CGPoint {
        let sx = (p.x - screenTarget.midX) / scale + sourcePixels.width / 2
        let sy = (p.y - screenTarget.midY) / scale + sourcePixels.height / 2
        return CGPoint(x: screenFrame.minX + sx / backing,
                       y: screenFrame.minY + sy / backing)
    }

    func screenRect(fromCanvas r: CGRect) -> CGRect {
        let a = screenPoint(fromCanvas: CGPoint(x: r.minX, y: r.minY))
        let b = screenPoint(fromCanvas: CGPoint(x: r.maxX, y: r.maxY))
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }

    /// Rect del canvas (px) → rect en px de la FUENTE de pantalla. Lo usa el
    /// sensor de oclusión para recortar exactamente lo que la burbuja tapa.
    func sourceRect(fromCanvas r: CGRect) -> CGRect {
        let x0 = (r.minX - screenTarget.midX) / scale + sourcePixels.width / 2
        let y0 = (r.minY - screenTarget.midY) / scale + sourcePixels.height / 2
        return CGRect(x: x0, y: y0, width: r.width / scale, height: r.height / scale)
    }

    /// Punto de pantalla (pt, global) → punto del canvas (px). La inversa exacta
    /// de `screenPoint`; la usan los tamaños, que se piden en puntos de pantalla
    /// (el idioma del Loom) y hay que devolverlos en rect de escena.
    func canvasPoint(fromScreen p: CGPoint) -> CGPoint {
        let sx = (p.x - screenFrame.minX) * backing
        let sy = (p.y - screenFrame.minY) * backing
        return CGPoint(x: (sx - sourcePixels.width / 2) * scale + screenTarget.midX,
                       y: (sy - sourcePixels.height / 2) * scale + screenTarget.midY)
    }

    /// Rect de pantalla (pt) → rect NORMALIZADO del item de escena.
    func normalizedRect(fromScreen r: CGRect) -> CGRect {
        let a = canvasPoint(fromScreen: CGPoint(x: r.minX, y: r.minY))
        let b = canvasPoint(fromScreen: CGPoint(x: r.maxX, y: r.maxY))
        return CGRect(x: a.x / canvas.width, y: a.y / canvas.height,
                      width: (b.x - a.x) / canvas.width, height: (b.y - a.y) / canvas.height)
    }

    /// Movimiento del mouse en pt de pantalla → delta NORMALIZADO del canvas.
    /// Es el puente del arrastre: muevo el espejo, se mueve el programa.
    func normalizedDelta(fromScreen d: CGSize) -> CGSize {
        CGSize(width: d.width * backing * scale / canvas.width,
               height: d.height * backing * scale / canvas.height)
    }
}

// MARK: - el panel

/// No roba foco: arrastrar el espejo no debe activar SFCast ni sacar del frente
/// la app que estás grabando.
final class MirrorPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// La vista del espejo: halo debajo, video recortado, aro encima — el MISMO
/// orden de `Compositor.compose` (halo → video → anillo).
final class MirrorContentView: NSView {
    weak var mirror: StudioMirror?

    private let glowLayer = CALayer()        // sombra = halo (sin clip, respira)
    private let clipLayer = CALayer()        // el recorte del video vive aquí
    private let warnLayer = CAShapeLayer()   // aviso de oclusión (punteado ámbar)

    var videoLayer: AVCaptureVideoPreviewLayer? {
        didSet {
            oldValue?.removeFromSuperlayer()
            if let v = videoLayer { clipLayer.addSublayer(v) }
        }
    }

    private var shape: CGPath?
    private var dragging = false
    private var dragOrigin: CGPoint?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        glowLayer.masksToBounds = false
        clipLayer.masksToBounds = true
        clipLayer.backgroundColor = NSColor.black.cgColor
        warnLayer.fillColor = nil
        warnLayer.strokeColor = NSColor(calibratedRed: 1.0, green: 0.567, blue: 0.004, alpha: 0.95).cgColor
        warnLayer.lineDashPattern = [7, 5]
        warnLayer.isHidden = true
        layer?.addSublayer(glowLayer)
        layer?.addSublayer(clipLayer)
        layer?.addSublayer(warnLayer)
    }
    required init?(coder: NSCoder) { fatalError() }

    func applyLayout(_ l: MirrorLayout) {
        let local = CGRect(x: l.pad, y: l.pad, width: l.rect.width, height: l.rect.height)
        let path = l.shapePath(in: local)
        shape = path
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // El video se escala a LLENAR el rect del item y se recorta con la forma
        // — exactamente el orden de `Compositor.place` (aspect-fill sobre el
        // rect, máscara circular después).
        clipLayer.frame = local
        let mask = CAShapeLayer()
        mask.path = path.shifted(dx: -local.minX, dy: -local.minY)
        clipLayer.mask = mask
        clipLayer.opacity = Float(l.opacity)
        videoLayer?.frame = CGRect(origin: .zero, size: local.size)

        glowLayer.frame = bounds
        if let rgb = l.glow.rgb {
            glowLayer.shadowColor = CGColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1)
            glowLayer.shadowOpacity = Float(SceneGlow.haloAlpha * l.opacity)
            // CALayer difumina la sombra con un radio ~2σ, y CIGaussianBlur usa
            // σ directo. Sin el 0.5 el halo del espejo salía el doble de ancho
            // que el del video — que es justo la paridad que se busca aquí.
            glowLayer.shadowRadius = l.halo * 0.5
            glowLayer.shadowOffset = .zero
            glowLayer.shadowPath = path
        } else {
            glowLayer.shadowOpacity = 0
        }
        // El aviso de oclusión vive FUERA de la forma: el espejo enseña cómo se
        // ve el video, y la alarma se lee como UI.
        let out = max(4.0, l.minSide * 0.02)
        warnLayer.path = l.shapePath(in: local.insetBy(dx: -out, dy: -out))
        warnLayer.lineWidth = max(1.5, l.minSide * 0.006)
        CATransaction.commit()
    }

    func setWarning(_ on: Bool) { warnLayer.isHidden = !on }

    /// Solo la FORMA recibe clics — las esquinas del cuadro que sobran alrededor
    /// del círculo siguen siendo de la app que estés usando.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let shape else { return nil }
        return shape.contains(convert(point, from: nil)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let m = mirror else { return }
        // Doble clic = ciclar tamaño, el mismo gesto que la burbuja del Loom
        // (`BubbleView.mouseDown`). Quien ya usa el Loom no tiene que aprender
        // nada nuevo aquí.
        if event.clickCount == 2 {
            dragging = false
            dragOrigin = nil
            m.cycleSize()
            return
        }
        dragging = true
        dragOrigin = NSEvent.mouseLocation
        m.dragBegan()
        m.showChips()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let m = mirror, dragging, let o = dragOrigin else { return }
        let now = NSEvent.mouseLocation
        m.dragMoved(byScreenDelta: CGSize(width: now.x - o.x, height: now.y - o.y))
    }

    override func mouseUp(with event: NSEvent) {
        guard let m = mirror, dragging else { return }
        dragging = false
        dragOrigin = nil
        m.dragEnded()
    }

    override func mouseEntered(with event: NSEvent) { mirror?.showChips() }
    override func mouseExited(with event: NSEvent) { mirror?.scheduleHideChips() }

    /// Clic derecho = el menú de tamaños de la burbuja del Loom, punto. Rayos X
    /// y fijar NO están aquí: viven en el botón Espejo del Estudio.
    override func rightMouseDown(with event: NSEvent) {
        guard mirror != nil else { return }
        let menu = NSMenu()
        for s in CameraBubble.Size.allCases {
            let i = NSMenuItem(title: s.label, action: #selector(pickSize(_:)), keyEquivalent: "")
            i.representedObject = s.rawValue
            i.target = self
            menu.addItem(i)
        }
        menu.addItem(.separator())
        let close = NSMenuItem(title: "Apagar el espejo", action: #selector(pickClose), keyEquivalent: "")
        close.target = self
        menu.addItem(close)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func pickSize(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let s = CameraBubble.Size(rawValue: raw) else { return }
        mirror?.applySize(s)
    }
    @objc private func pickClose() { mirror?.onRequestClose?() }
}

private extension CGPath {
    func shifted(dx: CGFloat, dy: CGFloat) -> CGPath {
        var t = CGAffineTransform(translationX: dx, y: dy)
        return copy(using: &t) ?? self
    }
}

// MARK: - chips de tamaño — el mismo idioma que los del Loom

/// También `sharingType = .none`: los chips JAMÁS salen en el video. (En el
/// Loom la burbuja sí sale por diseño y solo los chips se excluyen; aquí se
/// excluye todo, porque aquí la burbuja la pinta el compositor.)
final class MirrorChipsPanel: NSPanel {
    private var buttons: [NSButton] = []

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        let w: CGFloat = 152, h: CGFloat = 32
        super.init(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 5)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        sharingType = .none

        let host = MirrorChipHostView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 0.94).cgColor
        host.layer?.cornerRadius = h / 2
        host.layer?.borderWidth = 1
        host.layer?.borderColor = NSColor(calibratedWhite: 0.35, alpha: 0.8).cgColor

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 8)
        // LOS CHIPS DEL LOOM, no unos nuevos. Se leen de `CameraBubble.Size`
        // (chip "S·M·L·⛶" y label "Chica/Mediana/Grande/Pantalla completa"), que
        // es donde ya estaban pulidos: mismo gesto, mismo orden, mismas
        // etiquetas. Si mañana el Loom gana un tamaño, el espejo lo hereda sin
        // que nadie toque este archivo. (Daniel, 9 ago: "reutilizar lo que ya
        // habíamos construido allá en lugar de lo que tú construiste".)
        // Nada de esto es emoji: S/M/L son letras y ⛶ es un glifo geométrico
        // monocromo, así que heredan el tint igual que un SF Symbol.
        for s in CameraBubble.Size.allCases {
            let b = NSButton(title: s.chip, target: nil, action: #selector(StudioMirror.chipTapped(_:)))
            b.bezelStyle = .inline
            b.isBordered = false
            b.font = .systemFont(ofSize: 13, weight: .semibold)
            b.contentTintColor = .white
            b.identifier = NSUserInterfaceItemIdentifier(s.rawValue)
            b.toolTip = s.label
            stack.addArrangedSubview(b)
            buttons.append(b)
        }
        // Lo único que el Loom no necesita: apagar el espejo (allá la burbuja
        // ES la grabación, aquí es una ayuda que se quita).
        let close = NSButton(title: "", target: nil, action: #selector(StudioMirror.chipTapped(_:)))
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Apagar el espejo")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        close.imagePosition = .imageOnly
        close.bezelStyle = .inline
        close.isBordered = false
        close.contentTintColor = .white
        close.identifier = NSUserInterfaceItemIdentifier("close")
        close.toolTip = "Apagar el espejo"
        stack.addArrangedSubview(close)
        buttons.append(close)
        stack.frame = host.bounds
        stack.autoresizingMask = [.width, .height]
        host.addSubview(stack)
        contentView = host
    }

    /// El target se cablea AQUÍ y no en el init: cuando el contentView entra a
    /// la ventana el `mirror` todavía no existe.
    func attach(to mirror: StudioMirror) {
        (contentView as? MirrorChipHostView)?.mirror = mirror
        for b in buttons { b.target = mirror }
    }
}

final class MirrorChipHostView: NSView {
    weak var mirror: StudioMirror?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { mirror?.showChips() }
    override func mouseExited(with event: NSEvent) { mirror?.scheduleHideChips() }
}

// MARK: - medición para el QA del espejo

/// Herramientas de MEDICIÓN del `--mirrortest`. Viven aquí, con la feature, y
/// no en el QA: lo que se mide es propiedad del espejo, no del script que lo
/// ejerce.
enum MirrorProbe {
    private static let ctx = CIContext(options: [.cacheIntermediates: false])

    /// Color medio de una región del frame, en 0-1. Es el detector de fugas: si
    /// el panel se colara a la captura, este recorte pasaría de "escritorio" a
    /// "aro morado + cara", y el promedio se movería sin remedio.
    static func meanRGB(of pb: CVPixelBuffer, rect: CGRect) -> (r: Double, g: Double, b: Double)? {
        let img = CIImage(cvPixelBuffer: pb)
        let crop = rect.integral.intersection(img.extent)
        guard crop.width > 4, crop.height > 4 else { return nil }
        guard let avg = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: img, kCIInputExtentKey: CIVector(cgRect: crop),
        ])?.outputImage else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        ctx.render(avg, toBitmap: &px, rowBytes: 4,
                   bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                   format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return (Double(px[0]) / 255, Double(px[1]) / 255, Double(px[2]) / 255)
    }

    /// Guarda un recorte del frame como PNG (evidencia para el ojo — un aro
    /// neón no se valida leyendo un promedio, se valida mirándolo).
    @discardableResult
    static func writeCrop(_ pb: CVPixelBuffer, rect: CGRect, to url: URL) -> Bool {
        let img = CIImage(cvPixelBuffer: pb)
        let crop = rect.integral.intersection(img.extent)
        guard crop.width > 4, crop.height > 4,
              let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return false }
        let shifted = img.cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        guard let data = ctx.pngRepresentation(of: shifted, format: .RGBA8, colorSpace: cs)
        else { return false }
        try? data.write(to: url)
        return true
    }
}

// MARK: - identidad del display

extension NSScreen {
    /// El `CGDirectDisplayID` de esta pantalla (para comparar layouts sin
    /// depender de `hash`, que no promete estabilidad).
    var displayNumber: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? 0
    }
}
