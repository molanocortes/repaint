import AppKit

// Renders the real view hierarchy off screen and writes PNGs. Nothing is
// mocked up: this is the same RibbonView, CanvasView and StatusBarView the
// app runs, drawn into a bitmap instead of onto a display.

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

func capture(_ wc: PaintWindowController, to name: String) {
    guard let content = wc.window?.contentView else { return }
    content.layoutSubtreeIfNeeded()
    guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
    content.cacheDisplay(in: content.bounds, to: rep)
    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    let url = URL(fileURLWithPath: outDir).appendingPathComponent(name)
    try? data.write(to: url)
    print("wrote \(url.path)  (\(rep.pixelsWide)x\(rep.pixelsHigh))")
}

/// Paints the demo picture. Everything goes through the same routines the
/// tools use: filled polygons like the polygon tool, round dabs like the
/// brush, scattered pixels like the airbrush, and hard non-antialiased edges.
func drawArtwork(_ b: Bitmap) {
    let c = b.ctx
    c.saveGState()
    c.setShouldAntialias(false)
    let w = CGFloat(b.width), h = CGFloat(b.height)

    func rgb(_ r: Int, _ g: Int, _ bl: Int) -> NSColor { .fromRGB8(UInt8(r), UInt8(g), UInt8(bl)) }
    func mix(_ a: NSColor, _ d: NSColor, _ t: CGFloat) -> NSColor {
        let x = a.usingColorSpace(.sRGB)!, y = d.usingColorSpace(.sRGB)!
        let k = min(max(t, 0), 1)
        return NSColor(srgbRed: x.redComponent + (y.redComponent - x.redComponent) * k,
                       green: x.greenComponent + (y.greenComponent - x.greenComponent) * k,
                       blue: x.blueComponent + (y.blueComponent - x.blueComponent) * k, alpha: 1)
    }
    func path(_ pts: [CGPoint]) -> CGPath {
        let p = CGMutablePath(); p.addLines(between: pts); p.closeSubpath(); return p
    }
    func fill(_ p: CGPath, _ color: NSColor) {
        c.setFillColor(color.cgColorRGB); c.addPath(p); c.fillPath()
    }
    /// Fills a shape and confines everything the closure draws to it, so snow
    /// and shading can never escape the silhouette.
    func inside(_ p: CGPath, _ base: NSColor, _ body: () -> Void) {
        fill(p, base)
        c.saveGState(); c.addPath(p); c.clip(); body(); c.restoreGState()
    }
    func dab(_ from: CGPoint, _ to: CGPoint, _ color: NSColor, _ size: CGFloat) {
        c.setStrokeColor(color.cgColorRGB); c.setLineWidth(size); c.setLineCap(.round)
        c.move(to: from); c.addLine(to: to); c.strokePath()
    }
    /// Short strokes at a given angle: the painterly texture pass.
    func strokes(_ rect: CGRect, angle: CGFloat, count: Int, length: ClosedRange<CGFloat>,
                 width: ClosedRange<CGFloat>, tones: [NSColor]) {
        for _ in 0..<count {
            let x = CGFloat.random(in: rect.minX...rect.maxX)
            let y = CGFloat.random(in: rect.minY...rect.maxY)
            let l = CGFloat.random(in: length)
            let a = angle + CGFloat.random(in: -0.22...0.22)
            dab(CGPoint(x: x, y: y),
                CGPoint(x: x + cos(a) * l, y: y + sin(a) * l),
                tones.randomElement()!, CGFloat.random(in: width))
        }
    }
    func spatter(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat,
                 _ color: NSColor, _ count: Int) {
        let p = color.rgba8
        for _ in 0..<count {
            let a = CGFloat.random(in: 0..<(2 * .pi))
            let d = sqrt(CGFloat.random(in: 0..<1))
            b.setPixel(Int(cx + cos(a) * rx * d), Int(cy + sin(a) * ry * d), p)
        }
    }
    /// A ridge line with random jitter, for snow edges that are not straight.
    func jagged(_ from: CGPoint, _ to: CGPoint, _ steps: Int, _ amp: CGFloat) -> [CGPoint] {
        (0...steps).map { i -> CGPoint in
            let t = CGFloat(i) / CGFloat(steps)
            let j = (i == 0 || i == steps) ? 0 : CGFloat.random(in: -amp...amp)
            return CGPoint(x: from.x + (to.x - from.x) * t + j,
                           y: from.y + (to.y - from.y) * t + j * 0.6)
        }
    }

    let horizon = h * 0.62
    let skyTop = rgb(38, 74, 126), skyLow = rgb(202, 226, 244)

    // Sky.
    var y: CGFloat = 0
    while y < horizon { c.setFillColor(mix(skyTop, skyLow, pow(y / horizon, 0.85)).cgColorRGB)
        c.fill(CGRect(x: 0, y: y, width: w, height: 2)); y += 2 }
    strokes(CGRect(x: 0, y: 0, width: w, height: horizon * 0.72), angle: 0, count: 320,
            length: 30...110, width: 3...9,
            tones: [rgb(84, 122, 174), rgb(112, 148, 194), rgb(70, 108, 162)])

    // Sun.
    let sun = CGPoint(x: w * 0.76, y: h * 0.15)
    spatter(sun.x, sun.y, 130, 108, rgb(206, 228, 246), 2600)
    for (r, col) in [(58.0, rgb(226, 240, 250)), (40.0, rgb(246, 250, 254)),
                     (26.0, rgb(255, 253, 240))] {
        c.setFillColor(col.cgColorRGB)
        c.fillEllipse(in: CGRect(x: sun.x - r, y: sun.y - r, width: r * 2, height: r * 2))
    }

    // Clouds.
    func cloud(_ x: CGFloat, _ cy: CGFloat, _ scale: CGFloat) {
        let lumps: [(CGFloat, CGFloat, CGFloat)] = [(-78, 10, 24), (-44, -4, 32), (-8, -16, 38),
                                                    (28, -6, 33), (66, 8, 25), (100, 14, 18)]
        for (dx, dy, r) in lumps {
            let rr = r * scale
            for (off, tone) in [(6.0, rgb(196, 214, 234)), (0.0, rgb(244, 249, 253))] {
                c.setFillColor(tone.cgColorRGB)
                c.fillEllipse(in: CGRect(x: x + dx * scale - rr, y: cy + dy * scale - rr + off,
                                         width: rr * 2, height: rr * 2))
            }
        }
        strokes(CGRect(x: x - 110 * scale, y: cy - 34 * scale,
                       width: 230 * scale, height: 56 * scale),
                angle: 0.05, count: Int(90 * scale), length: 10...34, width: 2...5,
                tones: [rgb(255, 255, 255), rgb(222, 234, 248)])
    }
    cloud(w * 0.18, h * 0.15, 1.0)
    cloud(w * 0.52, h * 0.09, 0.72)
    cloud(w * 0.90, h * 0.27, 0.60)

    // Far range.
    let far = path([CGPoint(x: -10, y: horizon), CGPoint(x: w * 0.05, y: h * 0.45),
                    CGPoint(x: w * 0.16, y: h * 0.53), CGPoint(x: w * 0.27, y: h * 0.41),
                    CGPoint(x: w * 0.39, y: h * 0.54), CGPoint(x: w * 0.53, y: h * 0.46),
                    CGPoint(x: w * 0.67, y: h * 0.55), CGPoint(x: w * 0.81, y: h * 0.42),
                    CGPoint(x: w * 0.93, y: h * 0.52), CGPoint(x: w + 10, y: h * 0.45),
                    CGPoint(x: w + 10, y: horizon)])
    inside(far, rgb(150, 174, 204)) {
        strokes(CGRect(x: 0, y: h * 0.40, width: w, height: horizon - h * 0.40),
                angle: -1.1, count: 700, length: 12...40, width: 2...5,
                tones: [rgb(166, 188, 214), rgb(134, 158, 190), rgb(182, 202, 224)])
    }

    // Right shoulder.
    let shoulder = path([CGPoint(x: w * 0.60, y: horizon), CGPoint(x: w * 0.79, y: h * 0.28),
                         CGPoint(x: w * 0.89, y: h * 0.41), CGPoint(x: w + 10, y: h * 0.26),
                         CGPoint(x: w + 10, y: horizon)])
    inside(shoulder, rgb(104, 128, 166)) {
        fill(path(jagged(CGPoint(x: w * 0.72, y: h * 0.40), CGPoint(x: w * 0.79, y: h * 0.28), 6, 7)
                  + [CGPoint(x: w * 0.86, y: h * 0.40)]), rgb(232, 242, 252))
        strokes(CGRect(x: w * 0.58, y: h * 0.26, width: w * 0.44, height: horizon - h * 0.26),
                angle: -0.9, count: 500, length: 12...42, width: 2...6,
                tones: [rgb(118, 142, 178), rgb(92, 114, 152), rgb(140, 164, 196)])
    }

    // Main massif.
    let peak = CGPoint(x: w * 0.40, y: h * 0.13)
    let massif = path([CGPoint(x: -10, y: horizon), CGPoint(x: w * 0.16, y: h * 0.40),
                       CGPoint(x: w * 0.27, y: h * 0.31), peak,
                       CGPoint(x: w * 0.51, y: h * 0.29), CGPoint(x: w * 0.59, y: h * 0.43),
                       CGPoint(x: w * 0.74, y: horizon)])
    inside(massif, rgb(72, 90, 126)) {
        // Face catching the light from the right.
        fill(path([peak, CGPoint(x: w * 0.51, y: h * 0.29), CGPoint(x: w * 0.59, y: h * 0.43),
                   CGPoint(x: w * 0.74, y: horizon), CGPoint(x: w * 0.44, y: horizon)]),
             rgb(108, 130, 168))
        // Snow fields, edges deliberately ragged.
        fill(path([peak] + jagged(CGPoint(x: w * 0.47, y: h * 0.24),
                                  CGPoint(x: w * 0.31, y: h * 0.30), 9, 10)),
             rgb(240, 247, 253))
        fill(path([peak] + jagged(CGPoint(x: w * 0.455, y: h * 0.26),
                                  CGPoint(x: w * 0.40, y: h * 0.34), 6, 8)),
             rgb(210, 226, 242))
        fill(path(jagged(CGPoint(x: w * 0.20, y: h * 0.42), CGPoint(x: w * 0.30, y: h * 0.33), 7, 9)
                  + [CGPoint(x: w * 0.27, y: h * 0.47)]), rgb(226, 238, 250))
        // Couloirs and ridges.
        for (x0, y0, x1, y1) in [(0.40, 0.13, 0.30, 0.46), (0.40, 0.13, 0.50, 0.42),
                                 (0.27, 0.31, 0.21, 0.50), (0.51, 0.29, 0.57, 0.50),
                                 (0.40, 0.13, 0.38, 0.55)] {
            dab(CGPoint(x: w * CGFloat(x0), y: h * CGFloat(y0)),
                CGPoint(x: w * CGFloat(x1), y: h * CGFloat(y1)), rgb(52, 68, 100), 3)
        }
        strokes(CGRect(x: 0, y: h * 0.13, width: w * 0.80, height: horizon - h * 0.13),
                angle: -1.0, count: 1500, length: 12...46, width: 2...6,
                tones: [rgb(86, 106, 144), rgb(62, 78, 112), rgb(120, 142, 178),
                        rgb(200, 216, 236)])
        spatter(w * 0.38, h * 0.30, 120, 70, rgb(228, 240, 250), 1200)
        spatter(w * 0.24, h * 0.46, 100, 60, rgb(58, 74, 106), 900)
    }

    // Treeline.
    for i in 0..<86 {
        let tx = -10 + CGFloat(i) * (w + 20) / 86 + CGFloat.random(in: -5...5)
        let base = horizon + CGFloat.random(in: -3...3)
        let th = CGFloat.random(in: 16...34), tw = CGFloat.random(in: 0.28...0.40) * th
        fill(path([CGPoint(x: tx, y: base - th), CGPoint(x: tx + tw, y: base),
                   CGPoint(x: tx - tw, y: base)]),
             [rgb(26, 54, 50), rgb(34, 66, 58), rgb(20, 44, 42)].randomElement()!)
    }

    // Lake.
    let lake = CGRect(x: 0, y: horizon, width: w, height: h * 0.21)
    inside(path([CGPoint(x: 0, y: lake.minY), CGPoint(x: w, y: lake.minY),
                 CGPoint(x: w, y: lake.maxY), CGPoint(x: 0, y: lake.maxY)]),
           rgb(84, 126, 170)) {
        // Reflected snow, smeared into horizontal bands.
        for i in 0..<34 {
            let t = CGFloat(i) / 34
            let ly = lake.minY + t * lake.height
            let spread = 20 + t * 90
            dab(CGPoint(x: w * 0.40 - spread, y: ly), CGPoint(x: w * 0.40 + spread, y: ly),
                mix(rgb(186, 210, 234), rgb(96, 138, 180), t), CGFloat.random(in: 3...7))
        }
        strokes(lake, angle: 0, count: 420, length: 30...140, width: 3...7,
                tones: [rgb(76, 116, 160), rgb(104, 144, 184), rgb(64, 104, 148)])
        strokes(lake, angle: 0, count: 90, length: 16...60, width: 2...3,
                tones: [rgb(176, 204, 230), rgb(206, 226, 244)])
    }

    // Near bank.
    let bank = path([CGPoint(x: -10, y: lake.maxY - 6), CGPoint(x: w * 0.32, y: lake.maxY - 14),
                     CGPoint(x: w * 0.70, y: lake.maxY + 2), CGPoint(x: w + 10, y: lake.maxY - 10),
                     CGPoint(x: w + 10, y: h + 10), CGPoint(x: -10, y: h + 10)])
    inside(bank, rgb(30, 40, 40)) {
        for _ in 0..<34 {
            let rx = CGFloat.random(in: 0...w)
            let ry = CGFloat.random(in: (lake.maxY + 4)...h)
            let rr = CGFloat.random(in: 10...30)
            fill(path([CGPoint(x: rx - rr, y: ry + rr * 0.55),
                       CGPoint(x: rx - rr * 0.45, y: ry - rr * 0.5),
                       CGPoint(x: rx + rr * 0.35, y: ry - rr * 0.62),
                       CGPoint(x: rx + rr, y: ry + rr * 0.45)]),
                 [rgb(92, 104, 100), rgb(58, 70, 70), rgb(122, 132, 122)].randomElement()!)
        }
        strokes(CGRect(x: 0, y: lake.maxY - 10, width: w, height: h - lake.maxY + 10),
                angle: -0.25, count: 620, length: 14...52, width: 3...8,
                tones: [rgb(44, 56, 56), rgb(24, 32, 34), rgb(66, 78, 72)])
        // A little rim light where the bank meets the water.
        strokes(CGRect(x: 0, y: lake.maxY - 12, width: w, height: 22),
                angle: -0.12, count: 150, length: 12...44, width: 2...4,
                tones: [rgb(120, 136, 126), rgb(150, 166, 152)])
    }

    c.restoreGState()
}

let wc = PaintWindowController()
wc.window?.setContentSize(NSSize(width: 1180, height: 720))
wc.state.bitmap.resizeCanvas(width: 1000, height: 520, fill: .white)
drawArtwork(wc.state.bitmap)
wc.state.foreground = PaintState.defaultPalette[3]
wc.state.background = PaintState.defaultPalette[17]
wc.state.tool = .brush
wc.state.shapeFill = true
wc.canvas.updateFrameSize()
wc.canvasDidModify()
capture(wc, to: "screenshot-home.png")

// The View tab, plus a zoomed-in look at the pixel grid.
wc.ribbon.activeTab = 2
wc.state.zoom = 8
wc.state.showGrid = true
wc.canvas.updateFrameSize()
wc.canvasZoomChanged(wc.state.zoom)
if let clip = wc.canvas.enclosingScrollView?.contentView {
    clip.scroll(to: NSPoint(x: 2680, y: 760))
    wc.canvas.enclosingScrollView?.reflectScrolledClipView(clip)
}
capture(wc, to: "screenshot-view-zoom.png")

print("done")
