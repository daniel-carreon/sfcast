import AppKit

/// Panel de control durante la grabación — pill flotante estilo Loom:
/// blur oscuro titanium, punto rojo pulsante, timer, Detener prominente en
/// mostaza, cancelar discreto. Arrastrable. sharingType = .none: JAMÁS sale
/// en el video (la burbuja de cámara SÍ, por diseño).
@MainActor
final class ControlPanel {
    private(set) var panel: NSPanel?
    private let timeLabel = NSTextField(labelWithString: "00:00")
    private var recDot: NSView?
    private var pauseButton: NSButton?
    private var timer: Timer?
    private var accumulated: TimeInterval = 0
    private var segmentStart: Date?

    var onPauseToggle: (() -> Void)?
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?

    var windowNumber: Int { panel?.windowNumber ?? -1 }

    static let mostaza = NSColor(calibratedRed: 1.0, green: 0.567, blue: 0.004, alpha: 1)

    func show(on screen: NSScreen) {
        if panel == nil { build(on: screen) }
        accumulated = 0
        segmentStart = Date()
        enterRecording()
        updateLabel()
        startTimer()
        panel?.orderFrontRegardless()
    }

    func hide() {
        timer?.invalidate(); timer = nil
        panel?.orderOut(nil)
    }

    func enterPaused() {
        if let s = segmentStart { accumulated += Date().timeIntervalSince(s) }
        segmentStart = nil
        setPauseIcon("play.fill", tip: "Reanudar")
        recDot?.layer?.removeAnimation(forKey: "pulse")
        recDot?.layer?.backgroundColor = NSColor.systemOrange.cgColor
        updateLabel()
    }

    func enterRecording() {
        segmentStart = Date()
        setPauseIcon("pause.fill", tip: "Pausar")
        recDot?.layer?.backgroundColor = NSColor.systemRed.cgColor
        startPulse()
    }

    var elapsed: TimeInterval {
        accumulated + (segmentStart.map { Date().timeIntervalSince($0) } ?? 0)
    }

    private func build(on screen: NSScreen) {
        let w: CGFloat = 392, h: CGFloat = 60
        let p = BubblePanel(
            contentRect: NSRect(x: screen.visibleFrame.midX - w / 2,
                                y: screen.visibleFrame.minY + 16,
                                width: w, height: h),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        p.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 4)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        // Invisible para CUALQUIER captura de pantalla (más robusto que la
        // exclusión por SCContentFilter, que no matcheaba — evidencia E2E).
        p.sharingType = .none

        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = h / 2
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 1
        effect.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.14).cgColor
        effect.autoresizingMask = [.width, .height]

        // tinte titanium encima del blur (paleta del hub)
        let tint = NSView(frame: effect.bounds)
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor(calibratedRed: 0.043, green: 0.047, blue: 0.055, alpha: 0.72).cgColor
        tint.autoresizingMask = [.width, .height]
        effect.addSubview(tint)

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 5
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 10).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 10).isActive = true
        recDot = dot

        timeLabel.textColor = .white
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 17, weight: .semibold)

        let pause = iconButton("pause.fill", tip: "Pausar", action: #selector(pauseTapped))
        pauseButton = pause

        let stop = NSButton(title: "", target: self, action: #selector(stopTapped))
        stop.isBordered = false
        stop.wantsLayer = true
        stop.layer?.backgroundColor = Self.mostaza.cgColor
        stop.layer?.cornerRadius = 17
        stop.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: "Detener")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .bold))
        stop.imagePosition = .imageLeading
        stop.contentTintColor = .black
        stop.attributedTitle = NSAttributedString(
            string: " Detener",
            attributes: [.foregroundColor: NSColor.black,
                         .font: NSFont.systemFont(ofSize: 13, weight: .bold)])
        stop.toolTip = "Detener y copiar el link"
        stop.translatesAutoresizingMaskIntoConstraints = false
        stop.widthAnchor.constraint(equalToConstant: 116).isActive = true
        stop.heightAnchor.constraint(equalToConstant: 34).isActive = true

        let cancel = iconButton("xmark", tip: "Cancelar y descartar", action: #selector(cancelTapped))
        cancel.contentTintColor = NSColor(calibratedWhite: 0.55, alpha: 1)

        let stack = NSStackView(views: [dot, timeLabel, separator(), pause, stop, separator(), cancel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 22, bottom: 0, right: 12)
        stack.frame = effect.bounds
        stack.autoresizingMask = [.width, .height]
        effect.addSubview(stack)

        p.contentView = effect
        panel = p
    }

    private func iconButton(_ symbol: String, tip: String, action: Selector) -> NSButton {
        let b = NSButton(title: "", target: self, action: action)
        b.isBordered = false
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold))
        b.contentTintColor = .white
        b.toolTip = tip
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 34).isActive = true
        b.heightAnchor.constraint(equalToConstant: 34).isActive = true
        return b
    }

    private func separator() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.12).cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: 1).isActive = true
        v.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return v
    }

    private func setPauseIcon(_ symbol: String, tip: String) {
        pauseButton?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold))
        pauseButton?.toolTip = tip
    }

    private func startPulse() {
        guard let layer = recDot?.layer, layer.animation(forKey: "pulse") == nil else { return }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 1.0
        a.toValue = 0.25
        a.duration = 0.8
        a.autoreverses = true
        a.repeatCount = .infinity
        layer.add(a, forKey: "pulse")
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateLabel() }
        }
    }

    private func updateLabel() {
        let t = Int(elapsed)
        timeLabel.stringValue = String(format: "%02d:%02d", t / 60, t % 60)
    }

    @objc private func pauseTapped() { onPauseToggle?() }
    @objc private func stopTapped() { onStop?() }
    @objc private func cancelTapped() { onCancel?() }
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
