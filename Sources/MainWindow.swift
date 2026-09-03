import AppKit
import UniformTypeIdentifiers

final class PaintWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation,
                                   CanvasViewDelegate, RibbonDelegate {
    let state = PaintState()
    var canvas: CanvasView!
    var ribbon: RibbonView!
    private var scrollView: NSScrollView!
    private var statusBar: StatusBarView!
    private var textPanel: NSPanel?
    private var editingColorSlot = 0

    convenience init() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "Untitled - Paint"
        win.minSize = NSSize(width: 900, height: 520)
        self.init(window: win)
        win.delegate = self
        buildUI()
        win.center()
    }

    // MARK: - UI assembly

    private func buildUI() {
        guard let win = window else { return }
        let content = FlippedView(frame: win.contentLayoutRect)
        content.autoresizingMask = [.width, .height]
        win.contentView = content

        canvas = CanvasView(state: state)
        canvas.delegate = self
        canvas.updateFrameSize()

        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .noBorder
        scrollView.backgroundColor = Chrome.canvasBack
        scrollView.drawsBackground = true
        let clip = FlippedClipView()
        clip.drawsBackground = true
        clip.backgroundColor = Chrome.canvasBack
        scrollView.contentView = clip
        scrollView.documentView = canvas

        ribbon = RibbonView(state: state)
        ribbon.delegate = self

        statusBar = StatusBarView()

        content.addSubview(scrollView)
        content.addSubview(ribbon)
        content.addSubview(statusBar)
        layoutViews()
        updateStatusMetrics()
    }

    private func layoutViews() {
        guard let content = window?.contentView else { return }
        let b = content.bounds
        let statusH: CGFloat = ribbon.showStatusBar ? 26 : 0
        ribbon.frame = NSRect(x: 0, y: 0, width: b.width, height: RibbonView.height)
        statusBar.frame = NSRect(x: 0, y: b.height - statusH, width: b.width, height: statusH)
        scrollView.frame = NSRect(x: 0, y: RibbonView.height, width: b.width,
                                  height: b.height - RibbonView.height - statusH)
        [ribbon, statusBar, scrollView].forEach { $0?.needsDisplay = true }
    }

    func windowDidResize(_ notification: Notification) { layoutViews() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        confirmDiscardChanges()
    }

    // MARK: - Canvas delegate

    func canvasCursorMoved(to point: CGPoint?) {
        statusBar.coordinate = point.map { "\(Int($0.x)), \(Int($0.y))px" } ?? ""
    }

    func canvasSizeIndicator(_ size: CGSize?) {
        statusBar.sizeText = size.map { "\(Int($0.width)) x \(Int($0.height))px" } ?? ""
    }

    func canvasDidModify() {
        updateTitle()
        updateStatusMetrics()
    }

    func canvasZoomChanged(_ zoom: CGFloat) {
        statusBar.zoomText = "\(Int(zoom * 100))%"
        ribbon.needsDisplay = true
    }

    func canvasColorsChanged() {
        ribbon.needsDisplay = true
        canvas.refreshTextAttributes()
    }

    func canvasSelectionChanged(active: Bool) { }

    private func updateStatusMetrics() {
        statusBar.canvasText = "\(state.bitmap.width) x \(state.bitmap.height)px"
        statusBar.zoomText = "\(Int(state.zoom * 100))%"
    }

    // MARK: - Ribbon delegate

    func ribbonSelect(tool: Tool) {
        canvas.cancelMultiStepTools()
        if tool != .text { canvas.commitText() }
        if tool != .select && tool != .freeFormSelect { canvas.deselect() }
        statusBar.hint = tool.hint
        ribbon.needsDisplay = true
        if tool == .text { showTextPanel() } else { hideTextPanel() }
    }

    func ribbonPick(color: NSColor, secondary: Bool) {
        if secondary { state.background = color } else { state.foreground = color }
        canvas.refreshTextAttributes()
        ribbon.needsDisplay = true
    }

    func ribbonEditColor(slot: Int) {
        editingColorSlot = slot
        let panel = NSColorPanel.shared
        panel.color = slot == 0 ? state.foreground : state.background
        panel.setTarget(self)
        panel.setAction(#selector(colorSlotChanged(_:)))
        panel.makeKeyAndOrderFront(nil)
    }

    @objc func colorSlotChanged(_ sender: NSColorPanel) {
        if editingColorSlot == 0 { state.foreground = sender.color }
        else { state.background = sender.color }
        canvas.refreshTextAttributes()
        ribbon.needsDisplay = true
    }

    func ribbonSelectTab(_ tab: Int) {
        if tab == 0 { showFileMenu() } else { ribbon.activeTab = tab; ribbon.needsDisplay = true }
    }

    func ribbonCommand(_ command: RibbonView.Command, from rect: NSRect) {
        switch command {
        case .paste: paste(nil)
        case .cut: cut(nil)
        case .copy: copy(nil)
        case .save: saveDocument(nil)
        case .undo: undo(nil)
        case .redo: redo(nil)
        case .crop: cropToSelection()
        case .resize: stretchSkew(nil)
        case .editColors: ribbonEditColor(slot: 0)
        case .rotate: popUp(rotateMenu(), from: rect)
        case .selectMenu: popUp(selectMenu(), from: rect)
        case .brushesMenu: popUp(brushesMenu(), from: rect)
        case .sizeMenu: popUp(sizeMenu(), from: rect)
        case .outlineMenu: popUp(outlineMenu(), from: rect)
        case .fillMenu: popUp(fillMenu(), from: rect)
        case .zoomIn: stepZoom(+1)
        case .zoomOut: stepZoom(-1)
        case .zoom100: setZoom(1)
        case .gridlines:
            state.showGrid.toggle()
            canvas.needsDisplay = true
            ribbon.needsDisplay = true
        case .statusBarToggle:
            ribbon.showStatusBar.toggle()
            statusBar.isHidden = !ribbon.showStatusBar
            layoutViews()
        case .fullScreen:
            window?.toggleFullScreen(nil)
        }
    }

    private let zoomLevels: [CGFloat] = [0.25, 0.5, 1, 2, 4, 6, 8]

    private func stepZoom(_ direction: Int) {
        let current = zoomLevels.firstIndex(of: state.zoom) ?? 2
        let next = min(zoomLevels.count - 1, max(0, current + direction))
        setZoom(zoomLevels[next])
    }

    private func setZoom(_ z: CGFloat) {
        canvas.commitFloating()
        state.zoom = z
        canvas.updateFrameSize()
        canvasZoomChanged(z)
    }

    private func popUp(_ menu: NSMenu, from rect: NSRect) {
        // Clicking a ribbon dropdown should focus Paint first, otherwise the
        // menu opens behind whatever app currently has key.
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        // Showing the menu from inside mouseDown lets the matching mouseUp
        // dismiss it immediately; let the event queue drain first.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            menu.popUp(positioning: nil,
                       at: NSPoint(x: rect.minX, y: rect.maxY + 2), in: self.ribbon)
        }
    }

    private func item(_ title: String, _ action: Selector, _ tag: Int = 0,
                      on: Bool = false) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        i.tag = tag
        i.state = on ? .on : .off
        return i
    }

    private func selectMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(item("Rectangular selection", #selector(pickSelectTool(_:)), 0,
                       on: state.tool == .select))
        m.addItem(item("Free-form selection", #selector(pickSelectTool(_:)), 1,
                       on: state.tool == .freeFormSelect))
        m.addItem(.separator())
        m.addItem(item("Select all", #selector(selectAllImage(_:))))
        m.addItem(item("Delete", #selector(delete(_:))))
        m.addItem(.separator())
        m.addItem(item("Transparent selection", #selector(toggleDrawOpaque(_:)), 0,
                       on: state.selectionMode == .transparent))
        return m
    }

    private func rotateMenu() -> NSMenu {
        let m = NSMenu()
        for (i, t) in ["Rotate right 90°", "Rotate left 90°", "Rotate 180°",
                       "Flip vertical", "Flip horizontal"].enumerated() {
            m.addItem(item(t, #selector(applyRotate(_:)), i))
        }
        return m
    }

    private func brushesMenu() -> NSMenu {
        let m = NSMenu()
        for (i, shape) in BrushShape.all.enumerated() {
            let name: String
            switch shape.family {
            case .circle: name = "Round brush"
            case .square: name = "Square brush"
            case .slashLeft: name = "Left diagonal"
            case .slashRight: name = "Right diagonal"
            }
            m.addItem(item("\(name) — \(Int(shape.size))px", #selector(pickBrush(_:)), i,
                           on: state.tool == .brush && state.brushShape == shape))
        }
        m.addItem(.separator())
        m.addItem(item("Airbrush", #selector(pickAirbrush(_:)), 0, on: state.tool == .airbrush))
        return m
    }

    private func sizeMenu() -> NSMenu {
        let m = NSMenu()
        for (i, px) in [1, 3, 5, 8].enumerated() {
            m.addItem(item("\(px)px", #selector(pickSize(_:)), i,
                           on: state.lineWidthIndex == i))
        }
        return m
    }

    private func outlineMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(item("No outline", #selector(pickOutline(_:)), 0, on: !state.shapeOutline))
        m.addItem(item("Solid color", #selector(pickOutline(_:)), 1, on: state.shapeOutline))
        return m
    }

    private func fillMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(item("No fill", #selector(pickFill(_:)), 0, on: !state.shapeFill))
        m.addItem(item("Solid color", #selector(pickFill(_:)), 1, on: state.shapeFill))
        return m
    }

    private func showFileMenu() {
        let m = NSMenu()
        m.addItem(item("New", #selector(newDocument(_:))))
        m.addItem(item("Open…", #selector(openDocument(_:))))
        m.addItem(item("Save", #selector(saveDocument(_:))))
        m.addItem(item("Save as…", #selector(saveDocumentAs(_:))))
        m.addItem(.separator())
        m.addItem(item("Print…", #selector(printDocument(_:))))
        m.addItem(.separator())
        m.addItem(item("Properties…", #selector(imageAttributes(_:))))
        popUp(m, from: NSRect(x: 4, y: 26, width: 52, height: 24))
    }

    @objc func pickToolMenu(_ sender: NSMenuItem) {
        guard let t = Tool(rawValue: sender.tag) else { return }
        state.tool = t
        ribbonSelect(tool: t)
    }

    @objc func pickSelectTool(_ s: NSMenuItem) {
        state.tool = s.tag == 0 ? .select : .freeFormSelect
        ribbonSelect(tool: state.tool)
    }

    @objc func pickBrush(_ s: NSMenuItem) {
        state.brushShape = BrushShape.all[s.tag]
        state.tool = .brush
        ribbonSelect(tool: .brush)
    }

    @objc func pickAirbrush(_ s: NSMenuItem) {
        state.tool = .airbrush
        ribbonSelect(tool: .airbrush)
    }

    @objc func pickSize(_ s: NSMenuItem) {
        state.lineWidthIndex = [0, 2, 4, 4][s.tag]
        if s.tag == 3 { state.lineWidthIndex = 4 }
        ribbon.needsDisplay = true
    }

    @objc func pickOutline(_ s: NSMenuItem) {
        state.shapeOutline = s.tag == 1
        ribbon.needsDisplay = true
    }

    @objc func pickFill(_ s: NSMenuItem) {
        state.shapeFill = s.tag == 1
        ribbon.needsDisplay = true
    }

    @objc func applyRotate(_ s: NSMenuItem) {
        canvas.commitFloating()
        let ops: [Bitmap.FlipRotate] = [.rotate90, .rotate270, .rotate180, .vertical, .horizontal]
        state.replaceBitmap(state.bitmap.transformed(ops[s.tag]))
        refreshAll()
    }

    /// Crop the picture down to the current selection.
    @objc func cropToSelection() {
        guard let sel = canvas.currentSelectionRect else { NSSound.beep(); return }
        canvas.commitFloating()
        state.replaceBitmap(state.bitmap.crop(sel))
        canvas.deselect()
        refreshAll()
    }

    // MARK: - Title / status

    private func updateTitle() {
        let name = state.fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
        window?.title = "\(name) - Paint"
        window?.isDocumentEdited = state.isDirty
        ribbon.needsDisplay = true
    }

    private func refreshAll() {
        canvas.updateFrameSize()
        canvas.needsDisplay = true
        ribbon.needsDisplay = true
        updateTitle()
        updateStatusMetrics()
    }

    // MARK: - File actions

    @objc func newDocument(_ sender: Any?) {
        guard confirmDiscardChanges() else { return }
        canvas.deselect()
        state.replaceBitmap(Bitmap(width: 640, height: 480, fill: .white), registerUndo: false)
        state.resetUndo()
        state.fileURL = nil
        state.isDirty = false
        refreshAll()
    }

    @objc func openDocument(_ sender: Any?) {
        guard confirmDiscardChanges() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .bmp, .gif, .tiff]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadImage(from: url)
    }

    func loadImage(from url: URL) {
        guard let img = NSImage(contentsOf: url) else {
            alert("Paint cannot read this file.", info: url.lastPathComponent)
            return
        }
        var rect = CGRect(origin: .zero, size: img.size)
        guard let cg = img.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return }
        canvas.deselect()
        let bmp = Bitmap(width: cg.width, height: cg.height, fill: .white)
        bmp.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        state.replaceBitmap(bmp, registerUndo: false)
        state.resetUndo()
        state.fileURL = url
        state.isDirty = false
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        refreshAll()
    }

    @objc func saveDocument(_ sender: Any?) {
        canvas.commitText()
        canvas.commitFloating()
        if let url = state.fileURL { write(to: url) } else { saveDocumentAs(sender) }
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        canvas.commitText()
        canvas.commitFloating()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg, .bmp, .gif, .tiff]
        panel.nameFieldStringValue = state.fileURL?.lastPathComponent ?? "untitled.png"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        write(to: url)
    }

    private func fileType(for url: URL) -> NSBitmapImageRep.FileType {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return .jpeg
        case "bmp": return .bmp
        case "gif": return .gif
        case "tif", "tiff": return .tiff
        default: return .png
        }
    }

    private func write(to url: URL) {
        guard let cg = state.bitmap.cgImage else { return }
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = NSSize(width: state.bitmap.width, height: state.bitmap.height)
        var props: [NSBitmapImageRep.PropertyKey: Any] = [:]
        let type = fileType(for: url)
        if type == .jpeg { props[.compressionFactor] = 0.9 }
        guard let data = rep.representation(using: type, properties: props) else {
            alert("Could not encode the image.", info: url.lastPathComponent)
            return
        }
        do {
            try data.write(to: url)
            state.fileURL = url
            state.isDirty = false
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            updateTitle()
        } catch {
            alert("Could not save the file.", info: error.localizedDescription)
        }
    }

    @objc func printDocument(_ sender: Any?) {
        canvas.commitFloating()
        let view = NSImageView(frame: NSRect(x: 0, y: 0,
                                             width: state.bitmap.width, height: state.bitmap.height))
        view.image = state.bitmap.nsImage
        view.imageScaling = .scaleProportionallyUpOrDown
        let op = NSPrintOperation(view: view)
        op.printInfo.horizontalPagination = .fit
        op.printInfo.verticalPagination = .fit
        op.run()
    }

    private func confirmDiscardChanges() -> Bool {
        guard state.isDirty else { return true }
        let a = NSAlert()
        a.messageText = "Save changes to \(state.fileURL?.lastPathComponent ?? "untitled")?"
        a.informativeText = "Your changes will be lost if you don't save them."
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Don't Save")
        a.addButton(withTitle: "Cancel")
        switch a.runModal() {
        case .alertFirstButtonReturn:
            saveDocument(nil)
            return !state.isDirty
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    private func alert(_ message: String, info: String) {
        let a = NSAlert()
        a.messageText = message
        a.informativeText = info
        a.runModal()
    }

    // MARK: - Edit actions

    @objc func undo(_ sender: Any?) {
        canvas.cancelMultiStepTools()
        canvas.deselect()
        state.undo(); refreshAll()
    }

    @objc func redo(_ sender: Any?) {
        canvas.deselect()
        state.redo(); refreshAll()
    }

    @objc func cut(_ sender: Any?) { canvas.cutSelection() }
    @objc func copy(_ sender: Any?) { canvas.copySelection() }
    @objc func paste(_ sender: Any?) { canvas.paste(); refreshAll() }
    @objc func delete(_ sender: Any?) { canvas.deleteSelection() }
    @objc func selectAllImage(_ sender: Any?) { canvas.selectAll(); ribbon.needsDisplay = true }

    @objc func copyTo(_ sender: Any?) {
        guard canvas.hasSelection else { NSSound.beep(); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg, .bmp]
        panel.nameFieldStringValue = "selection.png"
        guard panel.runModal() == .OK, let url = panel.url,
              let piece = canvas.selectionBitmap(), let cg = piece.cgImage else { return }
        let rep = NSBitmapImageRep(cgImage: cg)
        if let data = rep.representation(using: fileType(for: url), properties: [:]) {
            try? data.write(to: url)
        }
    }

    @objc func pasteFrom(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .bmp, .gif, .tiff]
        guard panel.runModal() == .OK, let url = panel.url,
              let img = NSImage(contentsOf: url) else { return }
        var r = CGRect(origin: .zero, size: img.size)
        guard let cg = img.cgImage(forProposedRect: &r, context: nil, hints: nil) else { return }
        canvas.insertFloating(cg)
        refreshAll()
    }

    // MARK: - Image menu

    @objc func flipRotate(_ sender: Any?) {
        canvas.commitFloating()
        let accessory = NSStackView()
        accessory.orientation = .vertical
        accessory.alignment = .leading
        let options = ["Flip horizontal", "Flip vertical", "Rotate by 90°",
                       "Rotate by 180°", "Rotate by 270°"]
        var buttons: [NSButton] = []
        for (i, title) in options.enumerated() {
            let b = NSButton(radioButtonWithTitle: title, target: nil, action: nil)
            b.state = i == 0 ? .on : .off
            buttons.append(b)
            accessory.addArrangedSubview(b)
        }
        accessory.frame = NSRect(x: 0, y: 0, width: 220, height: 120)
        let a = NSAlert()
        a.messageText = "Flip and Rotate"
        a.accessoryView = accessory
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn,
              let idx = buttons.firstIndex(where: { $0.state == .on }) else { return }
        let ops: [Bitmap.FlipRotate] = [.horizontal, .vertical, .rotate90, .rotate180, .rotate270]
        state.replaceBitmap(state.bitmap.transformed(ops[idx]))
        refreshAll()
    }

    @objc func stretchSkew(_ sender: Any?) {
        canvas.commitFloating()
        let fields = (0..<4).map { _ -> NSTextField in
            let f = NSTextField(frame: .zero)
            f.alignment = .right
            return f
        }
        fields[0].stringValue = "100"; fields[1].stringValue = "100"
        fields[2].stringValue = "0";   fields[3].stringValue = "0"

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Stretch horizontal:"), fields[0], NSTextField(labelWithString: "%")],
            [NSTextField(labelWithString: "Stretch vertical:"), fields[1], NSTextField(labelWithString: "%")],
            [NSTextField(labelWithString: "Skew horizontal:"), fields[2], NSTextField(labelWithString: "degrees")],
            [NSTextField(labelWithString: "Skew vertical:"), fields[3], NSTextField(labelWithString: "degrees")]
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.frame = NSRect(x: 0, y: 0, width: 340, height: 130)
        fields.forEach { $0.widthAnchor.constraint(equalToConstant: 60).isActive = true }

        let a = NSAlert()
        a.messageText = "Stretch and Skew"
        a.accessoryView = grid
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let sx = Double(fields[0].stringValue) ?? 100
        let sy = Double(fields[1].stringValue) ?? 100
        let kx = Double(fields[2].stringValue) ?? 0
        let ky = Double(fields[3].stringValue) ?? 0
        state.replaceBitmap(state.bitmap.stretchSkew(xPercent: sx, yPercent: sy,
                                                     xDegrees: kx, yDegrees: ky))
        refreshAll()
    }

    @objc func invertColors(_ sender: Any?) {
        canvas.commitFloating()
        state.beginUndo()
        state.bitmap.invertColors()
        refreshAll()
    }

    @objc func imageAttributes(_ sender: Any?) {
        canvas.commitFloating()
        let wField = NSTextField(string: "\(state.bitmap.width)")
        let hField = NSTextField(string: "\(state.bitmap.height)")
        [wField, hField].forEach {
            $0.alignment = .right
            $0.widthAnchor.constraint(equalToConstant: 70).isActive = true
        }
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Width:"), wField, NSTextField(labelWithString: "pixels")],
            [NSTextField(labelWithString: "Height:"), hField, NSTextField(labelWithString: "pixels")]
        ])
        grid.rowSpacing = 8; grid.columnSpacing = 8
        grid.frame = NSRect(x: 0, y: 0, width: 320, height: 70)

        let a = NSAlert()
        a.messageText = "Attributes"
        a.informativeText = "Canvas size. Content is anchored to the top-left corner."
        a.accessoryView = grid
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        a.addButton(withTitle: "Default")
        let response = a.runModal()
        guard response != .alertSecondButtonReturn else { return }
        var w = Int(wField.stringValue) ?? state.bitmap.width
        var h = Int(hField.stringValue) ?? state.bitmap.height
        if response == .alertThirdButtonReturn { w = 640; h = 480 }
        guard w > 0, h > 0, w <= 20000, h <= 20000 else {
            alert("Invalid size.", info: "Width and height must be between 1 and 20000 pixels.")
            return
        }
        state.beginUndo()
        state.bitmap.resizeCanvas(width: w, height: h, fill: state.background)
        refreshAll()
    }

    @objc func clearImage(_ sender: Any?) {
        canvas.deselect()
        state.beginUndo()
        state.bitmap.clear(state.background)
        refreshAll()
    }

    @objc func toggleDrawOpaque(_ sender: NSMenuItem) {
        state.selectionMode = state.selectionMode == .opaque ? .transparent : .opaque
        sender.state = state.selectionMode == .opaque ? .on : .off
        ribbon.needsDisplay = true
        canvas.needsDisplay = true
    }

    // MARK: - View menu

    @objc func zoomTo(_ sender: NSMenuItem) {
        canvas.commitFloating()
        state.zoom = CGFloat(sender.tag)
        canvas.updateFrameSize()
        canvasZoomChanged(state.zoom)
    }

    @objc func toggleGrid(_ sender: NSMenuItem) {
        state.showGrid.toggle()
        sender.state = state.showGrid ? .on : .off
        canvas.needsDisplay = true
    }

    @objc func editColors(_ sender: Any?) {
        let panel = NSColorPanel.shared
        panel.color = state.foreground
        panel.setTarget(self)
        panel.setAction(#selector(foregroundColorChanged(_:)))
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func foregroundColorChanged(_ sender: NSColorPanel) {
        state.foreground = sender.color
        ribbon.needsDisplay = true
        canvas.refreshTextAttributes()
    }

    // MARK: - Text toolbar

    @objc func toggleTextToolbar(_ sender: Any?) {
        if textPanel?.isVisible == true { hideTextPanel() } else { showTextPanel() }
    }

    private func showTextPanel() {
        if let p = textPanel { p.orderFront(nil); return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 44),
                            styleMask: [.titled, .closable, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = "Fonts"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false

        let fontPopup = NSPopUpButton(frame: NSRect(x: 8, y: 10, width: 170, height: 24))
        let families = NSFontManager.shared.availableFontFamilies.sorted()
        fontPopup.addItems(withTitles: families)
        fontPopup.selectItem(withTitle: canvas.textFont.familyName ?? "Helvetica")
        fontPopup.target = self
        fontPopup.action = #selector(textFontChanged(_:))

        let sizePopup = NSPopUpButton(frame: NSRect(x: 184, y: 10, width: 64, height: 24))
        sizePopup.addItems(withTitles: ["8", "9", "10", "11", "12", "14", "16", "18",
                                        "20", "24", "28", "36", "48", "72"])
        sizePopup.selectItem(withTitle: "\(Int(canvas.textFont.pointSize))")
        sizePopup.target = self
        sizePopup.action = #selector(textSizeChanged(_:))

        let bold = NSButton(frame: NSRect(x: 254, y: 10, width: 30, height: 24))
        bold.title = "B"; bold.setButtonType(.pushOnPushOff); bold.bezelStyle = .rounded
        bold.target = self; bold.action = #selector(textBoldToggled(_:))

        let italic = NSButton(frame: NSRect(x: 286, y: 10, width: 30, height: 24))
        italic.title = "I"; italic.setButtonType(.pushOnPushOff); italic.bezelStyle = .rounded
        italic.target = self; italic.action = #selector(textItalicToggled(_:))

        let opaque = NSButton(checkboxWithTitle: "Opaque",
                              target: self, action: #selector(textOpaqueToggled(_:)))
        opaque.frame = NSRect(x: 320, y: 12, width: 80, height: 20)

        [fontPopup, sizePopup, bold, italic, opaque].forEach { panel.contentView?.addSubview($0) }
        textPanel = panel
        panel.orderFront(nil)
    }

    private func hideTextPanel() { textPanel?.orderOut(nil) }

    private func rebuildFont(family: String? = nil, size: CGFloat? = nil,
                             toggleBold: Bool = false, toggleItalic: Bool = false) {
        let fm = NSFontManager.shared
        var font = canvas.textFont
        if let family = family {
            font = NSFont(name: family, size: font.pointSize)
                ?? fm.font(withFamily: family, traits: [], weight: 5, size: font.pointSize)
                ?? font
        }
        if let size = size { font = NSFont(descriptor: font.fontDescriptor, size: size) ?? font }
        if toggleBold {
            let isBold = fm.traits(of: font).contains(.boldFontMask)
            font = (isBold ? fm.convert(font, toNotHaveTrait: .boldFontMask)
                           : fm.convert(font, toHaveTrait: .boldFontMask))
        }
        if toggleItalic {
            let isItalic = fm.traits(of: font).contains(.italicFontMask)
            font = (isItalic ? fm.convert(font, toNotHaveTrait: .italicFontMask)
                             : fm.convert(font, toHaveTrait: .italicFontMask))
        }
        canvas.textFont = font
        canvas.refreshTextAttributes()
    }

    @objc private func textFontChanged(_ s: NSPopUpButton) { rebuildFont(family: s.titleOfSelectedItem) }
    @objc private func textSizeChanged(_ s: NSPopUpButton) {
        rebuildFont(size: CGFloat(Double(s.titleOfSelectedItem ?? "18") ?? 18))
    }
    @objc private func textBoldToggled(_ s: NSButton) { rebuildFont(toggleBold: true) }
    @objc private func textItalicToggled(_ s: NSButton) { rebuildFont(toggleItalic: true) }
    @objc private func textOpaqueToggled(_ s: NSButton) {
        canvas.textOpaque = (s.state == .on)
        canvas.refreshTextAttributes()
    }

    // MARK: - Menu validation

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): return state.canUndo
        case #selector(redo(_:)): return state.canRedo
        case #selector(cut(_:)), #selector(copy(_:)),
             #selector(delete(_:)), #selector(copyTo(_:)):
            return canvas.hasSelection
        case #selector(paste(_:)):
            return NSPasteboard.general.canReadObject(forClasses: [NSImage.self], options: nil)
        case #selector(selectAllImage(_:)):
            return !canvas.isEditingText
        default: return true
        }
    }
}

/// Top-left origin container so manual layout reads naturally.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) { Chrome.vGradient(dirtyRect, Chrome.ribbonFace, Chrome.ribbonBottom) }
}

final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

