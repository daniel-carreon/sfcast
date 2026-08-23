// make-icon.swift — genera el iconset de SFCast (anillo + punto mostaza sobre
// titanium, misma marca que el icono del menu bar). Uso:
//   swift scripts/make-icon.swift /tmp/SFCast.iconset
//   iconutil -c icns /tmp/SFCast.iconset -o assets/SFCast.icns
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1
                 ? CommandLine.arguments[1] : "SFCast.iconset")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let sizes: [(Int, String)] = [
    (16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"),
    (128, "128x128"), (256, "128x128@2x"), (256, "256x256"), (512, "256x256@2x"),
    (512, "512x512"), (1024, "512x512@2x"),
]

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let s = CGFloat(px)
    let rect = NSRect(x: 0, y: 0, width: s, height: s)
    let radius = s * 0.2237   // squircle macOS

    // fondo titanium con gradiente sutil
    let bg = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    NSGradient(colors: [
        NSColor(calibratedRed: 0.115, green: 0.125, blue: 0.145, alpha: 1),
        NSColor(calibratedRed: 0.043, green: 0.047, blue: 0.055, alpha: 1),
    ])!.draw(in: bg, angle: -90)

    // borde superior con luz
    NSColor(calibratedWhite: 1, alpha: 0.09).setStroke()
    let inner = NSBezierPath(roundedRect: rect.insetBy(dx: s * 0.01, dy: s * 0.01),
                             xRadius: radius, yRadius: radius)
    inner.lineWidth = max(1, s * 0.006)
    inner.stroke()

    let mostaza = NSColor(srgbRed: 1.0, green: 0.567, blue: 0.004, alpha: 1)   // #ff9101 sRGB: calibratedRGB lo desviaba

    // halo suave detrás del anillo (glow de marca)
    if px >= 64 {
        let halo = NSBezierPath(ovalIn: rect.insetBy(dx: s * 0.22, dy: s * 0.22))
        mostaza.withAlphaComponent(0.16).setStroke()
        halo.lineWidth = s * 0.11
        halo.stroke()
    }

    // anillo REC
    let ring = NSBezierPath(ovalIn: rect.insetBy(dx: s * 0.26, dy: s * 0.26))
    mostaza.setStroke()
    ring.lineWidth = s * 0.058
    ring.stroke()

    // punto central
    mostaza.setFill()
    NSBezierPath(ovalIn: rect.insetBy(dx: s * 0.405, dy: s * 0.405)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (px, name) in sizes {
    try! render(px).write(to: outDir.appendingPathComponent("icon_\(name).png"))
}
print("iconset OK → \(outDir.path)")
