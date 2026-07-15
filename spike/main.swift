// SFCast SPIKE #1 — prueba TCC + SCRecordingOutput sin Apple Developer Program.
// Graba 4s del display principal a MP4 (HEVC hardware) y sale.
// Necesita NSApplication corriendo: SCK crea su status item (indicador de
// grabación) via AppKit y sin run loop de app crashea (aprendido aquí mismo).
// Uso: ./spike [ruta-salida.mp4]
import Foundation
import AppKit
import ScreenCaptureKit
import CoreMedia

final class RecDelegate: NSObject, SCRecordingOutputDelegate {
    var done = false
    func recordingOutputDidStartRecording(_ output: SCRecordingOutput) {
        print("SPIKE: grabacion INICIADA")
    }
    func recordingOutput(_ output: SCRecordingOutput, didFailWithError error: Error) {
        print("SPIKE_FAIL(recording): \(error.localizedDescription)")
        exit(2)
    }
    func recordingOutputDidFinishRecording(_ output: SCRecordingOutput) {
        print("SPIKE: grabacion FINALIZADA")
        done = true
    }
}

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/sfcast-spike.mp4"

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    print("SPIKE_FAIL: sin displays"); exit(2)
                }
                let scale = NSScreen.screens.first(where: {
                    ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
                })?.backingScaleFactor ?? 2.0

                let filter = SCContentFilter(display: display, excludingWindows: [])
                let cfg = SCStreamConfiguration()
                cfg.width = Int(CGFloat(display.width) * scale)
                cfg.height = Int(CGFloat(display.height) * scale)
                cfg.minimumFrameInterval = CMTime(value: 1, timescale: 30)
                cfg.showsCursor = true

                let stream = SCStream(filter: filter, configuration: cfg, delegate: nil)
                let recCfg = SCRecordingOutputConfiguration()
                recCfg.outputURL = URL(fileURLWithPath: outPath)
                recCfg.outputFileType = .mp4
                recCfg.videoCodecType = .hevc
                let del = RecDelegate()
                let rec = SCRecordingOutput(configuration: recCfg, delegate: del)
                try stream.addRecordingOutput(rec)   // ANTES de startCapture
                try await stream.startCapture()
                print("SPIKE: capturando \(cfg.width)x\(cfg.height) (scale \(scale)) -> \(outPath)")
                try await Task.sleep(nanoseconds: 4_000_000_000)
                try await stream.stopCapture()
                for _ in 0..<100 where !del.done {
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                print(del.done ? "SPIKE_OK" : "SPIKE_WARN: sin didFinish (archivo puede estar OK igual)")
                exit(0)
            } catch {
                let granted = CGPreflightScreenCaptureAccess()
                print("SPIKE_FAIL: \(error) | preflight=\(granted)")
                if !granted { CGRequestScreenCaptureAccess() }
                exit(2)
            }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
