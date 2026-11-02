// Dibuja el icono de NX Build (logo A: mando partido en dos mitades) y genera Assets/AppIcon.icns.
// Uso: swift Tools/make_icon.swift   (desde la raíz del repo)
import AppKit

func color(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}

/// Mismo dibujo que el diseño (viewBox 300×300) en un lienzo de `px`, con el cuerpo del icono en la rejilla de macOS
/// (824 de 1024, centrado).
func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    let k = CGFloat(px) / 1024
    let s = 824.0 / 280.0 * k
    ctx.translateBy(x: 0, y: CGFloat(px)); ctx.scaleBy(x: 1, y: -1)               // coordenadas como en SVG
    ctx.translateBy(x: 100 * k - 10 * s, y: 100 * k - 10 * s); ctx.scaleBy(x: s, y: s)

    let body = CGPath(roundedRect: CGRect(x: 10, y: 10, width: 280, height: 280), cornerWidth: 64, cornerHeight: 64, transform: nil)
    ctx.addPath(body); ctx.setFillColor(color(0x1e2129)); ctx.fillPath()

    func half(left: Bool) -> CGPath {
        let p = CGMutablePath(), r: CGFloat = 54
        if left {
            p.move(to: CGPoint(x: 150, y: 58)); p.addLine(to: CGPoint(x: 112, y: 58))
            p.addArc(tangent1End: CGPoint(x: 58, y: 58), tangent2End: CGPoint(x: 58, y: 112), radius: r)
            p.addLine(to: CGPoint(x: 58, y: 188))
            p.addArc(tangent1End: CGPoint(x: 58, y: 242), tangent2End: CGPoint(x: 112, y: 242), radius: r)
            p.addLine(to: CGPoint(x: 150, y: 242))
        } else {
            p.move(to: CGPoint(x: 150, y: 58)); p.addLine(to: CGPoint(x: 188, y: 58))
            p.addArc(tangent1End: CGPoint(x: 242, y: 58), tangent2End: CGPoint(x: 242, y: 112), radius: r)
            p.addLine(to: CGPoint(x: 242, y: 188))
            p.addArc(tangent1End: CGPoint(x: 242, y: 242), tangent2End: CGPoint(x: 188, y: 242), radius: r)
            p.addLine(to: CGPoint(x: 150, y: 242))
        }
        p.closeSubpath(); return p
    }
    ctx.addPath(half(left: true)); ctx.setFillColor(color(0x2ee6c5)); ctx.fillPath()
    ctx.addPath(half(left: false)); ctx.setFillColor(color(0xeef1f6)); ctx.fillPath()
    ctx.setFillColor(color(0x1e2129)); ctx.fill(CGRect(x: 146, y: 58, width: 8, height: 184))

    func dot(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ c: UInt32) {
        ctx.setFillColor(color(c)); ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
    }
    dot(104, 118, 16, 0x0b1a17)                                       // stick
    ctx.setFillColor(color(0x0b1a17))                                 // cruceta
    ctx.fill(CGRect(x: 98, y: 176, width: 12, height: 36)); ctx.fill(CGRect(x: 86, y: 188, width: 36, height: 12))
    dot(196, 182, 16, 0x14161b)                                       // stick
    for (x, y) in [(196.0, 118.0), (220, 140), (172, 140)] { dot(x, y, 8, 0x14161b) }   // botones

    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let set = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: set); try! fm.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: set.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: set.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try! render(1024).write(to: URL(fileURLWithPath: "Assets/AppIcon.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", "Assets/AppIcon.icns"]
try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "Assets/AppIcon.icns" : "iconutil falló")
