import AppKit
import SwiftUI

// ── Tema SaaS Factory (paleta SFlow: titanium + mostaza) ─────────────────────
enum Theme {
    static let bg = Color(red: 0.043, green: 0.047, blue: 0.055)      // #0b0c0e
    static let card = Color(red: 0.078, green: 0.086, blue: 0.098)    // #141619
    static let line = Color(red: 0.15, green: 0.16, blue: 0.18)
    static let txt = Color(red: 0.91, green: 0.91, blue: 0.90)
    static let dim = Color(red: 0.60, green: 0.60, blue: 0.58)
    static let acc = Color(red: 1.0, green: 0.567, blue: 0.004)       // #ff9101
    static let purple = Color(red: 0.549, green: 0.153, blue: 0.945)  // #8C27F1
}

// ── Ventana hub (panel de control estilo SFlow) ──────────────────────────────
@MainActor
final class HubWindowController: NSObject, NSWindowDelegate {
    static let shared = HubWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
                styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            w.title = "SFCast"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.appearance = NSAppearance(named: .darkAqua)
            w.backgroundColor = NSColor(red: 0.043, green: 0.047, blue: 0.055, alpha: 1)
            w.isReleasedWhenClosed = false
            w.center()
            w.delegate = self
            w.contentViewController = NSHostingController(rootView: HubView())
            window = w
        }
        // Con el hub abierto SFCast es una app "de verdad": icono en el Dock,
        // Cmd+Tab, Cmd+Q. Al cerrarlo vuelve a ser agente puro de menu bar.
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

// ── Vistas ───────────────────────────────────────────────────────────────────
private enum HubTab: String, CaseIterable {
    case inicio = "Inicio", ajustes = "Ajustes", historial = "Historial"
    var icon: String {
        switch self {
        case .inicio: return "house.fill"
        case .ajustes: return "gearshape.fill"
        case .historial: return "clock.fill"
        }
    }
}

struct HubView: View {
    @State private var tab: HubTab = .inicio

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(Theme.line)
            Group {
                switch tab {
                case .inicio: InicioView()
                case .ajustes: AjustesView()
                case .historial: HistorialView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.bg)
        }
        .frame(minWidth: 820, minHeight: 560)
        .background(Theme.bg)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9).fill(Theme.acc).frame(width: 34, height: 34)
                    Image(systemName: "record.circle").font(.system(size: 19, weight: .bold)).foregroundColor(.black)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text("SFCast").font(.system(size: 15, weight: .bold)).foregroundColor(Theme.txt)
                    Text("SaaS Factory").font(.system(size: 10, weight: .semibold)).foregroundColor(Theme.acc)
                }
            }
            .padding(.bottom, 22).padding(.top, 30)

            ForEach(HubTab.allCases, id: \.self) { t in
                Button { tab = t } label: {
                    HStack(spacing: 9) {
                        Image(systemName: t.icon).frame(width: 16)
                        Text(t.rawValue).font(.system(size: 13, weight: .medium))
                        Spacer()
                    }
                    .foregroundColor(tab == t ? Theme.txt : Theme.dim)
                    .padding(.vertical, 8).padding(.horizontal, 10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(tab == t ? Theme.card : .clear))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(tab == t ? Theme.acc.opacity(0.5) : .clear, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Text("v1.5").font(.system(size: 9)).foregroundColor(Theme.dim.opacity(0.6))
                .padding(.bottom, 16)
        }
        .padding(.horizontal, 14)
        .frame(width: 190)
        .background(Color.black.opacity(0.35))
    }
}

// ── Inicio ───────────────────────────────────────────────────────────────────
private struct InicioView: View {
    @State private var videos = History.load()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                PermisosCard()
                card("📊  Estado") {
                    HStack {
                        Text("Videos publicados").foregroundColor(Theme.dim)
                        Spacer()
                        Text("\(videos.filter { $0.status == "done" }.count)")
                            .font(.system(size: 14, weight: .bold)).foregroundColor(Theme.acc)
                    }
                    .font(.system(size: 13))
                    HStack {
                        Text("Biblioteca privada").foregroundColor(Theme.dim)
                        Spacer()
                        Button("Abrir →") {
                            if let url = URL(string: "\(AppSettings.load().baseURL)/biblioteca/") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.plain).foregroundColor(Theme.acc).font(.system(size: 13, weight: .semibold))
                    }
                    .font(.system(size: 13))
                }
                Button {
                    Task { @MainActor in
                        HubWindowController.shared.hide()
                        await RecordingController.shared.startScreen()
                    }
                } label: {
                    HStack {
                        Image(systemName: "record.circle.fill")
                        Text("Grabar pantalla").fontWeight(.bold)
                    }
                    .font(.system(size: 15))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.acc))
                }
                .buttonStyle(.plain)
            }
            .padding(26)
        }
        .onAppear { videos = History.load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SFCast").font(.system(size: 26, weight: .bold)).foregroundColor(Theme.acc)
            Text("Todo se maneja desde el icono ⏺ del menu bar (⌘⇧L graba).")
                .font(.system(size: 13)).foregroundColor(Theme.dim)
        }
    }
}

// ── Permisos (tarjeta viva: se refresca sola cada 2s) ────────────────────────
private struct PermisosCard: View {
    @State private var cam = false
    @State private var mic = false
    @State private var scr = false
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    @State private var working = false

    var body: some View {
        card("🔐  Permisos de macOS") {
            row("Pantalla y audio del sistema", ok: scr, anchor: "ScreenCapture")
            row("Cámara (burbuja)", ok: cam, anchor: "Camera")
            row("Micrófono", ok: mic, anchor: "Microphone")

            if !cam || !mic {
                // Botón GRANDE: pedir por gesto de usuario es lo más confiable
                // para que el diálogo se pinte. El broker activa la app, sube este
                // hub al frente y pide cámara+mic EN SERIE (jamás toca el
                // renderer de diálogos del sistema — lección 15 jul).
                Button { activar() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: working ? "hourglass" : "camera.fill")
                        Text(working ? "Pidiendo permisos…" : "Activar cámara y micrófono").fontWeight(.bold)
                    }
                    .font(.system(size: 13.5))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.acc))
                }
                .buttonStyle(.plain).disabled(working)
                Text("Aparecen DOS diálogos (cámara y micrófono): dale «Permitir» en ambos. Si tienes dos monitores, míralos los dos.")
                    .font(.system(size: 11)).foregroundColor(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
                Text("¿No aparece NINGÚN diálogo ni con el botón? macOS tiene su cola de permisos atascada. Reinicia la Mac UNA vez y al reabrir SFCast saldrán solos. (Es cosa de macOS, no de SFCast.)")
                    .font(.system(size: 10.5)).foregroundColor(Theme.acc.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Todo listo. La burbuja de cámara y tu voz se graban solas.")
                    .font(.system(size: 11)).foregroundColor(.green)
            }

            HStack(spacing: 8) {
                Button("🔧 Reparar") { repair() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.acc)
                Text("resetea los permisos de SFCast y los vuelve a pedir desde cero")
                    .font(.system(size: 10)).foregroundColor(Theme.dim)
            }
        }
        .onAppear { refresh() }
        .onReceive(tick) { _ in refresh() }
    }

    private func refresh() {
        cam = Permissions.cameraGranted
        mic = Permissions.micGranted
        scr = Permissions.screenGranted
    }

    private func activar() {
        working = true
        Task { @MainActor in
            await PermissionBroker.shared.ensureCameraAndMic()
            refresh()
            working = false
        }
    }

    /// Escalación: resetea las entradas TCC de la app (tccutil) y re-pide via
    /// broker. Si ni así aparece el diálogo, la cola de tccd está atascada a
    /// nivel OS y solo un reinicio de la Mac la limpia (guía en la tarjeta).
    private func repair() {
        working = true
        PermissionBroker.shared.resetAndReRequest()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            refresh()
            working = false
        }
    }

    private func row(_ label: String, ok: Bool, anchor: String) -> some View {
        HStack(spacing: 8) {
            Circle().fill(ok ? Color.green : Color(red: 0.92, green: 0.32, blue: 0.25))
                .frame(width: 8, height: 8)
            Text(label).font(.system(size: 13)).foregroundColor(Theme.txt)
            Spacer()
            Text(ok ? "OK" : "falta")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(ok ? .green : Theme.acc)
            if !ok {
                Button("Ajustes…") { Permissions.openPrivacyPane(anchor) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.acc)
            }
        }
    }
}

// ── Ajustes ──────────────────────────────────────────────────────────────────
private struct AjustesView: View {
    @State private var s = AppSettings.load()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Ajustes").font(.system(size: 26, weight: .bold)).foregroundColor(Theme.acc)
                Text("Cámara, micrófono y modo viven en el panel del icono ⏺. El tamaño y glow de la burbuja, en la burbuja misma (clic derecho).")
                    .font(.system(size: 12)).foregroundColor(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)

                card("🔊  Audio del sistema") {
                    Toggle(isOn: Binding(get: { s.systemAudioEnabled }, set: { v in mutate { $0.systemAudioEnabled = v } })) {
                        Text("Grabar audio del sistema").font(.system(size: 13)).foregroundColor(Theme.txt)
                    }
                    .toggleStyle(.switch).tint(Theme.acc)
                }
                card("⏱️  Countdown") {
                    Picker("", selection: Binding(get: { s.countdownSeconds }, set: { v in mutate { $0.countdownSeconds = v } })) {
                        Text("Sin countdown").tag(0)
                        Text("3 segundos").tag(3)
                        Text("5 segundos").tag(5)
                    }
                    .labelsHidden().pickerStyle(.segmented)
                }
                Text("Los videos se publican en \(s.baseURL). Ajustes guardados al instante.")
                    .font(.system(size: 11)).foregroundColor(Theme.dim)
            }
            .padding(26)
        }
        .onAppear { s = AppSettings.load() }
    }

    /// Mutación segura: relee del DISCO, aplica el cambio y guarda. Sin esto,
    /// la copia @State vieja pisaba en silencio lo cambiado desde el menú ⏺
    /// (review adversarial 14 jul: "reversión silenciosa de ajustes").
    private func mutate(_ f: (inout AppSettings) -> Void) {
        var fresh = AppSettings.load()
        f(&fresh)
        fresh.save()
        s = fresh
    }

}

// ── Historial ────────────────────────────────────────────────────────────────
private struct HistorialView: View {
    @State private var items = History.load()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Historial").font(.system(size: 26, weight: .bold)).foregroundColor(Theme.acc)
                if items.isEmpty {
                    Text("Aún no hay grabaciones. Dale a ⌘⇧L y estrénala.")
                        .font(.system(size: 13)).foregroundColor(Theme.dim)
                }
                ForEach(items, id: \.id) { e in
                    HStack(spacing: 12) {
                        Text(e.status == "done" ? "✓" : (e.status == "uploading" ? "↑" : "⚠️"))
                            .foregroundColor(e.status == "done" ? .green : Theme.acc)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.title ?? e.id).font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.txt)
                            Text("\(e.date.prefix(10)) · \(Int(e.durationSeconds))s · \(e.mode)")
                                .font(.system(size: 11)).foregroundColor(Theme.dim)
                        }
                        Spacer()
                        Button("Copiar link") { copy(e.url) }
                            .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.acc)
                        Button("Abrir") { if let u = URL(string: e.url) { NSWorkspace.shared.open(u) } }
                            .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.dim)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line, lineWidth: 1))
                }
            }
            .padding(26)
        }
        .onAppear { items = History.load() }
    }

    private func copy(_ str: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(str, forType: .string)
    }
}

// ── card helper ──────────────────────────────────────────────────────────────
private func card(_ title: String, @ViewBuilder content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 12) {
        Text(title).font(.system(size: 12, weight: .bold)).foregroundColor(Theme.acc)
            .textCase(.uppercase).kerning(0.8)
        content()
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1))
}

extension HubWindowController {
    func hide() {
        // acceso interno para el botón Grabar (cierra el hub antes del countdown)
        NSApp.windows.first(where: { $0.contentViewController is NSHostingController<HubView> })?.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)   // sin hub, sin icono en el Dock
    }
}
