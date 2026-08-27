import Foundation
import IOKit.pwr_mgt

/// EL CANDADO CONTRA EL SUEÑO DE PANTALLA (26 ago 2026).
///
/// Esta Mac tiene `displaysleep 5`: **a los cinco minutos sin teclado ni ratón,
/// macOS apaga los monitores**. Y grabar un curso hablando a cámara es
/// exactamente eso — cinco, diez, veinte minutos sin tocar nada.
///
/// Cuando la pantalla se duerme, ScreenCaptureKit deja de tener pantalla que
/// capturar y el stream se cae con "No se encontraron pantallas ni ventanas por
/// capturar". Está en el log del 26 ago dos veces, a las 06:15 y a las 07:02 —
/// justo las horas en que la máquina llevaba rato sola. En una toma de verdad
/// eso son minutos de curso grabados contra un monitor apagado, y el reenganche
/// del watchdog no arregla nada porque no hay nada a lo que reengancharse.
///
/// OBS declara esta misma aserción desde siempre. Nosotros no la teníamos, y por
/// eso "se congeló" era un desenlace posible cada vez que Daniel se quedaba
/// quieto explicando algo.
///
/// Se toma al empezar a grabar y se suelta al parar: fuera de la toma, que la
/// Mac administre su energía como quiera.
final class PowerAssertion {
    private var id: IOPMAssertionID = 0
    private var held = false
    private let motivo: String

    init(motivo: String) { self.motivo = motivo }

    func tomar() {
        guard !held else { return }
        var aid: IOPMAssertionID = 0
        let r = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            motivo as CFString,
            &aid)
        if r == kIOReturnSuccess {
            id = aid
            held = true
            Log.info("Estudio: candado de energía TOMADO — la pantalla no se dormirá mientras grabas")
        } else {
            // Sin actuador no hay sensor: si el candado no se pudo tomar, hay
            // que decirlo, porque el riesgo (perder minutos de toma contra un
            // monitor apagado) sigue vivo y solo Daniel puede compensarlo.
            Log.error("Estudio: NO pude tomar el candado de energía (\(r)) — si dejas de tocar el "
                      + "teclado 5 min, la pantalla puede dormirse a mitad de la toma")
        }
    }

    func soltar() {
        guard held else { return }
        IOPMAssertionRelease(id)
        held = false
        Log.info("Estudio: candado de energía suelto")
    }
}
