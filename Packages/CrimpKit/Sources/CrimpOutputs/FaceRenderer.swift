import CoreGraphics
import CrimpCore
import Foundation

/// Draws a `FaceDrawing` into a y-down CoreGraphics context (screen or PDF). SVG export uses the same primitives.
public enum FaceRenderer {
    public static func draw(_ d: FaceDrawing, in cg: CGContext) {
        for p in d.primitives {
            switch p {
            case let .rect(x, y, w, h, r, fill, stroke, lw):
                let path = CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil)
                paint(cg, path, fill, stroke, lw)
            case let .circle(cx, cy, r, fill, stroke, lw):
                paint(cg, CGPath(ellipseIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r), transform: nil), fill, stroke, lw)
            case let .stripe(cx, cy, r, c):
                cg.saveGState()
                cg.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
                cg.clip()
                cg.translateBy(x: cx, y: cy)
                cg.rotate(by: -35 * .pi / 180)
                cg.setFillColor(color(c))
                cg.fill(CGRect(x: -r, y: -r * 0.28, width: 2 * r, height: r * 0.56))
                cg.restoreGState()
            case let .hatch(cx, cy, r, c):
                cg.saveGState()
                cg.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
                cg.clip()
                cg.setStrokeColor(color(c))
                cg.setLineWidth(1)
                var dx = -2 * r
                while dx <= 2 * r {
                    cg.move(to: CGPoint(x: cx + dx - r, y: cy + r))
                    cg.addLine(to: CGPoint(x: cx + dx + r, y: cy - r))
                    dx += max(r / 2.5, 2)
                }
                cg.strokePath()
                cg.restoreGState()
            case let .rightHalf(cx, cy, r, c):
                cg.saveGState()
                cg.move(to: CGPoint(x: cx, y: cy - r))
                cg.addArc(center: CGPoint(x: cx, y: cy), radius: r, startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: false)
                cg.closePath()
                cg.setFillColor(color(c))
                cg.fillPath()
                cg.restoreGState()
            case let .image(data, x, y, w, h, mirrored):
                guard let img = ConnectorImageCache.image(data) else { break }
                cg.saveGState()
                cg.translateBy(x: mirrored ? x + w : x, y: y + h)
                cg.scaleBy(x: mirrored ? -1 : 1, y: -1)
                cg.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
                cg.restoreGState()
            case let .text(x, y, s, size, c, bold, anchor):
                let align: TextDraw.Align = switch anchor { case .start: .left; case .middle: .center; case .end: .right }
                // SVG text y is the baseline; TextDraw takes the top of the line.
                TextDraw.draw(s, in: cg, at: CGPoint(x: x, y: y - size * 0.8), size: size, bold: bold, color: color(c), align: align)
            }
        }
    }

    private static func paint(_ cg: CGContext, _ path: CGPath, _ fill: String?, _ stroke: String?, _ lw: Double) {
        if let fill {
            cg.addPath(path)
            cg.setFillColor(color(fill))
            cg.fillPath()
        }
        if let stroke, lw > 0 {
            cg.addPath(path)
            cg.setStrokeColor(color(stroke))
            cg.setLineWidth(lw)
            cg.strokePath()
        }
    }
}
