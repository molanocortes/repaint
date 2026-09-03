import AppKit
import CoreGraphics

/// A plain 8-bit RGBA raster with a CoreGraphics context bound to it.
/// The context is pre-flipped so all drawing uses top-left origin image
/// coordinates, which matches the pixel buffer layout (row 0 == top row).
final class Bitmap {
    private(set) var width: Int
    private(set) var height: Int
    private(set) var data: UnsafeMutablePointer<UInt8>
    private(set) var ctx: CGContext
    private(set) var bytesPerRow: Int

    init(width: Int, height: Int, fill: NSColor? = .white) {
        let w = max(1, width), h = max(1, height)
        self.width = w
        self.height = h
        self.bytesPerRow = w * 4
        // Let CoreGraphics own the pixel memory: a CGImage handed out by
        // makeImage() can outlive this object, and a buffer we freed ourselves
        // would then be drawn as whatever now occupies that memory.
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        self.ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                             bytesPerRow: bytesPerRow, space: cs,
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        self.data = ctx.data!.bindMemory(to: UInt8.self, capacity: bytesPerRow * h)
        // Flip so (0,0) is the top-left corner.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.setShouldAntialias(false)
        ctx.interpolationQuality = .none
        if let fill = fill {
            ctx.saveGState()
            ctx.setFillColor(fill.cgColorRGB)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.restoreGState()
        }
    }

    // MARK: - Copies and snapshots

    func copy() -> Bitmap {
        let b = Bitmap(width: width, height: height, fill: nil)
        memcpy(b.data, data, bytesPerRow * height)
        return b
    }

    /// Raw pixel snapshot, used by the undo stack.
    func snapshot() -> Data { Data(bytes: data, count: bytesPerRow * height) }

    func restore(_ snap: Data, width w: Int, height h: Int) {
        if w != width || h != height { resizeCanvas(width: w, height: h, fill: .white) }
        snap.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                memcpy(data, base, min(raw.count, bytesPerRow * height))
            }
        }
    }

    var cgImage: CGImage? { ctx.makeImage() }

    var nsImage: NSImage {
        let img = NSImage(size: NSSize(width: width, height: height))
        if let cg = cgImage { img.addRepresentation(NSBitmapImageRep(cgImage: cg)) }
        return img
    }

    // MARK: - Pixel access

    @inline(__always) func offset(_ x: Int, _ y: Int) -> Int { y * bytesPerRow + x * 4 }

    @inline(__always) func inBounds(_ x: Int, _ y: Int) -> Bool {
        x >= 0 && y >= 0 && x < width && y < height
    }

    func pixel(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        guard inBounds(x, y) else { return (255, 255, 255, 255) }
        let o = offset(x, y)
        return (data[o], data[o + 1], data[o + 2], data[o + 3])
    }

    func color(at x: Int, _ y: Int) -> NSColor {
        let p = pixel(x, y)
        return NSColor(srgbRed: CGFloat(p.0) / 255, green: CGFloat(p.1) / 255,
                       blue: CGFloat(p.2) / 255, alpha: 1)
    }

    func setPixel(_ x: Int, _ y: Int, _ rgba: (UInt8, UInt8, UInt8, UInt8)) {
        guard inBounds(x, y) else { return }
        let o = offset(x, y)
        data[o] = rgba.0; data[o + 1] = rgba.1; data[o + 2] = rgba.2; data[o + 3] = rgba.3
    }

    // MARK: - Whole-image operations

    func clear(_ color: NSColor) {
        ctx.saveGState()
        ctx.setFillColor(color.cgColorRGB)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.restoreGState()
    }

    /// Draws a CGImage upright into a top-left-origin context.
    ///
    /// The context is pre-flipped so paths use image coordinates, but
    /// `CGContext.draw` still assumes a bottom-left origin — without undoing
    /// the flip for the blit, every image lands upside down.
    static func blit(_ image: CGImage, in rect: CGRect, into ctx: CGContext) {
        ctx.saveGState()
        ctx.setShouldAntialias(false)
        ctx.interpolationQuality = .none
        ctx.translateBy(x: 0, y: rect.midY * 2)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: rect)
        ctx.restoreGState()
    }

    func draw(_ image: CGImage, in rect: CGRect) {
        Bitmap.blit(image, in: rect, into: ctx)
    }

    /// Replaces the backing store with a new size, anchoring the old content
    /// at the top-left the way Paint's Attributes dialog does.
    func resizeCanvas(width newW: Int, height newH: Int, fill: NSColor) {
        let w = max(1, newW), h = max(1, newH)
        let old = cgImage
        let oldW = width, oldH = height
        let newRow = w * 4
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let nctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                             bytesPerRow: newRow, space: cs,
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        nctx.translateBy(x: 0, y: CGFloat(h))
        nctx.scaleBy(x: 1, y: -1)
        nctx.setShouldAntialias(false)
        nctx.interpolationQuality = .none
        nctx.setFillColor(fill.cgColorRGB)
        nctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        if let old = old {
            Bitmap.blit(old, in: CGRect(x: 0, y: 0, width: oldW, height: oldH), into: nctx)
        }
        ctx = nctx
        data = nctx.data!.bindMemory(to: UInt8.self, capacity: newRow * h)
        width = w
        height = h
        bytesPerRow = newRow
    }

    // MARK: - Flood fill (4-connected, scanline)

    func floodFill(x: Int, y: Int, with color: NSColor) {
        guard inBounds(x, y) else { return }
        let row = bytesPerRow
        let target = pixel(x, y)
        let c = color.rgba8
        if target.0 == c.0 && target.1 == c.1 && target.2 == c.2 { return }

        @inline(__always) func matches(_ px: Int, _ py: Int) -> Bool {
            let o = py * row + px * 4
            return data[o] == target.0 && data[o + 1] == target.1 && data[o + 2] == target.2
        }
        @inline(__always) func paint(_ px: Int, _ py: Int) {
            let o = py * row + px * 4
            data[o] = c.0; data[o + 1] = c.1; data[o + 2] = c.2; data[o + 3] = 255
        }

        var stack = [(x, y)]
        stack.reserveCapacity(1024)
        while let (sx, sy) = stack.popLast() {
            var lx = sx
            while lx >= 0 && matches(lx, sy) { lx -= 1 }
            lx += 1
            var rx = sx
            while rx < width && matches(rx, sy) { rx += 1 }
            rx -= 1
            if lx > rx { continue }
            for px in lx...rx { paint(px, sy) }
            for (ny, _) in [(sy - 1, 0), (sy + 1, 0)] where ny >= 0 && ny < height {
                var px = lx
                while px <= rx {
                    if matches(px, ny) {
                        stack.append((px, ny))
                        while px <= rx && matches(px, ny) { px += 1 }
                    }
                    px += 1
                }
            }
        }
    }

    func invertColors() {
        let row = bytesPerRow
        for y in 0..<height {
            for x in 0..<width {
                let o = y * row + x * 4
                data[o] = 255 &- data[o]
                data[o + 1] = 255 &- data[o + 1]
                data[o + 2] = 255 &- data[o + 2]
            }
        }
    }

    /// Replaces one colour with another across the whole image (Color Eraser).
    func replaceColor(from: NSColor, to: NSColor, tolerance: Int = 0) {
        let f = from.rgba8, t = to.rgba8
        let row = bytesPerRow
        for y in 0..<height {
            for x in 0..<width {
                let o = y * row + x * 4
                if abs(Int(data[o]) - Int(f.0)) <= tolerance,
                   abs(Int(data[o + 1]) - Int(f.1)) <= tolerance,
                   abs(Int(data[o + 2]) - Int(f.2)) <= tolerance {
                    data[o] = t.0; data[o + 1] = t.1; data[o + 2] = t.2; data[o + 3] = 255
                }
            }
        }
    }

    // MARK: - Geometry transforms

    enum FlipRotate { case horizontal, vertical, rotate90, rotate180, rotate270 }

    func transformed(_ op: FlipRotate) -> Bitmap {
        let swapDims = (op == .rotate90 || op == .rotate270)
        let nw = swapDims ? height : width
        let nh = swapDims ? width : height
        let out = Bitmap(width: nw, height: nh, fill: .white)
        let srcRow = bytesPerRow, dstRow = out.bytesPerRow
        // Remap pixel by pixel; image coordinates run top-left with y down.
        for y in 0..<height {
            for x in 0..<width {
                let dx: Int, dy: Int
                switch op {
                case .horizontal: dx = width - 1 - x;  dy = y
                case .vertical:   dx = x;              dy = height - 1 - y
                case .rotate180:  dx = width - 1 - x;  dy = height - 1 - y
                case .rotate90:   dx = height - 1 - y; dy = x
                case .rotate270:  dx = y;              dy = width - 1 - x
                }
                let so = y * srcRow + x * 4
                let dof = dy * dstRow + dx * 4
                out.data[dof] = data[so]
                out.data[dof + 1] = data[so + 1]
                out.data[dof + 2] = data[so + 2]
                out.data[dof + 3] = data[so + 3]
            }
        }
        return out
    }

    /// Paint's Stretch/Skew: percentage scale plus degree shear.
    func stretchSkew(xPercent: Double, yPercent: Double,
                     xDegrees: Double, yDegrees: Double) -> Bitmap {
        guard let src = cgImage else { return copy() }
        let sx = max(0.01, xPercent / 100.0)
        let sy = max(0.01, yPercent / 100.0)
        let sw = Double(width) * sx
        let sh = Double(height) * sy
        let tanX = tan(xDegrees * .pi / 180.0)
        let tanY = tan(yDegrees * .pi / 180.0)
        let nw = Int((sw + abs(tanX) * sh).rounded())
        let nh = Int((sh + abs(tanY) * sw).rounded())
        let out = Bitmap(width: max(1, nw), height: max(1, nh), fill: .white)
        let c = out.ctx
        c.saveGState()
        c.translateBy(x: tanX < 0 ? CGFloat(abs(tanX) * sh) : 0,
                      y: tanY < 0 ? CGFloat(abs(tanY) * sw) : 0)
        c.concatenate(CGAffineTransform(a: 1, b: CGFloat(tanY), c: CGFloat(tanX), d: 1, tx: 0, ty: 0))
        Bitmap.blit(src, in: CGRect(x: 0, y: 0, width: sw, height: sh), into: c)
        c.restoreGState()
        return out
    }

    /// Extracts a sub-rectangle as a new bitmap.
    func crop(_ rect: CGRect) -> Bitmap {
        let r = rect.integral
        let out = Bitmap(width: Int(r.width), height: Int(r.height), fill: .white)
        if let src = cgImage {
            Bitmap.blit(src, in: CGRect(x: -r.origin.x, y: -r.origin.y,
                                        width: CGFloat(width), height: CGFloat(height)),
                        into: out.ctx)
        }
        return out
    }
}

// MARK: - Colour helpers

extension NSColor {
    /// sRGB CGColor with alpha forced opaque — the canvas has no transparency.
    var cgColorRGB: CGColor {
        let c = usingColorSpace(.sRGB) ?? NSColor.black
        return CGColor(srgbRed: c.redComponent, green: c.greenComponent,
                       blue: c.blueComponent, alpha: 1)
    }

    var rgba8: (UInt8, UInt8, UInt8, UInt8) {
        let c = usingColorSpace(.sRGB) ?? NSColor.black
        return (UInt8((c.redComponent * 255).rounded()),
                UInt8((c.greenComponent * 255).rounded()),
                UInt8((c.blueComponent * 255).rounded()), 255)
    }

    var hexString: String {
        let p = rgba8
        return String(format: "#%02X%02X%02X", p.0, p.1, p.2)
    }

    static func fromRGB8(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }
}
