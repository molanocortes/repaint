import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: PaintWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        let c = PaintWindowController()
        controller = c
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        controller?.loadImage(from: URL(fileURLWithPath: filename))
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first { controller?.loadImage(from: url) }
    }

    // MARK: - Menu bar

    private func buildMenu() {
        let main = NSMenu()

        // Application menu
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Paint",
                        action: #selector(showAbout), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Paint",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                                         action: #selector(NSApplication.hideOtherApplications(_:)),
                                         keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All",
                        action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Paint",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        // File
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        add(fileMenu, "New", #selector(PaintWindowController.newDocument(_:)), "n")
        add(fileMenu, "Open…", #selector(PaintWindowController.openDocument(_:)), "o")
        fileMenu.addItem(.separator())
        add(fileMenu, "Save", #selector(PaintWindowController.saveDocument(_:)), "s")
        let saveAs = add(fileMenu, "Save As…", #selector(PaintWindowController.saveDocumentAs(_:)), "s")
        saveAs.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(.separator())
        add(fileMenu, "Print…", #selector(PaintWindowController.printDocument(_:)), "p")
        fileMenu.addItem(.separator())
        let recent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: "Open Recent")
        recentMenu.perform(Selector(("_setMenuName:")), with: "NSRecentDocumentsMenu")
        recent.submenu = recentMenu
        fileMenu.addItem(recent)
        fileMenu.addItem(.separator())
        add(fileMenu, "Close", #selector(NSWindow.performClose(_:)), "w")
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        // Edit
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        add(editMenu, "Undo", #selector(PaintWindowController.undo(_:)), "z")
        let redo = add(editMenu, "Redo", #selector(PaintWindowController.redo(_:)), "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        add(editMenu, "Cut", #selector(PaintWindowController.cut(_:)), "x")
        add(editMenu, "Copy", #selector(PaintWindowController.copy(_:)), "c")
        add(editMenu, "Paste", #selector(PaintWindowController.paste(_:)), "v")
        add(editMenu, "Clear Selection", #selector(PaintWindowController.delete(_:)), "\u{8}")
        add(editMenu, "Select All", #selector(PaintWindowController.selectAllImage(_:)), "a")
        editMenu.addItem(.separator())
        add(editMenu, "Copy To…", #selector(PaintWindowController.copyTo(_:)), "")
        add(editMenu, "Paste From…", #selector(PaintWindowController.pasteFrom(_:)), "")
        editItem.submenu = editMenu
        main.addItem(editItem)

        // View
        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let zoomItem = NSMenuItem(title: "Zoom", action: nil, keyEquivalent: "")
        let zoomMenu = NSMenu(title: "Zoom")
        for (title, factor, key) in [("Normal Size", 1, "1"), ("Large Size (2x)", 2, "2"),
                                     ("4x", 4, "4"), ("6x", 6, "6"), ("8x", 8, "8")] {
            let mi = add(zoomMenu, title, #selector(PaintWindowController.zoomTo(_:)), key)
            mi.tag = factor
        }
        zoomItem.submenu = zoomMenu
        viewMenu.addItem(zoomItem)
        add(viewMenu, "Show Grid", #selector(PaintWindowController.toggleGrid(_:)), "g")
        viewMenu.addItem(.separator())
        add(viewMenu, "Text Toolbar", #selector(PaintWindowController.toggleTextToolbar(_:)), "")
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        // Tools
        let toolsItem = NSMenuItem()
        let toolsMenu = NSMenu(title: "Tools")
        for t in [Tool.pencil, .fill, .text, .eraser, .pickColor, .magnifier] {
            let mi = add(toolsMenu, t.title, #selector(PaintWindowController.pickToolMenu(_:)), "")
            mi.tag = t.rawValue
        }
        toolsMenu.addItem(.separator())
        let brushItem = NSMenuItem(title: "Brushes", action: nil, keyEquivalent: "")
        let brushMenu = NSMenu(title: "Brushes")
        for (i, shape) in BrushShape.all.enumerated() {
            let name: String
            switch shape.family {
            case .circle: name = "Round"
            case .square: name = "Square"
            case .slashLeft: name = "Left diagonal"
            case .slashRight: name = "Right diagonal"
            }
            let mi = add(brushMenu, "\(name) — \(Int(shape.size))px",
                         #selector(PaintWindowController.pickBrush(_:)), "")
            mi.tag = i
        }
        brushMenu.addItem(.separator())
        add(brushMenu, "Airbrush", #selector(PaintWindowController.pickAirbrush(_:)), "")
        brushItem.submenu = brushMenu
        toolsMenu.addItem(brushItem)

        let sizeItem = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu(title: "Size")
        for (i, px) in [1, 3, 5, 8].enumerated() {
            let mi = add(sizeMenu, "\(px)px", #selector(PaintWindowController.pickSize(_:)), "")
            mi.tag = i
        }
        sizeItem.submenu = sizeMenu
        toolsMenu.addItem(sizeItem)
        toolsMenu.addItem(.separator())

        for (title, sel) in [("Outline", #selector(PaintWindowController.pickOutline(_:))),
                             ("Fill", #selector(PaintWindowController.pickFill(_:)))] {
            let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let sub = NSMenu(title: title)
            add(sub, "No \(title.lowercased())", sel, "").tag = 0
            add(sub, "Solid color", sel, "").tag = 1
            it.submenu = sub
            toolsMenu.addItem(it)
        }
        toolsItem.submenu = toolsMenu
        main.addItem(toolsItem)

        // Shapes
        let shapesItem = NSMenuItem()
        let shapesMenu = NSMenu(title: "Shapes")
        for t in Tool.shapeGallery {
            let mi = add(shapesMenu, t.title, #selector(PaintWindowController.pickToolMenu(_:)), "")
            mi.tag = t.rawValue
        }
        shapesItem.submenu = shapesMenu
        main.addItem(shapesItem)

        // Image
        let imageItem = NSMenuItem()
        let imageMenu = NSMenu(title: "Image")
        let selItem = NSMenuItem(title: "Select", action: nil, keyEquivalent: "")
        let selMenu = NSMenu(title: "Select")
        add(selMenu, "Rectangular selection",
            #selector(PaintWindowController.pickSelectTool(_:)), "").tag = 0
        add(selMenu, "Free-form selection",
            #selector(PaintWindowController.pickSelectTool(_:)), "").tag = 1
        selItem.submenu = selMenu
        imageMenu.addItem(selItem)
        add(imageMenu, "Crop", #selector(PaintWindowController.cropToSelection), "")

        let rotItem = NSMenuItem(title: "Rotate", action: nil, keyEquivalent: "")
        let rotMenu = NSMenu(title: "Rotate")
        for (i, t) in ["Rotate right 90°", "Rotate left 90°", "Rotate 180°",
                       "Flip vertical", "Flip horizontal"].enumerated() {
            add(rotMenu, t, #selector(PaintWindowController.applyRotate(_:)), "").tag = i
        }
        rotItem.submenu = rotMenu
        imageMenu.addItem(rotItem)
        add(imageMenu, "Flip/Rotate…", #selector(PaintWindowController.flipRotate(_:)), "r")
        add(imageMenu, "Stretch/Skew…", #selector(PaintWindowController.stretchSkew(_:)), "w")
        add(imageMenu, "Invert Colors", #selector(PaintWindowController.invertColors(_:)), "i")
        add(imageMenu, "Attributes…", #selector(PaintWindowController.imageAttributes(_:)), "e")
        add(imageMenu, "Clear Image", #selector(PaintWindowController.clearImage(_:)), "\u{7f}")
        imageMenu.addItem(.separator())
        let opaque = add(imageMenu, "Draw Opaque",
                         #selector(PaintWindowController.toggleDrawOpaque(_:)), "")
        opaque.state = .on
        imageItem.submenu = imageMenu
        main.addItem(imageItem)

        // Colors
        let colorsItem = NSMenuItem()
        let colorsMenu = NSMenu(title: "Colors")
        add(colorsMenu, "Edit Colors…", #selector(PaintWindowController.editColors(_:)), "")
        colorsItem.submenu = colorsMenu
        main.addItem(colorsItem)

        // Window
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize",
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)),
                           keyEquivalent: "")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        // Help
        let helpItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(withTitle: "Paint Help",
                         action: #selector(showHelp), keyEquivalent: "?").target = self
        helpItem.submenu = helpMenu
        main.addItem(helpItem)

        NSApp.mainMenu = main
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector,
                     _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menu.addItem(item)
        return item
    }

    @objc private func showAbout() {
        let a = NSAlert()
        a.messageText = "Paint"
        a.informativeText = """
        A rebuild of the ribbon-era Windows Paint for macOS.

        Every tool, 21 shapes, the 20-colour palette, selections, \
        text, crop, rotate, stretch/skew and 8x zoom — \
        native AppKit, no dependencies.
        """
        a.runModal()
    }

    @objc private func showHelp() {
        let a = NSAlert()
        a.messageText = "Paint — Quick Help"
        a.informativeText = """
        Left-click draws with the foreground colour, right-click with the \
        background colour. That applies to the pencil, brush, shapes and the fill bucket.

        Palette: click a colour to set the foreground, right-click to set the \
        background, double-click to edit it.

        Selections: drag with either select tool, then drag inside to move, \
        drag a handle to resize, or hold Option while dragging to leave a copy \
        behind. Arrow keys nudge; Escape deselects.

        Curve: drag the straight line first, then drag twice to bend it.
        Polygon: click each corner, then double-click (or right-click) to close.
        Magnifier: left-click zooms in, right-click zooms out.
        Eraser: right-drag erases only the foreground colour.
        """
        a.runModal()
    }
}
