/// ZOOM DE LA APP — ⌘+ / ⌘− / ⌘0, como en un navegador.
///
/// Pedido de Daniel (22 ago): *"permíteme un atajo cmd +/- para adaptar el
/// tamaño a mis necesidades y al tamaño de letra que busco"*, y después
/// *"asegúrate que sea responsivo a cada parte"*.
///
/// POR QUÉ NO ES UN `scaleEffect` DE SWIFTUI: eso maqueta la vista a su tamaño
/// original, la rasteriza y la estira. El texto sale suave y NADA se reacomoda —
/// que es justo lo contrario de lo que se pide cuando alguien quiere leer mejor.
///
/// CÓMO SE HACE BIEN: la relación `frame / bounds` de una NSView ES su escala, y
/// AppKit dibuja a través de esa transformación a resolución de pantalla. Con el
/// marco al tamaño de la ventana y los *bounds* a `tamaño / zoom`, SwiftUI
/// maqueta en MENOS puntos lógicos: todo se ve más grande, cada glifo se
/// rasteriza a su tamaño final, y la maqueta se REHACE (los paneles se
/// reacomodan, el texto reflowea, los `maxWidth: .infinity` reparten distinto).
/// Es el zoom de un navegador, no el de una lupa. Los eventos de ratón los
/// convierte AppKit por la misma transformación, así que los clics caen donde se
/// ven sin tocar una línea de hit-testing.
///
/// ES DE LA APP, NO DE UNA VENTANA: el valor es uno solo, se persiste, y al
/// cambiarlo se avisa a todas las superficies montadas. ⌘+ en el Estudio también
/// agranda el Hub.

import AppKit

final class ZoomHost: NSView {
    static let clave = "sfcast.zoom"
    static let aviso = Notification.Name("SFCastZoomCambio")
    static let pasos: [CGFloat] = [0.7, 0.8, 0.9, 1.0, 1.1, 1.25, 1.4, 1.6, 1.8]

    /// UNO para toda la app, y persistido: el tamaño de letra es una decisión de
    /// la persona, no de la sesión. Volver a abrir y encontrarlo chiquito otra
    /// vez sería pedirle que lo decida cada día.
    static var valor: CGFloat = {
        let z = UserDefaults.standard.double(forKey: ZoomHost.clave)
        return (0.7...1.8).contains(z) ? CGFloat(z) : 1.0
    }() {
        didSet {
            guard valor != oldValue else { return }
            UserDefaults.standard.set(Double(valor), forKey: clave)
            NotificationCenter.default.post(name: aviso, object: nil)
        }
    }

    static func alejar()  { mover(-1) }
    static func acercar() { mover(1) }
    static func normal()  { valor = 1 }

    private static func mover(_ dir: Int) {
        // Al escalón MÁS CERCANO y de ahí uno: si el valor guardado no cae justo
        // en un escalón, el primer ⌘+ no puede quedarse sin hacer nada.
        let i = pasos.enumerated()
            .min(by: { abs($0.element - valor) < abs($1.element - valor) })?.offset ?? 3
        valor = pasos[min(max(i + dir, 0), pasos.count - 1)]
    }

    /// Envuelve una vista de SwiftUI. Devuelve el contenedor que va de
    /// `contentView`. Una línea por superficie: así ninguna se queda fuera.
    static func envolver(_ contenido: NSView) -> ZoomHost {
        let z = ZoomHost()
        contenido.autoresizingMask = []
        z.escala.addSubview(contenido)
        return z
    }

    /// La capa que lleva la escala, y la razón de que exista.
    ///
    /// Que el contenedor se escalara A SÍ MISMO se comía la cola: `layout()`
    /// calculaba los bounds lógicos a partir de `frame`, pero al tocar sus
    /// propios bounds el siguiente pase leía otra cosa y volvía a dividir. El
    /// zoom se COMPUSO — 1.25 pedido, ~3.7 en pantalla (1.25⁶). Con una capa en
    /// medio el marco se le asigna SIEMPRE desde fuera y no hay realimentación.
    fileprivate let escala = NSView()

    /// Se llama al cambiar el zoom, con el factor nuevo. Sirve para que cada
    /// superficie ajuste lo suyo (tamaño mínimo de ventana, nitidez de capas).
    var alCambiar: ((CGFloat) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
        addSubview(escala)
        NotificationCenter.default.addObserver(
            forName: ZoomHost.aviso, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.needsLayout = true
            self.layoutSubtreeIfNeeded()
            self.alCambiar?(ZoomHost.valor)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// ⚠️ TRES CAPAS, Y CADA UNA HACE UNA COSA
    ///
    ///   ZoomHost  — mide la ventana. Sus bounds NO se tocan jamás.
    ///     escala  — frame = tamaño físico · bounds = tamaño / zoom.
    ///               Esa razón ES la magnificación, y AppKit dibuja a través de
    ///               ella a resolución de pantalla (texto nítido) y convierte
    ///               los clics por el mismo camino (nada que tocar en hit-test).
    ///       hijo  — frame = los bounds de escala. SwiftUI maqueta contra su
    ///               FRAME, así que aquí es donde recibe menos puntos y
    ///               reacomoda de verdad: paneles, reflow, todo.
    ///
    /// Los dos intentos fallidos, por si vuelve la tentación de simplificar:
    /// achicar los bounds del `NSHostingView` no reacomoda nada (SwiftUI mira el
    /// frame) y desborda un cuarto del Estudio fuera de la ventana; y que el
    /// contenedor se escale a sí mismo compone el zoom en cada pase de maqueta.
    override func layout() {
        super.layout()
        guard bounds.width > 1, bounds.height > 1 else { return }
        let z = max(0.7, min(ZoomHost.valor, 1.8))
        // El marco PRIMERO: asignarlo reinicia el tamaño de los bounds. Y viene
        // de los bounds del PADRE, que nadie modifica: sin realimentación.
        escala.frame = bounds
        // SIEMPRE, tambien en z == 1. Cambiar el FRAME de una vista ya escalada
        // NO deshace su escala: AppKit conserva la razon frame/bounds. Con el
        // `if z != 1` de antes, volver a 1.0 con ⌘0 dejaba la maqueta a 1.25
        // para siempre — el numero decia 1 y la pantalla decia otra cosa.
        let logico = NSSize(width: bounds.width / z, height: bounds.height / z)
        if escala.bounds.size != logico { escala.setBoundsSize(logico) }
        if let c = escala.subviews.first, c.frame.size != escala.bounds.size {
            c.frame = CGRect(origin: .zero, size: escala.bounds.size)
        }
    }

    /// El zoom cambia cuántos puntos lógicos hay, así que una capa que se
    /// rasteriza sola (el preview de video) necesita saberlo o sale suave.
    var escalaDeDibujo: CGFloat { (window?.backingScaleFactor ?? 2) * ZoomHost.valor }

    // MARK: los atajos

    /// Se atienden aquí y no en un menú porque SFCast vive en la barra de
    /// estado: no tiene menú de aplicación donde colgarlos. Al estar en el
    /// contenedor raíz, funcionan con el foco en cualquier parte de la ventana.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command),
              !event.modifierFlags.contains(.option),
              !event.modifierFlags.contains(.control) else { return false }
        switch event.charactersIgnoringModifiers {
        case "+", "=":  ZoomHost.acercar(); return true   // ⌘+ sin Shift llega como "="
        case "-", "_":  ZoomHost.alejar();  return true
        case "0":       ZoomHost.normal();  return true
        default:        return false
        }
    }
}
