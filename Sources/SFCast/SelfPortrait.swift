/// AUTORRETRATO — la ventana del Estudio se fotografía a sí misma.
///
/// POR QUÉ EXISTE: la ventana del Estudio nace con `sharingType = .none` (estilo
/// OBS: no aparece en las capturas, para que grabar la pantalla no se grabe a sí
/// mismo). Efecto colateral: NADIE de fuera puede ver cómo quedó la interfaz —
/// ni Levy verificando su propio trabajo, ni una captura del sistema, ni el
/// navegador del gate. Y verificar mirando el código no es verificar.
///
/// Una app SÍ puede dibujar su propia ventana, sin permisos y sin importar el
/// sharingType. Se renderiza a PNG cuando aparece `~/.sfcast/pedir-foto`.
///
///     touch ~/.sfcast/pedir-foto      →     ~/.sfcast/ui.png
///
/// No es un atajo: es quitarle al único sensor de la interfaz una dependencia
/// de permisos del sistema que se cae sola cada tanto.

import AppKit

final class Autorretrato {
    private weak var ventana: NSWindow?
    private var timer: Timer?
    private let dir: URL = {
        let d = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".sfcast")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    init(_ w: NSWindow) {
        ventana = w
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.revisarPedido()
        }
    }

    deinit { timer?.invalidate() }

    private func revisarPedido() {
        let foto = dir.appendingPathComponent("pedir-foto")
        guard FileManager.default.fileExists(atPath: foto.path) else { return }
        try? FileManager.default.removeItem(at: foto)
        retratar()
    }

    func retratar() {
        guard let w = ventana, let vista = w.contentView else { return }
        let r = vista.bounds
        guard r.width > 1, r.height > 1,
              let rep = vista.bitmapImageRepForCachingDisplay(in: r) else { return }
        vista.cacheDisplay(in: r, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: dir.appendingPathComponent("ui.png"))
    }
}
