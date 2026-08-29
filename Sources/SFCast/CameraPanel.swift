/// LA CÁMARA — la Sony ZV-E10 se opera DENTRO del Estudio, en UNA tarjeta.
///
/// Por qué vive aquí y no en una app aparte: SFCast ya tiene la vista de la
/// cámara, ya es donde se graba, y durante una toma cambiar de ventana para
/// corregir el ISO no es una opción. Una superficie menos que atender.
///
/// Y por qué UNA (28 ago 2026): llegó a estar en TRES a la vez —columna del
/// panel inferior, cajón propio a la derecha y la tarjeta del enchufe al fondo
/// de El Set—. Daniel las contó: *"hay tres lugares donde tenemos la cámara
/// conectada... la cámara es lo principal, ponla la primerita hasta arriba a la
/// derecha en el set"*. Quedó `SetCameraCard`, la primera tarjeta del cajón,
/// con el ISO a la vista y todo lo demás detrás de «Avanzado».
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
        /// RADIO / MENU / RANGE, tal cual lo manda el CLI. `temp` (temperatura
        /// de color) es RANGE y llega SIN opciones: si no se mira el tipo, la
        /// fila cae en el camino de "no editable" y el control desaparece.
        let tipo: String
        /// Su valor es un CÓDIGO que nadie tradujo. Se muestra aparte y
        /// avisando: bautizar un código con un nombre inventado es fabricar
        /// un dato, y aquí se toman decisiones con lo que dice la pantalla.
        let crudo: Bool
        var id: String { clave }

        var esRango: Bool { tipo == "RANGE" }
        /// Cuánto mueve un ±. La ZV-E10 solo acepta múltiplos de 100 en la
        /// temperatura de color: MEDIDO el 28 ago —`set temp 4350` reintentó
        /// seis veces y la cámara se quedó en 4300—, así que el botón nunca
        /// pide un valor que ella va a rechazar.
        var paso: Int { clave == "temp" ? 100 : 1 }
        var minimo: Int { clave == "temp" ? 2500 : 0 }
        var maximo: Int { clave == "temp" ? 9900 : 1_000_000 }
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

    /// Solo estas claves, de la cámara real. Un parpadeo corto y dirigido.
    static func leerCamara(claves: [String]) -> Estado {
        parsear(correr(["status", "--json", "--keys", claves.joined(separator: ",")], timeout: 90))
    }

    /// PROPIEDADES QUE ABREN O CIERRAN A OTRAS (medido el 28 ago 2026).
    ///
    /// El balance de blancos manda sobre la temperatura de color: con cualquier
    /// preajuste (Daylight, Fluorescent…) la ZV-E10 devuelve `colortemperature`
    /// con `Readonly: 1`, y solo la abre en «Choose Color Temperature».
    ///
    /// EL PROBLEMA MEDIDO: `sfcam set wb X` actualiza el espejo de `wb`, pero
    /// deja el `readonly` de `temp` como estaba. O sea que la app ponía el
    /// balance correcto y seguía pintando la temperatura como intocable —
    /// para siempre, porque nadie volvía a leerla. Daniel: *"se cambia si
    /// modifico el balance de blancos, pero la temperatura no cambia"*.
    ///
    /// Por eso, y SOLO en estos casos, se paga un parpadeo extra: escribir la
    /// clave de la izquierda obliga a releer las de la derecha en la cámara.
    static let dependientes: [String: [String]] = ["wb": ["wb", "temp"]]

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
                tipo: (v["type"] as? String) ?? "",
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
            var r = SFCam.leerEspejo()
            // …salvo cuando lo que se escribió MANDA sobre otra propiedad: ahí el
            // espejo se queda con un permiso viejo y el panel bloquea un control
            // que la cámara ya abrió. Ver `SFCam.dependientes`.
            if let dep = SFCam.dependientes[clave] {
                let real = SFCam.leerCamara(claves: dep)
                if real.conectada {
                    var props = r.props
                    for p in real.props {
                        if let i = props.firstIndex(where: { $0.clave == p.clave }) { props[i] = p }
                        else { props.append(p) }
                    }
                    r = SFCam.Estado(props: props, modelo: real.modelo ?? r.modelo,
                                     leidoEn: real.leidoEn ?? r.leidoEn, fresco: real.fresco,
                                     conectada: true, error: nil)
                }
            }
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
            } else if p.editable && p.esRango {
                RangoProp(m: m, p: p, compacta: compacta)
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

/// UN VALOR CONTINUO (la temperatura de color): ± en los pasos que la cámara
/// acepta, más un menú con las temperaturas de rodaje. No hay lista de opciones
/// que enseñar —la cámara manda un rango, no un catálogo—, así que sin esto la
/// fila salía como texto muerto: se veía el número y no se podía tocar. Fue el
/// segundo hallazgo del 28 ago (*"no me permite modificar la temperatura de
/// color manualmente, ¿por qué pasa esto?"*).
private struct RangoProp: View {
    @ObservedObject var m: CameraPanelModel
    let p: SFCam.Prop
    var compacta = false

    /// Las de rodaje, no una escala de física: tungsteno, halógena, día,
    /// nublado, sombra. Son las que se piden de verdad delante de una cámara.
    private static let deRodaje = [3200, 4300, 5600, 6500, 7500]

    var body: some View {
        HStack(spacing: 5) {
            boton("minus") { mover(-p.paso) }
            Menu {
                ForEach(Self.deRodaje, id: \.self) { k in
                    Button("\(k) K") { m.aplicar(p.clave, "\(k)") }
                }
            } label: {
                Text(p.valor)
                    .font(.system(size: compacta ? 10.5 : 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(m.e.fresco ? StudioSkin.text : StudioSkin.dim)
            }
            .menuStyle(.borderlessButton).fixedSize().disabled(m.ocupado)
            boton("plus") { mover(p.paso) }
        }
    }

    private func boton(_ icono: String, _ accion: @escaping () -> Void) -> some View {
        Button(action: accion) {
            Image(systemName: icono).font(.system(size: 8, weight: .bold))
                .frame(width: 15, height: 15)
                .background(Color.white.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain).foregroundStyle(StudioSkin.dim).disabled(m.ocupado)
    }

    private func mover(_ delta: Int) {
        guard let n = Int(p.valor.filter(\.isNumber)) else { return }
        let v = min(max(n + delta, p.minimo), p.maximo)
        guard v != n else { return }
        m.aplicar(p.clave, "\(v)")
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

// MARK: - el enchufe de la cámara (Shelly, vía el panel del Set)

/// LA CORRIENTE DE LA ZV-E10. Vivía en una tarjeta propia al FONDO de El Set,
/// llamada también "Cámara" — el tercer sitio donde aparecía la cámara. Se sube
/// aquí porque es lo primero que se hace cuando pone *sin conexión*: la Sony
/// vive con dummy battery y este enchufe es su apagón real (0 W, no standby);
/// al llegarle corriente fresca arranca sola.
///
/// Habla por el MISMO proxy que el panel web (`:8088/api/shelly/...`): el
/// adaptador sigue siendo uno solo, esto es otro mando sobre el mismo aparato.
@MainActor
final class EnchufeCamara: ObservableObject {
    static let shared = EnchufeCamara()

    @Published private(set) var encendido: Bool?      // nil = todavía no se sabe
    @Published private(set) var watts: Double?
    @Published private(set) var ocupado = false

    private var reloj: Timer?
    private init() {}

    /// Mientras la tarjeta está a la vista, el interruptor se refresca solo cada
    /// 20 s. Es LAN y no le cuesta un parpadeo a nadie (esto NO es la cámara);
    /// sin esto, apagar el enchufe desde el iPhone dejaba aquí un interruptor
    /// mintiendo. Al desaparecer la tarjeta se para: nada late sin público.
    func mirar() {
        leer()
        reloj?.invalidate()
        reloj = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.leer() }
        }
    }

    func dejarDeMirar() { reloj?.invalidate(); reloj = nil }

    func leer() { pedir("/api/shelly/status") }
    func alternar() { pedir(encendido == true ? "/api/shelly/off" : "/api/shelly/on") }

    private func pedir(_ ruta: String) {
        guard !ocupado, let url = URL(string: "http://127.0.0.1:8088" + ruta) else { return }
        ocupado = true
        var r = URLRequest(url: url)
        r.timeoutInterval = 8
        r.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: r) { [weak self] data, _, _ in
            let d = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            Task { @MainActor in
                guard let self else { return }
                self.ocupado = false
                // Sin respuesta NO se inventa un estado: se queda en "no sé".
                // Un enchufe que no contesta pintado como "apagado" es el mismo
                // error que un cero en un sensor que no midió.
                guard let d, (d["ok"] as? Bool) == true else { self.encendido = nil; return }
                self.encendido = d["on"] as? Bool
                self.watts = d["watts"] as? Double
            }
        }.resume()
    }
}

// MARK: - LA tarjeta de la cámara (la primera de El Set)

/// UNA sola superficie para la ZV-E10, arriba del todo en El Set.
///
/// Antes eran TRES (columna del panel inferior + cajón propio + tarjeta del
/// enchufe al fondo del Set) y Daniel las contó una por una el 28 ago:
/// *"hay tres lugares donde tenemos la cámara conectada... la cámara es lo
/// principal, ponla la primerita hasta arriba a la derecha en el set"*.
///
/// QUÉ SE VE SIN ABRIR NADA: lo que él toca de verdad. Sus palabras: *"nunca
/// toco la configuración, se queda estandarizada; por lo mucho modifico el ISO
/// dependiendo de la iluminación. El resto casi siempre se queda estático"*.
/// O sea: ISO, el lazo que lo mueve solo, lo que el ojo mide, y los avisos que
/// cuestan una toma. Todo lo demás existe y se toca — detrás de «Avanzado».
struct SetCameraCard: View {
    @ObservedObject private var m = CameraPanelModel.shared
    @ObservedObject private var enchufe = EnchufeCamara.shared
    @EnvironmentObject var c: StudioController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cabecera
            if !SFCam.disponible {
                Text("sfcam no está instalado")
                    .font(.system(size: 11)).foregroundStyle(StudioSkin.dim)
                    .padding(10)
            } else if c.camAvanzado {
                // Avanzado: scroll propio y techo de altura, para que la tarjeta
                // no se coma El Set entero.
                ScrollView { cuerpo(avanzado: true).padding(10) }
                    .frame(maxHeight: 420)
            } else {
                cuerpo(avanzado: false).padding(10)
            }
        }
        .background(StudioSkin.panel)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(StudioSkin.panelBorder))
        // NO se lee la cámara al aparecer: el espejo de disco ya está cargado y
        // cada lectura le apaga la imagen 1-4 s. El enchufe sí (es LAN, gratis).
        .onAppear { enchufe.mirar() }
        .onDisappear { enchufe.dejarDeMirar() }
    }

    // MARK: cabecera

    private var cabecera: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(m.e.conectada ? (m.e.fresco ? Color(red: 0.25, green: 0.85, blue: 0.45)
                                                  : StudioSkin.mostaza)
                                    : Color.gray)
                .frame(width: 7, height: 7)
            Text("Cámara")
                .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(StudioSkin.text)
            Text(m.e.conectada ? (m.e.modelo ?? "ZV-E10") : "sin conexión")
                .font(.system(size: 10)).foregroundStyle(StudioSkin.dim)
                .lineLimit(1)
            if let b = m.e.valor("battery"), m.e.conectada {
                Text(b).font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(bateriaColor(b))
            }
            Spacer(minLength: 4)
            if m.ocupado {
                ProgressView().scaleEffect(0.42).frame(width: 13, height: 13)
            } else {
                Button { m.refrescar(completo: c.camAvanzado) } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10.5, weight: m.e.fresco ? .regular : .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(m.e.fresco ? StudioSkin.dim : StudioSkin.mostaza)
                .help(m.e.fresco ? "Leer la cámara (le apaga la imagen un segundo)"
                                 : "Estos valores son de la sesión anterior — pulsa para confirmarlos")
            }
            avanzadoToggle
            // SIN APARATO NO HAY MANDO (28 ago 2026). El Shelly de la cámara no
            // está en la LAN —barrido completo del /24 ese día: cero respuestas—
            // y el interruptor salía gris, sin hacer nada, pareciendo un control
            // roto de la app. Daniel: *"la cámara no tiene un botón de toggle
            // para apagar; siempre está activa a menos que la apague
            // manualmente"*. Si el enchufe no contesta, aquí no hay botón; en
            // cuanto conteste (se reintenta cada 20 s) vuelve solo.
            if enchufe.encendido != nil { interruptor }
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(StudioSkin.panelBorder),
                 alignment: .bottom)
    }

    /// ABRE Y CIERRA, y por eso vive en la CABECERA (arreglo del 28 ago). Estaba
    /// al final del contenido: con «Avanzado» abierto quedaba detrás de un scroll
    /// de cinco secciones, o sea que se podía abrir y no se podía cerrar —
    /// Daniel: *"no me permite volver a contraerlo"*. Un interruptor tiene que
    /// estar en el mismo sitio en los dos estados.
    private var avanzadoToggle: some View {
        Button { withAnimation(.easeInOut(duration: 0.16)) { c.camAvanzado.toggle() } } label: {
            HStack(spacing: 3) {
                Text("Avanzado").font(.system(size: 9.5, weight: .medium))
                Image(systemName: c.camAvanzado ? "chevron.up" : "chevron.down")
                    .font(.system(size: 7.5))
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .foregroundStyle(c.camAvanzado ? StudioSkin.mostaza : StudioSkin.dim)
            .background(c.camAvanzado ? StudioSkin.mostaza.opacity(0.12) : Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help("Obturación, apertura, balance, temperatura, enfoque, formato y estado")
    }

    /// El enchufe. Gris cuando no se sabe: no se pinta un estado que no se midió.
    private var interruptor: some View {
        Button { enchufe.alternar() } label: {
            Capsule()
                .fill(enchufe.encendido == true ? StudioSkin.mostaza : Color.white.opacity(0.12))
                .frame(width: 30, height: 16)
                .overlay(
                    Circle().fill(.white.opacity(enchufe.encendido == nil ? 0.35 : 0.95))
                        .frame(width: 12, height: 12)
                        .offset(x: enchufe.encendido == true ? 7 : -7)
                )
        }
        .buttonStyle(.plain)
        .disabled(enchufe.ocupado)
        .help(enchufeAyuda)
    }

    private var enchufeAyuda: String {
        switch enchufe.encendido {
        case .some(true):  return "Corriente de la ZV-E10: ENCENDIDA"
                                + (enchufe.watts.map { String(format: " · %.1f W medidos", $0) } ?? "")
        case .some(false): return "Corriente de la ZV-E10: apagada — enciéndela y la cámara arranca sola"
        case .none:        return "No sé si el enchufe está encendido (no contestó)"
        }
    }

    private func bateriaColor(_ v: String) -> Color {
        let pct = Double(v.replacingOccurrences(of: "%", with: "")) ?? 0
        return pct > 40 ? Color(red: 0.25, green: 0.85, blue: 0.45)
                        : (pct > 18 ? StudioSkin.mostaza : .red)
    }

    // MARK: cuerpo

    @ViewBuilder
    private func cuerpo(avanzado: Bool) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            if m.e.props.isEmpty {
                vacio
            } else {
                if avanzado, let b = m.e.valor("battery") { BarraBateria(valor: b) }
                filaISO
                atajos
                loQueVe
                AvisosCamara(e: m.e)
                if avanzado {
                    ForEach(SFCam.grupos, id: \.self) { g in seccion(g) }
                    huerfanas
                    sinTraducir
                }
            }
            if let a = m.aviso {
                Text(a).font(.system(size: 9.5)).foregroundStyle(StudioSkin.mostaza)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
            pie(avanzado: avanzado)
        }
    }

    private var vacio: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(m.e.error ?? "Sin leer todavía")
                .font(.system(size: 11)).foregroundStyle(StudioSkin.dim)
                .fixedSize(horizontal: false, vertical: true)
            if enchufe.encendido == false {
                Text("El enchufe está apagado: enciéndelo con el interruptor de arriba y la cámara arranca sola.")
                    .font(.system(size: 10)).foregroundStyle(StudioSkin.mostaza)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Leer la cámara") { m.refrescar(completo: true) }
                .font(.system(size: 11)).disabled(m.ocupado)
        }
    }

    /// EL ISO, grande. Es LO ÚNICO que Daniel mueve a mano en un rodaje.
    @ViewBuilder
    private var filaISO: some View {
        if let iso = m.e.props.first(where: { $0.clave == "iso" }) {
            HStack(spacing: 8) {
                Text("ISO").font(.system(size: 11, weight: .semibold)).tracking(0.6)
                    .foregroundStyle(StudioSkin.mostaza)
                Spacer(minLength: 4)
                if m.enVuelo == "iso" {
                    ProgressView().scaleEffect(0.45).frame(width: 14, height: 14)
                } else if iso.editable && !iso.opciones.isEmpty {
                    Menu {
                        ForEach(iso.opciones, id: \.self) { op in
                            Button(op) { m.aplicar("iso", op) }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(iso.valor)
                                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                                .foregroundStyle(m.e.fresco ? StudioSkin.text : StudioSkin.dim)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 8)).foregroundStyle(StudioSkin.dim.opacity(0.7))
                        }
                    }
                    .menuStyle(.borderlessButton).fixedSize().disabled(m.ocupado)
                } else {
                    Text(iso.valor).font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundStyle(StudioSkin.dim)
                }
            }
        }
    }

    /// Las dos cosas que se piden hablando y también con el dedo.
    private var atajos: some View {
        HStack(spacing: 6) {
            boton("Exponer a la cara", "wand.and.stars") { m.autoISO() }
                .help("Mide la luz de tu cara en la imagen real y mueve el ISO hasta dejarla en rango")
            if m.e.valor("formato") != "XAVC S 4K" {
                boton("4K limpia", "sparkles") { m.aplicar("formato", "XAVC S 4K") }
                    .help("En XAVC S 4K la cámara apaga sus sobreimpresos sola (medido: bandas 15.6% → 0%)")
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

    /// LO QUE VE: la medición de la imagen real. El único número de aquí que NO
    /// cuesta un parpadeo — sale del frame que ya está entrando.
    @ViewBuilder
    private var loQueVe: some View {
        if let o = m.ojo, o.hayImagen {
            HStack(spacing: 9) {
                dato("cara", String(format: "%.0f", o.lumCentro), colorCara(o.lumCentro))
                dato("quemado", String(format: "%.1f%%", o.clipAlto),
                     o.clipAlto > 2 ? .red : StudioSkin.dim)
                Text(o.veredicto)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(colorCara(o.lumCentro))
                Spacer(minLength: 0)
            }
        } else if m.ojo != nil {
            Text("sin señal de la cámara").font(.system(size: 10)).foregroundStyle(.red)
        }
    }

    private func dato(_ etiqueta: String, _ valor: String, _ col: Color) -> some View {
        HStack(spacing: 3) {
            Text(etiqueta).font(.system(size: 9)).foregroundStyle(StudioSkin.dim)
            Text(valor).font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(col)
        }
    }

    /// El rango sano de una cara bien expuesta: 75-110. Salió de calibrar contra
    /// la luz real de este estudio, no de una tabla.
    private func colorCara(_ v: Double) -> Color {
        (75...110).contains(v) ? Color(red: 0.25, green: 0.85, blue: 0.45) : StudioSkin.mostaza
    }

    @ViewBuilder
    private func seccion(_ g: String) -> some View {
        let items = m.e.grupo(g).filter { !(g == "Exposición" && $0.clave == "iso") }
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                Text(g.uppercased())
                    .font(.system(size: 8, weight: .semibold)).tracking(0.8)
                    .foregroundStyle(StudioSkin.mostaza)
                ForEach(items) { p in FilaProp(m: m, p: p) }
                if g == "Color" { notaTemperatura }
            }
        }
    }

    /// POR QUÉ LA TEMPERATURA NO SE DEJA TOCAR (28 ago 2026).
    ///
    /// No es la app: es la cámara. Con el balance en Daylight (o en cualquier
    /// preajuste) la ZV-E10 devuelve `colortemperature` con `Readonly: 1`, y solo
    /// la abre cuando el balance está en «Choose Color Temperature». Medido ese
    /// día por USB: en Daylight `readonly: true`; al cambiar el balance,
    /// `readonly: false` y `set temp 5600` entra a la primera.
    ///
    /// Así que el panel no se calla ni finge un control muerto: dice el motivo y
    /// ofrece el único movimiento que lo desbloquea.
    @ViewBuilder
    private var notaTemperatura: some View {
        if let t = m.e.props.first(where: { $0.clave == "temp" }), !t.editable,
           let wb = m.e.valor("wb"), !wb.lowercased().contains("color temperature") {
            VStack(alignment: .leading, spacing: 5) {
                Text("La cámara solo deja mover la temperatura con el balance en «Choose Color Temperature». Ahora está en \(wb).")
                    .font(.system(size: 9.5)).foregroundStyle(StudioSkin.dim)
                    .fixedSize(horizontal: false, vertical: true)
                boton("Poner el balance en temperatura", "thermometer.medium") {
                    m.aplicar("wb", "Choose Color Temperature")
                }
            }
            .padding(.top, 1)
        }
    }

    /// El candado hecho pantalla: si algo no cayó en su grupo, sale aquí.
    @ViewBuilder
    private var huerfanas: some View {
        let items = m.e.huerfanas
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                Text("SIN CLASIFICAR").font(.system(size: 8, weight: .semibold)).tracking(0.8)
                    .foregroundStyle(.red)
                ForEach(items) { p in FilaProp(m: m, p: p) }
                Text("Estas llegaron con un grupo que este panel no conoce.\nSalen aquí para que no se pierdan.")
                    .font(.system(size: 9)).foregroundStyle(StudioSkin.dim.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Lo que la cámara expone pero nadie mapeó. Va colapsado y rotulado como lo
    /// que es: códigos. Esconderlo sería mentir por omisión, bautizarlo sería
    /// mentir a secas.
    @ViewBuilder
    private var sinTraducir: some View {
        let items = m.e.sinTraducir
        if !items.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 7) {
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

    /// Pie: la frescura del dato (el toggle vive arriba, en la cabecera).
    private func pie(avanzado: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                PieLectura(m: m, completo: avanzado)
                Spacer(minLength: 0)
            }
            if avanzado {
                Text("No se consulta la cámara sola: cada consulta le apaga la\nimagen un segundo. Se lee al cambiar algo o con ↻.")
                    .font(.system(size: 9.5)).foregroundStyle(StudioSkin.dim.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 1)
    }
}
