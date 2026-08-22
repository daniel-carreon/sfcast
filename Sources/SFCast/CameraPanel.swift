/// PANEL CÁMARA — la Sony ZV-E10 se opera DENTRO del Estudio.
///
/// Por qué vive aquí y no en una app aparte: SFCast ya tiene la vista de la
/// cámara, ya es donde se graba, y durante una toma cambiar de ventana para
/// corregir el ISO no es una opción. Una superficie menos que atender.
///
/// Cómo habla con la cámara: llamando al CLI `sfcam` (repo `sfcam`, control por
/// PTP sobre libgphoto2). NO se duplica el motor aquí — ese motor tiene su
/// propia batería de pruebas contra la cámara real, y dos copias del mismo
/// protocolo se separan en cuanto una se toca.
///
/// ⚠️ DOS COSAS MEDIDAS QUE MANDAN EN TODO ESTE ARCHIVO
///
/// 1. **Cada lectura le apaga la imagen a la cámara 1-4 segundos.** La ZV-E10
///    corta su live view mientras atiende el USB. Por eso este panel abre desde
///    el ESPEJO en disco (`sfcam espejo`: instantáneo, cero PTP) y solo toca la
///    cámara cuando alguien lo pide. Si se te ocurre poner un temporizador
///    aquí, no lo hagas — ya se probó y es exactamente lo que hacía parpadear
///    la grabación (11 negros por minuto y medio).
///
/// 2. **Un dato viejo con aspecto de fresco es peor que no tenerlo.** Mientras
///    no se confirme con la cámara, los valores van atenuados, con su
///    antigüedad a la vista y el botón ↻ en ámbar pidiendo que lo pulsen.

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

    struct Prop: Identifiable {
        let clave: String
        let etiqueta: String
        let valor: String
        let opciones: [String]
        let grupo: String
        let editable: Bool
        /// Su valor es un CÓDIGO que nadie tradujo. Se muestra aparte y
        /// avisando: bautizar un código con un nombre inventado es fabricar
        /// un dato, y aquí se toman decisiones con lo que dice la pantalla.
        let crudo: Bool
        var id: String { clave }
    }

    struct Estado {
        var props: [Prop] = []
        var modelo: String?
        var leidoEn: Date?
        /// false = viene del espejo en disco, aún sin confirmar con la cámara.
        var fresco = false
        var conectada = false
        var error: String?

        func valor(_ clave: String) -> String? { props.first { $0.clave == clave }?.valor }
        /// Las de un grupo, ya traducidas. Fuera batería y modelo (van en su
        /// propio sitio) y fuera las de código crudo (van al final, aparte).
        func grupo(_ g: String) -> [Prop] {
            props.filter { $0.grupo == g && !$0.crudo
                        && $0.clave != "battery" && $0.clave != "model" }
        }
        var sinTraducir: [Prop] { props.filter(\.crudo) }

        /// CANDADO: lo que no cayó en ningún grupo conocido.
        ///
        /// Los nombres de grupo viajan como TEXTO desde el otro repo. Cuando allá
        /// les pusieron acento y aquí no, EXPOSICIÓN y PELÍCULA se esfumaron del
        /// panel sin un solo error — nueve controles desaparecidos y la pantalla
        /// tan campante. Ahora lo que no encaje aparece igual, aparte y rotulado:
        /// una propiedad puede salir en la sección equivocada, pero JAMÁS puede
        /// desaparecer sin que se note.
        var huerfanas: [Prop] {
            props.filter { !SFCam.grupos.contains($0.grupo) && !$0.crudo
                        && $0.clave != "battery" && $0.clave != "model" }
        }
    }

    /// Los grupos, en el orden en que se miran en un rodaje.
    ///
    /// ⚠️ SON LOS NOMBRES EXACTOS que manda el CLI (`CamProp.Group` en el repo
    /// `sfcam`). Se comparan como texto: al ponerles acento allá y no aquí,
    /// EXPOSICIÓN y PELÍCULA desaparecieron del panel sin un solo error —
    /// simplemente ningún grupo coincidía. Si se tocan allá, se tocan aquí.
    static let grupos = ["Exposición", "Color", "Enfoque", "Película", "Estado"]

    /// Lo que de verdad cambia mientras se graba. El refresco corto pide solo
    /// esto: 19 propiedades son tres sesiones PTP, o sea tres parpadeos más.
    static let ligeras = ["iso", "shutter", "aperture", "meter", "wb",
                          "focusmode", "focusarea", "formato",
                          "battery", "temp_cam", "grabando"]

    /// El espejo en disco. Instantáneo, cero PTP, cero parpadeo.
    static func leerEspejo() -> Estado { parsear(correr(["espejo"], timeout: 10)) }

    /// La cámara de verdad. `completo: false` pide solo las de rodaje.
    static func leerCamara(completo: Bool) -> Estado {
        var args = ["status", "--json"]
        if !completo { args += ["--keys", ligeras.joined(separator: ",")] }
        return parsear(correr(args, timeout: 90))
    }

    /// Devuelve nil si salió bien, o el motivo del fallo.
    static func escribir(_ clave: String, _ valor: String) -> String? {
        let salida = correr(["set", clave, valor], timeout: 150)
        if salida.contains("✓") || salida.contains("ya estaba en") { return nil }
        return salida.split(separator: "\n").last.map(String.init) ?? "sfcam no respondió"
    }

    /// El lazo del ISO: mide la cara en la imagen real y corrige hasta dejarla
    /// en rango. Necesita que algo publique la medición en `~/.sfcam/ojo.json`
    /// — lo hace el Estudio (ver `OjoDelEstudio`).
    static func autoISO(_ objetivo: Int = 95) -> String {
        correr(["auto", "\(objetivo)"], timeout: 240)
    }

    // MARK: parseo

    private static func parsear(_ salida: String) -> Estado {
        var e = Estado()
        guard let data = salida.data(using: .utf8),
              let raiz = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { e.error = "sfcam no respondió"; return e }

        e.conectada = (raiz["connected"] as? Bool) ?? false
        e.fresco = (raiz["fresh"] as? Bool) ?? true
        e.modelo = raiz["model"] as? String
        if let t = raiz["at"] as? Double, t > 0 { e.leidoEn = Date(timeIntervalSince1970: t) }
        guard e.conectada, let vals = raiz["values"] as? [String: [String: Any]] else {
            e.error = (raiz["error"] as? String) ?? "cámara no conectada"
            return e
        }
        // El CLI manda el orden del catálogo: se respeta, no se reinventa aquí.
        let orden = (raiz["order"] as? [String]) ?? Array(vals.keys).sorted()
        for clave in orden {
            guard let v = vals[clave] else { continue }
            // El zoom devuelve 4294967295 (0xFFFFFFFF) = el centinela de "no
            // aplica" con un objetivo manual. Enseñar "4294.97" como dato es
            // peor que no enseñar nada.
            if clave == "zoom", let n = Double((v["value"] as? String) ?? ""), n > 4000 { continue }
            let soloLectura = (v["readonly"] as? Bool) ?? true
            let escribible = (v["writable"] as? Bool) ?? false
            e.props.append(Prop(
                clave: clave,
                etiqueta: (v["label"] as? String) ?? clave,
                valor: (v["value"] as? String) ?? "?",
                opciones: (v["choices"] as? [String]) ?? [],
                grupo: (v["group"] as? String) ?? "Estado",
                editable: escribible && !soloLectura,
                crudo: (v["raw"] as? Bool) ?? false
            ))
        }
        return e
    }

    private static func correr(_ args: [String], timeout: TimeInterval) -> String {
        guard let exe = ruta else { return "" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return "" }

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

// MARK: - el modelo

/// UNO solo para las dos superficies (la columna del Estudio y el cajón). Si
/// hubiera dos, cada una leería la cámara por su cuenta y serían dos parpadeos
/// por cada cosa que se mira.
@MainActor
final class CameraPanelModel: ObservableObject {
    static let shared = CameraPanelModel()

    @Published var e = SFCam.Estado()
    @Published var enVuelo: String?          // propiedad que se está escribiendo
    @Published var leyendo = false
    @Published var aviso: String?
    @Published var tareaLarga: String?       // p.ej. el lazo del ISO
    /// Lo que el ojo mide de la imagen REAL. Se publica aquí para que el
    /// sensor sea VISIBLE: un ojo que solo escribe un archivo que nadie mira es
    /// un órgano que puede morirse sin que nadie se entere.
    @Published var ojo: MedicionOjo?
    /// Se re-dibuja sola para que "leído hace Ns" no se congele.
    @Published private var tic = 0

    private let cola = DispatchQueue(label: "sfcast.camara")
    private var reloj: Timer?

    private init() {
        // ABRIR EL ESTUDIO NO LE HABLA A LA CÁMARA: el espejo es de disco.
        cargarEspejo()
        // 1 Hz, y solo este objeto lo observa (el panel de la cámara). El aviso
        // del controlador sobre no publicar rápido va por los 15 Hz del vúmetro,
        // que invalidan la jerarquía ENTERA del Estudio.
        reloj = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.tic &+= 1
                if let at = OjoDelEstudio.ultimaAt, Date().timeIntervalSince(at) < 5 {
                    self.ojo = OjoDelEstudio.ultima
                } else {
                    self.ojo = nil    // el ojo dejó de latir: no se finge que sí
                }
            }
        }
    }

    var ocupado: Bool { leyendo || enVuelo != nil || tareaLarga != nil }

    func cargarEspejo() {
        cola.async {
            let r = SFCam.leerEspejo()
            DispatchQueue.main.async { if r.conectada { self.e = r } }
        }
    }

    func refrescar(completo: Bool = false) {
        guard !ocupado else { return }
        leyendo = true
        aviso = nil
        cola.async {
            var r = SFCam.leerCamara(completo: completo)
            // El bus puede estar ocupado un instante: un solo fallo no es un
            // diagnóstico. Se reintenta una vez antes de dar mala noticia.
            if !r.conectada { Thread.sleep(forTimeInterval: 1.5); r = SFCam.leerCamara(completo: completo) }
            DispatchQueue.main.async {
                self.leyendo = false
                if r.conectada { self.fusionar(r) }
                // Se CONSERVAN los últimos valores buenos: unos números de hace
                // un minuto son más útiles que un panel vacío, y borrarlos era
                // justo lo que hacía parecer muerta a una cámara viva.
                else { self.aviso = r.error }
            }
        }
    }

    func aplicar(_ clave: String, _ valor: String) {
        guard !ocupado else { return }
        enVuelo = clave
        aviso = nil
        cola.async {
            let err = SFCam.escribir(clave, valor)
            // `sfcam set` ya verifica contra la cámara y actualiza el espejo.
            // Releerla aquí sería un parpadeo de más para saber lo que ya sabemos.
            let r = SFCam.leerEspejo()
            DispatchQueue.main.async {
                self.enVuelo = nil
                self.aviso = err
                if r.conectada { self.fusionar(r) }
            }
        }
    }

    /// El lazo que mide la cara y corrige el ISO hasta dejarla en rango.
    func autoISO() {
        guard !ocupado else { return }
        tareaLarga = "midiendo la cara y ajustando el ISO…"
        aviso = nil
        cola.async {
            let salida = SFCam.autoISO(95)
            let r = SFCam.leerEspejo()
            DispatchQueue.main.async {
                self.tareaLarga = nil
                if r.conectada { self.fusionar(r) }
                self.aviso = salida.split(separator: "\n").last.map(String.init)
            }
        }
    }

    /// FUSIONAR, no reemplazar. Un refresco parcial trae 11 propiedades y no
    /// puede borrar las otras 8 que siguen siendo válidas. Este error ya se pagó
    /// dos veces en la app hermana; aquí no se repite.
    private func fusionar(_ nuevo: SFCam.Estado) {
        var props = e.props
        for p in nuevo.props {
            if let i = props.firstIndex(where: { $0.clave == p.clave }) { props[i] = p }
            else { props.append(p) }
        }
        // Mantener el orden del catálogo aunque lleguen en tandas distintas.
        let rango = Dictionary(uniqueKeysWithValues: SFCam.grupos.enumerated().map { ($1, $0) })
        props.sort { (rango[$0.grupo] ?? 9) < (rango[$1.grupo] ?? 9) }
        e = SFCam.Estado(props: props, modelo: nuevo.modelo ?? e.modelo,
                         leidoEn: nuevo.leidoEn ?? e.leidoEn, fresco: nuevo.fresco,
                         conectada: true, error: nil)
    }

    /// Cuánto hace que se leyó la cámara. Si el número es viejo hay que DECIRLO.
    var antiguedad: String {
        guard let t = e.leidoEn else { return "sin leer" }
        let s = Int(Date().timeIntervalSince(t))
        if s < 60 { return "hace \(max(s, 1))s" }
        if s < 3600 { return "hace \(s / 60) min" }
        return "hace \(s / 3600) h"
    }
}

// MARK: - piezas compartidas

/// Una fila: etiqueta a la izquierda, valor (o menú que escribe) a la derecha.
private struct FilaProp: View {
    @ObservedObject var m: CameraPanelModel
    let p: SFCam.Prop
    var compacta = false

    var body: some View {
        HStack(spacing: 6) {
            Text(p.etiqueta)
                .font(.system(size: compacta ? 10.5 : 11))
                .foregroundStyle(StudioSkin.dim)
                .lineLimit(1)
            Spacer(minLength: 4)
            if m.enVuelo == p.clave {
                ProgressView().scaleEffect(0.4).frame(width: 12, height: 12)
            } else if p.editable && !p.opciones.isEmpty {
                Menu {
                    ForEach(p.opciones, id: \.self) { op in
                        Button(op) { m.aplicar(p.clave, op) }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(p.valor)
                            .font(.system(size: compacta ? 10.5 : 11, weight: .medium, design: .monospaced))
                            // Atenuado mientras el dato venga del espejo: un
                            // número viejo con aspecto de fresco hace tomar
                            // decisiones sobre algo que ya cambió.
                            .foregroundStyle(m.e.fresco ? StudioSkin.text : StudioSkin.dim)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 7)).foregroundStyle(StudioSkin.dim.opacity(0.7))
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(m.ocupado)
            } else {
                Text(p.valor)
                    .font(.system(size: compacta ? 10.5 : 11, design: .monospaced))
                    .foregroundStyle(StudioSkin.dim)
                    .lineLimit(1)
            }
        }
    }
}

private struct BarraBateria: View {
    let valor: String
    var body: some View {
        let pct = Double(valor.replacingOccurrences(of: "%", with: "")) ?? 0
        let col: Color = pct > 40 ? Color(red: 0.25, green: 0.85, blue: 0.45)
                       : (pct > 18 ? StudioSkin.mostaza : .red)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("BATERÍA").font(.system(size: 8, weight: .semibold)).tracking(0.8)
                    .foregroundStyle(StudioSkin.dim)
                Spacer()
                Text(valor).font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(col)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.07))
                    Capsule().fill(col).frame(width: max(2, g.size.width * pct / 100))
                }
            }.frame(height: 4)
        }
    }
}

/// Los avisos que sí importan durante una toma: sobrecalentamiento y "grabando"
/// (la cámara rechaza cambios mientras graba en su propia tarjeta).
private struct AvisosCamara: View {
    let e: SFCam.Estado
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let t = e.valor("temp_cam"), t != "Normal", t != "?" {
                etiqueta("⚠ cámara \(t.lowercased())", .red)
            }
            if let g = e.valor("grabando"), g.lowercased().contains("grab") {
                etiqueta("● grabando en la tarjeta", StudioSkin.mostaza)
            }
            if e.valor("formato") == "XAVC S HD" {
                etiqueta("⚠ en HD la cámara sobreimprime su info", StudioSkin.mostaza)
            }
        }
    }
    private func etiqueta(_ s: String, _ c: Color) -> some View {
        Text(s).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(c)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Pie común: frescura del dato + ↻. En ámbar mientras no se confirme.
private struct PieLectura: View {
    @ObservedObject var m: CameraPanelModel
    var completo: Bool

    var body: some View {
        HStack(spacing: 6) {
            if m.leyendo || m.tareaLarga != nil {
                ProgressView().scaleEffect(0.4).frame(width: 12, height: 12)
                Text(m.tareaLarga ?? "leyendo — la imagen parpadea")
                    .font(.system(size: 9)).foregroundStyle(StudioSkin.dim).lineLimit(1)
            } else {
                Button { m.refrescar(completo: completo) } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: m.e.fresco ? .regular : .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(m.e.fresco ? StudioSkin.dim : StudioSkin.mostaza)
                .help(m.e.fresco ? "Leer la cámara (le apaga la imagen un segundo)"
                                 : "Estos valores son de la sesión anterior — pulsa para confirmarlos")
                Text(m.e.fresco ? m.antiguedad : "\(m.antiguedad) · sin confirmar")
                    .font(.system(size: 9))
                    .foregroundStyle(m.e.fresco ? StudioSkin.dim : StudioSkin.mostaza.opacity(0.85))
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - la columna del Estudio (compacta)

/// Lo que se mira de reojo mientras se graba. Todo lo demás vive en el cajón.
struct CameraPanel: View {
    @ObservedObject private var m = CameraPanelModel.shared
    @EnvironmentObject var c: StudioController

    private static let enColumna = ["iso", "shutter", "aperture", "wb", "focusarea", "formato"]

    var body: some View {
        PanelBox(title: "Cámara") {
            if !SFCam.disponible {
                Text("sfcam no está instalado")
                    .font(.system(size: 11)).foregroundStyle(StudioSkin.dim)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(m.e.props.filter { CameraPanel.enColumna.contains($0.clave) }) { p in
                        FilaProp(m: m, p: p, compacta: true)
                    }

                    if m.e.props.isEmpty && !m.leyendo {
                        Text(m.e.error ?? "Pulsa ↻ para leer la cámara.\nLeerla le apaga la imagen un segundo, así que no se hace sola.")
                            .font(.system(size: 10.5)).foregroundStyle(StudioSkin.dim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    AvisosCamara(e: m.e)
                    if let a = m.aviso, !m.e.props.isEmpty {
                        Text(a).font(.system(size: 9)).foregroundStyle(StudioSkin.mostaza)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)

                    HStack(spacing: 8) {
                        PieLectura(m: m, completo: false)
                        Spacer(minLength: 0)
                        Button { c.showCameraPanel = true } label: {
                            Image(systemName: "slider.horizontal.3").font(.system(size: 10))
                        }
                        .buttonStyle(.plain).foregroundStyle(StudioSkin.dim)
                        .help("Todos los controles de la cámara")
                    }
                }
            }
        }
        // NO se lee al abrir: el espejo de disco ya está cargado y cada lectura
        // le cuesta un parpadeo a la imagen que se está grabando.
    }
}

// MARK: - el cajón completo

/// TODO lo que la cámara deja tocar, agrupado como se piensa en un rodaje.
/// Vive al lado de la imagen a propósito: cambiar la exposición sin ver el
/// resultado es adivinar.
struct CameraDrawer: View {
    @ObservedObject private var m = CameraPanelModel.shared
    @EnvironmentObject var c: StudioController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            encabezado
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !m.e.fresco && !m.e.props.isEmpty { bannerEspejo }
                    if let a = m.aviso { aviso(a) }
                    AvisosCamara(e: m.e)

                    if m.e.props.isEmpty {
                        vacio
                    } else {
                        if let b = m.e.valor("battery") { BarraBateria(valor: b) }
                        loQueVe
                        atajos
                        ForEach(SFCam.grupos, id: \.self) { g in seccion(g) }
                        huerfanas
                        sinTraducir
                        nota
                    }
                }
                .padding(12)
            }
        }
        .background(StudioSkin.panel)
    }

    private var encabezado: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(m.e.conectada ? (m.e.fresco ? Color(red: 0.25, green: 0.85, blue: 0.45)
                                                  : StudioSkin.mostaza)
                                    : Color.gray)
                .frame(width: 7, height: 7)
            Text(m.e.modelo ?? "ZV-E10")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(StudioSkin.text)
            Spacer()
            if m.ocupado {
                ProgressView().scaleEffect(0.45).frame(width: 14, height: 14)
            } else {
                Button { m.refrescar(completo: true) } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: m.e.fresco ? .regular : .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(m.e.fresco ? StudioSkin.dim : StudioSkin.mostaza)
                .help("Leer TODAS las propiedades de la cámara")
            }
            Button { c.showCameraPanel = false } label: {
                Image(systemName: "xmark").font(.system(size: 10))
            }
            .buttonStyle(.plain).foregroundStyle(StudioSkin.dim)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(StudioSkin.panelBorder), alignment: .bottom)
    }

    private var bannerEspejo: some View {
        HStack(spacing: 7) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 11)).foregroundStyle(StudioSkin.mostaza)
            Text("Valores de la sesión anterior · sin confirmar")
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(StudioSkin.mostaza)
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StudioSkin.mostaza.opacity(0.11))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func aviso(_ s: String) -> some View {
        Text(s).font(.system(size: 10)).foregroundStyle(StudioSkin.mostaza)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var vacio: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(m.e.error ?? "Sin leer todavía")
                .font(.system(size: 11)).foregroundStyle(StudioSkin.dim)
                .fixedSize(horizontal: false, vertical: true)
            Button("Leer la cámara") { m.refrescar(completo: true) }
                .font(.system(size: 11)).disabled(m.ocupado)
        }
    }

    /// LO QUE VE: la medición de la imagen real, en vivo. Es el único número de
    /// este panel que NO cuesta un parpadeo — sale del frame que ya está
    /// entrando, no de preguntarle a la cámara.
    @ViewBuilder
    private var loQueVe: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("LO QUE VE").font(.system(size: 8, weight: .semibold)).tracking(0.8)
                .foregroundStyle(StudioSkin.mostaza)
            if let o = m.ojo, o.hayImagen {
                HStack(spacing: 10) {
                    dato("cara", String(format: "%.0f", o.lumCentro), colorCara(o.lumCentro))
                    dato("quemado", String(format: "%.1f%%", o.clipAlto),
                         o.clipAlto > 2 ? .red : StudioSkin.dim)
                    Text(o.veredicto)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(colorCara(o.lumCentro))
                }
            } else if m.ojo != nil {
                Text("sin señal de la cámara")
                    .font(.system(size: 10)).foregroundStyle(.red)
            } else {
                Text("el Estudio no está capturando")
                    .font(.system(size: 10)).foregroundStyle(StudioSkin.dim)
            }
        }
    }

    private func dato(_ etiqueta: String, _ valor: String, _ c: Color) -> some View {
        HStack(spacing: 3) {
            Text(etiqueta).font(.system(size: 9)).foregroundStyle(StudioSkin.dim)
            Text(valor).font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(c)
        }
    }

    /// El rango sano de una cara bien expuesta: 75-110. Salió de calibrar
    /// contra la luz real de este estudio, no de una tabla.
    private func colorCara(_ v: Double) -> Color {
        (75...110).contains(v) ? Color(red: 0.25, green: 0.85, blue: 0.45) : StudioSkin.mostaza
    }

    /// Las dos cosas que se piden hablando y ahora también se piden con el dedo.
    private var atajos: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ATAJOS").font(.system(size: 8, weight: .semibold)).tracking(0.8)
                .foregroundStyle(StudioSkin.mostaza)
            HStack(spacing: 6) {
                boton("Exponer a la cara", "wand.and.stars") { m.autoISO() }
                    .help("Mide la luz de tu cara en la imagen real y mueve el ISO hasta dejarla en rango")
                if m.e.valor("formato") != "XAVC S 4K" {
                    boton("4K limpia", "sparkles") { m.aplicar("formato", "XAVC S 4K") }
                        .help("En XAVC S 4K la cámara apaga sus sobreimpresos sola (medido: bandas 15.6% → 0%)")
                }
            }
        }
    }

    private func boton(_ titulo: String, _ icono: String, _ accion: @escaping () -> Void) -> some View {
        Button(action: accion) {
            HStack(spacing: 4) {
                Image(systemName: icono).font(.system(size: 9))
                Text(titulo).font(.system(size: 10, weight: .medium))
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(StudioSkin.mostaza.opacity(0.10))
            .foregroundStyle(StudioSkin.mostaza)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(StudioSkin.mostaza.opacity(0.35)))
        }
        .buttonStyle(.plain)
        .disabled(m.ocupado)
    }

    @ViewBuilder
    private func seccion(_ g: String) -> some View {
        let items = m.e.grupo(g)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(g.uppercased())
                    .font(.system(size: 8, weight: .semibold)).tracking(0.8)
                    .foregroundStyle(StudioSkin.mostaza)
                ForEach(items) { p in FilaProp(m: m, p: p) }
            }
        }
    }


    /// El candado hecho pantalla: si algo no cayó en su grupo, sale aquí.
    @ViewBuilder
    private var huerfanas: some View {
        let items = m.e.huerfanas
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("SIN CLASIFICAR").font(.system(size: 8, weight: .semibold)).tracking(0.8)
                    .foregroundStyle(.red)
                ForEach(items) { p in FilaProp(m: m, p: p) }
                Text("Estas llegaron con un grupo que este panel no conoce.\nSalen aquí para que no se pierdan.")
                    .font(.system(size: 9)).foregroundStyle(StudioSkin.dim.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Lo que la cámara expone pero nadie mapeó. Va colapsado y rotulado como
    /// lo que es: códigos. Está a propósito — esconderlo sería mentir por
    /// omisión, y bautizarlo sería mentir a secas.
    @ViewBuilder
    private var sinTraducir: some View {
        let items = m.e.sinTraducir
        if !items.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(items) { p in FilaProp(m: m, p: p) }
                    Text("La cámara devuelve estos como número. No se les puso\nnombre porque no está verificado cuál es cuál.")
                        .font(.system(size: 9)).foregroundStyle(StudioSkin.dim.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 6)
            } label: {
                Text("CÓDIGOS SIN TRADUCIR")
                    .font(.system(size: 8, weight: .semibold)).tracking(0.8)
                    .foregroundStyle(StudioSkin.dim)
            }
            .disclosureGroupStyle(.automatic)
            .tint(StudioSkin.dim)
        }
    }

    private var nota: some View {
        VStack(alignment: .leading, spacing: 5) {
            PieLectura(m: m, completo: true)
            Text("No se consulta la cámara sola: cada consulta le apaga la\nimagen un segundo. Se lee al cambiar algo o con ↻.")
                .font(.system(size: 9.5)).foregroundStyle(StudioSkin.dim.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 2)
    }
}


// MARK: - agarradera del cajón

/// Arrastra para cambiar el ancho del cajón de la cámara (280-520). El ancho
/// persiste en UserDefaults via `StudioController.cameraPanelWidth`.
struct CameraResizeHandle: View {
    @EnvironmentObject var c: StudioController
    @State private var startWidth: CGFloat? = nil

    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.001))   // zona de agarre invisible
            .frame(width: 9)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .fill(StudioSkin.panelBorder)
                    .frame(width: 3, height: 46)
            )
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { g in
                        let base = startWidth ?? c.cameraPanelWidth
                        if startWidth == nil { startWidth = base }
                        c.cameraPanelWidth = min(max(base - g.translation.width, 280), 520)
                    }
                    .onEnded { _ in startWidth = nil }
            )
    }
}
