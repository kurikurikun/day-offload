// Renders AppIcon.icns: ./Icon/make.sh
import AppKit

func render(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let k = CGFloat(px) / 1024
    NSGraphicsContext.current!.cgContext.scaleBy(x: k, y: k)

    // Big Sur grid: 824x824 squircle centred on a 1024 canvas
    let squircle = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    NSGradient(colors: [NSColor(calibratedRed: 0.10, green: 0.16, blue: 0.32, alpha: 1),
                        NSColor(calibratedRed: 0.20, green: 0.08, blue: 0.30, alpha: 1)])!
        .draw(in: squircle, angle: -60)

    func symbol(_ name: String, _ size: CGFloat, _ color: NSColor, _ center: NSPoint, _ weight: NSFont.Weight = .semibold) {
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return }
        let tinted = NSImage(size: img.size, flipped: false) { r in
            img.draw(in: r); color.set(); r.fill(using: .sourceAtop); return true
        }
        let s = tinted.size
        tinted.draw(in: NSRect(x: center.x - s.width / 2, y: center.y - s.height / 2, width: s.width, height: s.height))
    }
    symbol("sdcard.fill", 420, NSColor.white.withAlphaComponent(0.95), NSPoint(x: 470, y: 540))
    // amber badge: a copy going down to a drive
    let badge = NSBezierPath(ovalIn: NSRect(x: 560, y: 190, width: 300, height: 300))
    NSColor(calibratedRed: 0.22, green: 0.12, blue: 0.34, alpha: 1).setFill(); badge.fill()
    let inner = NSBezierPath(ovalIn: NSRect(x: 585, y: 215, width: 250, height: 250))
    NSColor(calibratedRed: 1.0, green: 0.76, blue: 0.20, alpha: 1).setFill(); inner.fill()
    symbol("arrow.down", 150, NSColor(calibratedRed: 0.12, green: 0.10, blue: 0.26, alpha: 1), NSPoint(x: 710, y: 340), .heavy)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
