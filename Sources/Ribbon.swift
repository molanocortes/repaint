import AppKit

protocol RibbonDelegate: AnyObject {
    func ribbonSelect(tool: Tool)
    func ribbonCommand(_ command: RibbonView.Command, from rect: NSRect)
    func ribbonPick(color: NSColor, secondary: Bool)
    func ribbonEditColor(slot: Int)
    func ribbonSelectTab(_ tab: Int)
}

/// The Home tab of the ribbon: Clipboard, Image, Tools, Brushes, Shapes,
/// Size, Colors — laid out and hit-tested by hand.
final class RibbonView: NSView {
    enum Command {
        case paste, cut, copy
        case selectMenu, crop, resize, rotate
        case brushesMenu, sizeMenu, outlineMenu, fillMenu
        case editColors, save, undo, redo
        case zoomIn, zoomOut, zoom100, gridlines, statusBarToggle, fullScreen
    }

    private enum Hit {
        case tool(Tool)
        case command(Command)
        case swatch(Int)
        case colorSlot(Int)
        case tab(Int)
    }

    static let height: CGFloat = 150
    private let quickBarH: CGFloat = 26
    private let tabsH: CGFloat = 24

    let state: PaintState
    weak var delegate: RibbonDelegate?
    var activeTab = 1                     // 0 File, 1 Home, 2 View

    private var regions: [(NSRect, Hit)] = []
    private var groupBounds: [(NSRect, String)] = []
    private var hovered: NSRect?

    init(state: PaintState) {
        self.state = state
        super.init(frame: NSRect(x: 0, y: 0, width: 1000, height: RibbonView.height))
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var bodyRect: NSRect {
        NSRect(x: 0, y: quickBarH + tabsH, width: bounds.width,
               height: bounds.height - quickBarH - tabsH)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        regions.removeAll()
        groupBounds.removeAll()

        drawQuickBar()
        drawTabs()

        let body = bodyRect
        Chrome.vGradient(body, Chrome.ribbonFace, Chrome.ribbonBottom)
        Chrome.rule.setFill()
        NSRect(x: 0, y: body.maxY - 1, width: bounds.width, height: 1).fill()

        // Groups are laid out left to right; each returns the x it ended at.
        var x: CGFloat = 6
        if activeTab == 2 {
            x = drawZoomGroup(startingAt: x, in: body)
            x = drawShowHide(startingAt: x, in: body)
            _ = drawDisplay(startingAt: x, in: body)
        } else {
            x = drawClipboard(startingAt: x, in: body)
            x = drawImageGroup(startingAt: x, in: body)
            x = drawTools(startingAt: x, in: body)
            x = drawBrushes(startingAt: x, in: body)
            x = drawShapes(startingAt: x, in: body)
            x = drawSize(startingAt: x, in: body)
            _ = drawColors(startingAt: x, in: body)
        }

        for (rect, name) in groupBounds {
            Chrome.label(name, in: NSRect(x: rect.minX, y: body.maxY - 16,
                                          width: rect.width, height: 13),
                         size: 10, color: Chrome.groupLabel)
            Chrome.rule.setFill()
            NSRect(x: rect.maxX + 3, y: body.minY + 4, width: 1, height: body.height - 22).fill()
        }
    }

    private func drawQuickBar() {
        let bar = NSRect(x: 0, y: 0, width: bounds.width, height: quickBarH)
        Chrome.vGradient(bar, Chrome.quickBarTop, Chrome.quickBarBottom)

        var x: CGFloat = 6
        let iconY = (quickBarH - 16) / 2
        // App badge.
        Glyph.colorWheel(in: NSRect(x: x, y: iconY, width: 16, height: 16))
        x += 22
        Chrome.rule.setFill(); NSRect(x: x, y: 5, width: 1, height: 16).fill()
        x += 6

        for (cmd, drawer) in [(Command.save, 0), (Command.undo, 1), (Command.redo, 2)] {
            let r = NSRect(x: x, y: iconY - 2, width: 20, height: 20)
            Chrome.drawControl(r, hovered == r ? .hover : .normal)
            drawQuickGlyph(drawer, in: r.insetBy(dx: 3, dy: 3))
            regions.append((r, .command(cmd)))
            x += 22
        }

        let title = "\(state.fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled") - repaint"
        Chrome.label(title, in: NSRect(x: x + 12, y: 5, width: bounds.width - x - 24, height: 16),
                     size: 11, color: Chrome.ink, align: .left)
    }

    private func drawQuickGlyph(_ kind: Int, in r: NSRect) {
        switch kind {
        case 0:   // floppy
            NSColor(srgbRed: 0.36, green: 0.55, blue: 0.80, alpha: 1).setFill()
            NSBezierPath(roundedRect: r, xRadius: 1.5, yRadius: 1.5).fill()
            NSColor.white.setFill()
            NSRect(x: r.minX + 2.5, y: r.minY + 1, width: r.width - 5, height: r.height * 0.4).fill()
        default:  // undo / redo arcs
            let p = NSBezierPath()
            let mirrored = (kind == 2)
            p.appendArc(withCenter: NSPoint(x: r.midX, y: r.midY - 1), radius: r.width * 0.42,
                        startAngle: mirrored ? 20 : 160, endAngle: mirrored ? 160 : 20,
                        clockwise: !mirrored)
            p.lineWidth = 2
            NSColor(srgbRed: 0.20, green: 0.52, blue: 0.24, alpha: 1).setStroke()
            if kind == 2 { NSColor(srgbRed: 0.20, green: 0.42, blue: 0.75, alpha: 1).setStroke() }
            p.stroke()
            let head = NSBezierPath()
            let hx = mirrored ? r.maxX - 1 : r.minX + 1
            head.move(to: NSPoint(x: hx, y: r.midY + 3))
            head.line(to: NSPoint(x: hx + (mirrored ? -4 : 4), y: r.midY + 1))
            head.line(to: NSPoint(x: hx, y: r.midY - 2.5))
            head.close()
            head.fill()
        }
    }

    private func drawTabs() {
        let strip = NSRect(x: 0, y: quickBarH, width: bounds.width, height: tabsH)
        Chrome.tabStrip.setFill(); strip.fill()

        let titles = ["File", "Home", "View"]
        var x: CGFloat = 4
        for (i, t) in titles.enumerated() {
            let w: CGFloat = i == 0 ? 52 : 56
            let r = NSRect(x: x, y: strip.minY + 2, width: w, height: tabsH - 2)
            if i == 0 {
                Chrome.fileTab.setFill()
                NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2).fill()
                Chrome.label(t, in: NSRect(x: r.minX, y: r.midY - 8, width: r.width, height: 15),
                             size: 11.5, color: .white)
            } else {
                if i == activeTab {
                    NSColor.white.setFill()
                    NSRect(x: r.minX, y: r.minY, width: r.width, height: r.height + 1).fill()
                    Chrome.rule.setStroke()
                    let p = NSBezierPath()
                    p.move(to: NSPoint(x: r.minX + 0.5, y: r.maxY + 1))
                    p.line(to: NSPoint(x: r.minX + 0.5, y: r.minY + 0.5))
                    p.line(to: NSPoint(x: r.maxX - 0.5, y: r.minY + 0.5))
                    p.line(to: NSPoint(x: r.maxX - 0.5, y: r.maxY + 1))
                    p.stroke()
                }
                Chrome.label(t, in: NSRect(x: r.minX, y: r.midY - 8, width: r.width, height: 15),
                             size: 11.5, color: Chrome.ink)
            }
            regions.append((r, .tab(i)))
            x += w + 2
        }
    }

    // MARK: - Group builders

    /// Big button with a caption and an optional dropdown chevron.
    private func bigButton(_ rect: NSRect, title: String, chevron: Bool,
                           selected: Bool = false, glyph: (NSRect) -> Void) {
        Chrome.drawControl(rect, selected ? .selected : (hovered == rect ? .hover : .normal))
        let icon = NSRect(x: rect.midX - 16, y: rect.minY + 4, width: 32, height: 32)
        glyph(icon)
        // 14pt per line: two 11pt lines clip inside 13.
        let h = CGFloat(title.contains("\n") ? 2 : 1) * 14
        let labelY = chevron ? rect.maxY - 13 - h : rect.maxY - 2 - h
        Chrome.label(title, in: NSRect(x: rect.minX, y: labelY, width: rect.width, height: h),
                     size: 11)
        if chevron { Chrome.chevron(at: NSPoint(x: rect.midX, y: rect.maxY - 10)) }
    }

    /// Small button with the icon on the left and the label beside it.
    private func smallButton(_ rect: NSRect, title: String, chevron: Bool = false,
                             selected: Bool = false, glyph: (NSRect) -> Void) {
        Chrome.drawControl(rect, selected ? .selected : (hovered == rect ? .hover : .normal))
        let icon = NSRect(x: rect.minX + 3, y: rect.midY - 8, width: 16, height: 16)
        glyph(icon)
        Chrome.label(title, in: NSRect(x: rect.minX + 22, y: rect.midY - 7,
                                       width: rect.width - 30, height: 14),
                     size: 11, align: .left)
        if chevron { Chrome.chevron(at: NSPoint(x: rect.maxX - 7, y: rect.midY + 1)) }
    }

    private func finishGroup(_ name: String, from x0: CGFloat, to x1: CGFloat,
                             in body: NSRect) -> CGFloat {
        groupBounds.append((NSRect(x: x0, y: body.minY, width: x1 - x0, height: body.height), name))
        return x1 + 8
    }

    private func drawClipboard(startingAt x0: CGFloat, in body: NSRect) -> CGFloat {
        let top = body.minY + 4
        let paste = NSRect(x: x0 + 4, y: top, width: 56, height: 68)
        bigButton(paste, title: "Paste", chevron: true) { Glyph.paste(in: $0) }
        regions.append((paste, .command(.paste)))

        let cut = NSRect(x: paste.maxX + 4, y: top + 4, width: 66, height: 22)
        smallButton(cut, title: "Cut") { Glyph.cut(in: $0) }
        regions.append((cut, .command(.cut)))

        let copy = NSRect(x: paste.maxX + 4, y: top + 28, width: 66, height: 22)
        smallButton(copy, title: "Copy") { Glyph.copyIcon(in: $0) }
        regions.append((copy, .command(.copy)))

        return finishGroup("Clipboard", from: x0, to: copy.maxX + 4, in: body)
    }

    private func drawImageGroup(startingAt x0: CGFloat, in body: NSRect) -> CGFloat {
        let top = body.minY + 4
        let sel = NSRect(x: x0 + 4, y: top, width: 52, height: 68)
        let selecting = state.tool == .select || state.tool == .freeFormSelect
        bigButton(sel, title: "Select", chevron: true, selected: selecting) {
            Glyph.tool(self.state.tool == .freeFormSelect ? .freeFormSelect : .select, in: $0)
        }
        regions.append((sel, .command(.selectMenu)))

        var y = top + 1
        for (title, cmd, glyph) in [("Crop", Command.crop, 0),
                                    ("Resize", Command.resize, 1),
                                    ("Rotate", Command.rotate, 2)] {
            let r = NSRect(x: sel.maxX + 4, y: y, width: 74, height: 22)
            smallButton(r, title: title, chevron: cmd == .rotate) { icon in
                switch glyph {
                case 0: Glyph.crop(in: icon)
                case 1: Glyph.resize(in: icon)
                default: Glyph.rotate(in: icon)
                }
            }
            regions.append((r, .command(cmd)))
            y += 23
        }
        return finishGroup("Image", from: x0, to: sel.maxX + 82, in: body)
    }

    private func drawTools(startingAt x0: CGFloat, in body: NSRect) -> CGFloat {
        let tools: [Tool] = [.pencil, .fill, .text, .eraser, .pickColor, .magnifier]
        let size: CGFloat = 26
        let top = body.minY + 10
        for (i, t) in tools.enumerated() {
            let r = NSRect(x: x0 + 4 + CGFloat(i % 3) * (size + 2),
                           y: top + CGFloat(i / 3) * (size + 2),
                           width: size, height: size)
            Chrome.drawControl(r, state.tool == t ? .selected : (hovered == r ? .hover : .normal))
            Glyph.tool(t, in: r.insetBy(dx: 5, dy: 5))
            regions.append((r, .tool(t)))
        }
        return finishGroup("Tools", from: x0, to: x0 + 4 + 3 * (size + 2), in: body)
    }

    private func drawBrushes(startingAt x0: CGFloat, in body: NSRect) -> CGFloat {
        let r = NSRect(x: x0 + 4, y: body.minY + 4, width: 52, height: 68)
        let on = state.tool == .brush || state.tool == .airbrush
        bigButton(r, title: "Brushes", chevron: true, selected: on) { Glyph.tool(.brush, in: $0) }
        regions.append((r, .command(.brushesMenu)))
        return finishGroup("Brushes", from: x0, to: r.maxX + 4, in: body)
    }

    private func drawShapes(startingAt x0: CGFloat, in body: NSRect) -> CGFloat {
        let cell: CGFloat = 23
        let cols = 7
        let top = body.minY + 4
        for (i, shape) in Tool.shapeGallery.enumerated() {
            let r = NSRect(x: x0 + 4 + CGFloat(i % cols) * cell,
                           y: top + CGFloat(i / cols) * cell,
                           width: cell - 1, height: cell - 1)
            Chrome.drawControl(r, state.tool == shape ? .selected
                                  : (hovered == r ? .hover : .normal))
            Glyph.shape(shape, in: r.insetBy(dx: 3, dy: 3))
            regions.append((r, .tool(shape)))
        }
        let gridRight = x0 + 4 + CGFloat(cols) * cell

        // Outline and Fill dropdowns sit to the right of the gallery.
        let outline = NSRect(x: gridRight + 6, y: top + 2, width: 74, height: 22)
        smallButton(outline, title: "Outline", chevron: true) { icon in
            Chrome.ink.setStroke()
            let p = NSBezierPath(rect: icon.insetBy(dx: 2.5, dy: 3.5))
            p.lineWidth = 1.4; p.stroke()
        }
        regions.append((outline, .command(.outlineMenu)))

        let fill = NSRect(x: gridRight + 6, y: top + 27, width: 74, height: 22)
        smallButton(fill, title: "Fill", chevron: true) { icon in
            NSColor(srgbRed: 0.42, green: 0.62, blue: 0.86, alpha: 1).setFill()
            icon.insetBy(dx: 2.5, dy: 3.5).fill()
            Chrome.ink.setStroke()
            NSBezierPath(rect: icon.insetBy(dx: 2.5, dy: 3.5)).stroke()
        }
        regions.append((fill, .command(.fillMenu)))

        return finishGroup("Shapes", from: x0, to: outline.maxX + 4, in: body)
    }

    private func drawSize(startingAt x0: CGFloat, in body: NSRect) -> CGFloat {
        let r = NSRect(x: x0 + 4, y: body.minY + 4, width: 46, height: 68)
        bigButton(r, title: "Size", chevron: true) { Glyph.sizeStack(in: $0) }
        regions.append((r, .command(.sizeMenu)))
        return finishGroup("Size", from: x0, to: r.maxX + 4, in: body)
    }

    private func drawColors(startingAt x0: CGFloat, in body: NSRect) -> CGFloat {
        let top = body.minY + 6
        // Color 1 / Color 2 wells.
        var x = x0 + 4
        for (i, color) in [state.foreground, state.background].enumerated() {
            let well = NSRect(x: x, y: top, width: 38, height: 38)
            Chrome.drawControl(well, hovered == well ? .hover : .normal)
            let sw = well.insetBy(dx: 5, dy: 5)
            color.setFill(); sw.fill()
            NSColor(white: 0.35, alpha: 1).setStroke()
            NSBezierPath(rect: sw.insetBy(dx: 0.5, dy: 0.5)).stroke()
            Chrome.label(i == 0 ? "Color 1" : "Color 2",
                         in: NSRect(x: well.minX - 4, y: well.maxY + 1, width: 46, height: 26),
                         size: 10)
            regions.append((well, .colorSlot(i)))
            x += 46
        }

        // The palette: two rows of ten.
        x += 4
        let sw: CGFloat = 19
        let cols = 10
        for (i, color) in state.palette.prefix(cols * 2).enumerated() {
            let r = NSRect(x: x + CGFloat(i % cols) * sw,
                           y: top + CGFloat(i / cols) * sw,
                           width: sw - 2, height: sw - 2)
            color.setFill(); r.fill()
            NSColor(white: 0.45, alpha: 1).setStroke()
            NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5)).stroke()
            regions.append((r, .swatch(i)))
        }
        let paletteRight = x + CGFloat(cols) * sw

        let edit = NSRect(x: paletteRight + 6, y: top - 2, width: 52, height: 66)
        bigButton(edit, title: "Edit\ncolors", chevron: false) { Glyph.colorWheel(in: $0) }
        regions.append((edit, .command(.editColors)))

        return finishGroup("Colors", from: x0, to: edit.maxX + 4, in: body)
    }

    // MARK: - View tab

    private func magnifierGlyph(_ r: NSRect, sign: Int) {
        Glyph.tool(.magnifier, in: r)
        guard sign != 0 else { return }
        NSColor(srgbRed: 0.15, green: 0.35, blue: 0.62, alpha: 1).setFill()
        NSRect(x: r.midX - 5, y: r.midY - 1.5, width: 10, height: 3).fill()
        if sign > 0 { NSRect(x: r.midX - 1.5, y: r.midY - 5, width: 3, height: 10).fill() }
    }

    private func drawZoomGroup(startingAt x0: CGFloat, in body: NSRect) -> CGFloat {
        var x = x0 + 4
        let specs: [(String, Command, Int)] = [("Zoom in", .zoomIn, 1),
                                               ("Zoom out", .zoomOut, -1),
                                               ("100%", .zoom100, 0)]
        for (title, cmd, sign) in specs {
            let r = NSRect(x: x, y: body.minY + 4, width: 54, height: 68)
            bigButton(r, title: title, chevron: false) { self.magnifierGlyph($0, sign: sign) }
            regions.append((r, .command(cmd)))
            x += 58
        }
        return finishGroup("Zoom", from: x0, to: x, in: body)
    }

    private func drawShowHide(startingAt x0: CGFloat, in body: NSRect) -> CGFloat {
        var y = body.minY + 8
        let specs: [(String, Command, Bool)] = [
            ("Gridlines", .gridlines, state.showGrid),
            ("Status bar", .statusBarToggle, showStatusBar)
        ]
        for (title, cmd, on) in specs {
            let r = NSRect(x: x0 + 4, y: y, width: 104, height: 24)
            smallButton(r, title: title, selected: on) { icon in
                let box = icon.insetBy(dx: 2, dy: 2)
                NSColor.white.setFill(); box.fill()
                Chrome.ink.setStroke()
                NSBezierPath(rect: box.insetBy(dx: 0.5, dy: 0.5)).stroke()
                if on {
                    let check = NSBezierPath()
                    check.lineWidth = 1.8
                    check.move(to: NSPoint(x: box.minX + 2, y: box.midY))
                    check.line(to: NSPoint(x: box.midX, y: box.maxY - 2.5))
                    check.line(to: NSPoint(x: box.maxX - 1.5, y: box.minY + 2))
                    NSColor(srgbRed: 0.15, green: 0.45, blue: 0.20, alpha: 1).setStroke()
                    check.stroke()
                }
            }
            regions.append((r, .command(cmd)))
            y += 26
        }
        return finishGroup("Show or hide", from: x0, to: x0 + 112, in: body)
    }

    private func drawDisplay(startingAt x0: CGFloat, in body: NSRect) -> CGFloat {
        let r = NSRect(x: x0 + 4, y: body.minY + 4, width: 66, height: 68)
        bigButton(r, title: "Full\nscreen", chevron: false) { icon in
            Chrome.ink.setStroke()
            let p = NSBezierPath(rect: icon.insetBy(dx: 3, dy: 6))
            p.lineWidth = 1.4; p.stroke()
            NSColor(srgbRed: 0.42, green: 0.62, blue: 0.86, alpha: 1).setFill()
            icon.insetBy(dx: 5, dy: 8).fill()
        }
        regions.append((r, .command(.fullScreen)))
        return finishGroup("Display", from: x0, to: r.maxX + 4, in: body)
    }

    /// Mirrors the controller so the checkbox renders correctly.
    var showStatusBar = true

    // MARK: - Interaction

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let hit = regions.last { $0.0.contains(p) }?.0
        if hit != hovered { hovered = hit; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        if hovered != nil { hovered = nil; needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) { handleClick(event, secondary: false) }
    override func rightMouseDown(with event: NSEvent) { handleClick(event, secondary: true) }

    private func handleClick(_ event: NSEvent, secondary: Bool) {
        let p = convert(event.locationInWindow, from: nil)
        guard let (rect, hit) = regions.last(where: { $0.0.contains(p) }) else { return }
        switch hit {
        case .tool(let t):
            state.tool = t
            delegate?.ribbonSelect(tool: t)
        case .command(let c):
            delegate?.ribbonCommand(c, from: rect)
        case .swatch(let i):
            guard i < state.palette.count else { return }
            if event.clickCount >= 2 {
                delegate?.ribbonEditColor(slot: secondary ? 1 : 0)
            } else {
                delegate?.ribbonPick(color: state.palette[i], secondary: secondary)
            }
        case .colorSlot(let slot):
            delegate?.ribbonEditColor(slot: slot)
        case .tab(let i):
            delegate?.ribbonSelectTab(i)
        }
        needsDisplay = true
    }
}

/// Windows 7 Paint's status bar: cursor position, selection size, canvas size
/// and the zoom readout.
final class StatusBarView: NSView {
    var hint: String = "" { didSet { needsDisplay = true } }
    var coordinate: String = "" { didSet { needsDisplay = true } }
    var sizeText: String = "" { didSet { needsDisplay = true } }
    var canvasText: String = "" { didSet { needsDisplay = true } }
    var zoomText: String = "100%" { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Chrome.vGradient(bounds, .white, Chrome.statusFace)
        Chrome.rule.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()

        let y = bounds.midY - 8
        var x: CGFloat = 8
        for (glyph, text, width) in [(0, coordinate, CGFloat(110)),
                                     (1, sizeText, 110),
                                     (2, canvasText, 110)] {
            if !text.isEmpty {
                drawGlyph(glyph, in: NSRect(x: x, y: y + 2, width: 12, height: 12))
                Chrome.label(text, in: NSRect(x: x + 15, y: y, width: width, height: 15),
                             size: 10.5, align: .left)
            }
            x += width
        }
        Chrome.label(zoomText, in: NSRect(x: bounds.width - 70, y: y, width: 60, height: 15),
                     size: 10.5, align: .right)
    }

    private func drawGlyph(_ kind: Int, in r: NSRect) {
        NSColor(srgbRed: 0.35, green: 0.42, blue: 0.50, alpha: 1).setStroke()
        let p = NSBezierPath()
        p.lineWidth = 1
        switch kind {
        case 0:   // crosshair
            p.move(to: NSPoint(x: r.midX, y: r.minY)); p.line(to: NSPoint(x: r.midX, y: r.maxY))
            p.move(to: NSPoint(x: r.minX, y: r.midY)); p.line(to: NSPoint(x: r.maxX, y: r.midY))
        case 1:   // selection size
            p.appendRect(r.insetBy(dx: 1.5, dy: 2.5))
            let dash: [CGFloat] = [2, 2]
            p.setLineDash(dash, count: 2, phase: 0)
        default:  // canvas size
            p.appendRect(r.insetBy(dx: 1.5, dy: 2.5))
        }
        p.stroke()
    }
}
