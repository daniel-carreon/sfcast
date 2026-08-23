import AppKit

/// EL CONTADOR DE MARCAS — esquina superior derecha de la pantalla que se graba.
///
/// Pedido de Daniel (10 ago), y su razón es mejor que la mía: *"el aro no me
/// convence... simplemente una tijera de un color y una tijera de otro color,
/// así al ladito. Pero yo puedo ver ambas cosas."*
///
/// El destello del espejo era un EVENTO: confirma que la última pulsación llegó
/// y se va. Lo que él necesita mientras habla es un ESTADO — cuántas lleva de
/// cada una, sin tener que acordarse. Y además el destello dependía de que el
/// espejo estuviera encendido; esto no depende de nada.
///
/// Invisible al video (`sharingType = .none`, el mismo truco del pill y del
/// espejo) y transparente al ratón: está para mirarse, jamás para estorbar un
/// clic en plena toma.
@MainActor
final class MarkerHUD {
    private var panel: NSPanel?
    private var corte: NSTextField?
    private var bueno: NSTextField?

    /// Ámbar de marca para el corte, verde para lo bueno. Dos colores porque el
    /// ojo los separa de un vistazo, sin leer el número.
    private static let colorCorte = NSColor(srgbRed: 1.0, green: 0.567, blue: 0.004, alpha: 1)
    private static let colorBueno = NSColor(calibratedRed: 0.25, green: 0.85, blue: 0.45, alpha: 1)

    /// Se pinta en la pantalla CAPTURADA, no en `NSScreen.main`: con dos
    /// monitores, el HUD tiene que estar donde está el video (misma lección que
    /// la burbuja y el countdown — DECISIONS v1.2).
    private func pantallaCapturada() -> NSScreen? {
        let id = CGMainDisplayID()
        return NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == id
        }) ?? NSScreen.main
    }

    func show() {
        guard panel == nil, let screen = pantallaCapturada() else { return }
        let w: CGFloat = 132, h: CGFloat = 38, margen: CGFloat = 18
        let rect = NSRect(x: screen.frame.maxX - w - margen,
                          y: screen.frame.maxY - h - margen,
                          width: w, height: h)
        let p = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .statusBar
        p.hasShadow = false
        p.ignoresMouseEvents = true                  // jamás roba un clic
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        // INVISIBLE en la grabación… salvo en el modo de revisión: lo que es
        // invisible a la captura por diseño también es invisible para quien
        // quiere MIRARLO y decidir si está bien (mismo motivo que --paneltest
        // para el pill y --mirrorlook para el espejo).
        p.sharingType = CommandLine.arguments.contains("--hudlook") ? .readWrite : .none

        let fondo = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        fondo.material = .hudWindow
        fondo.state = .active
        fondo.blendingMode = .behindWindow
        fondo.wantsLayer = true
        fondo.layer?.cornerRadius = 10
        fondo.layer?.masksToBounds = true

        let c = etiqueta("✂︎ 0", color: Self.colorCorte)
        c.frame = NSRect(x: 12, y: 9, width: 54, height: 20)
        let b = etiqueta("★ 0", color: Self.colorBueno)
        b.frame = NSRect(x: 70, y: 9, width: 54, height: 20)
        fondo.addSubview(c)
        fondo.addSubview(b)

        p.contentView = fondo
        p.orderFrontRegardless()
        panel = p; corte = c; bueno = b
    }

    private func etiqueta(_ txt: String, color: NSColor) -> NSTextField {
        let l = NSTextField(labelWithString: txt)
        l.font = .monospacedDigitSystemFont(ofSize: 14, weight: .bold)
        l.textColor = color
        l.alignment = .center
        l.backgroundColor = .clear
        l.isBordered = false
        return l
    }

    /// Actualiza los dos contadores y da un pulso corto en el que cambió: el
    /// número dice cuántas, el pulso dice "esta pulsación llegó".
    func update(cortes: Int, buenos: Int, pulso: String?) {
        corte?.stringValue = "✂︎ \(cortes)"
        bueno?.stringValue = "★ \(buenos)"
        let objetivo = pulso == "retoma" ? corte : (pulso == "bueno" ? bueno : nil)
        guard let objetivo, let capa = objetivo.layer ?? { objetivo.wantsLayer = true; return objetivo.layer }() else { return }
        let anim = CAKeyframeAnimation(keyPath: "transform.scale")
        anim.values = [1.0, 1.35, 1.0]
        anim.keyTimes = [0, 0.35, 1]
        anim.duration = 0.28
        capa.add(anim, forKey: "pulso")
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil; corte = nil; bueno = nil
    }

    var isVisible: Bool { panel != nil }

    /// AUTO-RETRATO para revisar el diseño sin depender del permiso de pantalla
    /// (que tras cada rebuild está muerto, y `screencapture` tampoco lo tiene).
    /// El blur del `NSVisualEffectView` no sale en un `cacheDisplay` — se pinta
    /// un fondo sólido equivalente detrás para que el PNG represente lo que se
    /// ve, en vez de texto flotando en transparencia.
    @discardableResult
    func snapshot(to path: String) -> Bool {
        guard let panel, let vista = panel.contentView else { return false }
        let r = vista.bounds
        guard let rep = vista.bitmapImageRepForCachingDisplay(in: r) else { return false }
        vista.cacheDisplay(in: r, to: rep)
        let img = NSImage(size: r.size)
        img.lockFocus()
        NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
        NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10).fill()
        rep.draw(in: r)
        img.unlockFocus()
        guard let tiff = img.tiffRepresentation,
              let bmp = NSBitmapImageRep(data: tiff),
              let png = bmp.representation(using: .png, properties: [:]) else { return false }
        try? png.write(to: URL(fileURLWithPath: path))
        Log.info("HUD: retrato en \(path)")
        return true
    }
}
