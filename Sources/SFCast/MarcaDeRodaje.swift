/// MARCA DE RODAJE — un archivo que existe mientras se está grabando.
///
/// POR QUÉ EXISTE (28 ago 2026, un fallo real y caro de ver): El Set —el panel
/// web embebido en el Estudio— se RECARGA SOLO cuando su HTML cambia en disco.
/// Es correcto: sin eso la página se queda pintando una versión vieja durante
/// horas, con botones que ya no existen (por eso nació `/version`). Pero ese
/// panel está DENTRO del encuadre: esa tarde, mientras Daniel grababa, una
/// edición del panel lo recargó a mitad de toma y una tarjeta desapareció en
/// cámara. Nada se rompió; simplemente algo se movió solo en su video.
///
/// La regla que faltaba: una superficie que está en cámara no se repinta sola
/// mientras rueda. Con esta marca el panel APLAZA su recarga —no la pierde— y
/// se actualiza en cuanto se corta.
///
/// Es un archivo y no un puerto a propósito: lo lee `panel_server.py` (otro
/// proceso, otro lenguaje, otro repo) con un `exists()`, y si SFCast muere de
/// golpe el peor caso es una marca huérfana que solo aplaza una recarga.
import Foundation

enum MarcaDeRodaje {
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".sfcast/grabando")

    /// Idempotente y silenciosa: esto JAMÁS puede estorbar a una grabación.
    static func set(_ grabando: Bool) {
        let fm = FileManager.default
        if grabando {
            try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: Data())
                Log.info("Rodaje: marca puesta (El Set no se recargará solo mientras dure)")
            }
        } else if fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: url)
            Log.info("Rodaje: marca quitada")
        }
    }

    /// Al arrancar la app: una marca vieja de una sesión que murió a lo bruto
    /// dejaría al panel sin recargarse nunca. Se limpia siempre.
    static func limpiarAlArrancar() { set(false) }
}
