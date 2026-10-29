// Draws the Loomo disk image's window background: a soft gradient, an arrow from the app to the Applications
// shortcut, and one line of instructions. Run: swift Design/DMG/make-background.swift (writes background.tiff,
// with 1x and 2x images). The layout matches scripts/make-dmg.sh: a 560×340 window, icons centred at
// (140, 160) and (420, 160).
import AppKit

let size = NSSize(width: 560, height: 340)
let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Design/DMG/background.tiff")

func render(scale: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // Finder's coordinates run from the top; AppKit's from the bottom.
    func y(_ top: CGFloat) -> CGFloat { size.height - top }

    NSGradient(starting: NSColor(srgbRed: 0.98, green: 0.98, blue: 0.99, alpha: 1),
               ending: NSColor(srgbRed: 0.91, green: 0.93, blue: 0.96, alpha: 1))!
        .draw(in: NSRect(origin: .zero, size: size), angle: -90)

    // Arrow between the icons: a dashed shaft and a solid head.
    let accent = NSColor(srgbRed: 0.20, green: 0.45, blue: 0.90, alpha: 0.85)
    let shaft = NSBezierPath()
    shaft.move(to: NSPoint(x: 222, y: y(160)))
    shaft.line(to: NSPoint(x: 326, y: y(160)))
    shaft.lineWidth = 5
    shaft.lineCapStyle = .round
    shaft.setLineDash([2, 11], count: 2, phase: 0)
    accent.setStroke()
    shaft.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 344, y: y(160)))
    head.line(to: NSPoint(x: 324, y: y(147)))
    head.line(to: NSPoint(x: 324, y: y(173)))
    head.close()
    head.lineJoinStyle = .round
    head.lineWidth = 4
    accent.setFill()
    head.fill()
    head.stroke()

    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let title = NSAttributedString(string: "Drag Loomo to Applications to install", attributes: [
        .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
        .foregroundColor: NSColor(srgbRed: 0.15, green: 0.17, blue: 0.22, alpha: 1),
        .paragraphStyle: style,
    ])
    title.draw(in: NSRect(x: 0, y: y(282), width: size.width, height: 22))
    let note = NSAttributedString(string: "Then open Loomo from your Applications folder.", attributes: [
        .font: NSFont.systemFont(ofSize: 12),
        .foregroundColor: NSColor(srgbRed: 0.40, green: 0.43, blue: 0.50, alpha: 1),
        .paragraphStyle: style,
    ])
    note.draw(in: NSRect(x: 0, y: y(304), width: size.width, height: 18))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let image = NSImage(size: size)
image.addRepresentation(render(scale: 1))
image.addRepresentation(render(scale: 2))
let data = NSBitmapImageRep.representationOfImageReps(in: image.representations, using: .tiff, properties: [.compressionMethod: NSBitmapImageRep.TIFFCompression.lzw.rawValue])!
try data.write(to: out)
print("Wrote \(out.path)")
