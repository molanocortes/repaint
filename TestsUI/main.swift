import AppKit

// Headless check of the ribbon's command handlers. A window is created but
// never ordered on screen, and the pasteboard is left alone.
var failures = 0
func check(_ name: String, _ condition: Bool) {
    print("\(condition ? "PASS" : "FAIL")  \(name)")
    if !condition { failures += 1 }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

let wc = PaintWindowController()
let st = wc.state

// --- Tools group -----------------------------------------------------------
for tool in [Tool.pencil, .fill, .text, .eraser, .pickColor, .magnifier] {
    let mi = NSMenuItem(); mi.tag = tool.rawValue
    wc.pickToolMenu(mi)
    check("Tools: \(tool.title) selected", st.tool == tool)
}

// --- Shapes gallery --------------------------------------------------------
for tool in Tool.shapeGallery {
    let mi = NSMenuItem(); mi.tag = tool.rawValue
    wc.pickToolMenu(mi)
    check("Shapes: \(tool.title) selected", st.tool == tool)
}

// --- Brushes ---------------------------------------------------------------
for (i, shape) in BrushShape.all.enumerated() {
    let mi = NSMenuItem(); mi.tag = i
    wc.pickBrush(mi)
    check("Brushes: entry \(i) selects brush", st.tool == .brush && st.brushShape == shape)
}
wc.pickAirbrush(NSMenuItem())
check("Brushes: airbrush", st.tool == .airbrush)

// --- Size ------------------------------------------------------------------
for (i, expected) in [(0, 1), (1, 3), (2, 5), (3, 5)] {
    let mi = NSMenuItem(); mi.tag = i
    wc.pickSize(mi)
    check("Size: entry \(i) -> \(Int(st.lineWidth))px", Int(st.lineWidth) == expected)
}

// --- Outline / Fill --------------------------------------------------------
let on = NSMenuItem(); on.tag = 1
let off = NSMenuItem(); off.tag = 0
wc.pickOutline(on); wc.pickFill(off)
check("Outline solid, no fill", st.fillStyle == .outline)
wc.pickFill(on)
check("Outline plus fill", st.fillStyle == .filledBackground)
wc.pickOutline(off)
check("Fill only", st.fillStyle == .filledForeground)
wc.pickOutline(on); wc.pickFill(off)

// --- Select ----------------------------------------------------------------
wc.pickSelectTool(off)
check("Select: rectangular", st.tool == .select)
wc.pickSelectTool(on)
check("Select: free-form", st.tool == .freeFormSelect)

// --- Image: rotate and flip ------------------------------------------------
let w0 = st.bitmap.width, h0 = st.bitmap.height
for (tag, name, swaps) in [(0, "Rotate right 90", true), (1, "Rotate left 90", true),
                           (2, "Rotate 180", false), (3, "Flip vertical", false),
                           (4, "Flip horizontal", false)] {
    let before = (st.bitmap.width, st.bitmap.height)
    let mi = NSMenuItem(); mi.tag = tag
    wc.applyRotate(mi)
    let after = (st.bitmap.width, st.bitmap.height)
    check("Image: \(name)", swaps ? (after == (before.1, before.0)) : (after == before))
}
check("rotations left the canvas at its original size",
      st.bitmap.width == w0 && st.bitmap.height == h0)

// --- Image: crop -----------------------------------------------------------
wc.canvas.selectAll()
check("Select all makes a selection", wc.canvas.hasSelection)
wc.cropToSelection()
check("Crop to a full selection keeps the size",
      st.bitmap.width == w0 && st.bitmap.height == h0)

// --- Clipboard path (no pasteboard involved) -------------------------------
let stamp = Bitmap(width: 40, height: 30, fill: .blue)
if let cg = stamp.cgImage { wc.canvas.insertFloating(cg) }
check("Insert creates a floating selection", wc.canvas.hasSelection)
wc.canvas.commitFloating()
let px = st.bitmap.pixel(5, 5)
check("Committing a selection stamps its pixels", px.2 > 200 && px.0 < 60)
check("Committing clears the selection", !wc.canvas.hasSelection)

// --- Edit: undo / redo -----------------------------------------------------
check("Undo is available after edits", st.canUndo)
wc.undo(nil)
check("Undo restores white", st.bitmap.pixel(5, 5) == (255, 255, 255, 255))
wc.redo(nil)
check("Redo reapplies the stamp", st.bitmap.pixel(5, 5).2 > 200)

// --- Image: invert and clear ----------------------------------------------
wc.invertColors(nil)
check("Invert Colors runs", st.bitmap.pixel(400, 400) == (0, 0, 0, 255))
wc.clearImage(nil)
check("Clear Image fills with Color 2", st.bitmap.pixel(400, 400) == (255, 255, 255, 255))

// --- View tab --------------------------------------------------------------
let zoomRect = NSRect.zero
wc.ribbonCommand(.zoom100, from: zoomRect)
check("View: 100%", st.zoom == 1)
wc.ribbonCommand(.zoomIn, from: zoomRect)
check("View: zoom in", st.zoom == 2)
wc.ribbonCommand(.zoomIn, from: zoomRect)
check("View: zoom in again", st.zoom == 4)
wc.ribbonCommand(.zoomOut, from: zoomRect)
check("View: zoom out", st.zoom == 2)
wc.ribbonCommand(.zoom100, from: zoomRect)
check("View: back to 100%", st.zoom == 1)

let gridBefore = st.showGrid
wc.ribbonCommand(.gridlines, from: zoomRect)
check("View: gridlines toggle", st.showGrid != gridBefore)
wc.ribbonCommand(.gridlines, from: zoomRect)
check("View: gridlines toggle back", st.showGrid == gridBefore)

let barBefore = wc.ribbon.showStatusBar
wc.ribbonCommand(.statusBarToggle, from: zoomRect)
check("View: status bar toggle", wc.ribbon.showStatusBar != barBefore)
wc.ribbonCommand(.statusBarToggle, from: zoomRect)
check("View: status bar toggle back", wc.ribbon.showStatusBar == barBefore)

// --- Colors ----------------------------------------------------------------
wc.ribbonPick(color: .red, secondary: false)
check("Palette click sets Color 1", st.foreground.hexString == "#FF0000")
wc.ribbonPick(color: .blue, secondary: true)
check("Palette right-click sets Color 2", st.background.hexString == "#0000FF")

// --- Tabs ------------------------------------------------------------------
wc.ribbonSelectTab(2)
check("View tab activates", wc.ribbon.activeTab == 2)
wc.ribbonSelectTab(1)
check("Home tab activates", wc.ribbon.activeTab == 1)

// --- Tool switching tidies up ---------------------------------------------
wc.canvas.selectAll()
wc.ribbonSelect(tool: .pencil)
check("Choosing a drawing tool drops the selection", !wc.canvas.hasSelection)

// --- File: open ------------------------------------------------------------
// The panel is skipped; this exercises the decode-and-install path behind it.
let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("paint-open-test.png")
let source = Bitmap(width: 90, height: 60, fill: .white)
source.setPixel(0, 0, NSColor.red.rgba8)
source.setPixel(89, 59, NSColor.green.rgba8)
if let cg = source.cgImage,
   let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
    try? data.write(to: tmp)
}
wc.loadImage(from: tmp)
check("File: Open loads the picture", st.bitmap.width == 90 && st.bitmap.height == 60)
let tl = st.bitmap.pixel(0, 0), br = st.bitmap.pixel(89, 59)
check("File: Open keeps the picture upright",
      tl.0 > 200 && tl.1 < 60 && br.1 > 100 && br.0 < 60)
check("File: Open clears the dirty flag", !st.isDirty)
try? FileManager.default.removeItem(at: tmp)

// --- Clipboard group -------------------------------------------------------
// The user's clipboard is captured first and put back at the end.
let pb = NSPasteboard.general
var saved: [[NSPasteboard.PasteboardType: Data]] = []
for item in pb.pasteboardItems ?? [] {
    var entry: [NSPasteboard.PasteboardType: Data] = [:]
    for type in item.types { if let d = item.data(forType: type) { entry[type] = d } }
    if !entry.isEmpty { saved.append(entry) }
}

wc.canvas.selectAll()
wc.copy(nil)
check("Copy puts an image on the clipboard",
      pb.canReadObject(forClasses: [NSImage.self], options: nil))
wc.canvas.deselect()
wc.paste(nil)
check("Paste creates a floating selection", wc.canvas.hasSelection)
check("Paste keeps the copied size",
      wc.canvas.currentSelectionRect.map { Int($0.width) == 90 && Int($0.height) == 60 } ?? false)
wc.canvas.commitFloating()

wc.canvas.selectAll()
wc.cut(nil)
check("Cut clears the cut area", st.bitmap.pixel(5, 5) == st.background.rgba8)
check("Cut leaves no selection", !wc.canvas.hasSelection)

pb.clearContents()
for entry in saved {
    let item = NSPasteboardItem()
    for (type, data) in entry { item.setData(data, forType: type) }
    pb.writeObjects([item])
}
print("(clipboard restored: \(saved.count) item(s))")

print(failures == 0 ? "\nALL UI CHECKS PASSED" : "\n\(failures) UI CHECK(S) FAILED")
exit(failures == 0 ? 0 : 1)
