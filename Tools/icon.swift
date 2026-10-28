import AppKit

// Draws the 1024 px app icon: three balls orbiting on a dark squircle. Usage: swift Tools/icon.swift out.png
let size: CGFloat = 1024
func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Apple's icon grid: 824 px body, 100 px margin, soft shadow.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let squircle = NSBezierPath(roundedRect: body, xRadius: 186, yRadius: 186)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = .black.withAlphaComponent(0.35)
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.shadowBlurRadius = 28
shadow.set()
rgb(0x1C1917).setFill()
squircle.fill()
NSGraphicsContext.restoreGraphicsState()
NSGradient(colors: [rgb(0x2E2824), rgb(0x161311)])!.draw(in: squircle, angle: -90)

// The orbit, faint and dotted.
let center = NSPoint(x: 512, y: 500), orbit: CGFloat = 230
let path = NSBezierPath(ovalIn: NSRect(x: center.x - orbit, y: center.y - orbit, width: 2 * orbit, height: 2 * orbit))
path.lineWidth = 16
path.lineCapStyle = .round
path.setLineDash([2, 44], count: 2, phase: 0)
rgb(0xF2E8DC, 0.28).setStroke()
path.stroke()

// Three balls evenly spaced on the orbit, each lit from the top left.
func ball(_ angle: CGFloat, _ r: CGFloat, _ color: NSColor) {
    let a = angle * .pi / 180
    let c = NSPoint(x: center.x + orbit * cos(a), y: center.y + orbit * sin(a))
    let rect = NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
    NSGraphicsContext.saveGraphicsState()
    let s = NSShadow()
    s.shadowColor = .black.withAlphaComponent(0.4)
    s.shadowOffset = NSSize(width: 0, height: -14)
    s.shadowBlurRadius = 24
    s.set()
    color.setFill()
    NSBezierPath(ovalIn: rect).fill()
    NSGraphicsContext.restoreGraphicsState()
    let shine = NSGradient(colors: [.white.withAlphaComponent(0.45), .white.withAlphaComponent(0)])!
    shine.draw(in: NSBezierPath(ovalIn: rect), relativeCenterPosition: NSPoint(x: -0.4, y: 0.45))
}
ball(210, 104, rgb(0xE9B872))  // sand
ball(330, 104, rgb(0xF2E8DC))  // cream
ball(90, 116, rgb(0xD9774F))   // terracotta, at the top of the throw

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
