import AppKit
import Carbon.HIToolbox

/// ATAJOS GLOBALES — funcionan aunque SFCast esté en segundo plano.
///
/// Se usa `RegisterEventHotKey` (Carbon) a propósito, y no
/// `NSEvent.addGlobalMonitorForEvents`: el monitor global exige el permiso de
/// **Monitorización de entrada**, o sea otro diálogo de TCC más — y esta app ya
/// pagó caro esa moneda (el arco de permisos de v1.3-v1.4, el reset de pantalla
/// que se muere en cada rebuild). `RegisterEventHotKey` no pide nada: el sistema
/// entrega el evento solo cuando la combinación exacta se pulsa, así que ni
/// siquiera puede leer lo que Daniel teclea. Menos permiso y menos poder es
/// justo lo correcto aquí.
///
/// Existe para los MARCADORES EN VIVO (v3.2): Daniel está presentando en otra
/// app, se traba, y marca el punto sin salir de su presentación.
final class GlobalHotKey {

    private static var siguienteID: UInt32 = 1
    private static var registrados: [UInt32: GlobalHotKey] = [:]
    private static var handlerInstalado = false

    private var ref: EventHotKeyRef?
    private let id: UInt32
    private let accion: () -> Void
    let descripcion: String

    /// `key` es un virtual keycode de Carbon (`kVK_ANSI_X`, …). `mods` son
    /// `cmdKey/shiftKey/optionKey/controlKey`.
    @discardableResult
    init?(key: Int, mods: UInt32, descripcion: String, accion: @escaping () -> Void) {
        self.accion = accion
        self.descripcion = descripcion
        self.id = GlobalHotKey.siguienteID
        GlobalHotKey.siguienteID += 1

        GlobalHotKey.instalarHandlerSiHaceFalta()

        var hotKeyID = EventHotKeyID(signature: OSType(0x53464353), id: id)  // 'SFCS'
        var refLocal: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(key), mods, hotKeyID,
                                         GetApplicationEventTarget(), 0, &refLocal)
        guard status == noErr, let refLocal else {
            // Que otra app ya tenga el atajo no puede tumbar la grabación: se
            // reporta y se sigue sin él (el marcador tiene otras puertas).
            // El sospechoso #1 NO es "otra app": es OTRA INSTANCIA DE SFCAST
            // (o esta misma, que no soltó el atajo de la corrida anterior).
            // Decirlo mal mandó la cacería del 27 ago al lado equivocado.
            Log.error("Atajo global \(descripcion) NO se registró (status \(status)) "
                      + "— otra instancia de SFCast o alguna app lo tiene tomado")
            return nil
        }
        self.ref = refLocal
        GlobalHotKey.registrados[id] = self
        Log.info("Atajo global registrado: \(descripcion)")
        _ = hotKeyID
    }

    /// SUELTA la tecla de verdad. NO se puede confiar en `deinit`: mientras el
    /// atajo vive, `registrados[id] = self` es una referencia FUERTE a sí mismo,
    /// así que poner la propiedad en `nil` desde fuera no destruye nada y el
    /// hotkey se queda tomado hasta que muere el proceso. Ese era el bug del
    /// 26-27 ago: `soltarAtajosDeMarcador()` escribía "atajos liberados" en el
    /// log y no liberaba nada — ⌥C y ⌥X seguían comiéndose ç y ≈ en todas las
    /// apps, y el siguiente arranque de SFCast chocaba con su propio fantasma
    /// (`eventHotKeyExistsErr`, -9878) mientras el mensaje culpaba a "otra app".
    /// Un actuador que reporta su intención no es un sensor.
    func desregistrar() {
        guard let r = ref else { return }
        UnregisterEventHotKey(r)
        ref = nil
        GlobalHotKey.registrados[id] = nil
    }

    /// Red de seguridad: si alguien SÍ logra soltar la última referencia.
    deinit { desregistrar() }

    private static func instalarHandlerSiHaceFalta() {
        guard !handlerInstalado else { return }
        handlerInstalado = true
        var tipo = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, evento, _ -> OSStatus in
            var hkID = EventHotKeyID()
            let err = GetEventParameter(evento, EventParamName(kEventParamDirectObject),
                                        EventParamType(typeEventHotKeyID), nil,
                                        MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            guard err == noErr else { return err }
            DispatchQueue.main.async {
                GlobalHotKey.registrados[hkID.id]?.accion()
            }
            return noErr
        }, 1, &tipo, nil, nil)
    }
}
