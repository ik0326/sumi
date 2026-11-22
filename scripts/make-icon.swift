// Draws the Sumi app icon.  Usage: swift scripts/make-icon.swift <output.png> [stroke|dot|letter]
import AppKit

let variant = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "letter"
let size: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// macOS icon grid: an 824 pt rounded square centred in a 1024 pt canvas.
let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: plate, cornerWidth: 186, cornerHeight: 186, transform: nil)
let paper = NSColor(red: 0.975, green: 0.97, blue: 0.955, alpha: 1)
let ink = NSColor(red: 0.09, green: 0.09, blue: 0.10, alpha: 1)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.28).cgColor)
ctx.addPath(shape)
ctx.setFillColor(paper.cgColor)
ctx.fillPath()
ctx.restoreGState()

ctx.setFillColor(ink.cgColor)
switch variant {
case "dot":
    // One drop of ink on paper.
    ctx.fillEllipse(in: CGRect(x: 512 - 150, y: 512 - 150, width: 300, height: 300))
case "stroke":
    // A single brush stroke: full where the brush lands, thinning as it lifts.
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 268, y: 470))
    p.addCurve(to: CGPoint(x: 330, y: 566), control1: CGPoint(x: 250, y: 520), control2: CGPoint(x: 282, y: 566))
    p.addCurve(to: CGPoint(x: 772, y: 548), control1: CGPoint(x: 470, y: 566), control2: CGPoint(x: 640, y: 528))
    p.addCurve(to: CGPoint(x: 762, y: 520), control1: CGPoint(x: 786, y: 544), control2: CGPoint(x: 780, y: 524))
    p.addCurve(to: CGPoint(x: 330, y: 450), control1: CGPoint(x: 630, y: 486), control2: CGPoint(x: 470, y: 452))
    p.addCurve(to: CGPoint(x: 268, y: 470), control1: CGPoint(x: 300, y: 448), control2: CGPoint(x: 276, y: 452))
    p.closeSubpath()
    ctx.addPath(p)
    ctx.fillPath()
default:
    // The letter S in the system font.
    let font = NSFont.systemFont(ofSize: 520, weight: .semibold)
    let text = NSAttributedString(string: "S", attributes: [.font: font, .foregroundColor: ink])
    let box = text.size()
    text.draw(at: NSPoint(x: (size - box.width) / 2, y: (size - box.height) / 2 + 8))
}

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
