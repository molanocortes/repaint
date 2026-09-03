import AppKit

/// Windows 7-era ribbon chrome: pale blue gradients, thin cool-grey rules,
/// and a light blue wash for hovered or active controls.
enum Chrome {
    static let quickBarTop = NSColor(srgbRed: 0.855, green: 0.902, blue: 0.953, alpha: 1)
    static let quickBarBottom = NSColor(srgbRed: 0.780, green: 0.851, blue: 0.929, alpha: 1)
    static let tabStrip = NSColor(srgbRed: 0.898, green: 0.933, blue: 0.973, alpha: 1)
    static let ribbonFace = NSColor.white
    static let ribbonBottom = NSColor(srgbRed: 0.937, green: 0.957, blue: 0.980, alpha: 1)
    static let rule = NSColor(srgbRed: 0.784, green: 0.827, blue: 0.878, alpha: 1)
    static let groupLabel = NSColor(srgbRed: 0.35, green: 0.40, blue: 0.46, alpha: 1)
    static let hoverFill = NSColor(srgbRed: 0.855, green: 0.925, blue: 0.988, alpha: 1)
    static let hoverBorder = NSColor(srgbRed: 0.494, green: 0.678, blue: 0.851, alpha: 1)
    static let selectedFill = NSColor(srgbRed: 0.792, green: 0.882, blue: 0.976, alpha: 1)
    static let selectedBorder = NSColor(srgbRed: 0.365, green: 0.573, blue: 0.792, alpha: 1)
    static let fileTab = NSColor(srgbRed: 0.106, green: 0.396, blue: 0.702, alpha: 1)
    static let ink = NSColor(srgbRed: 0.13, green: 0.15, blue: 0.18, alpha: 1)
    static let shapeInk = NSColor(srgbRed: 0.15, green: 0.35, blue: 0.62, alpha: 1)
    static let canvasBack = NSColor(srgbRed: 0.75, green: 0.79, blue: 0.84, alpha: 1)
    static let statusFace = NSColor(srgbRed: 0.937, green: 0.957, blue: 0.980, alpha: 1)

    static func vGradient(_ rect: NSRect, _ top: NSColor, _ bottom: NSColor) {
        NSGradient(starting: top, ending: bottom)?.draw(in: rect, angle: -90)
    }

    enum ControlState { case normal, hover, selected }

    /// Flat ribbon button: nothing at rest, a light blue wash when live.
    static func drawControl(_ rect: NSRect, _ state: ControlState, radius: CGFloat = 3) {
        guard state != .normal else { return }
        let fill = state == .selected ? selectedFill : hoverFill
        let border = state == .selected ? selectedBorder : hoverBorder
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: radius, yRadius: radius)
        fill.setFill(); path.fill()
        border.setStroke(); path.lineWidth = 1; path.stroke()
    }

    static func label(_ text: String, in rect: NSRect, size: CGFloat = 11,
                      color: NSColor = Chrome.ink, align: NSTextAlignment = .center) {
        let ps = NSMutableParagraphStyle()
        ps.alignment = align
        ps.lineBreakMode = .byClipping
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size),
            .foregroundColor: color,
            .paragraphStyle: ps
        ]
        NSString(string: text).draw(in: rect, withAttributes: attrs)
    }

    /// The small ▾ under split buttons.
    static func chevron(at point: NSPoint, size: CGFloat = 4, color: NSColor = Chrome.ink) {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: point.x - size, y: point.y - size / 2))
        p.line(to: NSPoint(x: point.x + size, y: point.y - size / 2))
        p.line(to: NSPoint(x: point.x, y: point.y + size / 2 + 1))
        p.close()
        color.setFill()
        p.fill()
    }
}

/// Glyphs for the ribbon. Everything is drawn; there are no image assets.
enum Glyph {
    /// Icons are described bottom-up, so mirror them for the flipped ribbon.
    private static func flipped(_ rect: NSRect, _ body: () -> Void) {
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.saveGState()
        ctx.translateBy(x: 0, y: rect.midY * 2)
        ctx.scaleBy(x: 1, y: -1)
        body()
        ctx.restoreGState()
    }

    static func tool(_ tool: Tool, in rect: NSRect) {
        if tool == .text {
            let s = NSAttributedString(string: "A", attributes: [
                .font: NSFont.systemFont(ofSize: rect.height * 0.86, weight: .medium),
                .foregroundColor: Chrome.ink])
            s.draw(at: NSPoint(x: rect.midX - s.size().width / 2,
                               y: rect.midY - s.size().height / 2))
            return
        }
        flipped(rect) { drawToolBody(tool, in: rect.insetBy(dx: 1, dy: 1)) }
    }

    private static func drawToolBody(_ tool: Tool, in r: NSRect) {
        let ink = Chrome.ink
        switch tool {
        case .pencil:
            // Yellow barrel, graphite tip, pointing down-left.
            let body = NSBezierPath()
            body.move(to: NSPoint(x: r.minX + 1, y: r.minY + 1))
            body.line(to: NSPoint(x: r.minX + 3.5, y: r.minY + 5))
            body.line(to: NSPoint(x: r.maxX - 1, y: r.maxY - 1.5))
            body.line(to: NSPoint(x: r.maxX - 4, y: r.maxY - 4.5))
            body.close()
            NSColor(srgbRed: 0.97, green: 0.80, blue: 0.30, alpha: 1).setFill()
            body.fill()
            ink.setStroke(); body.lineWidth = 1; body.stroke()
            let tip = NSBezierPath()
            tip.move(to: NSPoint(x: r.minX + 1, y: r.minY + 1))
            tip.line(to: NSPoint(x: r.minX + 3.5, y: r.minY + 5))
            tip.line(to: NSPoint(x: r.minX + 5, y: r.minY + 3))
            tip.close()
            ink.setFill(); tip.fill()

        case .fill:
            let bucket = NSBezierPath()
            bucket.move(to: NSPoint(x: r.minX + 2, y: r.midY))
            bucket.line(to: NSPoint(x: r.midX + 1.5, y: r.maxY - 1))
            bucket.line(to: NSPoint(x: r.maxX - 1, y: r.midY + 1.5))
            bucket.line(to: NSPoint(x: r.midX + 2, y: r.minY + 2))
            bucket.close()
            NSColor(srgbRed: 0.42, green: 0.62, blue: 0.86, alpha: 1).setFill()
            bucket.fill()
            ink.setStroke(); bucket.lineWidth = 1; bucket.stroke()
            NSColor(srgbRed: 0.20, green: 0.42, blue: 0.75, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: r.minX, y: r.minY, width: 4, height: 5)).fill()

        case .eraser:
            let block = NSBezierPath()
            block.move(to: NSPoint(x: r.minX + 1, y: r.minY + 4))
            block.line(to: NSPoint(x: r.midX + 1, y: r.minY + 1))
            block.line(to: NSPoint(x: r.maxX - 1, y: r.maxY - 4))
            block.line(to: NSPoint(x: r.midX - 1, y: r.maxY - 1))
            block.close()
            NSColor(srgbRed: 0.95, green: 0.70, blue: 0.72, alpha: 1).setFill()
            block.fill()
            ink.setStroke(); block.lineWidth = 1; block.stroke()

        case .pickColor:
            let p = NSBezierPath()
            p.lineWidth = 1.6
            ink.setStroke()
            p.move(to: NSPoint(x: r.minX + 1, y: r.minY + 1))
            p.line(to: NSPoint(x: r.maxX - 4, y: r.maxY - 4))
            p.stroke()
            NSColor(srgbRed: 0.42, green: 0.62, blue: 0.86, alpha: 1).setFill()
            let bulb = NSBezierPath(ovalIn: NSRect(x: r.maxX - 6, y: r.maxY - 6,
                                                   width: 5.5, height: 5.5))
            bulb.fill()
            ink.setStroke(); bulb.lineWidth = 1; bulb.stroke()

        case .magnifier:
            let lens = NSBezierPath(ovalIn: NSRect(x: r.minX + 1, y: r.minY + 4,
                                                   width: r.width - 6, height: r.height - 6))
            NSColor(srgbRed: 0.85, green: 0.93, blue: 1.0, alpha: 1).setFill()
            lens.fill()
            ink.setStroke(); lens.lineWidth = 1.4; lens.stroke()
            let handle = NSBezierPath()
            handle.lineWidth = 2
            handle.move(to: NSPoint(x: r.maxX - 6, y: r.minY + 5))
            handle.line(to: NSPoint(x: r.maxX - 1, y: r.minY))
            handle.stroke()

        case .brush:
            let stick = NSBezierPath()
            stick.lineWidth = 2.2
            NSColor(srgbRed: 0.55, green: 0.38, blue: 0.22, alpha: 1).setStroke()
            stick.move(to: NSPoint(x: r.midX, y: r.midY))
            stick.line(to: NSPoint(x: r.maxX - 1, y: r.maxY - 1))
            stick.stroke()
            let head = NSBezierPath()
            head.move(to: NSPoint(x: r.minX + 1, y: r.minY + 1))
            head.line(to: NSPoint(x: r.midX + 2, y: r.midY - 1))
            head.line(to: NSPoint(x: r.midX - 1, y: r.midY + 2))
            head.close()
            NSColor(srgbRed: 0.20, green: 0.42, blue: 0.75, alpha: 1).setFill()
            head.fill()

        case .airbrush:
            let can = NSBezierPath(rect: NSRect(x: r.minX + 1, y: r.minY, width: 5.5, height: 9))
            NSColor(srgbRed: 0.80, green: 0.86, blue: 0.93, alpha: 1).setFill(); can.fill()
            ink.setStroke(); can.lineWidth = 1; can.stroke()
            ink.setFill()
            for i in 0..<6 {
                NSBezierPath(ovalIn: NSRect(x: r.minX + 8 + CGFloat(i % 3) * 3,
                                            y: r.minY + 5 + CGFloat(i / 3) * 4,
                                            width: 1.7, height: 1.7)).fill()
            }

        case .select, .freeFormSelect:
            let p = tool == .select
                ? NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5))
                : freeFormPath(r)
            p.lineWidth = 1
            let dash: [CGFloat] = [2, 2]
            p.setLineDash(dash, count: 2, phase: 0)
            ink.setStroke(); p.stroke()

        default:
            // Shapes and anything else share the gallery stroke.
            shape(tool, in: r, color: ink)
        }
    }

    private static func freeFormPath(_ r: NSRect) -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: r.minX + 1, y: r.midY))
        p.curve(to: NSPoint(x: r.maxX - 1, y: r.midY + 1),
                controlPoint1: NSPoint(x: r.minX + 2, y: r.maxY + 2),
                controlPoint2: NSPoint(x: r.maxX - 3, y: r.maxY))
        p.curve(to: NSPoint(x: r.minX + 1, y: r.midY),
                controlPoint1: NSPoint(x: r.maxX, y: r.minY - 1),
                controlPoint2: NSPoint(x: r.minX + 2, y: r.minY))
        return p
    }

    /// A Shapes-gallery glyph: the same path the tool will actually draw.
    static func shape(_ tool: Tool, in rect: NSRect, color: NSColor = Chrome.shapeInk) {
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.saveGState()
        ctx.setShouldAntialias(true)
        color.setStroke()
        let r = rect.insetBy(dx: 1.5, dy: 1.5)
        switch tool {
        case .line:
            let p = NSBezierPath()
            p.lineWidth = 1.4
            p.move(to: NSPoint(x: r.minX, y: r.maxY))
            p.line(to: NSPoint(x: r.maxX, y: r.minY))
            p.stroke()
        case .curve:
            let p = NSBezierPath()
            p.lineWidth = 1.4
            p.move(to: NSPoint(x: r.minX, y: r.midY))
            p.curve(to: NSPoint(x: r.maxX, y: r.midY),
                    controlPoint1: NSPoint(x: r.minX + r.width * 0.3, y: r.maxY + 3),
                    controlPoint2: NSPoint(x: r.maxX - r.width * 0.3, y: r.minY - 3))
            p.stroke()
        case .polygon:
            let p = NSBezierPath()
            p.lineWidth = 1.2
            p.move(to: NSPoint(x: r.minX, y: r.minY + 1))
            p.line(to: NSPoint(x: r.midX - 1, y: r.maxY))
            p.line(to: NSPoint(x: r.maxX, y: r.midY))
            p.line(to: NSPoint(x: r.maxX - 2, y: r.minY))
            p.close()
            p.stroke()
        default:
            let cg = CanvasView.shapePath(tool, in: r)
            ctx.addPath(cg)
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(1.2)
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    // MARK: - Ribbon command glyphs

    static func paste(in rect: NSRect) {
        flipped(rect) {
            let r = rect.insetBy(dx: 3, dy: 2)
            let board = NSBezierPath(roundedRect: NSRect(x: r.minX, y: r.minY,
                                                         width: r.width, height: r.height - 3),
                                     xRadius: 2, yRadius: 2)
            NSColor(srgbRed: 0.82, green: 0.63, blue: 0.36, alpha: 1).setFill(); board.fill()
            Chrome.ink.setStroke(); board.lineWidth = 1; board.stroke()
            let sheet = NSRect(x: r.minX + 3, y: r.minY + 3, width: r.width - 6, height: r.height - 9)
            NSColor.white.setFill(); sheet.fill()
            Chrome.ink.setStroke(); NSBezierPath(rect: sheet.insetBy(dx: 0.5, dy: 0.5)).stroke()
            let clip = NSRect(x: r.midX - 3.5, y: r.maxY - 6, width: 7, height: 5)
            NSColor(srgbRed: 0.62, green: 0.66, blue: 0.71, alpha: 1).setFill(); clip.fill()
        }
    }

    static func cut(in rect: NSRect) {
        flipped(rect) {
            let r = rect.insetBy(dx: 2, dy: 1)
            let p = NSBezierPath()
            p.lineWidth = 1.3
            Chrome.ink.setStroke()
            p.move(to: NSPoint(x: r.minX + 1, y: r.maxY)); p.line(to: NSPoint(x: r.maxX - 2, y: r.minY + 4))
            p.move(to: NSPoint(x: r.maxX - 2, y: r.maxY)); p.line(to: NSPoint(x: r.minX + 1, y: r.minY + 4))
            p.stroke()
            for x in [r.minX + 1.5, r.maxX - 3.5] {
                let ring = NSBezierPath(ovalIn: NSRect(x: x, y: r.minY, width: 3.6, height: 3.6))
                ring.lineWidth = 1.2; ring.stroke()
            }
        }
    }

    static func copyIcon(in rect: NSRect) {
        flipped(rect) {
            let r = rect.insetBy(dx: 3, dy: 2)
            let back = NSRect(x: r.minX, y: r.minY + 3, width: r.width - 4, height: r.height - 4)
            let front = NSRect(x: r.minX + 4, y: r.minY, width: r.width - 4, height: r.height - 4)
            for s in [back, front] {
                NSColor.white.setFill(); s.fill()
                Chrome.ink.setStroke()
                let p = NSBezierPath(rect: s.insetBy(dx: 0.5, dy: 0.5)); p.lineWidth = 1; p.stroke()
            }
        }
    }

    static func crop(in rect: NSRect) {
        flipped(rect) {
            let r = rect.insetBy(dx: 2, dy: 2)
            Chrome.ink.setStroke()
            let p = NSBezierPath()
            p.lineWidth = 1.3
            p.move(to: NSPoint(x: r.minX + 3, y: r.minY)); p.line(to: NSPoint(x: r.minX + 3, y: r.maxY - 3))
            p.line(to: NSPoint(x: r.maxX, y: r.maxY - 3))
            p.move(to: NSPoint(x: r.minX, y: r.minY + 3)); p.line(to: NSPoint(x: r.maxX - 3, y: r.minY + 3))
            p.line(to: NSPoint(x: r.maxX - 3, y: r.maxY))
            p.stroke()
        }
    }

    static func resize(in rect: NSRect) {
        flipped(rect) {
            let r = rect.insetBy(dx: 2, dy: 2)
            Chrome.ink.setStroke()
            let box = NSBezierPath(rect: NSRect(x: r.minX, y: r.minY,
                                                width: r.width * 0.6, height: r.height * 0.6))
            box.lineWidth = 1.2; box.stroke()
            let big = NSBezierPath(rect: NSRect(x: r.minX + r.width * 0.3, y: r.minY + r.height * 0.3,
                                                width: r.width * 0.7, height: r.height * 0.7))
            big.lineWidth = 1.2
            let dash: [CGFloat] = [2, 2]
            big.setLineDash(dash, count: 2, phase: 0)
            big.stroke()
        }
    }

    static func rotate(in rect: NSRect) {
        flipped(rect) {
            let r = rect.insetBy(dx: 2, dy: 2)
            let p = NSBezierPath()
            p.appendArc(withCenter: NSPoint(x: r.midX, y: r.midY),
                        radius: r.width * 0.42, startAngle: 40, endAngle: 320)
            p.lineWidth = 1.5
            Chrome.ink.setStroke(); p.stroke()
            let head = NSBezierPath()
            let tip = NSPoint(x: r.midX + cos(40 * .pi / 180) * r.width * 0.42,
                              y: r.midY + sin(40 * .pi / 180) * r.width * 0.42)
            head.move(to: NSPoint(x: tip.x - 3, y: tip.y + 1))
            head.line(to: NSPoint(x: tip.x + 2.5, y: tip.y + 2))
            head.line(to: NSPoint(x: tip.x, y: tip.y - 3.5))
            head.close()
            Chrome.ink.setFill(); head.fill()
        }
    }

    static func sizeStack(in rect: NSRect) {
        flipped(rect) {
            let r = rect.insetBy(dx: 2, dy: 2)
            NSColor(srgbRed: 0.16, green: 0.32, blue: 0.55, alpha: 1).setFill()
            var y = r.minY
            for w in [CGFloat(1), 2, 3.5, 5] {
                NSRect(x: r.minX, y: y, width: r.width, height: w).fill()
                y += w + 2.5
            }
        }
    }

    static func colorWheel(in rect: NSRect) {
        let r = rect.insetBy(dx: 1, dy: 1)
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.saveGState()
        let steps = 24
        for i in 0..<steps {
            let a0 = CGFloat(i) / CGFloat(steps) * 2 * .pi
            let a1 = CGFloat(i + 1) / CGFloat(steps) * 2 * .pi
            let wedge = NSBezierPath()
            wedge.move(to: NSPoint(x: r.midX, y: r.midY))
            wedge.appendArc(withCenter: NSPoint(x: r.midX, y: r.midY), radius: r.width / 2,
                            startAngle: a0 * 180 / .pi, endAngle: a1 * 180 / .pi)
            wedge.close()
            NSColor(hue: CGFloat(i) / CGFloat(steps), saturation: 0.85,
                    brightness: 0.95, alpha: 1).setFill()
            wedge.fill()
        }
        ctx.restoreGState()
    }
}
