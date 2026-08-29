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

/// QA DEL ESPEJO (`--mirrortest N`): prende el espejo sobre la config REAL y
/// mide lo que no se puede suponer — que el panel NO se cuela en la captura
/// (si se colara, la cara saldría duplicada en el video), que cae donde el
/// programa dice, que el arrastre mueve el rect de escena y persiste, y cuánto
/// cuesta en fps. Ver `StudioController.runMirrorTest`.
let mirrorTestSeconds: Int? = {
    guard let i = cliArgs.firstIndex(of: "--mirrortest") else { return nil }
    return (i + 1 < cliArgs.count ? Int(cliArgs[i + 1]) : nil) ?? 6
}()

/// QA VISUAL del espejo (`--mirrorlook N`): lo muestra N segundos CAPTURABLE
/// (y solo en este modo) para poder revisar el diseño con un screenshot,
/// paseándolo por los cuatro tamaños del Loom. Sin esto no hay forma de MIRAR
/// el espejo: por diseño es invisible a cualquier captura.
let mirrorLookSeconds: Int? = {
    guard let i = cliArgs.firstIndex(of: "--mirrorlook") else { return nil }
    return (i + 1 < cliArgs.count ? Int(cliArgs[i + 1]) : nil) ?? 12
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

/// QA VISUAL del contador de marcas (`--hudlook N`): lo muestra N segundos y
/// CAPTURABLE (solo en este modo), subiendo los contadores, para poder revisar
/// el diseño con un screenshot. Sin esto no hay forma de mirarlo: por diseño es
/// invisible a cualquier captura.
let hudLookSeconds: Int? = {
    guard let i = cliArgs.firstIndex(of: "--hudlook") else { return nil }
    return (i + 1 < cliArgs.count ? Int(cliArgs[i + 1]) : nil) ?? 10
}()

/// QA DEL ARCHIVO (`--rectest N [--chokems M]`): graba de verdad y verifica el
/// MP4 — pistas alineadas, cadencia, y nada perdido en silencio.
let recTestSeconds: Int? = {
    guard let i = cliArgs.firstIndex(of: "--rectest") else { return nil }
    return (i + 1 < cliArgs.count ? Int(cliArgs[i + 1]) : nil) ?? 12
}()

/// `--permisos`: imprime el estado de TCC de ESTE bundle y sale. Existe porque
/// el 26 ago hizo falta saber si un permiso seguía vivo con la pantalla
/// bloqueada —cuando ninguna captura de prueba puede responderlo— y no había
/// forma de preguntárselo a la app sin abrirla y ponerse a grabar.
let soloPermisos = cliArgs.contains("--permisos")

/// QA DEL VIGÍA DE MAIN (`--bloqueamain N`): congela main a propósito.
let bloqueaMainSeconds: Int? = {
    guard let i = cliArgs.firstIndex(of: "--bloqueamain") else { return nil }
    return (i + 1 < cliArgs.count ? Int(cliArgs[i + 1]) : nil) ?? 8
}()

/// QA DE TOMAS ENCADENADAS (`--tomas N [--dura S] [--pausa S]`): graba N veces
/// seguidas con pausas entre medias y le pregunta a CADA archivo si arrancó
/// limpio. Existe porque las dos rondas de rendimiento anteriores probaron UNA
/// toma, y el bug del 26 ago solo aparecía de la segunda en adelante.
let tomasCount: Int? = {
    guard let i = cliArgs.firstIndex(of: "--tomas") else { return nil }
    return (i + 1 < cliArgs.count ? Int(cliArgs[i + 1]) : nil) ?? 6
}()
let tomasDura: Int = {
    guard let i = cliArgs.firstIndex(of: "--dura"), i + 1 < cliArgs.count else { return 8 }
    return Int(cliArgs[i + 1]) ?? 8
}()
let tomasPausa: Int = {
    guard let i = cliArgs.firstIndex(of: "--pausa"), i + 1 < cliArgs.count else { return 0 }
    return Int(cliArgs[i + 1]) ?? 0
}()

/// QA DE SINCRONÍA (`--synctest N`): mide la latencia real de cámara, pantalla
/// y mic contra el reloj del host. Es el número que decide cuánto compensa el
/// `ProgramClock` — y el que no se pudo sacar del archivo por correlación.
let syncTestSeconds: Int? = {
    guard let i = cliArgs.firstIndex(of: "--synctest") else { return nil }
    return (i + 1 < cliArgs.count ? Int(cliArgs[i + 1]) : nil) ?? 10
}()

/// QA DE COSTO DEL COMPOSITOR (`--compbench [N]`): headless, sin TCC, sin
/// grabar. Mide cuántos ms cuesta componer UN frame en esta Mac a cada tamaño
/// de lienzo, con las escenas reales. Es el número que decide el default del
/// lienzo: hasta hoy se elegía "nativa" sin saber que el presupuesto son 33 ms.
/// SOAK (`--soak <minutos>`): resistencia headless con la escena compuesta real.
/// No depende de TCC, así que puede correr donde el permiso de pantalla no está.
if let i = cliArgs.firstIndex(of: "--soak") {
    let mins = (i + 1 < cliArgs.count ? Int(cliArgs[i + 1]) : nil) ?? 30
    StudioCompBench.soak(minutes: mins)
    exit(0)
}

if cliArgs.contains("--compbench") {
    let i = cliArgs.firstIndex(of: "--compbench")!
    let n = (i + 1 < cliArgs.count ? Int(cliArgs[i + 1]) : nil) ?? 90
    StudioCompBench.run(iterations: n)
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

    func applicationWillFinishLaunching(_ notification: Notification) {
        // URL scheme sfcast:// — la puerta programática (Modo Rodaje / F4 del
        // Logi). Se registra en WILL: si LaunchServices arranca la app por la
        // URL, el evento llega antes de DidFinish.
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL))
    }

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor,
                                      withReplyEvent reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: s), url.scheme == "sfcast" else { return }
        switch url.host {
        case "rodaje", "studio":
            // El Estudio al frente, en el monitor de rodaje. NO a pantalla
            // completa: eso lo decide Daniel, no la tecla.
            //
            // SIN FORZAR NADA DEL LAYOUT (Daniel, 25 ago): antes esto abria
            // `showSetPanel = true` a la brava, y como ese @Published PERSISTE
            // en su didSet, la tecla no solo cambiaba la vista de esta sesion
            // — le pisaba la preferencia guardada. F4 debe devolverle el
            // Estudio TAL COMO LO DEJO (escena activa, paneles, anchos); los
            // ajustes de camara ya los guarda la camara misma.
            Task { @MainActor in
                StudioController.shared.open()
                StudioController.shared.colocarParaRodaje()
            }
        default:
            Log.info("URL sfcast:// sin verbo conocido: \(s)")
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBar.setup()
        // Una marca de rodaje huérfana (sesión anterior muerta a lo bruto) dejaría
        // a El Set sin recargarse nunca. Al arrancar no se está grabando: se limpia.
        MarcaDeRodaje.limpiarAlArrancar()
        Log.info("SFCast arriba (demo=\(demo.map(String.init) ?? "no") selftest=\(selftest.map(String.init) ?? "no"))")
        if cliArgs.contains("--glowtest") {
            Task { @MainActor in await StudioController.shared.runGlowTest() }
        } else if let seconds = mirrorLookSeconds {
            Task { @MainActor in await StudioController.shared.runMirrorLook(seconds: seconds) }
        } else if let seconds = mirrorTestSeconds {
            Task { @MainActor in await StudioController.shared.runMirrorTest(seconds: seconds) }
        } else if let seconds = hudLookSeconds {
            Task { @MainActor in
                let hud = MarkerHUD()
                hud.show()
                var c = 0, b = 0
                for i in 0..<seconds {
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    if i % 3 == 2 { b += 1; hud.update(cortes: c, buenos: b, pulso: "bueno") }
                    else { c += 1; hud.update(cortes: c, buenos: b, pulso: "retoma") }
                }
                hud.snapshot(to: "/tmp/sfcast-hud.png")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                hud.hide()
                exit(0)
            }
        } else if soloPermisos {
            let pantalla = Permissions.screenGranted
            let linea = "PERMISOS pantalla=\(pantalla ? "SI" : "NO") "
                + "camara=\(Permissions.cameraGranted ? "SI" : "NO") "
                + "mic=\(Permissions.micGranted ? "SI" : "NO") "
                + "sesionBloqueada=\(ScreenDoctor.sesionBloqueada() ? "SI" : "NO")"
            Log.info(linea)
            print(linea)
            exit(pantalla ? 0 : 1)
        } else if let n = bloqueaMainSeconds {
            // QA DEL VIGÍA (`--bloqueamain N`): bloquea el hilo principal N
            // segundos a propósito. Es la única forma de comprobar que MainWatch
            // habla cuando el resto de los sensores se han quedado mudos — que es
            // exactamente lo que pasó el 26 ago y no dejó rastro.
            Task { @MainActor in
                StudioController.shared.open()
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                Log.info("QA: bloqueando main \(n)s a propósito…")
                Thread.sleep(forTimeInterval: Double(n))
                Log.info("QA: main liberado")
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                exit(0)
            }
        } else if let n = tomasCount {
            Task { @MainActor in
                await StudioController.shared.runTomasTest(tomas: n, dura: tomasDura, pausa: tomasPausa)
            }
        } else if let seconds = recTestSeconds {
            Task { @MainActor in await StudioController.shared.runRecTest(seconds: seconds) }
        } else if let seconds = syncTestSeconds {
            Task { @MainActor in await StudioController.shared.runSyncTest(seconds: seconds) }
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
            // Permisos listos → la cara de la app es el ESTUDIO (Daniel 6 ago:
            // ahí es donde graba de verdad). El modo Loom sigue a un clic
            // ("Modo Loom" dentro del Estudio, o el menú de la barra).
            StudioController.shared.open()
            // Doctor de pantalla (8 ago): mide el permiso EFECTIVO y se
            // auto-repara (reset + prompt + reabrir con un clic). El respiro
            // deja que el Estudio arranque y WindowServer se asiente.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                await ScreenDoctor.checkAndRepair(razon: "arranque")
            }
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
                // Doctor de pantalla DESPUÉS del broker (los prompts de TCC se
                // serializan: pedir pantalla con cámara/mic pendientes atora a
                // tccd — el cuelgue del 14 jul).
                await ScreenDoctor.checkAndRepair(razon: "arranque (hub)")
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        // Reabrir (clic al Dock) = el Estudio, igual que el arranque. Excepto
        // con el Loom GRABANDO: abrir el Estudio escondería la burbuja (que va
        // quemada en la captura) y pelearía la cámara — ahí, el hub.
        if RecordingController.shared.state == .idle {
            StudioController.shared.open()
        } else {
            HubWindowController.shared.show()
        }
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
