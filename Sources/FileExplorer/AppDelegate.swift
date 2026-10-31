import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate { NSApp.delegate as! AppDelegate }
    private var windows: [ExplorerWindowController] = []
    private var pendingOpen: [URL] = []
    private var launched = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        buildMenu()
        launched = true
        // Folders passed on the command line open in their own windows.
        for a in CommandLine.arguments.dropFirst() where !a.hasPrefix("-") {
            let u = URL(fileURLWithPath: (a as NSString).expandingTildeInPath)
            if u.isDirectoryOnDisk { pendingOpen.append(u) }
        }
        if pendingOpen.isEmpty {
            newWindow(nil)
        } else {
            pendingOpen.forEach { newWindow(.dir($0)) }
            pendingOpen = []
        }
        let wc = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            wc.addObserver(self, selector: #selector(volumesChanged), name: n, object: nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        DebugSnapshot.scheduleIfRequested()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { newWindow(nil) }
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        let dirs = urls.filter { $0.isDirectoryOnDisk }
        if launched { dirs.forEach { newWindow(.dir($0)) } } else { pendingOpen += dirs }
        sender.reply(toOpenOrPrint: .success)
    }

    @objc private func volumesChanged() {
        NotificationCenter.default.post(name: .volumesChanged, object: nil)
    }

    @discardableResult
    func newWindow(_ location: Location?) -> ExplorerWindowController {
        let wc = ExplorerWindowController(location: location ?? Settings.shared.startLocation)
        windows.append(wc)
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
        return wc
    }

    func windowClosed(_ wc: ExplorerWindowController) {
        windows.removeAll { $0 === wc }
    }

    @objc func newWindowAction(_ sender: Any?) { newWindow(nil) }
    @objc func showFolderOptions(_ sender: Any?) { FolderOptionsController.shared.present() }

    @objc func showShortcuts(_ sender: Any?) {
        Alerts.show("File Explorer keyboard shortcuts", """
        ⌘N  New window            ⌘T  New tab           ⌘W  Close tab
        ⌃⇥  Next tab              ⇧⌘N New folder        F2  Rename
        ⌘C / ⌘X / ⌘V  Copy, cut, paste                  ⌘Z  Undo
        ⌘⌫ / ⌦  Delete (Recycle Bin)      ⌥⌘⌫ / ⇧⌦  Permanently delete
        ↩  Open           ⌥↩ / ⌘I  Properties          Space  Quick Look
        ⌫ / ⌘[  Back      ⌘]  Forward      ⌘↑ / ⌥↑  Up one level
        ⌘L / F6  Address bar     ⌘F / ⌘E / F3  Search    ⌘R / F5  Refresh
        ⌘1 – ⌘8  Change view     ⌘ + scroll  Change icon size
        ⇧⌘.  Show hidden items   ⌥P  Preview pane    ⌥⇧P  Details pane
        ⇧⌘C  Copy as path
        """, style: .informational)
    }

    // MARK: Menu

    private func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command],
                      tag: Int = 0, target: AnyObject? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        i.tag = tag
        i.target = target
        return i
    }

    private func fn(_ k: Int) -> String { String(Character(UnicodeScalar(k)!)) }

    private func buildMenu() {
        typealias E = ExplorerViewController
        typealias W = ExplorerWindowController
        let main = NSMenu()

        let app = NSMenu(title: "File Explorer")
        app.addItem(item("About File Explorer", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        app.addItem(.separator())
        app.addItem(item("Folder Options…", #selector(showFolderOptions(_:)), ",", target: self))
        app.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        services.submenu = NSMenu()
        NSApp.servicesMenu = services.submenu
        app.addItem(services)
        app.addItem(.separator())
        app.addItem(item("Hide File Explorer", #selector(NSApplication.hide(_:)), "h"))
        app.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        app.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        app.addItem(.separator())
        app.addItem(item("Quit File Explorer", #selector(NSApplication.terminate(_:)), "q"))

        let file = NSMenu(title: "File")
        file.addItem(item("New Window", #selector(newWindowAction(_:)), "n", target: self))
        file.addItem(item("New Tab", #selector(W.newTab(_:)), "t"))
        file.addItem(item("New Folder", #selector(E.newFolder(_:)), "n", [.command, .shift]))
        file.addItem(item("New Text Document", #selector(E.newTextDocument(_:)), "n", [.command, .option]))
        file.addItem(.separator())
        file.addItem(item("Open", #selector(E.openSelection(_:)), "o"))
        file.addItem(item("Open in New Tab", #selector(E.openInNewTab(_:)), "o", [.command, .shift]))
        file.addItem(item("Open in New Window", #selector(E.openInNewWindow(_:)), "o", [.command, .option]))
        file.addItem(item("Open in Terminal", #selector(E.openInTerminal(_:))))
        file.addItem(item("Show in Finder", #selector(E.revealInFinder(_:)), "r", [.command, .option]))
        file.addItem(.separator())
        file.addItem(item("Close Tab", #selector(W.closeCurrentTab(_:)), "w"))
        file.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift]))
        file.addItem(.separator())
        file.addItem(item("Rename", #selector(E.renameSelection(_:)), fn(NSF2FunctionKey), []))
        file.addItem(item("Compress to ZIP File", #selector(E.compressSelection(_:))))
        file.addItem(item("Extract All…", #selector(E.extractSelection(_:))))
        file.addItem(item("Pin to Quick access", #selector(E.togglePin(_:))))
        file.addItem(item("Properties", #selector(E.showProperties(_:)), "i"))
        file.addItem(.separator())
        file.addItem(item("Move to Recycle Bin", #selector(E.delete(_:)), "\u{8}"))
        file.addItem(item("Delete Permanently", #selector(E.deletePermanently(_:)), "\u{8}", [.command, .option]))

        let edit = NSMenu(title: "Edit")
        edit.addItem(item("Undo", #selector(E.undo(_:)), "z"))
        edit.addItem(item("Redo", #selector(E.redo(_:)), "z", [.command, .shift]))
        edit.addItem(item("Redo", #selector(E.redo(_:)), "y"))
        edit.addItem(.separator())
        edit.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        edit.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        edit.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        edit.addItem(item("Copy as Path", #selector(E.copyAsPath(_:)), "c", [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        edit.addItem(item("Select None", #selector(E.selectNone(_:)), "a", [.command, .shift]))
        edit.addItem(item("Invert Selection", #selector(E.invertSelection(_:)), "i", [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(item("Search", #selector(E.focusSearch(_:)), "f"))
        edit.addItem(item("Search", #selector(E.focusSearch(_:)), "e"))

        let view = NSMenu(title: "View")
        for m in ViewMode.allCases {
            view.addItem(item(m.title, #selector(E.setViewModeAction(_:)), "\(m.rawValue + 1)", tag: m.rawValue))
        }
        view.addItem(.separator())
        view.addItem(item("Compact View", #selector(E.toggleCompact(_:))))
        view.addItem(.separator())
        let sort = NSMenu(title: "Sort by")
        for (i, k) in SortKey.allCases.enumerated() { sort.addItem(item(k.title, #selector(E.sortByAction(_:)), tag: i)) }
        let sortItem = NSMenuItem(title: "Sort by", action: nil, keyEquivalent: "")
        sortItem.submenu = sort
        view.addItem(sortItem)
        let group = NSMenu(title: "Group by")
        for (i, g) in GroupBy.allCases.enumerated() { group.addItem(item(g.title, #selector(E.groupByAction(_:)), tag: i)) }
        let groupItem = NSMenuItem(title: "Group by", action: nil, keyEquivalent: "")
        groupItem.submenu = group
        view.addItem(groupItem)
        view.addItem(.separator())
        view.addItem(item("Navigation Pane", #selector(E.toggleNavPane(_:))))
        view.addItem(item("Details Pane", #selector(E.toggleDetailsPane(_:)), "p", [.option, .shift]))
        view.addItem(item("Preview Pane", #selector(E.togglePreviewPane(_:)), "p", [.option]))
        view.addItem(.separator())
        view.addItem(item("File Name Extensions", #selector(E.toggleExtensions(_:))))
        view.addItem(item("Hidden Items", #selector(E.toggleHidden(_:)), ".", [.command, .shift]))
        view.addItem(.separator())
        view.addItem(item("Quick Look", #selector(E.quickLook(_:)), "y"))
        view.addItem(item("Refresh", #selector(E.refreshAction(_:)), "r"))
        view.addItem(.separator())
        view.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))

        let go = NSMenu(title: "Go")
        go.addItem(item("Back", #selector(E.goBack(_:)), "["))
        go.addItem(item("Forward", #selector(E.goForward(_:)), "]"))
        go.addItem(item("Up One Level", #selector(E.goUp(_:)), fn(NSUpArrowFunctionKey)))
        go.addItem(.separator())
        go.addItem(item("Home", #selector(E.goHome(_:)), "h", [.command, .shift]))
        go.addItem(item("Gallery", #selector(E.goGallery(_:))))
        go.addItem(item("This PC", #selector(E.goThisPC(_:)), "p", [.command, .shift]))
        go.addItem(item("User Folder", #selector(E.goUserFolder(_:)), "u", [.command, .shift]))
        go.addItem(.separator())
        let keys: [KnownFolder: String] = [.desktop: "d", .downloads: "l", .documents: "o"]
        for (i, k) in KnownFolder.allCases.enumerated() {
            go.addItem(item(k.title, #selector(E.goKnownFolder(_:)), keys[k] ?? "", keys[k] == nil ? [] : (k == .documents ? [.command, .shift] : [.command, .option]), tag: i))
        }
        go.addItem(item("Recycle Bin", #selector(E.goRecycleBin(_:))))
        go.addItem(.separator())
        go.addItem(item("Address Bar…", #selector(E.focusAddressBar(_:)), "l"))
        go.addItem(item("Go to Folder…", #selector(E.focusAddressBar(_:)), "g", [.command, .shift]))

        let window = NSMenu(title: "Window")
        window.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        window.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        window.addItem(.separator())
        window.addItem(item("Next Tab", #selector(W.nextExplorerTab(_:)), "\t", [.control]))
        window.addItem(item("Previous Tab", #selector(W.previousExplorerTab(_:)), "\t", [.control, .shift]))
        window.addItem(item("Next Tab", #selector(W.nextExplorerTab(_:)), "}", [.command]))
        window.addItem(item("Previous Tab", #selector(W.previousExplorerTab(_:)), "{", [.command]))
        window.addItem(.separator())
        window.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        NSApp.windowsMenu = window

        let help = NSMenu(title: "Help")
        help.addItem(item("Keyboard Shortcuts", #selector(showShortcuts(_:)), "/", target: self))
        NSApp.helpMenu = help

        for m in [app, file, edit, view, go, window, help] {
            let top = NSMenuItem(title: m.title, action: nil, keyEquivalent: "")
            top.submenu = m
            main.addItem(top)
        }
        NSApp.mainMenu = main
    }
}

/// Development aid: `FE_SNAPSHOT=/path/out.png` renders the front window to a PNG after launch.
/// `FE_ACTIONS` may contain comma separated steps (e.g. "view:2,select:1,menu") run before the capture.
enum DebugSnapshot {
    static func scheduleIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["FE_SNAPSHOT"] else { return }
        let actions = (env["FE_ACTIONS"] ?? "").split(separator: ",").map(String.init)
        var delay = 2.0
        for a in actions {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { perform(a) }
            delay += 1.2
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.8) {
            capture(to: out)
            if env["FE_QUIT"] != nil { NSApp.terminate(nil) }
        }
    }

    private static var vc: ExplorerViewController? {
        (NSApp.windows.compactMap { $0.windowController as? ExplorerWindowController }.first)?.activeTab
    }

    private static func perform(_ a: String) {
        let parts = a.split(separator: ":", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        switch parts[0] {
        case "view": if let m = ViewMode(rawValue: Int(arg) ?? 5) { vc?.setViewMode(m) }
        case "go": vc?.navigate(to: arg == "thispc" ? .thisPC : arg == "home" ? .home : arg == "gallery" ? .gallery : .dir(URL(fileURLWithPath: (arg as NSString).expandingTildeInPath)))
        case "selectall": vc?.selectAll(nil)
        case "details": Settings.shared.sidePane = .details
        case "preview": Settings.shared.sidePane = .preview
        case "nopane": Settings.shared.sidePane = .none
        case "tab": (NSApp.windows.compactMap { $0.windowController as? ExplorerWindowController }.first)?.addTab(.dir(homeURL))
        case "group": vc?.groupBy(GroupBy(rawValue: arg) ?? .none)
        case "search": vc?.debugSearch(arg)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "selftest": SelfTest.run(dir: URL(fileURLWithPath: arg))
        case "select": vc?.debugSelect(arg)
        case "props":
            if let u = vc?.selectedURLs.first ?? vc?.location.scopeURL { PropertiesWindowController.show(for: [u]) }
        default: break
        }
    }

    private static func dump(_ v: NSView, _ d: Int) {
        guard d < 9 else { return }
        print(String(repeating: "  ", count: d) + "\(type(of: v)) \(v.frame) hidden=\(v.isHidden)")
        v.subviews.forEach { dump($0, d + 1) }
    }

    private static func capture(to path: String) {
        let base = (path as NSString).deletingPathExtension
        for (i, w) in NSApp.orderedWindows.filter({ $0.isVisible }).enumerated() {
            guard let v = w.contentView,
                  let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
            v.cacheDisplay(in: v.bounds, to: rep)
            if ProcessInfo.processInfo.environment["FE_DUMP"] != nil { dump(v, 0) }
            let file = i == 0 ? path : "\(base)-\(i).png"
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: file))
        }
    }
}

enum SelfTest {
    static func run(dir: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: dir)
        let a = dir.appendingPathComponent("A"), b = dir.appendingPathComponent("B")
        try? fm.createDirectory(at: a, withIntermediateDirectories: true)
        try? fm.createDirectory(at: b, withIntermediateDirectories: true)
        fm.createFile(atPath: a.appendingPathComponent("one.txt").path, contents: Data(repeating: 65, count: 5_000_000))
        try? fm.createDirectory(at: a.appendingPathComponent("sub/deep"), withIntermediateDirectories: true)
        fm.createFile(atPath: a.appendingPathComponent("sub/deep/two.txt").path, contents: Data("hi".utf8))
        func check(_ name: String, _ ok: Bool) { print("[\(ok ? "PASS" : "FAIL")] \(name)") }
        let ops = FileOperations.shared
        // New folder naming
        let nf1 = ops.newFolder(in: b), nf2 = ops.newFolder(in: b)
        check("new folder names", nf1?.lastPathComponent == "New folder" && nf2?.lastPathComponent == "New folder (2)")
        // Copy into same folder -> "- Copy"
        ops.transfer([a.appendingPathComponent("one.txt")], to: a, kind: .copy) { r in
            check("duplicate name", r.first?.lastPathComponent == "one - Copy.txt")
            // Recursive copy to another folder
            ops.transfer([a.appendingPathComponent("sub")], to: b, kind: .copy) { r in
                check("recursive copy", fm.fileExists(atPath: b.appendingPathComponent("sub/deep/two.txt").path) && r.count == 1)
                // Move
                ops.transfer([a.appendingPathComponent("one - Copy.txt")], to: b, kind: .move) { r in
                    let moved = b.appendingPathComponent("one - Copy.txt")
                    check("move", fm.fileExists(atPath: moved.path) && !fm.fileExists(atPath: a.appendingPathComponent("one - Copy.txt").path))
                    check("move size", ((try? fm.attributesOfItem(atPath: moved.path)[.size]) as? Int) == 5_000_000)
                    UndoStack.shared.undo()
                    check("undo move", fm.fileExists(atPath: a.appendingPathComponent("one - Copy.txt").path) && !fm.fileExists(atPath: moved.path))
                    // Rename + undo
                    let r1 = ops.rename(a.appendingPathComponent("sub"), to: "renamed")
                    check("rename", r1?.lastPathComponent == "renamed")
                    UndoStack.shared.undo()
                    check("undo rename", fm.fileExists(atPath: a.appendingPathComponent("sub").path))
                    // Recycle + undo
                    ops.recycle([b.appendingPathComponent("New folder (2)")])
                    check("recycle", !fm.fileExists(atPath: b.appendingPathComponent("New folder (2)").path))
                    UndoStack.shared.undo()
                    check("undo recycle", fm.fileExists(atPath: b.appendingPathComponent("New folder (2)").path))
                    // Zip + extract
                    ops.compress([a.appendingPathComponent("sub")]) { z in
                        check("zip", z?.lastPathComponent == "sub.zip")
                        guard let z else { return }
                        ops.extract(z, to: b.appendingPathComponent("unzipped")) { out in
                            check("extract", fm.fileExists(atPath: b.appendingPathComponent("unzipped/sub/deep/two.txt").path))
                            print("SELFTEST DONE")
                        }
                    }
                }
            }
        }
    }
}
