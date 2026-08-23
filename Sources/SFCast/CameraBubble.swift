import AppKit
import AVFoundation

/// La burbuja de cámara: NSPanel flotante circular, arrastrable, 4 tamaños.
/// Se QUEMA en el video (está en el display capturado) — decisión cerrada del spec.
/// Tamaños: chips al hacer HOVER (estilo Loom, en panel EXCLUIDO de la captura),
/// doble clic = ciclar, clic derecho = menú. Glow configurable: ámbar/morado/nada.
@MainActor
final class CameraBubble: NSObject {
    enum Size: String, CaseIterable {
        case s, m, l, full
        var diameter: CGFloat {
            switch self {
            case .s: return 180
            case .m: return 280
            case .l: return 420
            case .full: return 0   // especial: rect grande centrado
            }
        }
        var label: String {
            switch self {
            case .s: return "Chica"
            case .m: return "Mediana"
            case .l: return "Grande"
            case .full: return "Pantalla completa"
            }
        }
        var chip: String {
            switch self {
            case .s: return "S"
            case .m: return "M"
            case .l: return "L"
            case .full: return "⛶"
            }
        }
    }

    enum Glow: String, CaseIterable {
        case ambar, morado, nada
        var color: NSColor? {
            switch self {
            case .ambar: return NSColor(srgbRed: 1.0, green: 0.567, blue: 0.004, alpha: 1)   // #ff9101
            case .morado: return NSColor(srgbRed: 0.549, green: 0.153, blue: 0.945, alpha: 1) // #8C27F1
            case .nada: return nil
            }
        }
        var label: String {
            switch self {
            case .ambar: return "Glow ámbar"
            case .morado: return "Glow morado"
            case .nada: return "Sin glow"
            }
        }
    }

    /// margen alrededor del círculo para que el glow respire (dentro del panel)
    static let glowPad: CGFloat = 34

    private(set) var panel: NSPanel?
    private var glowView: NSView?             // capa del GLOW (sin clip — el shadow respira)
    private var innerView: NSView?            // el círculo con el video (clip)
    private let session = AVCaptureSession()
    var captureSession: AVCaptureSession { session }
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private(set) var currentSize: Size = .m
    private(set) var currentGlow: Glow = .ambar
    private var chipPanel: NSPanel?           // hover chips — sharingType .none (NO sale en el video)
    private var chipHideTimer: Timer?
    private var placeholderLabel: NSTextField?   // "cámara sin permiso" dentro del círculo

    var isVisible: Bool { panel?.isVisible ?? false }
    var windowNumber: Int { panel?.windowNumber ?? -1 }

    func show(size: Size, glow: Glow, on screen: NSScreen) {
        currentSize = size
        if panel == nil { buildPanel(on: screen) }
        startSessionIfNeeded()
        setGlow(glow)
        apply(size: size, on: screen, animate: false)
        panel?.orderFrontRegardless()
    }

    func hide() {
        hideChips()
        panel?.orderOut(nil)
        session.stopRunning()
    }

    func setSize(_ size: Size, animate: Bool = true) {
        guard let screen = panel?.screen ?? NSScreen.main else { return }
        currentSize = size
        apply(size: size, on: screen, animate: animate)
        repositionChips()
    }

    func setGlow(_ glow: Glow) {
        currentGlow = glow
        guard let g = glowView?.layer, let inner = innerView?.layer else { return }
        // GOTCHA aprendido: shadow + masksToBounds en la MISMA capa = glow
        // recortado (invisible). Por eso el shadow vive en glowView (sin clip)
        // y el video en innerView (con clip).
        if let c = glow.color {
            // SUTIL (Daniel 15 jul: "muy amplio y se notan contornos cuadrados"):
            // radio corto y opacidad baja para que el halo muera DENTRO del
            // glowPad (34px) — un blur más grande se recorta contra el borde
            // cuadrado del panel y se ve el corte. Elegancia = anillo definido
            // + halo apenas presente.
            inner.borderWidth = 1.5
            inner.borderColor = c.withAlphaComponent(0.9).cgColor
            g.shadowColor = c.cgColor
            g.shadowOpacity = 0.5
            g.shadowRadius = 10
            g.shadowOffset = .zero
            updateShadowPath()
        } else {
            inner.borderWidth = 0
            g.shadowOpacity = 0
        }
    }

    private func updateShadowPath() {
        guard let g = glowView, let inner = innerView else { return }
        let r = inner.layer?.cornerRadius ?? 0
        g.layer?.shadowPath = CGPath(roundedRect: g.bounds, cornerWidth: r, cornerHeight: r, transform: nil)
    }

    /// API programática (modo --demo): mueve la burbuja a un punto (origen del panel).
    /// OJO: animator().setFrameOrigin es NO-OP en NSWindow — solo setFrame(_:display:animate:).
    func move(to origin: NSPoint, animate: Bool = true) {
        guard let p = panel else { return }
        p.setFrame(NSRect(origin: origin, size: p.frame.size), display: true, animate: animate)
        repositionChips()
    }

    func cycleSize() {
        let all = Size.allCases
        let idx = all.firstIndex(of: currentSize) ?? 0
        setSize(all[(idx + 1) % all.count])
    }

    // MARK: - construcción

    private func buildPanel(on screen: NSScreen) {
        let d = Size.m.diameter
        let pad = Self.glowPad
        let side = d + pad * 2
        let p = BubblePanel(
            contentRect: NSRect(x: screen.visibleFrame.maxX - side - 20,
                                y: screen.visibleFrame.minY + 20,
                                width: side, height: side),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        p.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 3)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false                    // el glow lo pinta la capa interna
        p.isMovableByWindowBackground = true
        p.hidesOnDeactivate = false

        let outer = BubbleView(frame: NSRect(x: 0, y: 0, width: side, height: side))
        outer.wantsLayer = true
        outer.layer?.masksToBounds = false     // deja respirar el glow
        outer.bubble = self

        let glow = NSView(frame: NSRect(x: pad, y: pad, width: d, height: d))
        glow.wantsLayer = true
        glow.layer?.masksToBounds = false      // el shadow (glow) respira aquí

        let inner = NSView(frame: glow.bounds)
        inner.wantsLayer = true
        inner.layer?.backgroundColor = NSColor.black.cgColor
        inner.layer?.masksToBounds = true      // el clip del círculo vive AQUÍ
        inner.layer?.cornerRadius = d / 2
        inner.autoresizingMask = [.width, .height]

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = inner.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        inner.layer?.addSublayer(layer)
        previewLayer = layer

        glow.addSubview(inner)
        outer.addSubview(glow)
        glowView = glow
        innerView = inner
        p.contentView = outer
        panel = p

        // hover tracking sobre TODO el panel (chips estilo Loom)
        let tracking = NSTrackingArea(
            rect: outer.bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: outer, userInfo: nil)
        outer.addTrackingArea(tracking)
    }

    // MARK: - hover chips (S · M · L · ⛶) — invisibles en la grabación

    func showChips() {
        chipHideTimer?.invalidate()
        if chipPanel == nil { buildChips() }
        repositionChips()
        chipPanel?.orderFrontRegardless()
    }

    func scheduleHideChips() {
        chipHideTimer?.invalidate()
        chipHideTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.hideChips() }
        }
    }

    private func hideChips() {
        chipPanel?.orderOut(nil)
    }

    private func buildChips() {
        let w: CGFloat = 168, h: CGFloat = 34
        let p = BubblePanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        p.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 5)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.sharingType = .none          // los chips JAMÁS salen en el video (burbuja sí, por diseño)

        let view = ChipHostView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        view.bubble = self
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 0.94).cgColor
        view.layer?.cornerRadius = h / 2
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor(calibratedWhite: 0.35, alpha: 0.8).cgColor

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 8)
        for s in Size.allCases {
            let b = NSButton(title: s.chip, target: self, action: #selector(chipTapped(_:)))
            b.bezelStyle = .inline
            b.isBordered = false
            b.font = .systemFont(ofSize: 13, weight: .semibold)
            b.contentTintColor = .white
            b.identifier = NSUserInterfaceItemIdentifier(s.rawValue)
            b.toolTip = s.label
            stack.addArrangedSubview(b)
        }
        stack.frame = view.bounds
        stack.autoresizingMask = [.width, .height]
        view.addSubview(stack)
        p.contentView = view
        chipPanel = p
    }

    @objc private func chipTapped(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let s = Size(rawValue: raw) else { return }
        setSize(s)
    }

    private func repositionChips() {
        guard let p = panel, let c = chipPanel else { return }
        let x = p.frame.midX - c.frame.width / 2
        let y = max(p.frame.minY + Self.glowPad - c.frame.height - 6,
                    (p.screen ?? NSScreen.main)?.visibleFrame.minY ?? 0)
        c.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - cámara

    private func startSessionIfNeeded() {
        // El PROMPT de cámara ya NO vive aquí: lo pide Permissions.preflight
        // (secuencial, antes del countdown). Aquí solo se configura si hay permiso.
        guard Permissions.cameraGranted else {
            Log.error("Cámara: sin permiso — burbuja en placeholder (hub → Permisos)")
            setPlaceholder("📷  Cámara sin permiso\nHub de SFCast → Permisos")
            return
        }
        setPlaceholder(nil)
        guard session.inputs.contains(where: { ($0 as? AVCaptureDeviceInput)?.device.hasMediaType(.video) ?? false }) else {
            configureInput()
            return
        }
        if !session.isRunning { DispatchQueue.global().async { [session] in session.startRunning() } }
    }

    /// Cambia el dispositivo de cámara EN VIVO (picker del hub o post-grant).
    func reloadCamera() {
        guard Permissions.cameraGranted else { return }
        session.beginConfiguration()
        for input in session.inputs {
            if let di = input as? AVCaptureDeviceInput, di.device.hasMediaType(.video) {
                session.removeInput(di)
            }
        }
        session.commitConfiguration()
        configureInput()
    }

    private func configureInput() {
        session.beginConfiguration()
        session.sessionPreset = .high
        let wanted = AppSettings.load().cameraDeviceID
        guard let device = Devices.camera(id: wanted),
              let input = try? AVCaptureDeviceInput(device: device) else {
            session.commitConfiguration()
            Log.error("Burbuja: sin cámara disponible")
            setPlaceholder("📷  Sin cámara disponible")
            return
        }
        Log.info("Burbuja: cámara '\(device.localizedName)'")
        if session.canAddInput(input) { session.addInput(input) }
        session.commitConfiguration()
        setPlaceholder(nil)
        if let conn = previewLayer?.connection, conn.isVideoMirroringSupported {
            conn.automaticallyAdjustsVideoMirroring = false
            conn.isVideoMirrored = true
        }
        DispatchQueue.global().async { [session] in session.startRunning() }
    }

    /// Texto centrado dentro del círculo cuando NO hay video (permiso/dispositivo).
    private func setPlaceholder(_ text: String?) {
        if let text {
            if placeholderLabel == nil, let inner = innerView {
                let l = NSTextField(labelWithString: "")
                l.alignment = .center
                l.textColor = NSColor(calibratedWhite: 0.75, alpha: 1)
                l.font = .systemFont(ofSize: 12, weight: .semibold)
                l.maximumNumberOfLines = 3
                l.frame = inner.bounds.insetBy(dx: 12, dy: 12)
                l.autoresizingMask = [.width, .height]
                inner.addSubview(l)
                placeholderLabel = l
            }
            placeholderLabel?.stringValue = text
            placeholderLabel?.isHidden = false
        } else {
            placeholderLabel?.isHidden = true
        }
    }

    // MARK: - geometría

    private func apply(size: Size, on screen: NSScreen, animate: Bool) {
        guard let p = panel, let inner = innerView, glowView != nil else { return }
        let pad = Self.glowPad
        let frame: NSRect
        let corner: CGFloat
        if size == .full {
            let vf = screen.visibleFrame
            let w = vf.width * 0.72
            let h = w * 9.0 / 16.0
            frame = NSRect(x: vf.midX - (w + pad * 2) / 2, y: vf.midY - (h + pad * 2) / 2,
                           width: w + pad * 2, height: h + pad * 2)
            corner = 24
        } else {
            let d = size.diameter
            let side = d + pad * 2
            let center = NSPoint(x: p.frame.midX, y: p.frame.midY)
            let origin = NSPoint(x: center.x - side / 2, y: center.y - side / 2)
            frame = NSRect(origin: clampToScreen(origin, side: side, screen: screen),
                           size: NSSize(width: side, height: side))
            corner = d / 2
        }
        p.setFrame(frame, display: true, animate: animate)
        let content = NSRect(x: pad, y: pad,
                             width: frame.width - pad * 2, height: frame.height - pad * 2)
        glowView?.frame = content
        inner.frame = NSRect(origin: .zero, size: content.size)
        inner.layer?.cornerRadius = corner
        updateShadowPath()
    }

    private func clampToScreen(_ o: NSPoint, side: CGFloat, screen: NSScreen) -> NSPoint {
        let vf = screen.visibleFrame
        return NSPoint(x: min(max(o.x, vf.minX - Self.glowPad), vf.maxX - side + Self.glowPad),
                       y: min(max(o.y, vf.minY - Self.glowPad), vf.maxY - side + Self.glowPad))
    }

    func sizeMenu() -> NSMenu {
        let menu = NSMenu()
        for s in Size.allCases {
            let item = NSMenuItem(title: s.label, action: #selector(BubbleView.pickSize(_:)), keyEquivalent: "")
            item.representedObject = s.rawValue
            item.state = s == currentSize ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for g in Glow.allCases {
            let item = NSMenuItem(title: g.label, action: #selector(BubbleView.pickGlow(_:)), keyEquivalent: "")
            item.representedObject = g.rawValue
            item.state = g == currentGlow ? .on : .off
            menu.addItem(item)
        }
        return menu
    }
}

/// Panel que no roba foco (drag fluido sin activar la app).
final class BubblePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class BubbleView: NSView {
    weak var bubble: CameraBubble?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            Task { @MainActor in bubble?.cycleSize() }
        } else {
            window?.performDrag(with: event)
            Task { @MainActor in bubble?.showChips() }   // re-pega los chips tras el drag
        }
    }

    override func mouseEntered(with event: NSEvent) {
        Task { @MainActor in bubble?.showChips() }
    }

    override func mouseExited(with event: NSEvent) {
        Task { @MainActor in bubble?.scheduleHideChips() }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let bubble else { return }
        let menu = bubble.sizeMenu()
        for item in menu.items { item.target = self }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc func pickSize(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let s = CameraBubble.Size(rawValue: raw) else { return }
        Task { @MainActor in bubble?.setSize(s) }
    }

    @objc func pickGlow(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let g = CameraBubble.Glow(rawValue: raw) else { return }
        Task { @MainActor in
            bubble?.setGlow(g)
            var s = AppSettings.load(); s.bubbleGlow = g.rawValue; s.save()
        }
    }
}

/// Host de los chips: mantiene los chips visibles mientras el mouse esté encima.
final class ChipHostView: NSView {
    weak var bubble: CameraBubble?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let tracking = NSTrackingArea(rect: bounds,
                                      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: self, userInfo: nil)
        addTrackingArea(tracking)
    }

    override func mouseEntered(with event: NSEvent) {
        Task { @MainActor in bubble?.showChips() }
    }

    override func mouseExited(with event: NSEvent) {
        Task { @MainActor in bubble?.scheduleHideChips() }
    }
}
