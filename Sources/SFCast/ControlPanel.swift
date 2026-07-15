import AppKit

// ════════════════════════════════════════════════════════════════════════════
// Panel de control durante la grabación — PILL VERTICAL estilo Loom (v1.5).
//
// Daniel 15 jul: "la nuestra se ve bien fea y la de Loom se ve bien sutil;
// cuando poso el mouse se amplía y salen botones de reiniciar/eliminar; la de
// Loom tiene un hover muy bonito y la nuestra ni siquiera tiene animación".
//
//   colapsado          hover
//   ┌──────┐          ┌──────┐
//   │  ■   │  stop    │  ■   │
//   │ 2:02 │  timer   │ 2:02 │
//   │  ⏸   │  pausa   │  ⏸   │
//   └──────┘          │ ───  │
//                     │  ↺   │  reiniciar (tira y vuelve a empezar)
//                     │  🗑   │  descartar
//                     └──────┘
//
// sharingType = .none: JAMÁS sale en el video (la burbuja SÍ, por diseño).
// ════════════════════════════════════════════════════════════════════════════

@MainActor
final class ControlPanel {
    // Geometría fija (determinista: nada de medir fittingSize en cada hover).
    private static let W: CGFloat = 58
    private static let COLLAPSED_H: CGFloat = 112
    private static let EXPANDED_H: CGFloat = 188

    private(set) var panel: NSPanel?
    private let timeLabel = NSTextField(labelWithString: "0:00")
    private var pauseButton: PillButton?
    private var extras: [NSView] = []          // separador · reiniciar · descartar
    private var timer: Timer?
    private var collapseTimer: Timer?
    private var accumulated: TimeInterval = 0
    private var segmentStart: Date?
    private(set) var expanded = false

    var onPauseToggle: (() -> Void)?
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?
    var onRestart: (() -> Void)?

    var windowNumber: Int { panel?.windowNumber ?? -1 }

    static let mostaza = NSColor(calibratedRed: 1.0, green: 0.567, blue: 0.004, alpha: 1)

    // MARK: - ciclo de vida

    func show(on screen: NSScreen) {
        if panel == nil { build(on: screen) }
        accumulated = 0
        segmentStart = Date()
        setExpanded(false, animate: false)
        enterRecording()
        updateLabel()
        startTimer()
        panel?.orderFrontRegardless()
    }

    func hide() {
        timer?.invalidate(); timer = nil
        collapseTimer?.invalidate(); collapseTimer = nil
        panel?.orderOut(nil)
        setExpanded(false, animate: false)
    }

    func enterPaused() {
        if let s = segmentStart { accumulated += Date().timeIntervalSince(s) }
        segmentStart = nil
        setPauseIcon("play.fill", tip: "Reanudar")
        // Señal de pausa SIN adornos (Loom no pinta puntos parpadeantes):
        // el timer se vuelve ámbar y el icono cambia a play.
        timeLabel.textColor = .systemOrange
        updateLabel()
    }

    func enterRecording() {
        segmentStart = Date()
        setPauseIcon("pause.fill", tip: "Pausar")
        timeLabel.textColor = .white
    }

    var elapsed: TimeInterval {
        accumulated + (segmentStart.map { Date().timeIntervalSince($0) } ?? 0)
    }

    // MARK: - hover: expandir / colapsar

    func setExpanded(_ on: Bool, animate: Bool = true) {
        collapseTimer?.invalidate(); collapseTimer = nil
        guard let panel else { return }
        if expanded == on && animate { return }
        expanded = on
        let h = on ? Self.EXPANDED_H : Self.COLLAPSED_H
        // El pill crece HACIA ABAJO: el borde superior queda clavado donde
        // Daniel lo dejó (el panel es arrastrable).
        let top = panel.frame.maxY
        let f = NSRect(x: panel.frame.minX, y: top - h, width: Self.W, height: h)
        if animate {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(f, display: true)
                for v in extras { v.animator().alphaValue = on ? 1 : 0 }
            }
        } else {
            panel.setFrame(f, display: true)
            for v in extras { v.alphaValue = on ? 1 : 0 }
        }
    }

    /// Salir del pill no colapsa al instante: un respiro evita el parpadeo
    /// cuando el mouse cruza entre botones.
    func scheduleCollapse() {
        collapseTimer?.invalidate()
        collapseTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.setExpanded(false) }
        }
    }

    // MARK: - construcción

    private func build(on screen: NSScreen) {
        let vf = screen.visibleFrame
        // Arranca arriba-izquierda como Loom (fuera del centro de la acción).
        let p = BubblePanel(
            contentRect: NSRect(x: vf.minX + 26,
                                y: vf.maxY - Self.COLLAPSED_H - 26,
                                width: Self.W, height: Self.COLLAPSED_H),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        p.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 4)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        // Invisible para CUALQUIER captura (más robusto que excluir por
        // SCContentFilter, que no matcheaba — evidencia E2E 14 jul).
        // Excepción: --paneltest, el único modo donde queremos poder verlo en
        // un screenshot para revisar el diseño.
        p.sharingType = panelTestMode ? .readOnly : .none

        let host = PillHostView()
        host.owner = self
        host.material = .hudWindow
        host.blendingMode = .behindWindow
        host.state = .active
        host.wantsLayer = true
        host.layer?.cornerRadius = 18
        host.layer?.masksToBounds = true      // clipa los extras cuando está colapsado
        host.layer?.borderWidth = 1
        host.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.10).cgColor

        // tinte titanium encima del blur (paleta del hub)
        let tint = NSView(frame: NSRect(x: 0, y: 0, width: Self.W, height: Self.EXPANDED_H))
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor(calibratedRed: 0.043, green: 0.047, blue: 0.055, alpha: 0.72).cgColor
        tint.autoresizingMask = [.width, .height]
        host.addSubview(tint)

        // ── stop: el cuadro mostaza, protagonista (como el rojo de Loom) ──
        let stop = PillButton(icon: "stop.fill", size: 40, pointSize: 13,
                              target: self, action: #selector(stopTapped))
        stop.layer?.cornerRadius = 12
        stop.baseBG = Self.mostaza
        stop.hoverBG = Self.mostaza.blended(withFraction: 0.2, of: .white) ?? Self.mostaza
        stop.baseTint = .black
        stop.hoverTint = .black
        stop.contentTintColor = .black
        stop.applyBaseBG()
        stop.toolTip = "Detener y copiar el link"

        timeLabel.textColor = .white
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .bold)
        timeLabel.alignment = .center
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.heightAnchor.constraint(equalToConstant: 14).isActive = true

        let pause = PillButton(icon: "pause.fill", size: 30, pointSize: 12,
                               target: self, action: #selector(pauseTapped))
        pause.toolTip = "Pausar"
        pauseButton = pause

        // ── extras (solo visibles en hover) ──
        let sep = NSView()
        sep.wantsLayer = true
        sep.layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.12).cgColor
        sep.translatesAutoresizingMaskIntoConstraints = false
        sep.widthAnchor.constraint(equalToConstant: 24).isActive = true
        sep.heightAnchor.constraint(equalToConstant: 1).isActive = true

        let restart = PillButton(icon: "arrow.counterclockwise", size: 30, pointSize: 12,
                                 target: self, action: #selector(restartTapped))
        restart.toolTip = "Reiniciar: tira lo grabado y empieza de cero"

        let discard = PillButton(icon: "trash", size: 30, pointSize: 12,
                                 target: self, action: #selector(cancelTapped))
        discard.toolTip = "Descartar la grabación"
        discard.hoverTint = NSColor(calibratedRed: 0.95, green: 0.35, blue: 0.3, alpha: 1)

        extras = [sep, restart, discard]
        for v in extras { v.alphaValue = 0 }

        let stack = NSStackView(views: [stop, timeLabel, pause] + extras)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(stack)
        // Pineado ARRIBA (no abajo): al colapsar, el pill CLIPA los extras en
        // vez de comprimir el stack (cero conflictos de constraints).
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: host.topAnchor, constant: 9),
            stack.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ])

        p.contentView = host
        panel = p
    }

    private func setPauseIcon(_ symbol: String, tip: String) {
        pauseButton?.setIcon(symbol)
        pauseButton?.toolTip = tip
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateLabel() }
        }
    }

    /// Formato Loom: "2:02" (sin cero a la izquierda); "1:02:02" si pasa la hora.
    private func updateLabel() {
        let t = Int(elapsed)
        timeLabel.stringValue = t >= 3600
            ? String(format: "%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60)
            : String(format: "%d:%02d", t / 60, t % 60)
    }

    @objc private func pauseTapped() { onPauseToggle?() }
    @objc private func stopTapped() { onStop?() }
    @objc private func cancelTapped() { onCancel?() }
    @objc private func restartTapped() { onRestart?() }
}

/// El cuerpo del pill: detecta hover para expandir/colapsar.
final class PillHostView: NSVisualEffectView {
    weak var owner: ControlPanel?
    private var ta: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta { removeTrackingArea(ta) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        ta = t
    }

    override func mouseEntered(with event: NSEvent) {
        Task { @MainActor in owner?.setExpanded(true) }
    }

    override func mouseExited(with event: NSEvent) {
        Task { @MainActor in owner?.scheduleCollapse() }
    }
}

/// Botón del pill con hover VIVO (lo que Daniel echaba de menos vs Loom):
/// fondo que aparece, micro-escala al entrar y rebote al pulsar.
///
/// Las animaciones son CABasicAnimation EXPLÍCITAS a propósito: en vistas
/// layer-backed de AppKit las implícitas están apagadas (el layer delegate
/// devuelve NSNull para las acciones), así que un simple `layer.transform = …`
/// saltaría sin animar.
final class PillButton: NSButton {
    var baseBG: NSColor = .clear
    var hoverBG: NSColor = NSColor(calibratedWhite: 1, alpha: 0.13)
    var baseTint: NSColor = NSColor(calibratedWhite: 1, alpha: 0.72)
    var hoverTint: NSColor = .white
    var hoverScale: CGFloat = 1.09

    private var pointSize: CGFloat = 12
    private var ta: NSTrackingArea?

    init(icon: String, size: CGFloat, pointSize: CGFloat, target: AnyObject, action: Selector) {
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        self.pointSize = pointSize
        self.target = target
        self.action = action
        title = ""
        isBordered = false
        imagePosition = .imageOnly
        wantsLayer = true
        layer?.cornerRadius = size / 2
        contentTintColor = baseTint
        setIcon(icon)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: size).isActive = true
        heightAnchor.constraint(equalToConstant: size).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("no soportado") }

    func setIcon(_ symbol: String) {
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .bold))
    }

    func applyBaseBG() {
        layer?.backgroundColor = baseBG.cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta { removeTrackingArea(ta) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        ta = t
    }

    override func mouseEntered(with event: NSEvent) {
        contentTintColor = hoverTint
        setBG(hoverBG, duration: 0.14)
        setScale(hoverScale, duration: 0.14)
    }

    override func mouseExited(with event: NSEvent) {
        contentTintColor = baseTint
        setBG(baseBG, duration: 0.16)
        setScale(1.0, duration: 0.16)
    }

    override func mouseDown(with event: NSEvent) {
        setScale(0.9, duration: 0.06)          // feedback de pulsación
        super.mouseDown(with: event)           // corre el tracking loop hasta soltar
        setScale(isMouseInside ? hoverScale : 1.0, duration: 0.12)
    }

    private var isMouseInside: Bool {
        guard let w = window else { return false }
        return bounds.contains(convert(w.mouseLocationOutsideOfEventStream, from: nil))
    }

    private func setBG(_ color: NSColor, duration: CFTimeInterval) {
        animate(key: "backgroundColor", to: color.cgColor, duration: duration)
    }

    private func setScale(_ s: CGFloat, duration: CFTimeInterval) {
        // anchorPoint por defecto (0.5, 0.5) ⇒ la escala respeta el centro.
        animate(key: "transform", to: NSValue(caTransform3D: CATransform3DMakeScale(s, s, 1)),
                duration: duration)
    }

    private func animate(key: String, to value: Any, duration: CFTimeInterval) {
        guard let layer else { return }
        let a = CABasicAnimation(keyPath: key)
        a.fromValue = layer.presentation()?.value(forKeyPath: key) ?? layer.value(forKeyPath: key)
        a.toValue = value
        a.duration = duration
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.setValue(value, forKeyPath: key)     // modelo primero: sin saltos al terminar
        layer.add(a, forKey: key)
    }
}

/// Countdown 3-2-1 en overlay grande. Se CIERRA antes de startCapture,
/// así jamás aparece en el video.
@MainActor
enum Countdown {
    static func run(seconds: Int, on screen: NSScreen) async {
        guard seconds > 0 else { return }
        let size: CGFloat = 260
        let panel = NSPanel(
            contentRect: NSRect(x: screen.frame.midX - size / 2,
                                y: screen.frame.midY - size / 2,
                                width: size, height: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.sharingType = .none   // el countdown tampoco sale jamás en el video

        let view = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(calibratedWhite: 0.05, alpha: 0.85).cgColor
        view.layer?.cornerRadius = size / 2

        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 120, weight: .bold)
        label.textColor = NSColor(calibratedRed: 1.0, green: 0.567, blue: 0.004, alpha: 1)
        label.alignment = .center
        label.frame = view.bounds
        view.addSubview(label)
        panel.contentView = view
        panel.orderFrontRegardless()

        for n in stride(from: seconds, through: 1, by: -1) {
            label.stringValue = "\(n)"
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        panel.orderOut(nil)
    }
}
