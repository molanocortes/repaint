import AppKit

var failures = 0
func check(_ name: String, _ condition: Bool) {
    print("\(condition ? "PASS" : "FAIL")  \(name)")
    if !condition { failures += 1 }
}

let scratch = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

// --- Canvas basics ---------------------------------------------------------
let bmp = Bitmap(width: 420, height: 300, fill: .white)
check("new canvas is white", bmp.pixel(10, 10) == (255, 255, 255, 255))
check("canvas dimensions", bmp.width == 420 && bmp.height == 300)

// --- Flood fill ------------------------------------------------------------
bmp.ctx.setShouldAntialias(false)
bmp.ctx.setStrokeColor(NSColor.black.cgColorRGB)
bmp.ctx.setLineWidth(1)
bmp.ctx.stroke(CGRect(x: 20.5, y: 20.5, width: 80, height: 60))
bmp.floodFill(x: 60, y: 50, with: NSColor.red)
check("flood fill paints inside", bmp.pixel(60, 50).0 == 255 && bmp.pixel(60, 50).1 == 0)
check("flood fill respects the border", bmp.pixel(10, 10) == (255, 255, 255, 255))

// --- Every shape in the gallery draws something ----------------------------
var shapesDrawn = 0
for (i, tool) in Tool.shapeGallery.enumerated() where tool.isDragShape {
    let probe = Bitmap(width: 60, height: 60, fill: .white)
    let path = CanvasView.shapePath(tool, in: CGRect(x: 6, y: 6, width: 48, height: 48))
    probe.ctx.saveGState()
    probe.ctx.setShouldAntialias(false)
    probe.ctx.setStrokeColor(NSColor.black.cgColorRGB)
    probe.ctx.setLineWidth(2)
    probe.ctx.addPath(path)
    probe.ctx.strokePath()
    probe.ctx.restoreGState()
    var inked = 0
    for y in 0..<60 { for x in 0..<60 where probe.pixel(x, y).0 < 128 { inked += 1 } }
    check("shape \(i) \(tool.title) draws ink", inked > 20)
    // The path must stay inside the box it was given.
    let bounds = path.boundingBox
    check("shape \(i) \(tool.title) stays in bounds",
          bounds.minX >= 4 && bounds.minY >= 4 && bounds.maxX <= 56 && bounds.maxY <= 56)
    shapesDrawn += 1
}
check("all drag shapes covered", shapesDrawn == 18)

// --- Orientation ------------------------------------------------------------
// A single marker in the top-left corner tells us whether any operation
// silently mirrors the picture.
func marked(_ w: Int = 40, _ h: Int = 30) -> Bitmap {
    let b = Bitmap(width: w, height: h, fill: .white)
    b.setPixel(0, 0, NSColor.red.rgba8)          // top-left
    b.setPixel(w - 1, 0, NSColor.green.rgba8)    // top-right
    b.setPixel(0, h - 1, NSColor.blue.rgba8)     // bottom-left
    return b
}
func isRed(_ b: Bitmap, _ x: Int, _ y: Int) -> Bool {
    let p = b.pixel(x, y); return p.0 > 200 && p.1 < 60 && p.2 < 60
}
func isGreen(_ b: Bitmap, _ x: Int, _ y: Int) -> Bool {
    let p = b.pixel(x, y); return p.1 > 100 && p.0 < 60 && p.2 < 60
}
func isBlue(_ b: Bitmap, _ x: Int, _ y: Int) -> Bool {
    let p = b.pixel(x, y); return p.2 > 200 && p.0 < 60 && p.1 < 60
}

let m = marked()
check("marker sanity", isRed(m, 0, 0) && isGreen(m, 39, 0) && isBlue(m, 0, 29))

let mCopy = m.copy()
check("copy preserves orientation", isRed(mCopy, 0, 0) && isBlue(mCopy, 0, 29))

let mCrop = m.crop(CGRect(x: 0, y: 0, width: 20, height: 15))
check("crop preserves orientation", isRed(mCrop, 0, 0) && !isBlue(mCrop, 0, 14))

let mGrown = m.copy()
mGrown.resizeCanvas(width: 60, height: 50, fill: .white)
check("canvas resize keeps the picture upright",
      isRed(mGrown, 0, 0) && isGreen(mGrown, 39, 0) && isBlue(mGrown, 0, 29))

// A blit of one bitmap into another (paste, and stamping a selection).
let host = Bitmap(width: 60, height: 50, fill: .white)
if let cg = m.cgImage { host.draw(cg, in: CGRect(x: 10, y: 5, width: 40, height: 30)) }
check("blit keeps the image upright",
      isRed(host, 10, 5) && isGreen(host, 49, 5) && isBlue(host, 10, 34))

check("flip horizontal moves top-left to top-right",
      isRed(m.transformed(.horizontal), 39, 0))
check("flip vertical moves top-left to bottom-left",
      isRed(m.transformed(.vertical), 0, 29))
check("rotate 180 moves top-left to bottom-right",
      isRed(m.transformed(.rotate180), 39, 29))
let r90 = m.transformed(.rotate90)
check("rotate 90 clockwise moves top-left to top-right",
      isRed(r90, 29, 0) && isGreen(r90, 29, 39))
let r270 = m.transformed(.rotate270)
check("rotate 270 moves top-left to bottom-left",
      isRed(r270, 0, 39) && isGreen(r270, 0, 0))
check("rotate 90 then 270 is a round trip",
      isRed(m.transformed(.rotate90).transformed(.rotate270), 0, 0))

let mStretch = m.stretchSkew(xPercent: 200, yPercent: 100, xDegrees: 0, yDegrees: 0)
check("stretch keeps the picture upright", isRed(mStretch, 0, 0) && isBlue(mStretch, 0, 29))

// --- Transforms ------------------------------------------------------------
let rot = bmp.transformed(.rotate90)
check("rotate 90 swaps dimensions", rot.width == 300 && rot.height == 420)
let rot180 = bmp.transformed(.rotate180)
check("rotate 180 keeps dimensions", rot180.width == 420 && rot180.height == 300)
let flip = bmp.transformed(.horizontal)
check("flip keeps dimensions", flip.width == 420 && flip.height == 300)

let stretched = bmp.stretchSkew(xPercent: 50, yPercent: 200, xDegrees: 0, yDegrees: 0)
check("stretch scales both axes", stretched.width == 210 && stretched.height == 600)
let skewed = bmp.stretchSkew(xPercent: 100, yPercent: 100, xDegrees: 20, yDegrees: 0)
check("skew widens the canvas", skewed.width > 420)

let cropped = bmp.crop(CGRect(x: 20, y: 20, width: 80, height: 60))
check("crop returns the requested size", cropped.width == 80 && cropped.height == 60)

// --- Canvas resize keeps content anchored top-left -------------------------
let resized = bmp.copy()
resized.resizeCanvas(width: 500, height: 400, fill: .white)
check("resize grows the canvas", resized.width == 500 && resized.height == 400)
check("resize keeps existing pixels", resized.pixel(60, 50).0 == 255 && resized.pixel(60, 50).1 == 0)
check("resize fills new area", resized.pixel(480, 380) == (255, 255, 255, 255))
resized.resizeCanvas(width: 100, height: 90, fill: .white)
check("resize shrinks the canvas", resized.width == 100 && resized.height == 90)
check("row stride tracks the new width after shrinking",
      resized.pixel(60, 50).0 == 255 && resized.pixel(60, 50).1 == 0)

// --- Invert ----------------------------------------------------------------
let inv = bmp.copy()
inv.invertColors()
check("invert flips white to black", inv.pixel(10, 10) == (0, 0, 0, 255))
inv.invertColors()
check("invert twice is a round trip", inv.pixel(10, 10) == (255, 255, 255, 255))

// --- Colour replace (the colour eraser) ------------------------------------
let rep = bmp.copy()
rep.replaceColor(from: .red, to: .blue)
check("replace colour swaps only the target",
      rep.pixel(60, 50).2 == 255 && rep.pixel(60, 50).0 == 0)

// --- Undo stack ------------------------------------------------------------
let st = PaintState(width: 40, height: 40)
check("undo starts empty", !st.canUndo && !st.canRedo)
st.beginUndo()
st.bitmap.clear(.red)
check("undo available after an edit", st.canUndo)
st.undo()
check("undo restores white", st.bitmap.pixel(5, 5) == (255, 255, 255, 255))
check("redo available after undo", st.canRedo)
st.redo()
check("redo reapplies red", st.bitmap.pixel(5, 5).0 == 255 && st.bitmap.pixel(5, 5).1 == 0)

// Undo across a size change.
st.beginUndo()
st.bitmap.resizeCanvas(width: 80, height: 70, fill: .white)
st.undo()
check("undo restores the previous canvas size", st.bitmap.width == 40 && st.bitmap.height == 40)

// --- Outline / fill mapping ------------------------------------------------
let ps = PaintState()
check("default is outline only", ps.fillStyle == .outline)
ps.shapeFill = true
check("outline plus fill", ps.fillStyle == .filledBackground)
ps.shapeOutline = false
check("fill only", ps.fillStyle == .filledForeground)

// --- Palette ---------------------------------------------------------------
check("palette has twenty colours", PaintState.defaultPalette.count == 20)
check("first swatch is black", PaintState.defaultPalette[0].hexString == "#000000")
check("eleventh swatch is white", PaintState.defaultPalette[10].hexString == "#FFFFFF")
check("red swatch matches Paint", PaintState.defaultPalette[3].hexString == "#ED1C24")

// --- File encoders ---------------------------------------------------------
guard let cg = bmp.cgImage else { fatalError("no image") }
let rep2 = NSBitmapImageRep(cgImage: cg)
for (name, type) in [("png", NSBitmapImageRep.FileType.png), ("jpg", .jpeg),
                     ("bmp", .bmp), ("gif", .gif), ("tiff", .tiff)] {
    let data = rep2.representation(using: type, properties: type == .jpeg
                                   ? [.compressionFactor: 0.9] : [:])
    check("encode \(name)", (data?.count ?? 0) > 100)
    if let data = data {
        let url = URL(fileURLWithPath: scratch).appendingPathComponent("engine-out.\(name)")
        try? data.write(to: url)
        let reread = NSImage(contentsOf: url)
        check("re-read \(name)", reread != nil && reread!.size.width == 420)
    }
}

print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
exit(failures == 0 ? 0 : 1)
