import AppKit
import SwiftUI
import AVFoundation
import CoreMedia
import ScreenCaptureKit

// ════════════════════════════════════════════════════════════════════════════
// El MICROPANEL pre-grabación (estilo Loom, petición Daniel 15 jul):
// click en el icono del menu bar → panel flotante con TODO lo que importa
// ANTES de grabar: modo (pantalla/ventana/cámara), cámara On/Off con la
// burbuja EN VIVO como preview, micrófono On/Off con VÚMETRO en tiempo real
// (sabes que se escucha ANTES de grabar), y el botón Empezar a grabar.
// Click en el icono otra vez (o ✕ / Esc) = se oculta todo, súper sutil.
// ════════════════════════════════════════════════════════════════════════════

// ── Vúmetro: mide el nivel del mic elegido SOLO mientras el panel está abierto ─
// Sesión AVCapture propia (ligera). Se DETIENE siempre antes de grabar: el
// motor de grabación (SCStream) toma el mic por su cuenta y no queremos dos
// clientes peleando el dispositivo.
@MainActor
final class MicLevelMeter: NSObject, ObservableObject {
    @Published private(set) var level: Double = 0     // 0..1 suavizado
    private var session: AVCaptureSession?
    private let queue = DispatchQueue(label: "so.saasfactory.sfcast.miclevel")

    func start(deviceID: String?) {
        stop()
        guard Permissions.micGranted,
              let dev = Devices.microphone(id: deviceID),
              let input = try? AVCaptureDeviceInput(device: dev) else { return }
        let s = AVCaptureSession()
        s.beginConfiguration()
        guard s.canAddInput(input) else { s.commitConfiguration(); return }
        s.addInput(input)
        let out = AVCaptureAudioDataOutput()
        out.setSampleBufferDelegate(self, queue: queue)
        if s.canAddOutput(out) { s.addOutput(out) }
        s.commitConfiguration()
        session = s
        queue.async { s.startRunning() }
    }

    func stop() {
        // SÍNCRONO a propósito (hallazgo del review v1.4): con countdown en 0,
        // un stop fire-and-forget podía seguir vivo cuando la grabación ya
        // estaba tomando el mismo mic. queue.sync espera a que el último
        // callback del delegate termine (el callback no bloquea main: solo
        // agenda un Task, así que no hay deadlock) y detiene la sesión YA.
        if let s = session { queue.sync { s.stopRunning() } }
        session = nil
        level = 0
    }
}

extension MicLevelMeter: AVCaptureAudioDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        let power = connection.audioChannels.map(\.averagePowerLevel).max() ?? -60
        let norm = max(0, min(1, (Double(power) + 50) / 50))    // -50dB..0dB → 0..1
        Task { @MainActor [weak self] in
            guard let self else { return }
            // ataque instantáneo, caída suave: el vúmetro se siente vivo
            self.setLevel(norm > self.level ? norm : self.level * 0.82)
        }
    }

    private func setLevel(_ v: Double) { level = v }
}

// ── Controller del panel ─────────────────────────────────────────────────────
@MainActor
final class LauncherPanelController {
    static let shared = LauncherPanelController()
    let meter = MicLevelMeter()

    private var panel: NSPanel?
    private var hosting: NSHostingView<LauncherView>?
    /// Anclaje: el panel cuelga del icono del menu bar; si el contenido cambia
    /// de alto (modo ventana agrega una fila), el TOP queda fijo.
    private var anchorTop: CGFloat = 0
    private var anchorMidX: CGFloat = 0

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle(relativeTo button: NSStatusBarButton?) {
        if isVisible { hide() } else { show(relativeTo: button) }
    }

    func show(relativeTo button: NSStatusBarButton?) {
        guard RecordingController.shared.state == .idle else { return }
        if panel == nil { build() }
        // contenido fresco en cada apertura (settings/dispositivos releídos)
        let view = LauncherView(meter: meter)
        hosting?.rootView = view

        // ancla bajo el icono del menu bar (o esquina sup. derecha si no hay botón)
        if let button, let bw = button.window {
            let rect = bw.convertToScreen(button.convert(button.bounds, to: nil))
            anchorTop = rect.minY - 8
            anchorMidX = rect.midX
        } else if let screen = NSScreen.main {
            anchorTop = screen.visibleFrame.maxY - 8
            anchorMidX = screen.visibleFrame.maxX - 180
        }
        relayout()
        panel?.orderFrontRegardless()
        panel?.makeKey()
        startPreview()
    }

    /// keepPreview=true cuando el ocultamiento es porque VA a arrancar la
    /// grabación: la burbuja se queda (continuidad visual), solo muere el
    /// vúmetro (libera el mic ANTES de que SCStream lo tome).
    func hide(keepPreview: Bool = false) {
        meter.stop()
        panel?.orderOut(nil)
        if !keepPreview, RecordingController.shared.state == .idle {
            RecordingController.shared.bubble.hide()
        }
    }

    /// Recalcula el frame respetando el ancla superior (el panel crece hacia abajo).
    func relayout() {
        guard let panel, let hosting else { return }
        let size = hosting.fittingSize
        var x = anchorMidX - size.width / 2
        // clamp contra la pantalla DEL ANCLA (el icono puede vivir en el
        // monitor secundario — NSScreen.main es la pantalla con foco, no esa).
        let anchorScreen = NSScreen.screens.first {
            $0.frame.contains(NSPoint(x: anchorMidX, y: anchorTop - 1))
        } ?? NSScreen.main
        if let vf = anchorScreen?.visibleFrame {
            x = min(max(x, vf.minX + 8), vf.maxX - size.width - 8)
        }
        panel.setFrame(NSRect(x: x, y: anchorTop - size.height,
                              width: size.width, height: size.height), display: true)
    }

    // ── preview: burbuja viva + vúmetro, ANTES de grabar (el gap vs Loom) ────
    func startPreview() {
        updateCameraPreview()
        updateMicMeter()
    }

    func updateCameraPreview() {
        let rc = RecordingController.shared
        guard rc.state == .idle else { return }
        let s = AppSettings.load()
        guard s.cameraEnabled else { rc.bubble.hide(); return }
        guard let screen = RecordingController.captureScreen() else { return }
        if Permissions.cameraGranted {
            rc.bubble.show(size: CameraBubble.Size(rawValue: s.bubbleSize) ?? .m,
                           glow: CameraBubble.Glow(rawValue: s.bubbleGlow) ?? .ambar,
                           on: screen)
        } else if Permissions.canPrompt {
            // pide via broker (serializado); si concede y el panel sigue abierto,
            // enciende el preview
            Task { @MainActor in
                if await PermissionBroker.shared.request(.video),
                   AppSettings.load().cameraEnabled, self.isVisible {
                    self.updateCameraPreview()
                }
            }
        }
    }

    func updateMicMeter() {
        let s = AppSettings.load()
        if s.micEnabled, Permissions.micGranted, isVisible {
            meter.start(deviceID: s.micDeviceID)
        } else {
            meter.stop()
        }
    }

    // ── construcción ─────────────────────────────────────────────────────────
    private func build() {
        let p = LauncherNSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 420),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        p.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 4)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.hidesOnDeactivate = false
        p.sharingType = .none            // el micropanel JAMÁS sale en el video

        let host = NSHostingView(rootView: LauncherView(meter: meter))
        p.contentView = host
        hosting = host
        panel = p
    }
}

/// Borderless que SÍ puede ser key (los pickers/toggles de SwiftUI lo
/// necesitan) pero sin activar la app (.nonactivatingPanel). Esc lo cierra.
final class LauncherNSPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) {
        Task { @MainActor in LauncherPanelController.shared.hide() }
    }
}

// ── La vista ─────────────────────────────────────────────────────────────────
struct LauncherView: View {
    @ObservedObject var meter: MicLevelMeter
    @State private var s = AppSettings.load()
    @State private var cams = Devices.cameras()
    @State private var mics = Devices.microphones()
    @State private var mode: RecordingController.Mode = .screen
    @State private var windows: [SCWindow] = []
    @State private var selectedWindow: Int = -1
    @State private var camOK = Permissions.cameraGranted
    @State private var micOK = Permissions.micGranted
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 10) {
            header
            modePicker
            if mode == .window { windowRow }
            cameraRow
            micRow
            recordButton
            footer
        }
        .padding(14)
        .frame(width: 320)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Theme.bg.opacity(0.96))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.13), lineWidth: 1))
        )
        .onAppear {
            s = AppSettings.load()
            cams = Devices.cameras()
            mics = Devices.microphones()
            camOK = Permissions.cameraGranted
            micOK = Permissions.micGranted
            loadWindows()
        }
        .onReceive(tick) { _ in
            // permisos pueden llegar con el panel abierto (broker en vuelo)
            let c = Permissions.cameraGranted, m = Permissions.micGranted
            if c != camOK || m != micOK {
                camOK = c; micOK = m
                LauncherPanelController.shared.updateMicMeter()
            }
        }
    }

    // ── header: marca + cerrar ────────────────────────────────────────────────
    private var header: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 7).fill(Theme.acc).frame(width: 26, height: 26)
                Image(systemName: "record.circle").font(.system(size: 15, weight: .bold)).foregroundColor(.black)
            }
            Text("SFCast").font(.system(size: 14, weight: .bold)).foregroundColor(Theme.txt)
            Spacer()
            iconButton("gearshape.fill", tip: "Ajustes") {
                // hide() PLENO: si no va a arrancar grabación, la cámara se
                // apaga (keepPreview era fuga: luz encendida sin propósito).
                LauncherPanelController.shared.hide()
                HubWindowController.shared.show()
            }
            iconButton("xmark", tip: "Cerrar") {
                LauncherPanelController.shared.hide()
            }
        }
    }

    // ── modo ─────────────────────────────────────────────────────────────────
    private var modePicker: some View {
        HStack(spacing: 4) {
            modeChip(.screen, icon: "display", label: "Pantalla")
            modeChip(.window, icon: "macwindow", label: "Ventana")
            modeChip(.camOnly, icon: "web.camera", label: "Cámara")
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
    }

    private func modeChip(_ m: RecordingController.Mode, icon: String, label: String) -> some View {
        Button {
            mode = m
            if m == .window { loadWindows() }
            DispatchQueue.main.async { LauncherPanelController.shared.relayout() }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                Text(label).font(.system(size: 10, weight: .semibold))
            }
            .foregroundColor(mode == m ? .black : Theme.dim)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(mode == m ? Theme.acc : .clear))
        }
        .buttonStyle(.plain)
    }

    // ── fila ventana (solo modo ventana) ─────────────────────────────────────
    private var windowRow: some View {
        row(icon: "macwindow") {
            Picker("", selection: $selectedWindow) {
                Text(windows.isEmpty ? "Buscando ventanas…" : "Elige una ventana").tag(-1)
                ForEach(Array(windows.enumerated()), id: \.offset) { i, w in
                    Text(windowLabel(w)).tag(i)
                }
            }
            .labelsHidden().pickerStyle(.menu)
        }
    }

    private func windowLabel(_ w: SCWindow) -> String {
        let app = w.owningApplication?.applicationName ?? "?"
        let title = w.title ?? "sin título"
        return String("\(app) — \(title)".prefix(42))
    }

    private func loadWindows() {
        Task { @MainActor in
            if let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) {
                windows = content.windows.filter {
                    ($0.title?.isEmpty == false) && $0.frame.width > 300 && $0.frame.height > 200
                        && $0.owningApplication?.bundleIdentifier != "so.saasfactory.sfcast"
                }
                if selectedWindow >= windows.count { selectedWindow = -1 }
            }
        }
    }

    // ── fila cámara: picker + On/Off (preview vivo en la burbuja) ────────────
    private var cameraRow: some View {
        row(icon: "video.fill") {
            if camOK || Permissions.canPrompt {
                Picker("", selection: Binding(
                    get: { s.cameraDeviceID ?? "default" },
                    set: { v in
                        mutate { $0.cameraDeviceID = v == "default" ? nil : v }
                        if RecordingController.shared.bubble.isVisible {
                            RecordingController.shared.bubble.reloadCamera()
                        }
                    })) {
                    Text("Cámara automática").tag("default")
                    ForEach(cams) { Text($0.name).tag($0.id) }
                }
                .labelsHidden().pickerStyle(.menu)
                .disabled(!s.cameraEnabled)
                Toggle("", isOn: Binding(
                    get: { s.cameraEnabled },
                    set: { v in
                        mutate { $0.cameraEnabled = v }
                        LauncherPanelController.shared.updateCameraPreview()
                    }))
                    .labelsHidden().toggleStyle(.switch).tint(Theme.acc)
                    .scaleEffect(0.8)
            } else {
                Text("Cámara sin permiso").font(.system(size: 12)).foregroundColor(Theme.dim)
                Spacer()
                Button("Ajustes…") { Permissions.openPrivacyPane("Camera") }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundColor(Theme.acc)
            }
        }
    }

    // ── fila mic: picker + On/Off + VÚMETRO (sabes que se escucha) ───────────
    private var micRow: some View {
        VStack(spacing: 0) {
            row(icon: "mic.fill", corners: [.top]) {
                if micOK || Permissions.canPrompt {
                    Picker("", selection: Binding(
                        get: { s.micDeviceID ?? "default" },
                        set: { v in
                            mutate { $0.micDeviceID = v == "default" ? nil : v }
                            LauncherPanelController.shared.updateMicMeter()
                        })) {
                        Text("Mic automático").tag("default")
                        ForEach(mics) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden().pickerStyle(.menu)
                    .disabled(!s.micEnabled)
                    Toggle("", isOn: Binding(
                        get: { s.micEnabled },
                        set: { v in
                            mutate { $0.micEnabled = v }
                            LauncherPanelController.shared.updateMicMeter()
                        }))
                        .labelsHidden().toggleStyle(.switch).tint(Theme.acc)
                        .scaleEffect(0.8)
                } else {
                    Text("Micrófono sin permiso").font(.system(size: 12)).foregroundColor(Theme.dim)
                    Spacer()
                    Button("Ajustes…") { Permissions.openPrivacyPane("Microphone") }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundColor(Theme.acc)
                }
            }
            // vúmetro: la barra respira con tu voz (verificas el audio ANTES)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule().fill(Theme.acc)
                        .frame(width: max(3, geo.size.width * meter.level))
                        .animation(.linear(duration: 0.08), value: meter.level)
                }
            }
            .frame(height: 3)
            .padding(.horizontal, 12)
            .padding(.bottom, 9)
            .background(cardShape(corners: [.bottom]))
            .opacity(s.micEnabled && micOK ? 1 : 0.25)
        }
    }

    // ── Empezar a grabar ─────────────────────────────────────────────────────
    private var recordButton: some View {
        Button { start() } label: {
            HStack(spacing: 8) {
                Image(systemName: "record.circle.fill")
                Text("Empezar a grabar").fontWeight(.bold)
            }
            .font(.system(size: 14))
            .foregroundColor(.black)
            .frame(maxWidth: .infinity).padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 11).fill(
                startDisabled ? Theme.acc.opacity(0.35) : Theme.acc))
        }
        .buttonStyle(.plain)
        .disabled(startDisabled)
    }

    private var startDisabled: Bool {
        if mode == .window { return selectedWindow < 0 || selectedWindow >= windows.count }
        // modo Cámara con la cámara apagada = combo sin sentido (hallazgo del
        // review v1.4: startCamOnly prendería la cámara pese al toggle OFF)
        if mode == .camOnly { return !s.cameraEnabled }
        return false
    }

    private func start() {
        let m = mode
        let win: SCWindow? = (selectedWindow >= 0 && selectedWindow < windows.count)
            ? windows[selectedWindow] : nil
        LauncherPanelController.shared.hide(keepPreview: true)
        Task { @MainActor in
            switch m {
            case .screen: await RecordingController.shared.startScreen()
            case .window:
                if let win { await RecordingController.shared.startWindow(win) }
            case .camOnly: await RecordingController.shared.startCamOnly()
            }
        }
    }

    // ── footer mínimo ────────────────────────────────────────────────────────
    private var footer: some View {
        HStack(spacing: 18) {
            footItem("clock.fill", "Historial") {
                LauncherPanelController.shared.hide()
                HubWindowController.shared.show()
            }
            footItem("books.vertical.fill", "Biblioteca") {
                if let url = URL(string: "\(AppSettings.load().baseURL)/biblioteca/") {
                    NSWorkspace.shared.open(url)
                }
            }
            Spacer()
            Text("⌘⇧L").font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(Theme.dim.opacity(0.7))
        }
        .padding(.top, 2)
    }

    private func footItem(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                Text(label).font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(Theme.dim)
        }
        .buttonStyle(.plain)
    }

    // ── helpers ──────────────────────────────────────────────────────────────
    private enum Corner { case top, bottom }

    private func cardShape(corners: [Corner]) -> some View {
        // filas apiladas (mic + vúmetro) comparten un solo card visual
        UnevenRoundedRectangle(
            topLeadingRadius: corners.contains(.top) ? 10 : 0,
            bottomLeadingRadius: corners.contains(.bottom) ? 10 : 0,
            bottomTrailingRadius: corners.contains(.bottom) ? 10 : 0,
            topTrailingRadius: corners.contains(.top) ? 10 : 0)
            .fill(Theme.card)
    }

    private func row(icon: String, corners: [Corner] = [.top, .bottom],
                     @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.dim).frame(width: 18)
            content()
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardShape(corners: corners))
    }

    private func iconButton(_ symbol: String, tip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.dim)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.white.opacity(0.06)))
        }
        .buttonStyle(.plain)
        .help(tip)
    }

    /// Mutación segura (patrón del hub): relee del disco, aplica, guarda.
    private func mutate(_ f: (inout AppSettings) -> Void) {
        var fresh = AppSettings.load()
        f(&fresh)
        fresh.save()
        s = fresh
    }
}
