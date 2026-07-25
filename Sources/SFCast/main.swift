import AppKit

// SFCast — el Loom soberano de SaaS Factory.
// Modos headless (--demo, --selftest) se parsean ANTES de armar la app (patrón SFlow).

let cliArgs = CommandLine.arguments
var demoSeconds: Int? = nil
var demoNoUpload = false
var selftestSeconds: Int? = nil

if let i = cliArgs.firstIndex(of: "--demo"), i + 1 < cliArgs.count {
    demoSeconds = Int(cliArgs[i + 1]) ?? 130
}
if let i = cliArgs.firstIndex(of: "--selftest") {
    selftestSeconds = (i + 1 < cliArgs.count ? Int(cliArgs[i + 1]) : nil) ?? 4
}
if cliArgs.contains("--no-upload") { demoNoUpload = true }
if cliArgs.contains("--version") {
    print("SFCast 2.0.0")
    exit(0)
}

/// QA del Modo Estudio (`--studiotest N`): abre la vista desktop CAPTURABLE,
/// graba N segundos (patrón de prueba garantizado + pantalla/cámara si hay
/// permiso), hace un switch de escena en vivo a la mitad, y deja PNGs del frame
/// de programa + de la ventana + los archivos de la sesión como evidencia.
let studioTestSeconds: Int? = {
    guard let i = cliArgs.firstIndex(of: "--studiotest") else { return nil }
    return (i + 1 < cliArgs.count ? Int(cliArgs[i + 1]) : nil) ?? 8
}()

/// QA de PESO (`--studiobench N`): graba N segundos con la config REAL y
/// reporta MB/Mbps por archivo. El comparador del tamaño (ver runBench).
let studioBenchSeconds: Int? = {
    guard let i = cliArgs.firstIndex(of: "--studiobench") else { return nil }
    return (i + 1 < cliArgs.count ? Int(cliArgs[i + 1]) : nil) ?? 60
}()

/// QA del compresor (`--compresstest <dir>`): corre Transcoder sobre una COPIA
/// del directorio dado y reporta antes/después. Existe porque comprimir es lo
/// único del flujo que toca el MP4 en sitio: quiero poder probar el camino real
/// (temporal fuera de sessionDir, compuertas de tamaño y duración, replace)
/// contra un video de verdad sin arriesgar una grabación.
if let i = cliArgs.firstIndex(of: "--compresstest"), i + 1 < cliArgs.count {
    let src = URL(fileURLWithPath: cliArgs[i + 1])
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("sfcast-compresstest-\(UUID().uuidString)")
    let kbps = AppSettings.load().videoBitrateKbps
    do { try FileManager.default.copyItem(at: src, to: tmp) } catch {
        print("COMPRESSTEST_FAIL no pude copiar: \(error.localizedDescription)"); exit(1)
    }
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        let (before, after) = await Transcoder.compressSegments(in: tmp, bitrateKbps: kbps)
        print("COMPRESSTEST before=\(before) after=\(after) dir=\(tmp.path)")
        sem.signal()
    }
    sem.wait()
    exit(0)
}

/// QA del pill de grabación (`--paneltest N`): lo muestra N segundos SIN grabar
/// nada. Existe porque el pill lleva `sharingType = .none` y por diseño es
/// invisible para cualquier captura — sin este modo no hay forma de revisar el
/// diseño con un screenshot. En este modo (y SOLO en este) el pill se deja
/// capturable.
let panelTestSeconds: Int? = {
    guard let i = cliArgs.firstIndex(of: "--paneltest") else { return nil }
    return (i + 1 < cliArgs.count ? Int(cliArgs[i + 1]) : nil) ?? 8
}()
let panelTestMode = panelTestSeconds != nil

/// Selftest headless: graba N segundos de pantalla (sin burbuja, sin mic, sin
/// upload) y verifica que el MP4 exista con peso real. Prueba el motor completo
/// SCStream→SCRecordingOutput sin depender de prompts (usa permisos ya dados).
@MainActor
func runSelftest(seconds: Int) async {
    Log.info("SELFTEST: motor de captura, \(seconds)s, sin burbuja/mic/upload")
    let engine = CaptureEngine()
    var s = AppSettings.load()
    s.micEnabled = false
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("sfcast-selftest-\(makeVideoID())")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    engine.sessionDir = dir
    engine.settings = s
    engine.reset()
    do {
        try await engine.startSegment(target: .display)
        try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
        await engine.stopSegment()
        guard let url = engine.segmentURLs.first else {
            print("SELFTEST_FAIL sin-segmento"); exit(1)
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        try? FileManager.default.removeItem(at: dir)
        if size > 100_000 {
            Log.info("SELFTEST OK: \(url.lastPathComponent) = \(size) bytes")
            print("SELFTEST_OK bytes=\(size)")
            exit(0)
        }
        Log.error("SELFTEST FALLÓ: MP4 de \(size) bytes")
        print("SELFTEST_FAIL bytes=\(size)")
        exit(1)
    } catch {
        Log.error("SELFTEST FALLÓ: \(error.localizedDescription)")
        print("SELFTEST_FAIL \(error.localizedDescription)")
        exit(1)
    }
}

/// QA visual del pill: lo muestra N segundos, sin grabar ni tocar permisos.
@MainActor
func runPanelTest(seconds: Int) async {
    guard let screen = RecordingController.captureScreen() else { exit(2) }
    let panel = RecordingController.shared.panel
    panel.show(on: screen)
    print("PANELTEST: pill visible \(seconds)s en \(panel.panel?.frame ?? .zero)")
    try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
    panel.hide()
    print("PANELTEST_OK")
    exit(0)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let statusBar = StatusBar()
    let demo: Int?
    let noUpload: Bool
    let selftest: Int?
    let paneltest: Int?

    init(demo: Int?, noUpload: Bool, selftest: Int?, paneltest: Int?) {
        self.demo = demo
        self.noUpload = noUpload
        self.selftest = selftest
        self.paneltest = paneltest
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBar.setup()
        Log.info("SFCast arriba (demo=\(demo.map(String.init) ?? "no") selftest=\(selftest.map(String.init) ?? "no"))")
        if cliArgs.contains("--glowtest") {
            Task { @MainActor in await StudioController.shared.runGlowTest() }
        } else if let seconds = studioBenchSeconds {
            Task { @MainActor in await StudioController.shared.runBench(seconds: seconds) }
        } else if let seconds = studioTestSeconds {
            Task { @MainActor in await StudioController.shared.runTest(seconds: seconds) }
        } else if let seconds = paneltest {
            Task { @MainActor in await runPanelTest(seconds: seconds) }
        } else if let seconds = selftest {
            Task { @MainActor in await runSelftest(seconds: seconds) }
        } else if let seconds = demo {
            Task { @MainActor in
                await DemoChoreography.run(totalSeconds: seconds, noUpload: noUpload)
            }
        } else if Permissions.cameraGranted && Permissions.micGranted {
            // Permisos listos → la cara de la app es el MICROPANEL (estilo Loom,
            // Daniel 15 jul): minimalista, con preview de cámara y vúmetro. El
            // hub queda para ajustes/historial/permisos.
            LauncherPanelController.shared.show(relativeTo: statusBar.button)
        } else {
            // Falta algún permiso → hub con la tarjeta de permisos + prompts
            // serializados via broker (con la app activa para que el diálogo
            // salga en la pantalla activa). El respiro deja que WindowServer se
            // asiente tras el lanzamiento (pedir en el instante exacto del
            // arranque hacía que el diálogo no compositara).
            HubWindowController.shared.show()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_400_000_000)
                await PermissionBroker.shared.ensureCameraAndMic()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        HubWindowController.shared.show()
        return true
    }
}

// main.swift corre en el hilo principal: asumimos MainActor explícitamente.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    // Menú principal mínimo: Cmd+W cierra el hub, Cmd+Q sale — necesario porque
    // la app alterna a .regular (Dock) mientras el hub está abierto.
    let mainMenu = NSMenu()
    let appItem = NSMenuItem()
    mainMenu.addItem(appItem)
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "Cerrar ventana", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Salir de SFCast", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu
    app.mainMenu = mainMenu

    let appDelegate = AppDelegate(demo: demoSeconds, noUpload: demoNoUpload,
                                  selftest: selftestSeconds, paneltest: panelTestSeconds)
    app.delegate = appDelegate
    // retain del delegate (app.delegate es weak)
    objc_setAssociatedObject(app, "sfcastDelegate", appDelegate, .OBJC_ASSOCIATION_RETAIN)
    app.run()
}
