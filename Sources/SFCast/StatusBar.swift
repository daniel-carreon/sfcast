import AppKit
import ScreenCaptureKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleRecording = Self("toggleRecording", default: .init(.l, modifiers: [.command, .shift]))
}

/// Icono de menu bar + menú dinámico según estado.
@MainActor
final class StatusBar: NSObject, NSMenuDelegate {
    private var item: NSStatusItem!
    private let menu = NSMenu()
    private var cachedWindows: [SCWindow] = []
    private let rc = RecordingController.shared

    /// Icono MOSTAZA de marca (no template): visible aunque el menu bar esté saturado.
    static func brandIcon(fill: NSColor) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: false) { rect in
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
            fill.setStroke()
            ring.lineWidth = 2.2
            ring.stroke()
            let dot = NSBezierPath(ovalIn: rect.insetBy(dx: 6, dy: 6))
            fill.setFill()
            dot.fill()
            return true
        }
        img.isTemplate = false
        return img
    }

    static let mostaza = NSColor(srgbRed: 1.0, green: 0.567, blue: 0.004, alpha: 1)

    /// Botón del status item (ancla del micropanel).
    var button: NSStatusBarButton? { item.button }

    func setup() {
        armarPuertaDeAgentes()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.behavior = .terminationOnRemoval
        if let button = item.button {
            button.image = Self.brandIcon(fill: Self.mostaza)
            button.toolTip = "SFCast — el Loom soberano"
            // Estilo Loom (Daniel 15 jul): click IZQUIERDO togglea el micropanel
            // de grabación; click DERECHO (u Option) abre el menú clásico.
            // Durante una grabación el click izquierdo también va al menú
            // (pausar/detener/cancelar) — el micropanel es solo pre-grabación.
            button.target = self
            button.action = #selector(statusTapped)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        menu.delegate = self
        rc.onStateChange = { [weak self] in self?.refreshIcon() }

        KeyboardShortcuts.onKeyUp(for: .toggleRecording) { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                switch self.rc.state {
                case .idle: await self.rc.startScreen()
                case .recording, .paused: _ = await self.rc.stopAndWait()
                case .countdown: await self.rc.cancel()   // salida viva si el arranque se atora
                case .stopping: break
                }
            }
        }
    }

    private func refreshIcon() {
        guard let button = item.button else { return }
        switch rc.state {
        case .recording:
            button.image = Self.brandIcon(fill: .systemRed)
        case .paused:
            button.image = Self.brandIcon(fill: .systemOrange)
        default:
            button.image = Self.brandIcon(fill: Self.mostaza)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        switch rc.state {
        case .countdown, .stopping:
            // Arranque/cierre en vuelo: SIEMPRE debe haber una salida viva
            // (el "no hay ningún botón vivo" del review adversarial 14 jul).
            let info = NSMenuItem(title: rc.state == .countdown ? "Arrancando grabación…" : "Cerrando/subiendo…",
                                  action: nil, keyEquivalent: "")
            menu.addItem(info)
            add(menu, "✕ Cancelar arranque", #selector(cancelRec), key: "l", mods: [.command, .shift])
        case .idle:
            add(menu, "Panel de grabación…", #selector(openLauncher))
            add(menu, "Abrir SFCast…", #selector(openHub))
            menu.addItem(.separator())
            add(menu, "⏺ Grabar pantalla", #selector(recordScreen), key: "l", mods: [.command, .shift])
            let winItem = NSMenuItem(title: "Grabar ventana", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            if cachedWindows.isEmpty {
                sub.addItem(NSMenuItem(title: "(abriendo lista…)", action: nil, keyEquivalent: ""))
            }
            for w in cachedWindows.prefix(12) {
                let title = (w.owningApplication?.applicationName ?? "?") + " — " + (w.title ?? "sin título")
                let mi = NSMenuItem(title: String(title.prefix(60)), action: #selector(recordWindow(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = w
                sub.addItem(mi)
            }
            winItem.submenu = sub
            menu.addItem(winItem)
            add(menu, "Grabar solo cámara", #selector(recordCam))
            menu.addItem(.separator())
            add(menu, "🎬 Modo Estudio…", #selector(openStudio))
            menu.addItem(.separator())
            // La burbuja se configura EN la burbuja (clic derecho) y en el
            // micropanel — este menú ya no duplica esos controles (v1.4).
            let hist = History.load()
            if !hist.isEmpty {
                let histItem = NSMenuItem(title: "Historial", action: nil, keyEquivalent: "")
                let hsub = NSMenu()
                for e in hist.prefix(8) {
                    let name = e.title ?? e.id
                    if e.status == "local" {
                        // guardada solo en tu Mac: el click la SUBE al VPS
                        let mi = NSMenuItem(title: String("💾 \(name) (\(Int(e.durationSeconds))s) — ↑ subir".prefix(60)),
                                            action: #selector(uploadExistingItem(_:)), keyEquivalent: "")
                        mi.target = self
                        mi.representedObject = e.id
                        hsub.addItem(mi)
                    } else {
                        let icon = e.status == "done" ? "✓" : (e.status == "uploading" ? "↑" : "⚠️")
                        let mi = NSMenuItem(title: String("\(icon) \(name) (\(Int(e.durationSeconds))s)".prefix(60)),
                                            action: #selector(copyLink(_:)), keyEquivalent: "")
                        mi.target = self
                        mi.representedObject = e.url
                        hsub.addItem(mi)
                    }
                }
                hsub.addItem(.separator())
                let bib = NSMenuItem(title: "Abrir biblioteca…", action: #selector(openLibrary), keyEquivalent: "")
                bib.target = self
                hsub.addItem(bib)
                histItem.submenu = hsub
                menu.addItem(histItem)
                menu.addItem(.separator())
            }
            add(menu, "Salir de SFCast", #selector(quit), key: "q", mods: [.command])
            // refresca lista de ventanas en background para la próxima apertura
            Task { @MainActor in
                if let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) {
                    self.cachedWindows = content.windows.filter {
                        ($0.title?.isEmpty == false) && $0.frame.width > 300 && $0.frame.height > 200
                            && $0.owningApplication?.bundleIdentifier != "so.saasfactory.sfcast"
                    }
                }
            }
        case .recording:
            add(menu, "⏸ Pausar", #selector(pauseResume))
            add(menu, "⏹ Detener y copiar link", #selector(stopRec), key: "l", mods: [.command, .shift])
            add(menu, "✕ Cancelar grabación", #selector(cancelRec))
        case .paused:
            add(menu, "▶ Reanudar", #selector(pauseResume))
            add(menu, "⏹ Detener y copiar link", #selector(stopRec))
            add(menu, "✕ Cancelar grabación", #selector(cancelRec))
        }
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector,
                     key: String = "", mods: NSEvent.ModifierFlags = []) {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.keyEquivalentModifierMask = mods
        mi.target = self
        menu.addItem(mi)
    }

    @objc private func statusTapped() {
        let ev = NSApp.currentEvent
        let wantsMenu = ev?.type == .rightMouseUp
            || ev?.modifierFlags.contains(.option) == true
            || rc.state != .idle
        if wantsMenu, let button = item.button {
            menuNeedsUpdate(menu)
            menu.popUp(positioning: nil,
                       at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        } else {
            LauncherPanelController.shared.toggle(relativeTo: item.button)
        }
    }

    @objc private func openHub() { HubWindowController.shared.show() }
    @objc private func openStudio() { StudioController.shared.open() }

    /// Puerta para agentes: `touch ~/.sfcast/abrir-estudio` abre el Estudio.
    ///
    /// El Estudio solo se abria desde este menu de la barra, que no se puede
    /// pulsar por software sin permisos de Accesibilidad. Con esto Levy puede
    /// abrirlo cuando Daniel se lo pida hablando, y ademas se puede verificar
    /// el Estudio en pruebas automaticas.
    private static var vigilante: Timer?

    func armarPuertaDeAgentes() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".sfcast")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        /// Cada señal es un archivo que aparece y se consume. Se limpian al
        /// arrancar: una señal vieja en disco dispararia sola al abrir la app.
        let señales: [String: () -> Void] = [
            "abrir-estudio": { StudioController.shared.open() },
            // El panel de la camara, hablando. Es la puerta AI-first del
            // control de la ZV-E10 desde dentro del Estudio.
            "abrir-camara": {
                StudioController.shared.open()
                StudioController.shared.showCameraPanel = true
            },
            "cerrar-camara": { StudioController.shared.showCameraPanel = false },
            // EL SET (luces, Pixoo) por la misma puerta.
            "abrir-set": {
                StudioController.shared.open()
                StudioController.shared.showSetPanel = true
            },
        ]
        for nombre in señales.keys {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(nombre))
        }
        Self.vigilante = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            for (nombre, accion) in señales {
                let señal = dir.appendingPathComponent(nombre)
                guard FileManager.default.fileExists(atPath: señal.path) else { continue }
                try? FileManager.default.removeItem(at: señal)
                DispatchQueue.main.async(execute: accion)
            }
        }
    }
    @objc private func openLauncher() {
        LauncherPanelController.shared.show(relativeTo: item.button)
    }
    @objc private func recordScreen() { Task { await rc.startScreen() } }
    @objc private func recordCam() { Task { await rc.startCamOnly() } }
    @objc private func recordWindow(_ sender: NSMenuItem) {
        guard let w = sender.representedObject as? SCWindow else { return }
        Task { await rc.startWindow(w) }
    }
    @objc private func pauseResume() {
        Task { rc.state == .paused ? await rc.resume() : await rc.pause() }
    }
    @objc private func stopRec() { Task { _ = await rc.stopAndWait() } }
    @objc private func cancelRec() { Task { await rc.cancel() } }
    @objc private func copyLink(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        notify("SFCast", "Link copiado: \(url)")
    }
    @objc private func uploadExistingItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Task { await rc.uploadExisting(id: id) }
    }
    @objc private func openLibrary() {
        if let url = URL(string: "\(rc.settings.baseURL)/biblioteca/") {
            NSWorkspace.shared.open(url)
        }
    }
    @objc private func quit() { NSApp.terminate(nil) }
}
