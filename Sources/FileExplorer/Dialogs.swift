import AppKit
import UniformTypeIdentifiers

// MARK: - Properties

final class PropertiesWindowController: NSWindowController, NSWindowDelegate {
    private static var open: [PropertiesWindowController] = []

    static func show(for urls: [URL]) {
        guard !urls.isEmpty else { return }
        let c = PropertiesWindowController(urls: urls)
        open.append(c)
        c.window?.center()
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
    }

    private var urls: [URL]
    private var nameField: NSTextField?
    private var readOnlyBox: NSButton?
    private var hiddenBox: NSButton?
    private let sizeLabel = PropertiesWindowController.value("Calculating…")
    private let diskLabel = PropertiesWindowController.value("Calculating…")
    private let containsLabel = PropertiesWindowController.value("Calculating…")
    private var opensWithLabel: NSTextField?
    private var opensWithIcon: NSImageView?
    private var cancelled = false
    private let applyButton = NSButton(title: "Apply", target: nil, action: nil)
    private var initialHidden = false
    private var initialLocked = false

    init(urls: [URL]) {
        self.urls = urls
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 540), styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        super.init(window: w)
        w.delegate = self
        let name = urls.count == 1 ? Location.displayName(for: urls[0]) : "\(urls[0].lastPathComponent), …"
        w.title = "\(name) Properties"
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func key(_ s: String) -> NSTextField {
        let l = makeLabel(s, size: 12)
        l.alignment = .left
        return l
    }

    private static func value(_ s: String) -> NSTextField {
        let l = makeLabel(s, size: 12)
        l.isSelectable = true
        l.lineBreakMode = .byTruncatingMiddle
        return l
    }

    private func separator() -> NSView {
        let b = NSBox()
        b.boxType = .separator
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }

    private func grid(_ rows: [(String, NSView)]) -> NSGridView {
        let g = NSGridView(views: rows.map { [PropertiesWindowController.key($0.0), $0.1] })
        g.column(at: 0).width = 100
        g.rowSpacing = 8
        g.columnSpacing = 8
        g.translatesAutoresizingMaskIntoConstraints = false
        for i in 0..<g.numberOfRows { g.row(at: i).yPlacement = .center }
        return g
    }

    private var isVolume: Bool {
        urls.count == 1 && ((try? urls[0].resourceValues(forKeys: [.isVolumeKey]))?.isVolume ?? false)
    }

    private func build() {
        guard let w = window else { return }
        let tabs = NSTabView()
        tabs.translatesAutoresizingMaskIntoConstraints = false
        let general = NSTabViewItem(identifier: "general")
        general.label = "General"
        let content = FlippedView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
        ])
        general.view = content
        tabs.addTabViewItem(general)

        if isVolume { buildVolume(stack) } else { buildItems(stack) }
        for v in stack.arrangedSubviews where v is NSBox {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        let ok = NSButton(title: "OK", target: self, action: #selector(okPressed))
        ok.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
        cancel.keyEquivalent = "\u{1b}"
        applyButton.target = self
        applyButton.action = #selector(applyPressed)
        applyButton.isEnabled = false
        let buttons = NSStackView(views: [ok, cancel, applyButton])
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false
        for b in [ok, cancel, applyButton] { b.widthAnchor.constraint(greaterThanOrEqualToConstant: 76).isActive = true }

        let root = NSView()
        root.addSubview(tabs)
        root.addSubview(buttons)
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            tabs.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            tabs.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            tabs.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -10),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])
        w.contentView = root
    }

    private func header(_ icon: NSImage, editableName: String?, label: String?) -> NSView {
        let iv = NSImageView(image: icon)
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.widthAnchor.constraint(equalToConstant: 36).isActive = true
        iv.heightAnchor.constraint(equalToConstant: 36).isActive = true
        let right: NSView
        if let editableName {
            let f = NSTextField(string: editableName)
            f.translatesAutoresizingMaskIntoConstraints = false
            f.widthAnchor.constraint(equalToConstant: 270).isActive = true
            f.target = self
            f.action = #selector(changed)
            NotificationCenter.default.addObserver(self, selector: #selector(changed), name: NSControl.textDidChangeNotification, object: f)
            nameField = f
            right = f
        } else {
            right = makeLabel(label ?? "", size: 12)
        }
        let h = NSStackView(views: [iv, right])
        h.spacing = 20
        return h
    }

    private func buildItems(_ stack: NSStackView) {
        let items = urls.map { FileItem(url: $0) }
        let single = items.count == 1 ? items[0] : nil
        let icon = single.map { FileIcons.shared.icon(for: $0, size: 64) } ?? IconFactory.folder(size: 64)
        let files = items.filter { !$0.isDirectory }.count, folders = items.count - files
        stack.addArrangedSubview(header(icon, editableName: single?.name,
                                        label: "\(Fmt.count(files, "File")), \(Fmt.count(folders, "Folder"))"))
        stack.addArrangedSubview(separator())

        var typeRows: [(String, NSView)] = []
        if let it = single {
            if it.isDirectory {
                typeRows.append(("Type:", Self.value("File folder")))
            } else {
                typeRows.append(("Type of file:", Self.value(it.ext.isEmpty ? it.typeDescription : "\(it.typeDescription) (.\(it.ext))")))
                let app = NSWorkspace.shared.urlForApplication(toOpen: it.url)
                let iv = NSImageView(image: app.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage())
                iv.translatesAutoresizingMaskIntoConstraints = false
                iv.widthAnchor.constraint(equalToConstant: 16).isActive = true
                iv.heightAnchor.constraint(equalToConstant: 16).isActive = true
                let name = Self.value(app.map { FileManager.default.displayName(atPath: $0.path) } ?? "Pick an app")
                let change = NSButton(title: "Change…", target: self, action: #selector(changeApp))
                change.controlSize = .small
                let h = NSStackView(views: [iv, name, change])
                h.spacing = 6
                opensWithIcon = iv
                opensWithLabel = name
                typeRows.append(("Opens with:", h))
            }
        } else {
            let types = Set(items.map(\.typeDescription))
            typeRows.append(("Type:", Self.value(types.count == 1 ? "All of type \(types.first!)" : "Multiple Types")))
        }
        stack.addArrangedSubview(grid(typeRows))
        stack.addArrangedSubview(separator())

        let parents = Set(urls.map { $0.deletingLastPathComponent().path })
        var rows: [(String, NSView)] = [
            ("Location:", Self.value(parents.count == 1 ? (parents.count == 1 && items.count > 1 ? "All in \(parents.first!)" : parents.first!) : "Various locations")),
            ("Size:", sizeLabel),
            ("Size on disk:", diskLabel),
        ]
        if items.contains(where: \.isDirectory) { rows.append(("Contains:", containsLabel)) }
        stack.addArrangedSubview(grid(rows))
        stack.addArrangedSubview(separator())

        if let it = single {
            let fmt = { (d: Date?) in d.map { Fmt.longDate.string(from: $0) } ?? "" }
            stack.addArrangedSubview(grid([
                ("Created:", Self.value(fmt(it.created))),
                ("Modified:", Self.value(fmt(it.modified))),
                ("Accessed:", Self.value(fmt(it.accessed))),
            ]))
            stack.addArrangedSubview(separator())
        }

        let ro = NSButton(checkboxWithTitle: "Read-only (Locked)", target: self, action: #selector(changed))
        let hid = NSButton(checkboxWithTitle: "Hidden", target: self, action: #selector(changed))
        let vals = urls.compactMap { try? $0.resourceValues(forKeys: [.isUserImmutableKey, .isHiddenKey]) }
        initialLocked = vals.allSatisfy { $0.isUserImmutable == true }
        initialHidden = vals.allSatisfy { $0.isHidden == true }
        ro.state = initialLocked ? .on : .off
        hid.state = initialHidden ? .on : .off
        readOnlyBox = ro
        hiddenBox = hid
        let attrs = NSStackView(views: [ro, hid])
        attrs.spacing = 16
        stack.addArrangedSubview(grid([("Attributes:", attrs)]))

        calculateSizes()
    }

    private func buildVolume(_ stack: NSStackView) {
        guard let v = VolumeInfo.info(for: urls[0]) else { return }
        stack.addArrangedSubview(header(IconFactory.drive(size: 64, kind: v.kind), editableName: nil, label: v.name))
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(grid([("Type:", Self.value(v.typeName)), ("File system:", Self.value(v.format))]))
        stack.addArrangedSubview(separator())
        let used = v.total - v.free
        func swatch(_ c: NSColor) -> NSView {
            let s = ColorView(c)
            s.translatesAutoresizingMaskIntoConstraints = false
            s.widthAnchor.constraint(equalToConstant: 14).isActive = true
            s.heightAnchor.constraint(equalToConstant: 14).isActive = true
            return s
        }
        func row(_ c: NSColor?, _ title: String, _ bytes: Int64) -> [NSView] {
            let k = NSStackView(views: (c.map { [swatch($0)] } ?? []) + [Self.key(title)])
            k.spacing = 6
            return [k, Self.value("\(Fmt.number(bytes)) bytes"), Self.value(Fmt.size(bytes))]
        }
        let g = NSGridView(views: [
            row(NSColor(hex: 0x2B78E4), "Used space:", used),
            row(NSColor(hex: 0xD8D8D8), "Free space:", v.free),
        ])
        g.rowSpacing = 8
        g.columnSpacing = 18
        stack.addArrangedSubview(g)
        stack.addArrangedSubview(separator())
        let cap = NSGridView(views: [row(nil, "Capacity:", v.total)])
        cap.columnSpacing = 18
        stack.addArrangedSubview(cap)
        let pie = PieView(fraction: v.total > 0 ? Double(used) / Double(v.total) : 0)
        pie.translatesAutoresizingMaskIntoConstraints = false
        pie.widthAnchor.constraint(equalToConstant: 360).isActive = true
        pie.heightAnchor.constraint(equalToConstant: 130).isActive = true
        stack.addArrangedSubview(pie)
        let label = makeLabel("Drive \(v.name)", size: 12)
        stack.addArrangedSubview(label)
        stack.setCustomSpacing(4, after: pie)
    }

    private func calculateSizes() {
        let urls = self.urls
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var bytes: Int64 = 0, alloc: Int64 = 0, files = 0, dirs = 0
            var last = Date()
            let keys: Set<URLResourceKey> = [.fileSizeKey, .totalFileAllocatedSizeKey, .isDirectoryKey, .isSymbolicLinkKey]
            func add(_ u: URL) {
                guard let v = try? u.resourceValues(forKeys: keys) else { return }
                if v.isDirectory == true && v.isSymbolicLink != true { dirs += 1 } else {
                    files += 1
                    bytes += Int64(v.fileSize ?? 0)
                    alloc += Int64(v.totalFileAllocatedSize ?? 0)
                }
            }
            for u in urls {
                if self?.cancelled ?? true { return }
                let isDir = u.isDirectoryOnDisk
                if isDir {
                    let en = FileManager.default.enumerator(at: u, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true })
                    while let c = en?.nextObject() as? URL {
                        if self?.cancelled ?? true { return }
                        add(c)
                        if Date().timeIntervalSince(last) > 0.25 {
                            last = Date()
                            let (b, a, f, d) = (bytes, alloc, files, dirs)
                            DispatchQueue.main.async { self?.showSizes(b, a, f, d) }
                        }
                    }
                } else {
                    add(u)
                }
            }
            let (b, a, f, d) = (bytes, alloc, files, dirs)
            DispatchQueue.main.async { self?.showSizes(b, a, f, d) }
        }
    }

    private func showSizes(_ bytes: Int64, _ alloc: Int64, _ files: Int, _ dirs: Int) {
        sizeLabel.stringValue = Fmt.sizeWithBytes(bytes)
        diskLabel.stringValue = Fmt.sizeWithBytes(alloc)
        containsLabel.stringValue = "\(Fmt.count(files, "File")), \(Fmt.count(dirs, "Folder"))"
    }

    @objc private func changed() { applyButton.isEnabled = true }

    @objc private func changeApp() {
        guard let u = urls.first, let type = (try? u.resourceValues(forKeys: [.contentTypeKey]))?.contentType else { return }
        let p = NSOpenPanel()
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        p.allowedContentTypes = [.application]
        p.message = "Choose the app to always use to open .\(u.pathExtension) files"
        guard p.runModal() == .OK, let app = p.url else { return }
        NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type) { [weak self] err in
            DispatchQueue.main.async {
                if let err { Alerts.show("Couldn't change the default app", err.localizedDescription); return }
                self?.opensWithLabel?.stringValue = FileManager.default.displayName(atPath: app.path)
                self?.opensWithIcon?.image = NSWorkspace.shared.icon(forFile: app.path)
            }
        }
    }

    @discardableResult
    private func apply() -> Bool {
        if let ro = readOnlyBox, let hid = hiddenBox {
            let lock = ro.state == .on, hide = hid.state == .on
            for (i, u) in urls.enumerated() {
                var url = u
                var rv = URLResourceValues()
                if lock != initialLocked { rv.isUserImmutable = lock }
                if hide != initialHidden { rv.isHidden = hide }
                do { try url.setResourceValues(rv) } catch {
                    Alerts.show("Error Applying Attributes", "\(u.lastPathComponent): \(error.localizedDescription)")
                    return false
                }
                urls[i] = url
            }
            initialLocked = lock
            initialHidden = hide
        }
        if let f = nameField, urls.count == 1, f.stringValue != urls[0].lastPathComponent {
            guard let newURL = FileOperations.shared.rename(urls[0], to: f.stringValue) else { return false }
            urls[0] = newURL
            window?.title = "\(newURL.lastPathComponent) Properties"
        }
        applyButton.isEnabled = false
        NotificationCenter.default.post(name: .settingsChanged, object: nil)
        return true
    }

    @objc private func applyPressed() { apply() }
    @objc private func okPressed() { if apply() { close() } }
    @objc private func cancelPressed() { close() }

    func windowWillClose(_ notification: Notification) {
        cancelled = true
        NotificationCenter.default.removeObserver(self)
        PropertiesWindowController.open.removeAll { $0 === self }
    }
}

/// Windows-style drive usage chart.
final class PieView: NSView {
    let fraction: Double
    init(fraction: Double) {
        self.fraction = fraction
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let d: CGFloat = min(bounds.height - 10, 120)
        let r = NSRect(x: bounds.midX - d / 2, y: bounds.midY - d / 2, width: d, height: d)
        let c = NSPoint(x: r.midX, y: r.midY)
        let ring = NSBezierPath(ovalIn: r)
        NSColor(hex: 0xD8D8D8).setFill()
        ring.fill()
        let used = NSBezierPath()
        used.move(to: c)
        used.appendArc(withCenter: c, radius: d / 2, startAngle: 90, endAngle: 90 - CGFloat(fraction) * 360, clockwise: true)
        used.close()
        NSColor(hex: 0x2B78E4).setFill()
        used.fill()
        let hole = NSBezierPath(ovalIn: r.insetBy(dx: d * 0.22, dy: d * 0.22))
        NSColor.windowBackgroundColor.setFill()
        hole.fill()
    }
}

// MARK: - Folder options

final class FolderOptionsController: NSWindowController {
    static let shared = FolderOptionsController()
    private let openTo = NSPopUpButton()
    private let recent = NSButton(checkboxWithTitle: "Show recently used files in Home", target: nil, action: nil)
    private let hidden = NSButton(checkboxWithTitle: "Show hidden files, folders, and drives", target: nil, action: nil)
    private let hideExt = NSButton(checkboxWithTitle: "Hide extensions for known file types", target: nil, action: nil)
    private let compact = NSButton(checkboxWithTitle: "Decrease space between items (compact view)", target: nil, action: nil)
    private let navPane = NSButton(checkboxWithTitle: "Show navigation pane", target: nil, action: nil)

    private init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 380), styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "Folder Options"
        w.isReleasedWhenClosed = false
        super.init(window: w)
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        openTo.addItems(withTitles: ["Home", "This PC"])
        let clear = NSButton(title: "Clear", target: self, action: #selector(clearHistory))
        let ok = NSButton(title: "OK", target: self, action: #selector(okPressed))
        ok.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
        cancel.keyEquivalent = "\u{1b}"
        let apply = NSButton(title: "Apply", target: self, action: #selector(applyPressed))

        func section(_ t: String) -> NSTextField { makeLabel(t, size: 12, weight: .semibold) }
        let openRow = NSStackView(views: [makeLabel("Open File Explorer to:", size: 12), openTo])
        let clearRow = NSStackView(views: [makeLabel("Clear File Explorer history", size: 12), clear])
        let stack = NSStackView(views: [section("General"), openRow, section("Privacy"), recent, clearRow,
                                        section("View"), hidden, hideExt, compact, navPane])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(18, after: openRow)
        stack.setCustomSpacing(18, after: clearRow)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let buttons = NSStackView(views: [ok, cancel, apply])
        buttons.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(stack)
        root.addSubview(buttons)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
        ])
        window?.contentView = root
    }

    func present() {
        let s = Settings.shared
        openTo.selectItem(at: s.openTo == "thispc" ? 1 : 0)
        recent.state = s.showRecent ? .on : .off
        hidden.state = s.showHidden ? .on : .off
        hideExt.state = s.showExtensions ? .off : .on
        compact.state = s.compactView ? .on : .off
        navPane.state = s.showNavPane ? .on : .off
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func apply() {
        let s = Settings.shared
        s.openTo = openTo.indexOfSelectedItem == 1 ? "thispc" : "home"
        if s.showRecent != (recent.state == .on) { s.showRecent = recent.state == .on; RecentFiles.shared.refresh() }
        if s.showHidden != (hidden.state == .on) { s.showHidden = hidden.state == .on }
        if s.showExtensions != (hideExt.state == .off) { s.showExtensions = hideExt.state == .off }
        if s.compactView != (compact.state == .on) { s.compactView = compact.state == .on }
        if s.showNavPane != (navPane.state == .on) { s.showNavPane = navPane.state == .on }
    }

    @objc private func clearHistory() {
        Settings.shared.clearHistory()
        RecentFiles.shared.refresh()
    }

    @objc private func okPressed() { apply(); close() }
    @objc private func cancelPressed() { close() }
    @objc private func applyPressed() { apply() }
}
