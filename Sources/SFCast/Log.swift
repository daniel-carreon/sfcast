import Foundation

enum Log {
    static let path = NSString(string: "~/Library/Logs/sfcast.log").expandingTildeInPath

    static func info(_ msg: String) {
        let line = "[\(Self.stamp())] \(msg)"
        print(line)
        append(line)
    }

    static func error(_ msg: String) {
        let line = "[\(Self.stamp())] ERROR: \(msg)"
        FileHandle.standardError.write((line + "\n").data(using: .utf8)!)
        append(line)
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date())
    }

    private static func append(_ line: String) {
        let data = (line + "\n").data(using: .utf8)!
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}

func makeVideoID() -> String {
    let chars = Array("abcdefghijklmnopqrstuvwxyz0123456789")
    return String((0..<12).map { _ in chars.randomElement()! })
}

func notify(_ title: String, _ body: String) {
    // osascript: cero dramas de TCC/bundle para notificaciones (patrón headless).
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    let esc = { (s: String) in s.replacingOccurrences(of: "\"", with: "\\\"") }
    p.arguments = ["-e", "display notification \"\(esc(body))\" with title \"\(esc(title))\""]
    try? p.run()
}
