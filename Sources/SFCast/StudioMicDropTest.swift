import Foundation
import AVFoundation

/// QA DE LA CAÍDA DEL MIC (`--micdrop S [--dura D]`, v4.1 — 7 sep 2026).
///
/// **Por qué existe.** El 7 sep el Shure MV7+ se cayó del bus USB al minuto
/// 46.4 de una toma de 47 (`AppleUSBHostPort::terminateDevice … hardware
/// connection lost`, y volvió 11 ms después). Como mic y cámara comparten una
/// sola `AVCaptureSession`, AVFoundation cerró `camera.mov` con "Recording
/// Stopped" y el micrófono quedó mudo. La app SABÍA —watchdog, guard de voz,
/// notificación— pero se negaba a re-pegar "con una toma en curso", y Daniel
/// tuvo que parar la grabación.
///
/// Todos los arneses anteriores prueban fuentes que no se mueren. Éste mata el
/// mic a propósito a media toma y exige que la toma SIGA: mic de vuelta solo,
/// raw de cámara continuando en `camera-002.mov`, y el hueco anotado en el
/// manifest (zona muerta de `mic` + dos tramos de cámara con su offset).
///
/// Regla del 25 jul, textual en este repo: *"un mecanismo que nunca se disparó
/// no es un fix, es una intención"*.
@MainActor
enum StudioMicDropTest {

    static func run(dropAt: Int, dura: Int, engine: StudioEngine, recorder: StudioRecorder,
                    config: StudioConfig, scene: StudioScene?) async {
        Log.info("MICDROP — toma de \(dura)s; el mic se cae en el segundo \(dropAt)")
        guard engine.cameraAvailable else {
            Log.error("MICDROP_FAIL sin cámara (la sesión compartida es el sujeto del test)")
            print("MICDROP_FAIL sin cámara"); exit(3)
        }
        var cfg = config
        cfg.micEnabled = true
        cfg.outputs.rawCamera = true
        cfg.outputs.rawScreen = engine.screenAvailable
        guard engine.levels.fresh().mic else {
            Log.error("MICDROP_FAIL el micrófono no entrega audio ANTES de empezar: no hay nada que tirar")
            print("MICDROP_FAIL mic mudo al arrancar"); exit(3)
        }

        do {
            try recorder.start(engine: engine, config: cfg, activeScene: scene)
            StudioController.shared.isRecording = true
        } catch {
            Log.error("MICDROP_FAIL start: \(error.localizedDescription)")
            print("MICDROP_FAIL start"); exit(1)
        }
        try? await Task.sleep(nanoseconds: UInt64(dropAt) * 1_000_000_000)
        let tramosAntes = engine.camRawTramos.count
        engine.simularCaidaDelMic()

        // Lo que tiene que pasar solo: MUDO a los ~5 s, re-pegado (≤5 s más),
        // tramo nuevo en cuanto el audio vuelva a entrar.
        //
        // La simulación corre en `sessionQueue` y los buffers ya en vuelo
        // siguen llegando unos cientos de ms: "¿murió?" se pregunta comparando
        // dos lecturas DESPUÉS del corte (1.5 s y 3 s), no contra el instante
        // en que se pidió. La primera versión de este arnés comparó contra el
        // instante y dio un rojo falso con el mecanismo funcionando.
        var fallos: [String] = []
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let llegadas15 = engine.levels.micArrivals()
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let llegadasCaido = engine.levels.micArrivals()
        if llegadasCaido != llegadas15 {
            fallos.append("el mic siguió entregando tras quitar el input (la simulación no mató nada)")
        }
        let deadline = Date().addingTimeInterval(Double(dura - dropAt - 4))
        var revivio = false, reabrio = false
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if !revivio, engine.levels.micArrivals() > llegadasCaido + 5 {
                revivio = true
                Log.info("MICDROP: el mic volvió a entregar solo")
            }
            if !reabrio, engine.camRawTramos.count > tramosAntes {
                reabrio = true
                Log.info("MICDROP: el raw de cámara se reabrió en \(engine.camRawTramos.last?.file ?? "?")")
            }
            if revivio, reabrio { break }
        }
        // Se deja correr un rato con el tramo nuevo abierto, para que tenga cuerpo.
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        if !revivio { fallos.append("el micrófono NO volvió solo") }
        if !reabrio { fallos.append("el raw de cámara NO se reabrió") }

        StudioController.shared.isRecording = false
        var dirOpt = await recorder.stop(engine: engine, config: cfg)
        if dirOpt == nil, let ultima = recorder.lastDir {
            Log.info("MICDROP: la toma la detuvo un guard"
                     + (recorder.lastAutoStopReason.map { " (\($0))" } ?? ""))
            dirOpt = ultima
        }
        guard let dir = dirOpt else {
            Log.error("MICDROP_FAIL la toma no dejó carpeta")
            print("MICDROP_FAIL sin carpeta"); exit(1)
        }

        // AL ARCHIVO, no al recorder: el manifest y los tramos son lo que la
        // edición va a leer.
        let mURL = dir.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: mURL),
              let m = try? JSONDecoder().decode(StudioManifest.self, from: data) else {
            Log.error("MICDROP_FAIL no pude leer manifest.json")
            print("MICDROP_FAIL manifest"); exit(1)
        }
        let cams = m.outputs.filter { $0.role == "camera" }
        Log.info("MICDROP: manifest → \(cams.count) tramo(s) de cámara: "
                 + cams.map { "\($0.file) seg=\($0.segment ?? 0) dur=\(String(format: "%.1f", $0.durationSeconds ?? 0)) "
                              + "off=\($0.startOffsetSeconds.map { String(format: "%+.2f", $0) } ?? "nil")"
                              + "/\($0.startOffsetMethod ?? "-") fin=\($0.endedBy ?? "-")" }
                       .joined(separator: " · ")
                 + " · origen=\(m.timeOrigin ?? "nil")")
        // EXACTAMENTE dos: uno que murió y uno que cerró el stop. Tres significa
        // que se reabrió antes de tiempo (sin audio conectado) y ese tramo murió
        // también — un archivo de 0.3 s que parece cámara y no sirve.
        if cams.count != 2 { fallos.append("el manifest trae \(cams.count) tramo(s) de cámara, esperaba exactamente 2") }
        if let primero = cams.first, primero.endedBy?.hasPrefix("murió") != true {
            fallos.append("el primer tramo no dice que murió (endedBy=\(primero.endedBy ?? "nil"))")
        }
        if let ultimo = cams.last, cams.count >= 2 {
            if ultimo.endedBy != "stop" { fallos.append("el último tramo no lo cerró el stop (\(ultimo.endedBy ?? "nil"))") }
            if (ultimo.durationSeconds ?? 0) < 2 { fallos.append("\(ultimo.file) dura \(String(format: "%.2f", ultimo.durationSeconds ?? 0))s") }
            if ultimo.startOffsetSeconds == nil { fallos.append("camera-002.mov sin startOffsetSeconds") }
            let url = dir.appendingPathComponent(ultimo.file)
            let asset = AVURLAsset(url: url)
            let audio = (try? await asset.loadTracks(withMediaType: .audio))?.first
            if audio == nil { fallos.append("\(ultimo.file) no trae pista de audio (el mic no estaba al reabrir)") }
        }
        let zonasMic = m.deadZones.filter { $0.source == "mic" }
        Log.info("MICDROP: zonas muertas de mic → "
                 + zonasMic.map { String(format: "%.1f→%.1f", $0.from, $0.to) }.joined(separator: ", "))
        if zonasMic.isEmpty { fallos.append("el manifest no anota la zona muerta del mic") }
        if let z = zonasMic.first, z.to - z.from > 15 { fallos.append(String(format: "el mic tardó %.1fs en volver", z.to - z.from)) }

        if fallos.isEmpty {
            Log.info("MICDROP_OK — la toma sobrevivió a la caída del micrófono (\(dir.lastPathComponent))")
            print("MICDROP_OK \(dir.lastPathComponent)")
            exit(0)
        }
        for f in fallos { Log.error("MICDROP_FAIL — \(f)") }
        print("MICDROP_FAIL \(fallos.count) problema(s) — \(dir.lastPathComponent)")
        exit(2)
    }
}
