import AppKit
import SwiftUI
import IOSurface
import CoreImage
import CoreVideo

/// MODO ESTUDIO — vista desktop. Anatomía OBS/Streamlabs (Escenas + Fuentes +
/// Preview/Programa + Mixer + Salidas), piel Screen Studio: oscura, limpia,
/// acento mostaza de marca. La ventana lleva `sharingType = .none` (invisible a
/// cualquier captura — como el pill); SOLO en --studiotest se deja capturable.
@MainActor
final class StudioController: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = StudioController()

    let engine = StudioEngine()
    let recorder = StudioRecorder()

    @Published var config = StudioConfig.load()
    @Published var selectedItemID: UUID? { didSet { previewView?.refreshOverlay() } }
    @Published var showSettings = false
    @Published var isRecording = false
    @Published var elapsed: TimeInterval = 0
    @Published var micLevel: Float = 0
    @Published var systemLevel: Float = 0
    @Published var screenOK = false
    @Published var cameraOK = false
    @Published var starved: Set<StudioSourceKind> = []
    @Published var lastSessionDir: URL?
    @Published var recordError: String?

    var testMode = false          // --studiotest: ventana capturable
    private var window: NSWindow?
    private var meterTimer: Timer?

    // (El self-view "Burbuja" se ELIMINÓ en v2.3 a pedido de Daniel: el modo
    // Loom vive aparte con su burbuja real; en el Estudio el preview basta.)

    var isStudioRecording: Bool { recorder.isRecording }
    var isOpen: Bool { window?.isVisible ?? false }

    var activeScene: StudioScene? {
        config.scenes.first(where: { $0.id == config.activeSceneID })
    }

    // MARK: - ventana

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
                self?.previewView?.display(surface: surface)
            }
            Task { await engine.start(config: config); pullEngineStatus() }
        }
        startMeters()
    }

    /// El modo Loom arranca → el Estudio se hace a un lado (misma regla que el
    /// micropanel: una sola dueña de cámara/mic a la vez). Si el Estudio está
    /// GRABANDO no se llega aquí (los start* del Loom lo guardan antes).
    func closeForLoom() {
        guard isOpen || engine.isRunning else { return }
        window?.orderOut(nil)
        Task { await engine.stop() }
        stopMeters()
    }

    func windowWillClose(_ notification: Notification) {
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
        let half = UInt64(max(1, seconds / 2)) * 1_000_000_000
        try? await Task.sleep(nanoseconds: half)
        writeFramePNG(name: "studiotest-frame-a.png")
        selectScene(b.id)                                    // switch EN VIVO
        try? await Task.sleep(nanoseconds: half)
        writeFramePNG(name: "studiotest-frame-b.png")
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

    private func writeFramePNG(name: String) {
        guard let pb = engine.snapshotProgramFrame() else {
            print("STUDIOTEST_WARN sin frame de programa para \(name)")
            return
        }
        let img = CIImage(cvPixelBuffer: pb)
        let ctx = CIContext()
        let dir = AppSettings.recordingsDir.appendingPathComponent(recorder.videoID)
        let url = dir.appendingPathComponent(name)
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let data = ctx.pngRepresentation(of: img, format: .BGRA8, colorSpace: cs) else { return }
        try? data.write(to: url)
        print("STUDIOTEST_SHOT \(url.path)")
    }

    private func saveWindowShot(to dir: URL?) {
        guard let w = window, let v = w.contentView,
              let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            let out = (dir ?? FileManager.default.temporaryDirectory)
                .appendingPathComponent("studiotest-ui.png")
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
        w.minSize = NSSize(width: 940, height: 620)
        w.center()
        w.isReleasedWhenClosed = false
        w.backgroundColor = NSColor(calibratedRed: 0.043, green: 0.043, blue: 0.055, alpha: 1)
        // Visibilidad en capturas: configurable en Ajustes (default invisible,
        // estilo OBS). --studiotest siempre capturable.
        if !testMode { w.sharingType = config.windowCapturable ? .readOnly : .none }
        w.delegate = self
        let root = StudioRootView().environmentObject(self)
        let hosting = NSHostingView(rootView: root)
        w.contentView = hosting
        window = w
    }

    func registerPreview(_ v: StudioPreviewNSView) { previewView = v }

    // MARK: - estado del motor / meters

    private func pullEngineStatus() {
        screenOK = engine.screenAvailable
        cameraOK = engine.cameraAvailable
        starved = engine.starvedSources
    }

    private var tick = 0

    private func startMeters() {
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let l = self.engine.levels.get()
                // Vúmetro real: ataque INSTANTÁNEO, caída suave (el valor crudo
                // a 15Hz brincaba feo — feedback Daniel v2.3).
                self.micLevel = max(l.mic, self.micLevel * 0.80)
                self.systemLevel = max(l.system, self.systemLevel * 0.80)
                if self.isRecording { self.elapsed = self.recorder.elapsed }
                self.tick += 1
                if self.tick % 45 == 0 { self.engine.retryScreenIfNeeded() }   // ~3s
            }
        }
    }


    private func stopMeters() {
        meterTimer?.invalidate()
        meterTimer = nil
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

    /// Transform EN VIVO desde el canvas (drag/resize): actualiza el compositor
    /// a cada tick sin golpear disco; persiste al soltar (commitItemDrag).
    func setItemRect(_ id: UUID, _ rect: CGRect, persist: Bool) {
        guard let sIdx = config.scenes.firstIndex(where: { $0.id == config.activeSceneID }),
              let iIdx = config.scenes[sIdx].items.firstIndex(where: { $0.id == id }) else { return }
        config.scenes[sIdx].items[iIdx].rect = rect
        pushActiveScene()
        if persist { config.save() }
    }

    func commitItemDrag() {
        config.save()
    }

    /// Ajustes → Aplicar: reinicia el motor con la config nueva (fps/canvas/
    /// dispositivos se leen al arrancar). No disponible mientras grabas.
    func applySettings() {
        guard !recorder.isRecording else { return }
        config.save()
        Task {
            await engine.stop()
            await engine.start(config: config)
            pullEngineStatus()
        }
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
    }

    // MARK: - grabación

    func toggleRecord() {
        if recorder.isRecording {
            Task {
                let dir = await recorder.stop(engine: engine, config: config)
                isRecording = false
                elapsed = 0
                lastSessionDir = dir
                if let dir, !testMode {
                    NSWorkspace.shared.activateFileViewerSelecting([dir])
                }
            }
        } else {
            guard recorder.state == .idle else { return }   // anti doble-clic en .stopping
            do {
                try recorder.start(engine: engine, config: config, activeScene: activeScene)
                recordError = nil
                isRecording = true
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
    static let morado = NSColor(calibratedRed: 0.549, green: 0.153, blue: 0.945, alpha: 1) // #8C27F1

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
        return CGRect(x: f.minX + item.rect.minX * f.width,
                      y: f.minY + item.rect.minY * f.height,
                      width: item.rect.width * f.width,
                      height: item.rect.height * f.height)
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
        c.setItemRect(id, r, persist: false)
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

struct StudioRootView: View {
    @EnvironmentObject var c: StudioController

    var body: some View {
        VStack(spacing: 10) {
            topBar
            StudioPreviewView()
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(StudioSkin.panelBorder))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            // SIMETRÍA estilo Streamlabs: 4 columnas de ancho IGUAL, sin huecos.
            HStack(spacing: 10) {
                ScenesPanel().frame(maxWidth: .infinity)
                SourcesPanel().frame(maxWidth: .infinity)
                MixerPanel().frame(maxWidth: .infinity)
                OutputsPanel().frame(maxWidth: .infinity)
            }
            .frame(height: 235)
        }
        .padding(12)
        .background(StudioSkin.bg)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $c.showSettings) {
            StudioSettingsView().environmentObject(c)
        }
        // ⌘D duplica la escena activa desde cualquier lado del Estudio
        .background(
            Button("") { c.duplicateScene() }
                .keyboardShortcut("d", modifiers: .command)
                .hidden()
        )
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
            if let err = c.recordError {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
            Spacer()
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
                Text(timeString(c.elapsed))
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.red)
            }
        }
    }

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
                Button("Aplicar (reinicia el motor)") {
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

// MARK: - panel Mixer

struct MixerPanel: View {
    @EnvironmentObject var c: StudioController

    var body: some View {
        PanelBox(title: "Mixer") {
            VStack(alignment: .leading, spacing: 12) {
                meter("Micrófono", level: c.micLevel, enabled: Binding(
                    get: { c.config.micEnabled },
                    set: { c.config.micEnabled = $0; c.config.save() }))
                meter("Sistema", level: c.systemLevel, enabled: Binding(
                    get: { c.config.systemAudioEnabled },
                    set: { c.config.systemAudioEnabled = $0; c.config.save() }))
                Text("Los toggles aplican al\nabrir el Estudio de nuevo")
                    .font(.system(size: 9))
                    .foregroundStyle(StudioSkin.dim.opacity(0.7))
            }
        }
    }

    private func meter(_ label: String, level: Float, enabled: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.system(size: 11)).foregroundStyle(StudioSkin.text)
                Spacer()
                Toggle("", isOn: enabled).toggleStyle(.checkbox).labelsHidden()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.08))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(LinearGradient(colors: [StudioSkin.mostaza.opacity(0.7), level > 0.85 ? .red : StudioSkin.mostaza],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * CGFloat(min(level, 1)))
                        .animation(.linear(duration: 0.08), value: level)
                }
            }
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
                outputToggle("Pantalla (raw)", "screen.mp4", available: c.screenOK, isOn: Binding(
                    get: { c.config.outputs.rawScreen },
                    set: { c.config.outputs.rawScreen = $0; c.config.save() }))
                outputToggle("Cámara (raw)", "camera.mov", available: c.cameraOK, isOn: Binding(
                    get: { c.config.outputs.rawCamera },
                    set: { c.config.outputs.rawCamera = $0; c.config.save() }))
                outputToggle("Programa", "compuesto + escenas", available: true, isOn: Binding(
                    get: { c.config.outputs.program },
                    set: { c.config.outputs.program = $0; c.config.save() }))
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
