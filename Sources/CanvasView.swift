import AppKit

protocol CanvasViewDelegate: AnyObject {
    func canvasCursorMoved(to point: CGPoint?)
    func canvasSizeIndicator(_ size: CGSize?)
    func canvasDidModify()
    func canvasZoomChanged(_ zoom: CGFloat)
    func canvasColorsChanged()
    func canvasSelectionChanged(active: Bool)
}

/// The drawing surface. Owns all tool interaction, the floating selection and
/// the in-place text editor.
final class CanvasView: NSView, NSTextViewDelegate {
    let state: PaintState
    weak var delegate: CanvasViewDelegate?

    // Stroke bookkeeping
    private var strokeBase: Bitmap?          // pristine copy for live shape preview
    private var dragStart = CGPoint.zero
    private var lastPoint = CGPoint.zero
    private var isDrawing = false
    private var usingRightButton = false

    // Selection
    private(set) var selectionRect: CGRect?  // image coords, integral
    private var floating: Bitmap?            // lifted pixels
    private var floatingMask: CGImage?       // for free-form selections
    private var floatOrigin = CGPoint.zero
    private var hasLifted = false
    private var dragMode: DragMode = .none
    private var dragAnchor = CGPoint.zero
    private var originalSelRect = CGRect.zero
    private var lassoPoints: [CGPoint] = []
    private var antsPhase: CGFloat = 0
    private var antsTimer: Timer?

    private enum DragMode {
        case none, newSelection, move
        case resize(Int)   // handle index 0...7

        var isIdle: Bool { if case .none = self { return true }; return false }
    }

    // Multi-step tools
    private var curvePoints: [CGPoint] = []
    private var curveStage = 0
    private var polygonPoints: [CGPoint] = []

    // Airbrush continuous spray
    private var airbrushTimer: Timer?
    private var airbrushPoint = CGPoint.zero

    // Text tool
    private var textView: NSTextView?
    private var textRect: CGRect?
    var textFont: NSFont = NSFont(name: "Helvetica", size: 18) ?? .systemFont(ofSize: 18)
    var textOpaque = false

    // Dragging the canvas grips to resize the picture
    private var resizingGrip: Int?
    private var resizeStartSize = CGSize.zero
    private var resizeStartMouse = CGPoint.zero

    init(state: PaintState) {
        self.state = state
        super.init(frame: NSRect(x: 0, y: 0, width: state.bitmap.width, height: state.bitmap.height))
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
        startAnts()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { antsTimer?.invalidate(); airbrushTimer?.invalidate() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Geometry

    var zoom: CGFloat { state.zoom }

    /// Gap between the drawing area's corner and the picture itself.
    static let margin: CGFloat = 6

    var canvasPixelSize: CGSize {
        CGSize(width: CGFloat(state.bitmap.width), height: CGFloat(state.bitmap.height))
    }

    /// Total view size including the resize-handle margin Paint leaves.
    func updateFrameSize() {
        let s = canvasPixelSize
        let m = CanvasView.margin
        setFrameSize(NSSize(width: s.width * zoom + m + 8, height: s.height * zoom + m + 8))
        needsDisplay = true
    }

    private func imagePoint(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        let m = CanvasView.margin
        return CGPoint(x: floor((p.x - m) / zoom), y: floor((p.y - m) / zoom))
    }

    private func viewRect(forImage r: CGRect) -> CGRect {
        let m = CanvasView.margin
        return CGRect(x: r.origin.x * zoom + m, y: r.origin.y * zoom + m,
                      width: r.width * zoom, height: r.height * zoom)
    }

    private func clampToCanvas(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(0, p.x), canvasPixelSize.width - 1),
                y: min(max(0, p.y), canvasPixelSize.height - 1))
    }

    // MARK: - Drawing the view

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let size = canvasPixelSize
        let m = CanvasView.margin
        let canvasFrame = CGRect(x: m, y: m, width: size.width * zoom, height: size.height * zoom)

        NSColor(calibratedWhite: 0.5, alpha: 1).setFill()
        dirtyRect.fill()

        // Bitmap, nearest-neighbour so zoom shows hard pixels.
        if let cg = state.bitmap.cgImage {
            ctx.saveGState()
            ctx.interpolationQuality = .none
            ctx.setShouldAntialias(false)
            ctx.translateBy(x: canvasFrame.minX, y: canvasFrame.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(cg, in: CGRect(origin: .zero, size: canvasFrame.size))
            ctx.restoreGState()
        }

        // Floating selection sits above the canvas until committed.
        if let f = floating, let cg = renderedFloating(f) {
            let r = viewRect(forImage: CGRect(origin: floatOrigin,
                                              size: CGSize(width: f.width, height: f.height)))
            ctx.saveGState()
            ctx.interpolationQuality = .none
            ctx.setShouldAntialias(false)
            ctx.translateBy(x: 0, y: r.maxY + r.minY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(cg, in: r)
            ctx.restoreGState()
        }

        if state.showGrid && zoom >= 4 {
            ctx.saveGState()
            ctx.setShouldAntialias(false)
            ctx.setStrokeColor(NSColor(calibratedWhite: 0.75, alpha: 1).cgColor)
            ctx.setLineWidth(1)
            var x = canvasFrame.minX
            while x <= canvasFrame.maxX {
                ctx.move(to: CGPoint(x: x, y: canvasFrame.minY))
                ctx.addLine(to: CGPoint(x: x, y: canvasFrame.maxY)); x += zoom
            }
            var y = canvasFrame.minY
            while y <= canvasFrame.maxY {
                ctx.move(to: CGPoint(x: canvasFrame.minX, y: y))
                ctx.addLine(to: CGPoint(x: canvasFrame.maxX, y: y)); y += zoom
            }
            ctx.strokePath()
            ctx.restoreGState()
        }

        // Marching-ants outline for the current selection.
        if let sel = currentSelectionRect {
            drawAnts(around: viewRect(forImage: sel), in: ctx)
            if floating != nil || dragMode.isIdle {
                drawHandles(around: viewRect(forImage: sel), in: ctx)
            }
        } else if !lassoPoints.isEmpty {
            ctx.saveGState()
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setLineDash(phase: antsPhase, lengths: [4, 4])
            ctx.beginPath()
            ctx.move(to: CGPoint(x: lassoPoints[0].x * zoom, y: lassoPoints[0].y * zoom))
            for p in lassoPoints.dropFirst() { ctx.addLine(to: CGPoint(x: p.x * zoom, y: p.y * zoom)) }
            ctx.strokePath()
            ctx.restoreGState()
        }

        // Text box border.
        if let tr = textRect {
            ctx.saveGState()
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setLineDash(phase: antsPhase, lengths: [3, 3])
            ctx.stroke(viewRect(forImage: tr).insetBy(dx: -0.5, dy: -0.5))
            ctx.restoreGState()
        }

        // Canvas resize handles (bottom-right corner grips, like Paint).
        ctx.saveGState()
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.setStrokeColor(NSColor.black.cgColor)
        for r in canvasGrips() { ctx.fill(r); ctx.stroke(r) }
        ctx.restoreGState()
    }

    private func renderedFloating(_ f: Bitmap) -> CGImage? {
        guard let base = f.cgImage else { return nil }
        if state.selectionMode == .transparent {
            return maskOut(color: state.background, from: base) ?? base
        }
        if let m = floatingMask, let masked = base.masking(m) { return masked }
        return base
    }

    /// Builds a version of the image with all pixels of `color` made transparent.
    private func maskOut(color: NSColor, from image: CGImage) -> CGImage? {
        let c = color.rgba8
        let comps: [CGFloat] = [CGFloat(c.0), CGFloat(c.0), CGFloat(c.1),
                                CGFloat(c.1), CGFloat(c.2), CGFloat(c.2)]
        return image.copy(maskingColorComponents: comps)
    }

    private func drawAnts(around rect: CGRect, in ctx: CGContext) {
        ctx.saveGState()
        ctx.setShouldAntialias(false)
        ctx.setLineWidth(1)
        let r = rect.insetBy(dx: -0.5, dy: -0.5)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.stroke(r)
        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.setLineDash(phase: antsPhase, lengths: [4, 4])
        ctx.stroke(r)
        ctx.restoreGState()
    }

    private func handleRects(around rect: CGRect) -> [CGRect] {
        let s: CGFloat = 6, h = s / 2
        let xs = [rect.minX, rect.midX, rect.maxX]
        let ys = [rect.minY, rect.midY, rect.maxY]
        var out: [CGRect] = []
        for (i, y) in ys.enumerated() {
            for (j, x) in xs.enumerated() {
                if i == 1 && j == 1 { continue }
                out.append(CGRect(x: x - h, y: y - h, width: s, height: s))
            }
        }
        return out
    }

    private func drawHandles(around rect: CGRect, in ctx: CGContext) {
        ctx.saveGState()
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.setLineWidth(1)
        for r in handleRects(around: rect) { ctx.fill(r); ctx.stroke(r) }
        ctx.restoreGState()
    }

    private func canvasGrips() -> [CGRect] {
        let s = canvasPixelSize
        let m = CanvasView.margin
        let w = s.width * zoom + m, h = s.height * zoom + m
        let g: CGFloat = 5
        return [CGRect(x: w + 1, y: h / 2 - g / 2, width: g, height: g),   // right edge
                CGRect(x: w / 2 - g / 2, y: h + 1, width: g, height: g),   // bottom edge
                CGRect(x: w + 1, y: h + 1, width: g, height: g)]           // corner
    }

    private func startAnts() {
        antsTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.currentSelectionRect != nil || self.textRect != nil || !self.lassoPoints.isEmpty {
                self.antsPhase += 1
                self.needsDisplay = true
            }
        }
        if let t = antsTimer { RunLoop.main.add(t, forMode: .common) }
    }

    var currentSelectionRect: CGRect? {
        if let f = floating {
            return CGRect(origin: floatOrigin,
                          size: CGSize(width: f.width, height: f.height))
        }
        return selectionRect
    }

    var hasSelection: Bool { currentSelectionRect != nil }

    // MARK: - Mouse tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        let p = imagePoint(event)
        delegate?.canvasCursorMoved(to: p)
        updateCursor(at: p)
    }

    override func mouseExited(with event: NSEvent) {
        delegate?.canvasCursorMoved(to: nil)
    }

    private func updateCursor(at p: CGPoint) {
        var cursor = NSCursor.crosshair
        switch state.tool {
        case .select, .freeFormSelect:
            if let sel = currentSelectionRect {
                let vr = viewRect(forImage: sel)
                let vp = CGPoint(x: p.x * zoom, y: p.y * zoom)
                if handleRects(around: vr).contains(where: { $0.insetBy(dx: -2, dy: -2).contains(vp) }) {
                    cursor = NSCursor.crosshair
                } else if sel.contains(p) {
                    cursor = NSCursor.openHand
                }
            }
        case .fill, .pickColor, .airbrush, .magnifier:
            cursor = NSCursor.crosshair
        case .text:
            cursor = NSCursor.iBeam
        default:
            cursor = NSCursor.crosshair
        }
        cursor.set()
    }

    // MARK: - Mouse down / drag / up

    override func mouseDown(with event: NSEvent) {
        handleDown(event, right: false)
    }

    override func rightMouseDown(with event: NSEvent) {
        handleDown(event, right: true)
    }

    override func mouseDragged(with event: NSEvent) {
        handleDragged(event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        handleDragged(event)
    }

    override func mouseUp(with event: NSEvent) {
        handleUp(event)
    }

    override func rightMouseUp(with event: NSEvent) {
        handleUp(event)
    }

    private var primaryColor: NSColor { usingRightButton ? state.background : state.foreground }
    private var secondaryColor: NSColor { usingRightButton ? state.foreground : state.background }

    private func handleDown(_ event: NSEvent, right: Bool) {
        window?.makeFirstResponder(self)
        usingRightButton = right

        // Grips on the right/bottom edges resize the canvas itself.
        let viewPoint = convert(event.locationInWindow, from: nil)
        if !right {
            for (i, g) in canvasGrips().enumerated()
            where g.insetBy(dx: -3, dy: -3).contains(viewPoint) {
                commitText()
                commitFloating()
                resizingGrip = i
                resizeStartSize = canvasPixelSize
                resizeStartMouse = viewPoint
                state.beginUndo()
                return
            }
        }

        let raw = imagePoint(event)
        let p = clampToCanvas(raw)
        dragStart = p
        lastPoint = p

        // A click outside an active text box commits it first.
        if textView != nil && state.tool != .text { commitText() }

        switch state.tool {
        case .select, .freeFormSelect:
            beginSelectionInteraction(at: p, event: event)

        case .magnifier:
            let levels: [CGFloat] = [1, 2, 4, 6, 8]
            if right {
                if let i = levels.firstIndex(of: zoom), i > 0 { setZoom(levels[i - 1]) }
            } else {
                if let i = levels.firstIndex(of: zoom), i < levels.count - 1 { setZoom(levels[i + 1]) }
                else { setZoom(levels[min(1, levels.count - 1)]) }
            }

        case .pickColor:
            let c = state.bitmap.color(at: Int(p.x), Int(p.y))
            if right { state.background = c } else { state.foreground = c }
            delegate?.canvasColorsChanged()

        case .fill:
            commitFloating()
            state.beginUndo()
            state.bitmap.floodFill(x: Int(p.x), y: Int(p.y), with: primaryColor)
            finishMutation()

        case .pencil, .brush, .eraser, .airbrush:
            commitFloating()
            state.beginUndo()
            isDrawing = true
            if state.tool == .airbrush {
                airbrushPoint = p
                sprayAirbrush(at: p)
                airbrushTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                    guard let self = self, self.isDrawing else { return }
                    self.sprayAirbrush(at: self.airbrushPoint)
                    self.needsDisplay = true
                }
                if let t = airbrushTimer { RunLoop.main.add(t, forMode: .common) }
            } else {
                paintDab(from: p, to: p)
            }
            needsDisplay = true

        case .line:
            commitFloating()
            state.beginUndo()
            strokeBase = state.bitmap.copy()
            isDrawing = true

        case let t where t.isDragShape:
            commitFloating()
            state.beginUndo()
            strokeBase = state.bitmap.copy()
            isDrawing = true

        case .curve:
            commitFloating()
            if curveStage == 0 {
                state.beginUndo()
                strokeBase = state.bitmap.copy()
                curvePoints = [p, p]
                isDrawing = true
            } else {
                isDrawing = true
            }

        case .polygon:
            commitFloating()
            if polygonPoints.isEmpty {
                state.beginUndo()
                strokeBase = state.bitmap.copy()
                polygonPoints = [p]
                isDrawing = true
            } else if right || event.clickCount >= 2 ||
                        hypot(p.x - polygonPoints[0].x, p.y - polygonPoints[0].y) < 4 / zoom {
                finishPolygon()
            } else {
                polygonPoints.append(p)
                redrawPolygonPreview(to: p)
            }

        case .text:
            if let tr = textRect, tr.insetBy(dx: -3, dy: -3).contains(p) { break }
            commitText()
            commitFloating()
            dragStart = p
            isDrawing = true

        default:
            break
        }
    }

    private func handleDragged(_ event: NSEvent) {
        if let grip = resizingGrip {
            let vp = convert(event.locationInWindow, from: nil)
            let dx = (vp.x - resizeStartMouse.x) / zoom
            let dy = (vp.y - resizeStartMouse.y) / zoom
            var w = resizeStartSize.width, h = resizeStartSize.height
            if grip == 0 || grip == 2 { w = max(1, (resizeStartSize.width + dx).rounded()) }
            if grip == 1 || grip == 2 { h = max(1, (resizeStartSize.height + dy).rounded()) }
            state.bitmap.resizeCanvas(width: Int(w), height: Int(h), fill: state.background)
            updateFrameSize()
            delegate?.canvasSizeIndicator(CGSize(width: w, height: h))
            return
        }
        let raw = imagePoint(event)
        let p = clampToCanvas(raw)
        delegate?.canvasCursorMoved(to: raw)
        let shift = event.modifierFlags.contains(.shift)

        switch state.tool {
        case .select, .freeFormSelect:
            dragSelection(to: p, shift: shift)

        case .pencil, .brush, .eraser:
            guard isDrawing else { return }
            paintDab(from: lastPoint, to: p)
            lastPoint = p
            needsDisplay = true

        case .airbrush:
            guard isDrawing else { return }
            airbrushPoint = p
            sprayAirbrush(at: p)
            needsDisplay = true

        case .line:
            guard isDrawing, let base = strokeBase else { return }
            restore(base)
            let end = shift ? constrain45(from: dragStart, to: p) : p
            drawLine(from: dragStart, to: end, color: primaryColor, width: state.lineWidth)
            reportSize(from: dragStart, to: end)
            needsDisplay = true

        case let t where t.isDragShape:
            guard isDrawing, let base = strokeBase else { return }
            restore(base)
            let r = rectBetween(dragStart, p, square: shift)
            drawShape(t, in: r)
            delegate?.canvasSizeIndicator(r.size)
            needsDisplay = true

        case .curve:
            guard isDrawing, let base = strokeBase else { return }
            restore(base)
            if curveStage == 0 {
                curvePoints[1] = shift ? constrain45(from: curvePoints[0], to: p) : p
                drawLine(from: curvePoints[0], to: curvePoints[1], color: primaryColor, width: state.lineWidth)
            } else {
                if curvePoints.count < 3 { curvePoints.append(p) } else if curveStage == 1 { curvePoints[2] = p }
                if curveStage == 2 {
                    if curvePoints.count < 4 { curvePoints.append(p) } else { curvePoints[3] = p }
                }
                drawCurvePreview()
            }
            needsDisplay = true

        case .polygon:
            guard isDrawing, strokeBase != nil else { return }
            redrawPolygonPreview(to: p)

        case .text:
            guard isDrawing else { return }
            textRect = rectBetween(dragStart, p, square: false)
            delegate?.canvasSizeIndicator(textRect?.size)
            needsDisplay = true

        default:
            break
        }
    }

    private func handleUp(_ event: NSEvent) {
        if resizingGrip != nil {
            resizingGrip = nil
            delegate?.canvasSizeIndicator(nil)
            finishMutation()
            return
        }
        let p = clampToCanvas(imagePoint(event))
        switch state.tool {
        case .select, .freeFormSelect:
            endSelectionInteraction(at: p)

        case .pencil, .brush, .eraser:
            if isDrawing { isDrawing = false; finishMutation() }

        case .airbrush:
            isDrawing = false
            airbrushTimer?.invalidate(); airbrushTimer = nil
            finishMutation()

        case .line:
            if isDrawing {
                isDrawing = false
                strokeBase = nil
                finishMutation()
            }

        case let t where t.isDragShape:
            if isDrawing {
                isDrawing = false
                strokeBase = nil
                finishMutation()
            }

        case .curve:
            if isDrawing {
                isDrawing = false
                curveStage += 1
                if curveStage >= 3 {
                    curveStage = 0
                    curvePoints = []
                    strokeBase = nil
                    finishMutation()
                }
            }

        case .polygon:
            isDrawing = polygonPoints.isEmpty ? false : true
            if polygonPoints.count == 1 { polygonPoints.append(p) }

        case .text:
            if isDrawing {
                isDrawing = false
                if let tr = textRect, tr.width > 8, tr.height > 8 {
                    beginTextEditing(in: tr)
                } else {
                    textRect = nil
                }
                needsDisplay = true
            }

        default:
            break
        }
        delegate?.canvasSizeIndicator(nil)
        usingRightButton = false
    }

    private func finishMutation() {
        state.isDirty = true
        delegate?.canvasDidModify()
        needsDisplay = true
    }

    private func restore(_ base: Bitmap) {
        memcpy(state.bitmap.data, base.data, base.bytesPerRow * base.height)
    }

    private func reportSize(from a: CGPoint, to b: CGPoint) {
        delegate?.canvasSizeIndicator(CGSize(width: abs(b.x - a.x) + 1, height: abs(b.y - a.y) + 1))
    }

    // MARK: - Freehand painting

    private func paintDab(from a: CGPoint, to b: CGPoint) {
        let bmp = state.bitmap
        switch state.tool {
        case .pencil:
            plotLine(from: a, to: b) { x, y in
                bmp.setPixel(x, y, self.primaryColor.rgba8)
            }
        case .brush:
            let shape = state.brushShape
            let size = shape.size
            plotLine(from: a, to: b) { x, y in
                self.stampBrush(at: CGPoint(x: CGFloat(x), y: CGFloat(y)),
                                shape: shape, size: size, color: self.primaryColor)
            }
        case .eraser:
            let size = state.eraserSize
            // Right button is Paint's "colour eraser": only the foreground
            // colour is replaced, everything else is left alone.
            let colorEraser = usingRightButton
            plotLine(from: a, to: b) { x, y in
                let r = CGRect(x: CGFloat(x) - size / 2, y: CGFloat(y) - size / 2,
                               width: size, height: size).integral
                if colorEraser {
                    let target = self.state.foreground.rgba8
                    let repl = self.state.background.rgba8
                    for yy in Int(r.minY)..<Int(r.maxY) {
                        for xx in Int(r.minX)..<Int(r.maxX) {
                            let px = bmp.pixel(xx, yy)
                            if px.0 == target.0 && px.1 == target.1 && px.2 == target.2 {
                                bmp.setPixel(xx, yy, repl)
                            }
                        }
                    }
                } else {
                    bmp.ctx.saveGState()
                    bmp.ctx.setShouldAntialias(false)
                    bmp.ctx.setFillColor(self.state.background.cgColorRGB)
                    bmp.ctx.fill(r)
                    bmp.ctx.restoreGState()
                }
            }
        default:
            break
        }
    }

    private func stampBrush(at p: CGPoint, shape: BrushShape, size: CGFloat, color: NSColor) {
        let c = state.bitmap.ctx
        c.saveGState()
        c.setShouldAntialias(false)
        c.setFillColor(color.cgColorRGB)
        c.setStrokeColor(color.cgColorRGB)
        let half = (size / 2).rounded(.down)
        switch shape.family {
        case .circle:
            c.fillEllipse(in: CGRect(x: p.x - half, y: p.y - half, width: size, height: size))
        case .square:
            c.fill(CGRect(x: p.x - half, y: p.y - half, width: size, height: size))
        case .slashLeft:
            c.setLineWidth(1)
            c.setLineCap(.square)
            c.move(to: CGPoint(x: p.x - half, y: p.y + half))
            c.addLine(to: CGPoint(x: p.x + half, y: p.y - half))
            c.strokePath()
        case .slashRight:
            c.setLineWidth(1)
            c.setLineCap(.square)
            c.move(to: CGPoint(x: p.x - half, y: p.y - half))
            c.addLine(to: CGPoint(x: p.x + half, y: p.y + half))
            c.strokePath()
        }
        c.restoreGState()
    }

    private func sprayAirbrush(at p: CGPoint) {
        let radius = state.airbrushSize / 2
        let count = Int(radius * 1.6)
        let c = primaryColor.rgba8
        for _ in 0..<max(3, count) {
            let a = CGFloat.random(in: 0..<(2 * .pi))
            let r = CGFloat.random(in: 0..<radius)
            let x = Int((p.x + cos(a) * r).rounded())
            let y = Int((p.y + sin(a) * r).rounded())
            state.bitmap.setPixel(x, y, c)
        }
    }

    /// Bresenham, so freehand strokes land on exact pixels like Paint's.
    private func plotLine(from a: CGPoint, to b: CGPoint, plot: (Int, Int) -> Void) {
        var x0 = Int(a.x), y0 = Int(a.y)
        let x1 = Int(b.x), y1 = Int(b.y)
        let dx = abs(x1 - x0), dy = -abs(y1 - y0)
        let sx = x0 < x1 ? 1 : -1, sy = y0 < y1 ? 1 : -1
        var err = dx + dy
        while true {
            plot(x0, y0)
            if x0 == x1 && y0 == y1 { break }
            let e2 = 2 * err
            if e2 >= dy { err += dy; x0 += sx }
            if e2 <= dx { err += dx; y0 += sy }
        }
    }

    // MARK: - Shape drawing

    private func rectBetween(_ a: CGPoint, _ b: CGPoint, square: Bool) -> CGRect {
        var w = b.x - a.x, h = b.y - a.y
        if square {
            let s = min(abs(w), abs(h))
            w = w < 0 ? -s : s
            h = h < 0 ? -s : s
        }
        return CGRect(x: min(a.x, a.x + w), y: min(a.y, a.y + h),
                      width: abs(w), height: abs(h)).integral
    }

    private func constrain45(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        let len = hypot(dx, dy)
        return CGPoint(x: (a.x + cos(angle) * len).rounded(),
                       y: (a.y + sin(angle) * len).rounded())
    }

    private func drawLine(from a: CGPoint, to b: CGPoint, color: NSColor, width: CGFloat) {
        let c = state.bitmap.ctx
        c.saveGState()
        c.setShouldAntialias(false)
        c.setStrokeColor(color.cgColorRGB)
        c.setLineWidth(width)
        c.setLineCap(width > 1 ? .round : .square)
        c.move(to: CGPoint(x: a.x + 0.5, y: a.y + 0.5))
        c.addLine(to: CGPoint(x: b.x + 0.5, y: b.y + 0.5))
        c.strokePath()
        c.restoreGState()
    }

    /// Shared with the ribbon, which strokes the same paths as gallery icons.
    static func shapePath(_ tool: Tool, in rect: CGRect) -> CGPath {
        let x = rect.minX, y = rect.minY, w = rect.width, h = rect.height
        func poly(_ pts: [CGPoint]) -> CGPath {
            let p = CGMutablePath()
            p.addLines(between: pts)
            p.closeSubpath()
            return p
        }
        /// Regular n-gon inscribed in the box, first vertex pointing up.
        func regular(_ n: Int) -> CGPath {
            var pts: [CGPoint] = []
            for i in 0..<n {
                let a = -CGFloat.pi / 2 + CGFloat(i) * 2 * .pi / CGFloat(n)
                pts.append(CGPoint(x: rect.midX + cos(a) * w / 2,
                                   y: rect.midY + sin(a) * h / 2))
            }
            return poly(pts)
        }
        /// Alternating outer/inner vertices.
        func star(_ points: Int, inner: CGFloat) -> CGPath {
            var pts: [CGPoint] = []
            for i in 0..<(points * 2) {
                let a = -CGFloat.pi / 2 + CGFloat(i) * .pi / CGFloat(points)
                let f = i % 2 == 0 ? CGFloat(1) : inner
                pts.append(CGPoint(x: rect.midX + cos(a) * w / 2 * f,
                                   y: rect.midY + sin(a) * h / 2 * f))
            }
            return poly(pts)
        }
        /// Block arrow pointing right, then rotated into place.
        func arrow(rotation: CGFloat) -> CGPath {
            let base = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
            let stem = base.height * 0.28
            let headW = base.width * 0.42
            let pts = [
                CGPoint(x: base.minX, y: -stem), CGPoint(x: base.maxX - headW, y: -stem),
                CGPoint(x: base.maxX - headW, y: base.minY), CGPoint(x: base.maxX, y: 0),
                CGPoint(x: base.maxX - headW, y: base.maxY),
                CGPoint(x: base.maxX - headW, y: stem), CGPoint(x: base.minX, y: stem)
            ]
            let t = CGAffineTransform(translationX: rect.midX, y: rect.midY)
                .rotated(by: rotation)
            let p = CGMutablePath()
            p.addLines(between: pts, transform: t)
            p.closeSubpath()
            return p
        }

        switch tool {
        case .ellipse:
            return CGPath(ellipseIn: rect, transform: nil)
        case .roundRect, .calloutRounded:
            let r = min(14, min(w, h) / 4)
            let body = CGRect(x: x, y: y, width: w, height: tool == .roundRect ? h : h * 0.78)
            let p = CGMutablePath()
            p.addRoundedRect(in: body, cornerWidth: r, cornerHeight: r)
            if tool == .calloutRounded {
                p.move(to: CGPoint(x: x + w * 0.22, y: body.maxY))
                p.addLine(to: CGPoint(x: x + w * 0.16, y: y + h))
                p.addLine(to: CGPoint(x: x + w * 0.40, y: body.maxY))
                p.closeSubpath()
            }
            return p
        case .calloutOval:
            let body = CGRect(x: x, y: y, width: w, height: h * 0.78)
            let p = CGMutablePath()
            p.addEllipse(in: body)
            p.move(to: CGPoint(x: x + w * 0.24, y: body.maxY - h * 0.06))
            p.addLine(to: CGPoint(x: x + w * 0.16, y: y + h))
            p.addLine(to: CGPoint(x: x + w * 0.44, y: body.maxY - h * 0.02))
            p.closeSubpath()
            return p
        case .triangle:
            return poly([CGPoint(x: rect.midX, y: y), CGPoint(x: x + w, y: y + h),
                         CGPoint(x: x, y: y + h)])
        case .rightTriangle:
            return poly([CGPoint(x: x, y: y), CGPoint(x: x + w, y: y + h),
                         CGPoint(x: x, y: y + h)])
        case .diamond:
            return poly([CGPoint(x: rect.midX, y: y), CGPoint(x: x + w, y: rect.midY),
                         CGPoint(x: rect.midX, y: y + h), CGPoint(x: x, y: rect.midY)])
        case .pentagon: return regular(5)
        case .hexagon:  return regular(6)
        case .arrowRight: return arrow(rotation: 0)
        case .arrowLeft:  return arrow(rotation: .pi)
        case .arrowUp:    return arrow(rotation: -.pi / 2)
        case .arrowDown:  return arrow(rotation: .pi / 2)
        case .star4: return star(4, inner: 0.38)
        case .star5: return star(5, inner: 0.45)
        case .star6: return star(6, inner: 0.55)
        case .heart:
            let p = CGMutablePath()
            let tip = CGPoint(x: rect.midX, y: y + h)
            p.move(to: tip)
            // Left lobe, up and over.
            p.addCurve(to: CGPoint(x: x, y: y + h * 0.30),
                       control1: CGPoint(x: x + w * 0.30, y: y + h * 0.72),
                       control2: CGPoint(x: x, y: y + h * 0.52))
            p.addCurve(to: CGPoint(x: rect.midX, y: y + h * 0.24),
                       control1: CGPoint(x: x, y: y + h * 0.02),
                       control2: CGPoint(x: x + w * 0.44, y: y))
            // Right lobe, mirrored.
            p.addCurve(to: CGPoint(x: x + w, y: y + h * 0.30),
                       control1: CGPoint(x: x + w * 0.56, y: y),
                       control2: CGPoint(x: x + w, y: y + h * 0.02))
            p.addCurve(to: tip,
                       control1: CGPoint(x: x + w, y: y + h * 0.52),
                       control2: CGPoint(x: x + w * 0.70, y: y + h * 0.72))
            p.closeSubpath()
            return p
        default:
            return CGPath(rect: rect, transform: nil)
        }
    }

    private func drawShape(_ tool: Tool, in rect: CGRect) {
        guard rect.width >= 1, rect.height >= 1 else { return }
        let c = state.bitmap.ctx
        let inset = CGRect(x: rect.origin.x + 0.5, y: rect.origin.y + 0.5,
                           width: max(1, rect.width - 1), height: max(1, rect.height - 1))
        let path = CanvasView.shapePath(tool, in: inset)
        c.saveGState()
        c.setShouldAntialias(false)
        c.setLineWidth(state.lineWidth)
        switch state.fillStyle {
        case .outline:
            c.setStrokeColor(primaryColor.cgColorRGB)
            c.addPath(path); c.strokePath()
        case .filledBackground:
            c.setFillColor(secondaryColor.cgColorRGB)
            c.setStrokeColor(primaryColor.cgColorRGB)
            c.addPath(path); c.fillPath()
            c.addPath(path); c.strokePath()
        case .filledForeground:
            c.setFillColor(secondaryColor.cgColorRGB)
            c.addPath(path); c.fillPath()
        }
        c.restoreGState()
    }

    private func drawCurvePreview() {
        guard curvePoints.count >= 2 else { return }
        let c = state.bitmap.ctx
        c.saveGState()
        c.setShouldAntialias(false)
        c.setStrokeColor(primaryColor.cgColorRGB)
        c.setLineWidth(state.lineWidth)
        c.setLineCap(.round)
        let p0 = CGPoint(x: curvePoints[0].x + 0.5, y: curvePoints[0].y + 0.5)
        let p1 = CGPoint(x: curvePoints[1].x + 0.5, y: curvePoints[1].y + 0.5)
        c.move(to: p0)
        if curvePoints.count == 3 {
            let ctrl = CGPoint(x: curvePoints[2].x + 0.5, y: curvePoints[2].y + 0.5)
            c.addQuadCurve(to: p1, control: quadControl(p0, p1, ctrl))
        } else if curvePoints.count >= 4 {
            let c1 = CGPoint(x: curvePoints[2].x + 0.5, y: curvePoints[2].y + 0.5)
            let c2 = CGPoint(x: curvePoints[3].x + 0.5, y: curvePoints[3].y + 0.5)
            c.addCurve(to: p1, control1: bezControl(p0, p1, c1), control2: bezControl(p0, p1, c2))
        } else {
            c.addLine(to: p1)
        }
        c.strokePath()
        c.restoreGState()
    }

    /// Control points are derived so the curve actually passes near where the
    /// user dragged, matching Paint's feel.
    private func quadControl(_ a: CGPoint, _ b: CGPoint, _ through: CGPoint) -> CGPoint {
        CGPoint(x: 2 * through.x - (a.x + b.x) / 2, y: 2 * through.y - (a.y + b.y) / 2)
    }

    private func bezControl(_ a: CGPoint, _ b: CGPoint, _ through: CGPoint) -> CGPoint {
        CGPoint(x: through.x + (through.x - (a.x + b.x) / 2) * 0.5,
                y: through.y + (through.y - (a.y + b.y) / 2) * 0.5)
    }

    private func redrawPolygonPreview(to p: CGPoint) {
        guard let base = strokeBase else { return }
        restore(base)
        let c = state.bitmap.ctx
        c.saveGState()
        c.setShouldAntialias(false)
        c.setStrokeColor(primaryColor.cgColorRGB)
        c.setLineWidth(state.lineWidth)
        c.beginPath()
        c.move(to: CGPoint(x: polygonPoints[0].x + 0.5, y: polygonPoints[0].y + 0.5))
        for q in polygonPoints.dropFirst() { c.addLine(to: CGPoint(x: q.x + 0.5, y: q.y + 0.5)) }
        c.addLine(to: CGPoint(x: p.x + 0.5, y: p.y + 0.5))
        c.strokePath()
        c.restoreGState()
        needsDisplay = true
    }

    private func finishPolygon() {
        guard let base = strokeBase, polygonPoints.count >= 2 else {
            polygonPoints = []; strokeBase = nil; isDrawing = false; return
        }
        restore(base)
        let c = state.bitmap.ctx
        c.saveGState()
        c.setShouldAntialias(false)
        c.setLineWidth(state.lineWidth)
        c.beginPath()
        c.move(to: CGPoint(x: polygonPoints[0].x + 0.5, y: polygonPoints[0].y + 0.5))
        for q in polygonPoints.dropFirst() { c.addLine(to: CGPoint(x: q.x + 0.5, y: q.y + 0.5)) }
        c.closePath()
        switch state.fillStyle {
        case .outline:
            c.setStrokeColor(primaryColor.cgColorRGB); c.strokePath()
        case .filledBackground:
            c.setFillColor(secondaryColor.cgColorRGB)
            c.setStrokeColor(primaryColor.cgColorRGB)
            c.drawPath(using: .fillStroke)
        case .filledForeground:
            c.setFillColor(secondaryColor.cgColorRGB); c.fillPath()
        }
        c.restoreGState()
        polygonPoints = []
        strokeBase = nil
        isDrawing = false
        finishMutation()
    }

    /// Called when the tool changes or focus is lost, so half-finished
    /// polygons and curves do not linger.
    func cancelMultiStepTools() {
        if !polygonPoints.isEmpty { finishPolygon() }
        if curveStage != 0 || !curvePoints.isEmpty {
            curveStage = 0; curvePoints = []; strokeBase = nil
            finishMutation()
        }
    }

    private func setZoom(_ z: CGFloat) {
        commitFloating()
        state.zoom = z
        updateFrameSize()
        delegate?.canvasZoomChanged(z)
    }

    // MARK: - Selection

    private func beginSelectionInteraction(at p: CGPoint, event: NSEvent) {
        if let sel = currentSelectionRect {
            let vr = viewRect(forImage: sel)
            let vp = CGPoint(x: p.x * zoom, y: p.y * zoom)
            for (i, h) in handleRects(around: vr).enumerated() {
                if h.insetBy(dx: -3, dy: -3).contains(vp) {
                    liftSelectionIfNeeded()
                    dragMode = .resize(i)
                    originalSelRect = sel
                    dragAnchor = p
                    return
                }
            }
            if sel.contains(p) {
                // Option-drag leaves the original behind, like Ctrl-drag in Paint.
                liftSelectionIfNeeded(copy: event.modifierFlags.contains(.option))
                dragMode = .move
                dragAnchor = CGPoint(x: p.x - floatOrigin.x, y: p.y - floatOrigin.y)
                return
            }
        }
        commitFloating()
        dragMode = .newSelection
        lassoPoints = state.tool == .freeFormSelect ? [p] : []
        selectionRect = CGRect(origin: p, size: .zero)
        delegate?.canvasSelectionChanged(active: false)
    }

    private func dragSelection(to p: CGPoint, shift: Bool) {
        switch dragMode {
        case .newSelection:
            if state.tool == .freeFormSelect {
                lassoPoints.append(p)
            } else {
                selectionRect = rectBetween(dragStart, p, square: shift)
                delegate?.canvasSizeIndicator(selectionRect?.size)
            }
            needsDisplay = true

        case .move:
            floatOrigin = CGPoint(x: (p.x - dragAnchor.x).rounded(), y: (p.y - dragAnchor.y).rounded())
            needsDisplay = true

        case .resize(let handle):
            resizeFloating(handle: handle, to: p)
            needsDisplay = true

        case .none:
            break
        }
    }

    private func endSelectionInteraction(at p: CGPoint) {
        switch dragMode {
        case .newSelection:
            if state.tool == .freeFormSelect {
                if lassoPoints.count > 2 {
                    let xs = lassoPoints.map { $0.x }, ys = lassoPoints.map { $0.y }
                    let r = CGRect(x: xs.min()!, y: ys.min()!,
                                   width: max(1, xs.max()! - xs.min()!),
                                   height: max(1, ys.max()! - ys.min()!)).integral
                    selectionRect = r
                    buildLassoMask(rect: r)
                } else {
                    selectionRect = nil
                }
                lassoPoints = []
            } else if let r = selectionRect, r.width < 1 || r.height < 1 {
                selectionRect = nil
            }
            delegate?.canvasSelectionChanged(active: hasSelection)
        default:
            break
        }
        dragMode = .none
        needsDisplay = true
    }

    private func buildLassoMask(rect: CGRect) {
        let w = Int(rect.width), h = Int(rect.height)
        guard w > 0, h > 0 else { floatingMask = nil; return }
        // An 8-bit alpha mask: opaque inside the lasso, clear outside.
        guard let mctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                   bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                   bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
        mctx.setFillColor(CGColor(gray: 1, alpha: 1))
        mctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        mctx.translateBy(x: 0, y: CGFloat(h))
        mctx.scaleBy(x: 1, y: -1)
        mctx.setFillColor(CGColor(gray: 0, alpha: 1))
        mctx.beginPath()
        mctx.move(to: CGPoint(x: lassoPoints[0].x - rect.minX, y: lassoPoints[0].y - rect.minY))
        for q in lassoPoints.dropFirst() {
            mctx.addLine(to: CGPoint(x: q.x - rect.minX, y: q.y - rect.minY))
        }
        mctx.closePath()
        mctx.fillPath()
        floatingMask = mctx.makeImage()
    }

    /// Copies the selected pixels into a floating buffer and (unless copying)
    /// blanks the source area with the background colour.
    private func liftSelectionIfNeeded(copy: Bool = false) {
        guard !hasLifted, let sel = selectionRect else { return }
        state.beginUndo()
        let piece = state.bitmap.crop(sel)
        if !copy {
            let c = state.bitmap.ctx
            c.saveGState()
            c.setShouldAntialias(false)
            c.setFillColor(state.background.cgColorRGB)
            if let mask = floatingMask {
                // Free-form: only clear inside the lasso.
                c.saveGState()
                c.clip(to: sel, mask: invertedMask(mask) ?? mask)
                c.fill(sel)
                c.restoreGState()
            } else {
                c.fill(sel)
            }
            c.restoreGState()
        }
        floating = piece
        floatOrigin = sel.origin
        hasLifted = true
        delegate?.canvasSelectionChanged(active: true)
    }

    private func invertedMask(_ mask: CGImage) -> CGImage? {
        let w = mask.width, h = mask.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(mask, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let p = data.bindMemory(to: UInt8.self, capacity: w * h)
        for i in 0..<(w * h) { p[i] = 255 &- p[i] }
        return ctx.makeImage()
    }

    private func resizeFloating(handle: Int, to p: CGPoint) {
        guard floating != nil else { return }
        var r = originalSelRect
        // Handle order: 0..2 top row, 3..4 middle sides, 5..7 bottom row.
        switch handle {
        case 0: r = CGRect(x: p.x, y: p.y, width: r.maxX - p.x, height: r.maxY - p.y)
        case 1: r = CGRect(x: r.minX, y: p.y, width: r.width, height: r.maxY - p.y)
        case 2: r = CGRect(x: r.minX, y: p.y, width: p.x - r.minX, height: r.maxY - p.y)
        case 3: r = CGRect(x: p.x, y: r.minY, width: r.maxX - p.x, height: r.height)
        case 4: r = CGRect(x: r.minX, y: r.minY, width: p.x - r.minX, height: r.height)
        case 5: r = CGRect(x: p.x, y: r.minY, width: r.maxX - p.x, height: p.y - r.minY)
        case 6: r = CGRect(x: r.minX, y: r.minY, width: r.width, height: p.y - r.minY)
        default: r = CGRect(x: r.minX, y: r.minY, width: p.x - r.minX, height: p.y - r.minY)
        }
        guard r.width >= 1, r.height >= 1 else { return }
        selectionRect = r.integral
        floatOrigin = r.integral.origin
        resizedFloatingTarget = r.integral.size
        needsDisplay = true
    }

    private var resizedFloatingTarget: CGSize?

    /// Stamps the floating selection into the canvas.
    func commitFloating() {
        guard let f = floating else {
            selectionRect = nil
            floatingMask = nil
            hasLifted = false
            return
        }
        var image = f.cgImage
        if state.selectionMode == .transparent, let base = image {
            image = maskOut(color: state.background, from: base) ?? base
        } else if let mask = floatingMask, let base = image {
            image = base.masking(mask) ?? base
        }
        if let img = image {
            let size = resizedFloatingTarget ?? CGSize(width: f.width, height: f.height)
            state.bitmap.draw(img, in: CGRect(origin: floatOrigin, size: size))
        }
        floating = nil
        floatingMask = nil
        selectionRect = nil
        hasLifted = false
        resizedFloatingTarget = nil
        finishMutation()
        delegate?.canvasSelectionChanged(active: false)
    }

    func deselect() {
        commitFloating()
        selectionRect = nil
        lassoPoints = []
        needsDisplay = true
        delegate?.canvasSelectionChanged(active: false)
    }

    func selectAll() {
        commitFloating()
        state.tool = .select
        selectionRect = CGRect(origin: .zero, size: canvasPixelSize)
        floatingMask = nil
        hasLifted = false
        needsDisplay = true
        delegate?.canvasSelectionChanged(active: true)
    }

    // MARK: - Clipboard

    func copySelection() {
        guard let sel = currentSelectionRect else { return }
        let piece = floating ?? state.bitmap.crop(sel)
        var image = piece.cgImage
        if let mask = floatingMask, let base = image { image = base.masking(mask) ?? base }
        guard let cg = image else { return }
        let rep = NSBitmapImageRep(cgImage: cg)
        let pb = NSPasteboard.general
        pb.clearContents()
        if let png = rep.representation(using: .png, properties: [:]) {
            pb.setData(png, forType: .png)
        }
        pb.writeObjects([piece.nsImage])
    }

    func cutSelection() {
        guard currentSelectionRect != nil else { return }
        copySelection()
        deleteSelection()
    }

    func deleteSelection() {
        guard let sel = currentSelectionRect else { return }
        if floating != nil {
            floating = nil
            floatingMask = nil
            selectionRect = nil
            hasLifted = false
            finishMutation()
            delegate?.canvasSelectionChanged(active: false)
            return
        }
        state.beginUndo()
        let c = state.bitmap.ctx
        c.saveGState()
        c.setShouldAntialias(false)
        c.setFillColor(state.background.cgColorRGB)
        if let mask = floatingMask {
            c.clip(to: sel, mask: invertedMask(mask) ?? mask)
        }
        c.fill(sel)
        c.restoreGState()
        selectionRect = nil
        floatingMask = nil
        finishMutation()
        delegate?.canvasSelectionChanged(active: false)
    }

    func paste() {
        let pb = NSPasteboard.general
        guard let image = NSImage(pasteboard: pb) else { NSSound.beep(); return }
        var rect = CGRect(x: 0, y: 0, width: image.size.width, height: image.size.height)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return }
        insertFloating(cg)
    }

    /// Drops an image into the canvas as a floating selection at the top-left,
    /// which is what both Paste and "Paste From" do in Paint.
    func insertFloating(_ cg: CGImage) {
        commitFloating()
        state.beginUndo()
        let piece = Bitmap(width: cg.width, height: cg.height, fill: .white)
        piece.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        floating = piece
        floatingMask = nil
        floatOrigin = .zero
        selectionRect = CGRect(x: 0, y: 0, width: cg.width, height: cg.height)
        hasLifted = true
        resizedFloatingTarget = nil
        state.tool = .select
        needsDisplay = true
        delegate?.canvasSelectionChanged(active: true)
        delegate?.canvasDidModify()
    }

    /// The selected pixels as a standalone bitmap (used by Copy To…).
    func selectionBitmap() -> Bitmap? {
        guard let sel = currentSelectionRect else { return nil }
        return floating ?? state.bitmap.crop(sel)
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let key = event.keyCode
        switch key {
        case 51, 117:                      // delete / forward delete
            if hasSelection { deleteSelection() } else { super.keyDown(with: event) }
        case 53:                           // escape
            if textView != nil { cancelText() }
            else if hasSelection { deselect() }
            else { cancelMultiStepTools() }
        case 123, 124, 125, 126:           // arrow keys nudge the selection
            if hasSelection {
                liftSelectionIfNeeded()
                let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
                switch key {
                case 123: floatOrigin.x -= step
                case 124: floatOrigin.x += step
                case 125: floatOrigin.y += step
                default:  floatOrigin.y -= step
                }
                needsDisplay = true
            } else { super.keyDown(with: event) }
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - Text tool

    private func beginTextEditing(in rect: CGRect) {
        let vr = viewRect(forImage: rect)
        let tv = NSTextView(frame: vr)
        tv.font = textFont
        tv.textColor = state.foreground
        tv.drawsBackground = textOpaque
        tv.backgroundColor = textOpaque ? state.background : .clear
        tv.isRichText = false
        tv.delegate = self
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.isVerticallyResizable = false
        addSubview(tv)
        textView = tv
        textRect = rect
        window?.makeFirstResponder(tv)
        needsDisplay = true
    }

    func refreshTextAttributes() {
        textView?.font = textFont
        textView?.textColor = state.foreground
        textView?.drawsBackground = textOpaque
        textView?.backgroundColor = textOpaque ? state.background : .clear
        textView?.needsDisplay = true
    }

    var isEditingText: Bool { textView != nil }

    func commitText() {
        guard let tv = textView, let rect = textRect else { return }
        let text = tv.string
        tv.removeFromSuperview()
        textView = nil
        textRect = nil
        guard !text.isEmpty else { needsDisplay = true; return }

        state.beginUndo()
        let bmp = state.bitmap
        let gc = NSGraphicsContext(cgContext: bmp.ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        bmp.ctx.saveGState()
        if textOpaque {
            bmp.ctx.setShouldAntialias(false)
            bmp.ctx.setFillColor(state.background.cgColorRGB)
            bmp.ctx.fill(rect)
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: textFont,
            .foregroundColor: state.foreground
        ]
        NSString(string: text).draw(with: rect, options: [.usesLineFragmentOrigin], attributes: attrs)
        bmp.ctx.restoreGState()
        NSGraphicsContext.restoreGraphicsState()
        finishMutation()
    }

    func cancelText() {
        textView?.removeFromSuperview()
        textView = nil
        textRect = nil
        needsDisplay = true
    }

    func textDidChange(_ notification: Notification) { needsDisplay = true }
}
