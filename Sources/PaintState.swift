import AppKit

enum Tool: Int, CaseIterable {
    case freeFormSelect, select, eraser, fill, pickColor, magnifier, pencil, brush
    case airbrush, text, line, curve, rectangle, polygon, ellipse, roundRect
    // Shapes added in the ribbon-era Paint.
    case triangle, rightTriangle, diamond, pentagon, hexagon
    case arrowRight, arrowLeft, arrowUp, arrowDown
    case star4, star5, star6, calloutRounded, calloutOval, heart

    /// The Shapes gallery, in ribbon order: three rows of seven.
    static let shapeGallery: [Tool] = [
        .line, .curve, .ellipse, .rectangle, .roundRect, .triangle, .rightTriangle,
        .diamond, .pentagon, .hexagon, .arrowRight, .arrowLeft, .arrowUp, .arrowDown,
        .star4, .star5, .star6, .calloutRounded, .calloutOval, .heart, .polygon
    ]

    /// Shapes drawn by dragging out a bounding box.
    var isDragShape: Bool {
        switch self {
        case .rectangle, .ellipse, .roundRect, .triangle, .rightTriangle, .diamond,
             .pentagon, .hexagon, .arrowRight, .arrowLeft, .arrowUp, .arrowDown,
             .star4, .star5, .star6, .calloutRounded, .calloutOval, .heart:
            return true
        default: return false
        }
    }

    /// Original toolbox order, kept for reference: two columns, row by row.
    static let toolboxOrder: [Tool] = [
        .freeFormSelect, .select,
        .eraser, .fill,
        .pickColor, .magnifier,
        .pencil, .brush,
        .airbrush, .text,
        .line, .curve,
        .rectangle, .polygon,
        .ellipse, .roundRect
    ]

    var title: String {
        switch self {
        case .freeFormSelect: return "Free-Form Select"
        case .select: return "Select"
        case .eraser: return "Eraser/Color Eraser"
        case .fill: return "Fill With Color"
        case .pickColor: return "Pick Color"
        case .magnifier: return "Magnifier"
        case .pencil: return "Pencil"
        case .brush: return "Brush"
        case .airbrush: return "Airbrush"
        case .text: return "Text"
        case .line: return "Line"
        case .curve: return "Curve"
        case .rectangle: return "Rectangle"
        case .polygon: return "Polygon"
        case .ellipse: return "Oval"
        case .roundRect: return "Rounded Rectangle"
        case .triangle: return "Triangle"
        case .rightTriangle: return "Right Triangle"
        case .diamond: return "Diamond"
        case .pentagon: return "Pentagon"
        case .hexagon: return "Hexagon"
        case .arrowRight: return "Right Arrow"
        case .arrowLeft: return "Left Arrow"
        case .arrowUp: return "Up Arrow"
        case .arrowDown: return "Down Arrow"
        case .star4: return "Four-Point Star"
        case .star5: return "Five-Point Star"
        case .star6: return "Six-Point Star"
        case .calloutRounded: return "Rounded Rectangular Callout"
        case .calloutOval: return "Oval Callout"
        case .heart: return "Heart"
        }
    }

    /// Hint shown in the status bar, mirroring Paint's wording.
    var hint: String {
        switch self {
        case .freeFormSelect: return "Selects a free-form part of the picture to move, copy, or edit."
        case .select: return "Selects a rectangular part of the picture to move, copy, or edit."
        case .eraser: return "Erases a portion of the picture, using the selected eraser shape."
        case .fill: return "Fills an area with the current drawing color."
        case .pickColor: return "Picks up a color from the picture for drawing."
        case .magnifier: return "Changes the magnification."
        case .pencil: return "Draws a free-form line one pixel wide."
        case .brush: return "Draws using a brush with the selected shape and size."
        case .airbrush: return "Draws using an airbrush of the selected size."
        case .text: return "Inserts text into the picture."
        case .line: return "Draws a straight line with the selected line width."
        case .curve: return "Draws a curved line with the selected line width."
        case .rectangle: return "Draws a rectangle with the selected fill style."
        case .polygon: return "Draws a polygon with the selected fill style."
        case .ellipse: return "Draws an oval with the selected outline and fill."
        default: return "Drag to draw a \(title.lowercased()) with the selected outline and fill."
        }
    }

    /// Tools the Outline / Fill dropdowns apply to.
    var usesFillStyle: Bool { isDragShape || self == .polygon }

    /// Tools the Size dropdown applies to.
    var usesLineWidth: Bool {
        isDragShape || self == .polygon || self == .line || self == .curve
    }
}

/// Outline / filled-with-background / filled-with-foreground, as in Paint.
enum FillStyle: Int { case outline = 0, filledBackground = 1, filledForeground = 2 }

/// Selection-mode toggle from Paint's tool options (opaque vs. transparent).
enum SelectionMode: Int { case opaque = 0, transparent = 1 }

/// Brush shape families available under the Brush tool.
enum BrushShape: Int {
    case circle3, circle5, circle8
    case square3, square5, square8
    case slashLeft3, slashLeft5, slashLeft8
    case slashRight3, slashRight5, slashRight8

    var size: CGFloat {
        switch self {
        case .circle3, .square3, .slashLeft3, .slashRight3: return 3
        case .circle5, .square5, .slashLeft5, .slashRight5: return 5
        case .circle8, .square8, .slashLeft8, .slashRight8: return 9
        }
    }

    enum Family { case circle, square, slashLeft, slashRight }

    var family: Family {
        switch self {
        case .circle3, .circle5, .circle8: return .circle
        case .square3, .square5, .square8: return .square
        case .slashLeft3, .slashLeft5, .slashLeft8: return .slashLeft
        case .slashRight3, .slashRight5, .slashRight8: return .slashRight
        }
    }

    static let all: [BrushShape] = [
        .circle3, .square3, .slashLeft3, .slashRight3,
        .circle5, .square5, .slashLeft5, .slashRight5,
        .circle8, .square8, .slashLeft8, .slashRight8
    ]
}

/// Everything the canvas, toolbox and palette read from and write to.
final class PaintState {
    // Document
    var bitmap: Bitmap
    var fileURL: URL?
    var isDirty = false

    // Colours
    var foreground: NSColor = .black
    var background: NSColor = .white

    /// The 28 classic Paint palette entries (two rows of fourteen).
    var palette: [NSColor] = PaintState.defaultPalette

    // Tool settings
    var tool: Tool = .pencil
    var brushShape: BrushShape = .circle5
    var eraserSizeIndex = 1          // 0...3 -> 4, 6, 8, 10 px
    var airbrushSizeIndex = 0        // 0...2
    var lineWidthIndex = 0           // 0...4 -> 1...5 px
    var shapeOutline = true
    var shapeFill = false
    var selectionMode: SelectionMode = .opaque
    var zoom: CGFloat = 1
    var showGrid = false

    /// Paint draws the outline with Color 1 and the fill with Color 2.
    var fillStyle: FillStyle {
        if shapeFill && shapeOutline { return .filledBackground }
        if shapeFill { return .filledForeground }
        return .outline
    }

    var eraserSize: CGFloat { [4, 6, 8, 10][eraserSizeIndex] }
    var airbrushSize: CGFloat { [9, 15, 23][airbrushSizeIndex] }
    var lineWidth: CGFloat { CGFloat(lineWidthIndex + 1) }

    // Undo / redo
    private struct Snap { let data: Data; let w: Int; let h: Int }
    private var undoStack: [Snap] = []
    private var redoStack: [Snap] = []
    private let undoLimit = 50

    init(width: Int = 640, height: Int = 480) {
        bitmap = Bitmap(width: width, height: height, fill: .white)
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Call immediately *before* mutating the bitmap.
    func beginUndo() {
        undoStack.append(Snap(data: bitmap.snapshot(), w: bitmap.width, h: bitmap.height))
        if undoStack.count > undoLimit { undoStack.removeFirst() }
        redoStack.removeAll()
        isDirty = true
    }

    func undo() {
        guard let snap = undoStack.popLast() else { return }
        redoStack.append(Snap(data: bitmap.snapshot(), w: bitmap.width, h: bitmap.height))
        apply(snap)
    }

    func redo() {
        guard let snap = redoStack.popLast() else { return }
        undoStack.append(Snap(data: bitmap.snapshot(), w: bitmap.width, h: bitmap.height))
        apply(snap)
    }

    private func apply(_ snap: Snap) {
        if snap.w != bitmap.width || snap.h != bitmap.height {
            bitmap = Bitmap(width: snap.w, height: snap.h, fill: .white)
        }
        bitmap.restore(snap.data, width: snap.w, height: snap.h)
        isDirty = true
    }

    /// Swaps in a whole new raster (rotate, stretch, open, new).
    func replaceBitmap(_ new: Bitmap, registerUndo: Bool = true) {
        if registerUndo { beginUndo() }
        bitmap = new
        isDirty = registerUndo
    }

    func resetUndo() {
        undoStack.removeAll()
        redoStack.removeAll()
    }

    static let defaultPalette: [NSColor] = {
        let hexes = [
            // Top row
            "000000", "7F7F7F", "880015", "ED1C24", "FF7F27",
            "FFF200", "22B14C", "00A2E8", "3F48CC", "A349A4",
            // Bottom row
            "FFFFFF", "C3C3C3", "B97A57", "FFAEC9", "FFC90E",
            "EFE4B0", "B5E61D", "99D9EA", "7092BE", "C8BFE7"
        ]
        return hexes.map { hex in
            var v: UInt64 = 0
            Scanner(string: hex).scanHexInt64(&v)
            return NSColor.fromRGB8(UInt8((v >> 16) & 0xFF),
                                    UInt8((v >> 8) & 0xFF),
                                    UInt8(v & 0xFF))
        }
    }()
}
