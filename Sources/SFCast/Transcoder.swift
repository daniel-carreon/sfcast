import Foundation

/// Comprime los segmentos ANTES de subir.
///
/// POR QUÉ (medido con el video real de Daniel el 15 jul): el cuello de botella
/// NUNCA fue el pipeline del VPS (89s de punta a punta) sino la SUBIDA.
/// SCRecordingOutput escribe a ~7 Mbps (15 MB por 17 segundos = 52 MB por
/// minuto) y su API no expone bitrate — solo outputURL, fileType y codec. Con
/// ~0.5 Mbps de subida, esos 52 MB/min son ~14 min de espera por minuto grabado.
///
/// Un re-encode por HARDWARE (hevc_videotoolbox) deja el archivo ~5x más chico
/// en ~15% de la duración del video (15.0 MB → 3.1 MB en 2.5s, sin pérdida
/// visible en contenido de pantalla: se leen los menús y la barra lateral).
/// Corre DESPUÉS de que el link ya está en el portapapeles y el navegador ya
/// abrió: Daniel no lo siente, solo ve que el video aparece 5x antes.
///
/// BEST-EFFORT y NO destructivo por diseño: si ffmpeg no está, si falla, si
/// tarda de más o si el resultado sale más grande o con otra duración, se
/// sube el ORIGINAL tal cual. Comprimir jamás puede costar un video.
enum Transcoder {
    private static let candidates = [
        "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg",
    ]

    static var ffmpegPath: String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static var ffprobePath: String? {
        guard let ff = ffmpegPath else { return nil }
        let probe = ff.replacingOccurrences(of: "/ffmpeg", with: "/ffprobe")
        return FileManager.default.isExecutableFile(atPath: probe) ? probe : nil
    }

    /// Comprime EN SITIO cada `seg-*.mp4` del directorio. Devuelve los bytes
    /// antes/después (iguales si no se pudo comprimir nada).
    @discardableResult
    static func compressSegments(in dir: URL, bitrateKbps: Int) async -> (before: Int64, after: Int64) {
        guard let ffmpeg = ffmpegPath else {
            Log.info("Transcoder: sin ffmpeg en el sistema — se sube el original")
            return (0, 0)
        }
        let fm = FileManager.default
        // mp4 Y mov: el modo "solo cámara" escribe seg-NNN.mov (AVCaptureMovieFileOutput),
        // no .mp4 — filtrar solo mp4 dejaba ese modo entero sin comprimir (review 15 jul).
        // El worker del VPS ya globea las dos extensiones, así que se conserva la del
        // original y nadie más se entera.
        let segs = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("seg-")
                      && ["mp4", "mov"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !segs.isEmpty else { return (0, 0) }

        var before: Int64 = 0, after: Int64 = 0
        for seg in segs {
            let size0 = fileSize(seg)
            before += size0
            after += await compress(seg, ffmpeg: ffmpeg, baseKbps: bitrateKbps) ?? size0
        }
        if after < before {
            let ratio = Double(before) / Double(max(after, 1))
            Log.info(String(format: "Transcoder: %@ → %@ (%.1fx más chico)",
                            mb(before), mb(after), ratio))
        }
        return (before, after)
    }

    /// Comprime un segmento. Devuelve los bytes finales, o nil si se quedó el
    /// original (cualquier duda ⇒ original).
    private static func compress(_ url: URL, ffmpeg: String, baseKbps: Int) async -> Int64? {
        let fm = FileManager.default
        let size0 = fileSize(url)
        let info = await probe(url)
        let dur0 = info?.duration
        let isCamera = url.pathExtension.lowercased() == "mov"
        let kbps = targetBitrate(base: baseKbps, width: info?.width, height: info?.height, isCamera: isCamera)
        // El temporal vive FUERA de sessionDir a propósito: rsync sube el
        // directorio entero, y un .part suelto ahí acabaría en el VPS. Conserva
        // la extensión del original: ffmpeg elige el contenedor por ella y el
        // reemplazo deja el nombre intacto (meta.json y el worker no se enteran).
        let tmp = fm.temporaryDirectory
            .appendingPathComponent("sfcast-\(UUID().uuidString).\(url.pathExtension)")
        defer { try? fm.removeItem(at: tmp) }

        // -map 0 + -c:a copy: conserva TODAS las pistas (el audio ya viene
        // mezclado en una sola aac stereo) sin re-encodear sonido.
        // -tag:v hvc1: sin esto Safari/QuickTime no reproducen el HEVC.
        let args = ["-y", "-nostdin", "-nostats", "-loglevel", "error", "-i", url.path,
                    "-map", "0",
                    "-c:v", "hevc_videotoolbox", "-b:v", "\(kbps)k", "-tag:v", "hvc1",
                    "-c:a", "copy",
                    "-movflags", "+faststart",
                    tmp.path]
        // Techo generoso: el encode por hardware corre a ~7x tiempo real, así
        // que 2x la duración del video (mínimo 60s) es holgado sin ser eterno.
        // Sin ffprobe la duración se estima por peso (la captura ronda 7 Mbps):
        // un deadline fijo de 120s mataría en silencio los videos largos.
        let estimated = dur0 ?? (Double(size0) / 875_000)
        let deadline = max(60.0, estimated * 2)
        let t0 = Date()
        guard await runProcess(ffmpeg, args, timeout: deadline) else {
            Log.error("Transcoder: ffmpeg falló en \(url.lastPathComponent) — se sube el original")
            return nil
        }

        // Compuertas ANTES de tocar el original.
        let size1 = fileSize(tmp)
        guard size1 > 0, size1 < size0 else {
            Log.info("Transcoder: el re-encode no achicó \(url.lastPathComponent) — se queda el original")
            return nil
        }
        if let d0 = dur0, let d1 = await probe(tmp)?.duration, abs(d0 - d1) > 0.5 {
            Log.error(String(format: "Transcoder: duración cambió (%.2fs → %.2fs) — se queda el original", d0, d1))
            return nil
        }
        do {
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
        } catch {
            Log.error("Transcoder: no se pudo reemplazar \(url.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
        Log.info(String(format: "Transcoder: %@ %@ → %@ (%dk) en %.1fs",
                        url.lastPathComponent, mb(size0), mb(size1), kbps, Date().timeIntervalSince(t0)))
        return size1
    }

    /// El ancla (1200 kbps por defecto) está MEDIDA sobre pantalla 1080p real.
    /// Pero la captura no baja de resolución: en Retina/5K son 3-6x más píxeles
    /// y el mismo bitrate dejaría el texto borroso — justo el caso de uso de
    /// SFCast (grabar código). Así que se escala por píxeles para mantener los
    /// bits/píxel que sí verifiqué legibles.
    /// La cámara pide el doble: el video del mundo real (grano, movimiento
    /// continuo) es mucho menos compresible que una pantalla casi quieta.
    private static func targetBitrate(base: Int, width: Int?, height: Int?, isCamera: Bool) -> Int {
        let anchor = isCamera ? base * 2 : base
        guard let w = width, let h = height, w > 0, h > 0 else { return anchor }
        let scaled = Double(anchor) * Double(w * h) / (1920.0 * 1080.0)
        return max(400, min(Int(scaled.rounded()), 12_000))
    }

    private struct MediaInfo { var duration: Double?; var width: Int?; var height: Int? }

    private static func probe(_ url: URL) async -> MediaInfo? {
        guard let probe = ffprobePath else { return nil }
        guard let out = await runProcessCapturing(probe, [
            "-v", "error", "-select_streams", "v:0",
            "-show_entries", "stream=width,height:format=duration",
            "-of", "default=noprint_wrappers=1", url.path,
        ], timeout: 20) else { return nil }
        var info = MediaInfo()
        for line in out.split(separator: "\n") {
            let kv = line.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let v = kv[1].trimmingCharacters(in: .whitespaces)
            switch kv[0] {
            case "duration": info.duration = Double(v)
            case "width": info.width = Int(v)
            case "height": info.height = Int(v)
            default: break
            }
        }
        return info
    }

    private static func fileSize(_ url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func mb(_ bytes: Int64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    // MARK: - Procesos con deadline

    private static func runProcess(_ bin: String, _ args: [String], timeout: Double) async -> Bool {
        await runProcessCapturing(bin, args, timeout: timeout) != nil
    }

    /// Corre un proceso con TIMEOUT REAL: al vencer se mata el hijo (un ffmpeg
    /// colgado no puede dejar la subida esperando para siempre).
    ///
    /// GOTCHA: el stderr va a un ARCHIVO, no a un Pipe. ffmpeg escribe mucho por
    /// stderr y un Pipe que nadie drena se llena a los ~64KB y BLOQUEA a ffmpeg
    /// para siempre — el mismo pie con el que ya tropezamos en Uploader.run.
    private static func runProcessCapturing(_ bin: String, _ args: [String], timeout: Double) async -> String? {
        let fm = FileManager.default
        let errFile = fm.temporaryDirectory.appendingPathComponent("sfcast-err-\(UUID().uuidString).log")
        fm.createFile(atPath: errFile.path, contents: nil)
        let errHandle = try? FileHandle(forWritingTo: errFile)
        defer { try? errHandle?.close(); try? fm.removeItem(at: errFile) }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errHandle ?? FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice

        let once = OnceFlag()
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            p.terminationHandler = { proc in
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                if proc.terminationStatus != 0,
                   let err = try? String(contentsOf: errFile, encoding: .utf8), !err.isEmpty {
                    Log.error("Transcoder \(URL(fileURLWithPath: bin).lastPathComponent): \(err.suffix(400))")
                }
                if once.claim() {
                    cont.resume(returning: proc.terminationStatus == 0
                                ? (String(data: data, encoding: .utf8) ?? "") : nil)
                }
            }
            do { try p.run() } catch {
                if once.claim() { cont.resume(returning: nil) }
                return
            }
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if p.isRunning {
                    Log.error("Transcoder: \(URL(fileURLWithPath: bin).lastPathComponent) rebasó \(Int(timeout))s — matándolo")
                    p.terminate()
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if p.isRunning { kill(p.processIdentifier, SIGKILL) }
                }
            }
        }
    }
}
