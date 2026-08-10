import Foundation

/// Sube la sesión al VPS por rsync/ssh (alias hermes-vps, llave existente).
/// El link es determinístico ANTES de subir — por eso el clipboard se llena
/// al instante del stop y la subida corre en background.
struct Uploader {
    let settings: AppSettings

    struct Meta: Codable {
        var id: String
        var mode: String
        var startedAt: String
        var stoppedAt: String
        var durationSeconds: Double
        var segments: [String]
        var appVersion = "1.6.0"
    }

    /// Publica la página "Procesando…" instantánea en /v/<id>/ ANTES del upload.
    /// Auto-refresca cada 4s; el worker la pisa con el viewer real al terminar.
    /// Así el navegador puede abrirse al instante del stop sin caer en un 404.
    func publishPlaceholder(id: String) async throws {
        let remoteDir = "/opt/sfcast/www/v/\(id)"
        let html = Self.placeholderHTML(id: id)
        try await run("/usr/bin/ssh",
                      ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                       settings.sshHost, "mkdir -p '\(remoteDir)' && cat > '\(remoteDir)/index.html'"],
                      stdin: html)
        Log.info("Placeholder publicado → \(remoteDir)")
    }

    /// El upload murió (3 reintentos): pisa el placeholder para que la página
    /// abierta NO gire para siempre (review 14 jul, finding "refresh infinito").
    func publishFailurePage(id: String) async throws {
        let remoteDir = "/opt/sfcast/www/v/\(id)"
        try await run("/usr/bin/ssh",
                      ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                       settings.sshHost, "cat > '\(remoteDir)/index.html'"],
                      stdin: Self.failureHTML(id: id))
    }

    static func placeholderHTML(id: String) -> String {
        shellHTML(id: id, body: """
        <div class="spin"></div>
        <h1>Procesando tu video…</h1>
        <p id="msg">Transcript, título y capítulos en camino. Esta página se actualiza sola.</p>
        """, script: """
        <script>
        // refresh por JS con TOPE de 30 min: si el pipeline murió, avisa en vez
        // de girar para siempre (el worker pisa esta página con el viewer real).
        const KEY='sfcast-\(id)';
        const t0=Number(localStorage.getItem(KEY)||Date.now());
        localStorage.setItem(KEY,String(t0));
        if(Date.now()-t0<30*60*1000){setTimeout(()=>location.reload(),4000);}
        else{document.querySelector('.spin').style.display='none';
             document.getElementById('msg').textContent='Esto está tardando más de lo normal. Revisa la notificación en tu Mac o dile a Levy que mire el pipeline (sfcast-pipeline en el VPS).';}
        </script>
        """)
    }

    static func failureHTML(id: String) -> String {
        shellHTML(id: id, body: """
        <div style="font-size:40px;margin-bottom:14px">⚠️</div>
        <h1>El upload no llegó al servidor</h1>
        <p>Tu grabación está A SALVO en tu Mac: <span class="id">~/Movies/SFCast/\(id)</span>.<br>
        Reintenta desde el Historial de SFCast o dile a Levy que la suba.</p>
        """, script: "")
    }

    private static func shellHTML(id: String, body: String, script: String) -> String {
        """
        <!doctype html><html lang="es"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <link rel="icon" href="data:,">
        <title>Procesando tu video — SFCast</title>
        <style>
        body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;
             background:#0b0c0e;color:#e8e8e6;font-family:-apple-system,system-ui,sans-serif}
        .card{text-align:center;padding:48px 56px;background:#141619;border:1px solid #26282c;
              border-radius:18px;box-shadow:0 20px 60px rgba(0,0,0,.5);max-width:520px}
        .spin{width:44px;height:44px;margin:0 auto 22px;border-radius:50%;
              border:3px solid #26282c;border-top-color:#ff9101;animation:r 0.9s linear infinite}
        @keyframes r{to{transform:rotate(360deg)}}
        h1{font-size:19px;margin:0 0 8px}
        p{font-size:13px;color:#999;margin:0;line-height:1.6}
        .id{font-family:ui-monospace,monospace;color:#ff9101}
        .brand{margin-top:26px;font-size:11px;color:#666}
        .brand b{color:#ff9101}
        </style></head><body><div class="card">
        \(body)
        <p style="margin-top:10px"><span class="id">\(id)</span></p>
        <div class="brand">Grabado con <b>SFCast</b> — infraestructura propia de SaaS Factory</div>
        </div>\(script)</body></html>
        """
    }

    /// Pre-sube la sesión MIENTRAS sigues grabando, para que al detener solo
    /// quede la COLA por subir. Es el truco por el que Loom se siente
    /// instantáneo: cuando le das stop, ya tiene arriba casi todo.
    ///
    /// CORRECTITUD (lo único que de verdad importa aquí): usa `--inplace
    /// --append`, que asume que el archivo remoto es un PREFIJO del local. Un
    /// MP4 en escritura lo cumple casi siempre — el mdat crece secuencial y el
    /// moov se escribe al cerrar — pero si el writer escribiera hacia atrás, el
    /// remoto quedaría mal. NO IMPORTA: el rsync del stop corre SIN `--append`,
    /// o sea delta completo, y deja el remoto byte a byte igual al local pase lo
    /// que pase. Este lazo solo puede AHORRAR tiempo, jamás costar un video.
    ///
    /// Nunca crea UPLOAD_DONE: el worker del VPS no puede ver una sesión a
    /// medias porque es ESE marcador el que la hace visible al poller.
    ///
    /// Silencioso a propósito: nada de lo que pase aquí toca la UI ni el
    /// historial. Si el VPS no responde, se reintenta al siguiente tick.
    func liveSync(sessionDir: URL, id: String, everySeconds: Double = 20) async {
        let remoteDir = "\(settings.remoteIncoming)/\(id)"
        var ticks = 0, bootstrapped = false
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(everySeconds * 1_000_000_000))
            if Task.isCancelled { break }
            if !bootstrapped {
                guard (try? await run("/usr/bin/ssh",
                    ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                     settings.sshHost, "mkdir -p '\(remoteDir)'"])) != nil else { continue }
                bootstrapped = true
            }
            let ok: Void? = try? await run("/usr/bin/rsync",
                ["-a", "--inplace", "--append", "--partial",
                 "-e", "/usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=10",
                 sessionDir.path + "/", "\(settings.sshHost):\(remoteDir)/"])
            if ok != nil { ticks += 1 }
        }
        if ticks > 0 { Log.info("live-sync: \(ticks) tandas pre-subidas durante la grabación") }
    }

    /// Borra en el VPS lo que la pre-subida haya alcanzado a dejar de una sesión
    /// que terminaste cancelando.
    ///
    /// Sin esto, cada grabación cancelada dejaría un directorio a medias en
    /// `incoming/` para siempre — sin `UPLOAD_DONE` el poller ni lo mira, así
    /// que nadie se enteraría nunca. Es exactamente la basura silenciosa que
    /// encontramos del 15 jul: 2 sesiones huérfanas, 95 MB, 26 días invisibles.
    ///
    /// El id se valida contra la MISMA gramática que exige el worker, para que
    /// esto no pueda apuntar fuera de `remoteIncoming`.
    func discardRemote(id: String) async {
        guard id.range(of: "^[a-z0-9-]{4,40}$", options: .regularExpression) != nil else {
            Log.error("discardRemote: id inválido «\(id)» — no borro nada")
            return
        }
        let remoteDir = "\(settings.remoteIncoming)/\(id)"
        try? await run("/usr/bin/ssh",
                       ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                        settings.sshHost, "rm -rf -- '\(remoteDir)'"])
        Log.info("Pre-subida descartada en el VPS → \(remoteDir)")
    }

    func upload(sessionDir: URL, meta: Meta) async throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(meta).write(to: sessionDir.appendingPathComponent("meta.json"))

        let remoteDir = "\(settings.remoteIncoming)/\(meta.id)"
        var lastError: Error?
        for attempt in 1...3 {
            let t0 = Date()
            do {
                try await run("/usr/bin/ssh",
                              ["-o", "BatchMode=yes", "-o", "ConnectTimeout=15",
                               settings.sshHost, "mkdir -p '\(remoteDir)'"])
                // -a, NO -az: el payload es HEVC (ya comprimido) — gzip no gana
                // un byte y quema CPU en los dos lados del túnel.
                try await run("/usr/bin/rsync",
                              ["-a", "--partial",
                               "-e", "/usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=15",
                               sessionDir.path + "/",
                               "\(settings.sshHost):\(remoteDir)/"])
                try await run("/usr/bin/ssh",
                              ["-o", "BatchMode=yes", "-o", "ConnectTimeout=15",
                               settings.sshHost, "touch '\(remoteDir)/UPLOAD_DONE'"])
                // El SEGUNDO es el sensor del live-sync: con la pre-subida
                // funcionando esto tiene que quedar en pocos segundos aunque el
                // video pese cientos de MB. Si vuelve a crecer, el live-sync
                // dejó de servir y hay que mirarlo (lección: órgano sin sensor).
                Log.info(String(format: "Upload OK → %@ (intento %d, %.1fs de cola)",
                                remoteDir, attempt, Date().timeIntervalSince(t0)))
                return
            } catch {
                lastError = error
                Log.error("Upload intento \(attempt) falló: \(error.localizedDescription)")
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 3_000_000_000)
            }
        }
        throw lastError ?? NSError(domain: "SFCast", code: 2,
                                   userInfo: [NSLocalizedDescriptionKey: "Upload falló tras 3 intentos"])
    }

    private func run(_ bin: String, _ args: [String], stdin: String? = nil) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = args
            let errPipe = Pipe()
            p.standardError = errPipe
            p.standardOutput = Pipe()
            // GOTCHA (review 14 jul): escribir el stdin ANTES de p.run() bloquea
            // el MainActor si el payload rebasa el buffer del pipe (~64KB) —
            // nadie lo drena aún. Se escribe DESPUÉS de arrancar y en background.
            var inPipe: Pipe? = nil
            if stdin != nil {
                inPipe = Pipe()
                p.standardInput = inPipe
            }
            p.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    cont.resume()
                } else {
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    let msg = String(data: errData, encoding: .utf8) ?? "exit \(proc.terminationStatus)"
                    cont.resume(throwing: NSError(
                        domain: "SFCast", code: Int(proc.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: "\(bin): \(msg.prefix(300))"]))
                }
            }
            do {
                try p.run()
                if let stdin, let pipe = inPipe {
                    let data = stdin.data(using: .utf8)!
                    DispatchQueue.global(qos: .utility).async {
                        pipe.fileHandleForWriting.write(data)
                        try? pipe.fileHandleForWriting.close()
                    }
                }
            } catch { cont.resume(throwing: error) }
        }
    }
}

/// Historial local de grabaciones (para el menú del status bar).
struct History {
    struct Entry: Codable {
        var id: String
        var url: String
        var date: String
        var durationSeconds: Double
        var mode: String
        var status: String   // uploading | done | failed
        var title: String?
    }

    static let file = AppSettings.dir.appendingPathComponent("history.json")

    static func load() -> [Entry] {
        guard let data = try? Data(contentsOf: file),
              let list = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return list
    }

    static func upsert(_ entry: Entry) {
        var list = load().filter { $0.id != entry.id }
        list.insert(entry, at: 0)
        if list.count > 50 { list = Array(list.prefix(50)) }
        try? FileManager.default.createDirectory(at: AppSettings.dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(list) { try? data.write(to: file) }
    }
}
