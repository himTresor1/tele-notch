// Draws the background for the TeleNotch disk image window (660×420 points, written at 1× and 2×).
// Usage: swift scripts/dmg-background.swift <out-dir>
import AppKit

let W: CGFloat = 660, H: CGFloat = 420
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

func render(scale: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    // Finder draws the background with a top-left origin; flip so y grows downward like Finder's icon positions.
    ctx.translateBy(x: 0, y: H); ctx.scaleBy(x: 1, y: -1)

    NSColor.white.setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()

    // Soft teal glow behind the two icons
    let teal = NSColor(red: 0.08, green: 0.72, blue: 0.65, alpha: 1)
    let glow = NSGradient(colorsAndLocations: (teal.withAlphaComponent(0.16), 0), (teal.withAlphaComponent(0.06), 0.45),
                          (teal.withAlphaComponent(0), 0.75))!
    glow.draw(fromCenter: NSPoint(x: W / 2, y: 170), radius: 0, toCenter: NSPoint(x: W / 2, y: 170), radius: 300, options: [])

    func text(_ s: String, _ y: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
        let p = NSMutableParagraphStyle(); p.alignment = .center
        let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: p]
        NSGraphicsContext.saveGraphicsState()
        // Text needs an unflipped context to read the right way up.
        let t = NSAffineTransform(); t.translateX(by: 0, yBy: H); t.scaleX(by: 1, yBy: -1); t.concat()
        (s as NSString).draw(in: NSRect(x: 30, y: H - y - size * 1.4, width: W - 60, height: size * 1.6), withAttributes: a)
        NSGraphicsContext.restoreGraphicsState()
    }

    text("Drag TeleNotch into Applications", 30, size: 20, weight: .bold, color: NSColor(white: 0.07, alpha: 1))

    // Arrow between the app (x≈170) and Applications (x≈490), icons centred at y≈170
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 262, y: 170)); arrow.line(to: NSPoint(x: 388, y: 170))
    arrow.lineWidth = 3; arrow.lineCapStyle = .round
    NSColor(red: 0.08, green: 0.6, blue: 0.55, alpha: 1).setStroke(); arrow.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 376, y: 158)); head.line(to: NSPoint(x: 392, y: 170)); head.line(to: NSPoint(x: 376, y: 182))
    head.lineWidth = 3; head.lineCapStyle = .round; head.lineJoinStyle = .round; head.stroke()

    // First-launch help card
    let card = NSBezierPath(roundedRect: NSRect(x: 60, y: 282, width: W - 120, height: 108), xRadius: 14, yRadius: 14)
    NSColor(white: 0.955, alpha: 1).setFill(); card.fill()
    text("First time opening it?", 296, size: 13, weight: .semibold, color: NSColor(white: 0.1, alpha: 1))
    text("If macOS says “TeleNotch” Not Opened, click Done, then open", 320, size: 12, weight: .regular, color: NSColor(white: 0.3, alpha: 1))
    text("System Settings → Privacy & Security, scroll down, and click Open Anyway.", 338, size: 12, weight: .regular, color: NSColor(white: 0.3, alpha: 1))
    text("You only do this once. Updates install by themselves.", 362, size: 11, weight: .regular, color: NSColor(white: 0.5, alpha: 1))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try! render(scale: 1).write(to: URL(fileURLWithPath: "\(out)/background.png"))
try! render(scale: 2).write(to: URL(fileURLWithPath: "\(out)/background@2x.png"))
print("wrote \(out)/background.png and background@2x.png")
