/// PANEL CÁMARA — control de la Sony ZV-E10 sin salir del Estudio.
///
/// Por qué está aquí: durante una toma, cambiar de ventana para corregir el ISO
/// no es una opción. El control vive donde se graba.
///
/// Cómo habla con la cámara: llamando al CLI `sfcam` (repo `sfcam`, control por
/// PTP sobre libgphoto2). NO se duplica el motor aquí — ese motor tiene su
/// propia batería de pruebas contra la cámara real, y dos copias del mismo
/// protocolo se separan en cuanto una se toca.
///
/// ⚠️ CADA LECTURA LE APAGA LA IMAGEN A LA CÁMARA 1-4 SEGUNDOS. Está medido: la
/// ZV-E10 corta su live view mientras atiende el USB. Por eso este panel NO
/// consulta solo: lee al abrirse una vez, al escribir, y cuando se pulsa ↻.
/// Si se te ocurre poner un temporizador aquí, no lo hagas — ya se probó y es
/// exactamente lo que hacía parpadear la grabación.

import SwiftUI

// MARK: - puente al CLI

enum SFCam {
    /// Dónde puede estar el binario. El enlace de `~/.local/bin` es el normal.
    static let rutas = [
        NSHomeDirectory() + "/.local/bin/sfcam",
        NSHomeDirectory() + "/Developer/software/sfcam/dist/sfcam",
        "/usr/local/bin/sfcam",
    ]

    static var ruta: String? { rutas.first { FileManager.default.isExecutableFile(atPath: $0) } }
    static var disponible: Bool { ruta != nil }

    struct Prop {
        let clave: String
        let etiqueta: String
        let valor: String
        let opciones: [String]
        let editable: Bool
    }

    /// Las que se tocan en un rodaje. En ese orden.
    static let interesan = ["iso", "shutter", "aperture", "wb"]

    static func leer() -> (props: [Prop], temperatura: String?, error: String?) {
        guard let exe = ruta else { return ([], nil, "sfcam no está instalado") }
        let salida = correr(exe, ["status", "--json"], timeout: 60)
        guard let data = salida.data(using: .utf8),
              let raiz = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let vals = raiz["values"] as? [String: [String: Any]]
        else { return ([], nil, "la cámara no respondió") }
        if (raiz["connected"] as? Bool) != true {
            return ([], nil, (raiz["error"] as? String) ?? "cámara no conectada")
        }

        var props: [Prop] = []
        for clave in interesan {
            guard let v = vals[clave] else { continue }
            props.append(Prop(
                clave: clave,
                etiqueta: (v["label"] as? String) ?? clave,
                valor: (v["value"] as? String) ?? "?",
                opciones: (v["choices"] as? [String]) ?? [],
                editable: !((v["readonly"] as? Bool) ?? true)
            ))
        }
        let temp = (vals["temp_cam"]?["value"] as? String)
        return (props, temp, nil)
    }

    /// Devuelve nil si salió bien, o el motivo del fallo.
    static func escribir(_ clave: String, _ valor: String) -> String? {
        guard let exe = ruta else { return "sfcam no está instalado" }
        let salida = correr(exe, ["set", clave, valor], timeout: 120)
        return salida.contains("✓") ? nil : salida.split(separator: "\n").last.map(String.init)
    }

    private static func correr(_ exe: String, _ args: [String], timeout: TimeInterval) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return "no se pudo ejecutar sfcam" }

        var datos = Data()
        let g = DispatchGroup()
        g.enter()
        DispatchQueue.global().async {
            datos = pipe.fileHandleForReading.readDataToEndOfFile(); g.leave()
        }
        let limite = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < limite { Thread.sleep(forTimeInterval: 0.05) }
        if p.isRunning { p.terminate() }
        _ = g.wait(timeout: .now() + 5)
        return String(data: datos, encoding: .utf8) ?? ""
    }
}

// MARK: - el panel

@MainActor
final class CameraPanelModel: ObservableObject {
    @Published var props: [SFCam.Prop] = []
    @Published var temperatura: String?
    @Published var mensaje: String?
    @Published var ocupado = false
    @Published var leidoHace: Date?

    private let cola = DispatchQueue(label: "sfcast.camara")

    func leer() {
        guard !ocupado else { return }
        ocupado = true
        mensaje = nil
        cola.async {
            let r = SFCam.leer()
            DispatchQueue.main.async {
                self.ocupado = false
                if let e = r.error { self.mensaje = e }
                else {
                    self.props = r.props
                    self.temperatura = r.temperatura
                    self.leidoHace = Date()
                }
            }
        }
    }

    func escribir(_ clave: String, _ valor: String) {
        guard !ocupado else { return }
        ocupado = true
        mensaje = nil
        cola.async {
            let err = SFCam.escribir(clave, valor)
            let r = SFCam.leer()
            DispatchQueue.main.async {
                self.ocupado = false
                self.mensaje = err
                if r.error == nil {
                    self.props = r.props
                    self.temperatura = r.temperatura
                    self.leidoHace = Date()
                }
            }
        }
    }
}

struct CameraPanel: View {
    @StateObject private var m = CameraPanelModel()

    var body: some View {
        PanelBox(title: "Cámara") {
            if !SFCam.disponible {
                Text("sfcam no está instalado")
                    .font(.system(size: 11)).foregroundStyle(StudioSkin.dim)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(m.props, id: \.clave) { p in fila(p) }

                    if m.props.isEmpty && !m.ocupado {
                        Text(m.mensaje ?? "Pulsa ↻ para leer la cámara.\nLeerla le apaga la imagen un segundo, así que no se hace sola.")
                            .font(.system(size: 11)).foregroundStyle(StudioSkin.dim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let t = m.temperatura, t != "Normal" {
                        Text("⚠ cámara \(t.lowercased())")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.orange)
                    }
                    if let msg = m.mensaje, !m.props.isEmpty {
                        Text(msg).font(.system(size: 9)).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)

                    HStack(spacing: 6) {
                        if m.ocupado {
                            ProgressView().scaleEffect(0.4).frame(width: 12, height: 12)
                            Text("leyendo — la imagen parpadea")
                                .font(.system(size: 9)).foregroundStyle(StudioSkin.dim)
                        } else {
                            Button(action: { m.leer() }) {
                                Image(systemName: "arrow.clockwise").font(.system(size: 10))
                            }
                            .buttonStyle(.plain).foregroundStyle(StudioSkin.dim)
                            .help("Leer la cámara (le apaga la imagen un segundo)")
                            Text(antiguedad).font(.system(size: 9)).foregroundStyle(StudioSkin.dim)
                        }
                    }
                }
            }
        }
        // NO se lee al abrir. Cada lectura le apaga la imagen a la camara 1-4
        // segundos, y este panel vive en la ventana donde se GRABA: abrir el
        // Estudio no puede costar un parpadeo. Se lee cuando se pulsa ↻.
    }

    private var antiguedad: String {
        guard let t = m.leidoHace else { return "sin leer" }
        let s = Int(Date().timeIntervalSince(t))
        return s < 60 ? "hace \(max(s, 1))s" : "hace \(s / 60) min"
    }

    @ViewBuilder
    private func fila(_ p: SFCam.Prop) -> some View {
        HStack(spacing: 6) {
            Text(p.etiqueta)
                .font(.system(size: 11)).foregroundStyle(StudioSkin.dim)
                .lineLimit(1)
            Spacer(minLength: 4)
            if p.editable && !p.opciones.isEmpty {
                Menu {
                    ForEach(p.opciones, id: \.self) { op in
                        Button(op) { m.escribir(p.clave, op) }
                    }
                } label: {
                    Text(p.valor)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(m.ocupado)
            } else {
                Text(p.valor)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(StudioSkin.dim)
            }
        }
    }
}
