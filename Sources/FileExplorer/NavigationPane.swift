import AppKit

final class NavNode: NSObject {
    enum Kind { case home, gallery, separator, pinned, thisPC, drive, folder, recycleBin }
    let kind: Kind
    let url: URL?
    let title: String
    let icon: NSImage?
    var children: [NavNode]?
    var expandable: Bool

    init(_ kind: Kind, title: String = "", url: URL? = nil, icon: NSImage? = nil, expandable: Bool = false) {
        self.kind = kind
        self.title = title
        self.url = url
        self.icon = icon
        self.expandable = expandable
    }

    var location: Location? {
        switch kind {
        case .home: return .home
        case .gallery: return .gallery
        case .thisPC: return .thisPC
        case .separator: return nil
        default: return url.map { .dir($0) }
        }
    }

    func loadChildren() {
        guard children == nil else { return }
        switch kind {
        case .thisPC:
            children = VolumeInfo.list().map {
                NavNode(.drive, title: $0.name, url: $0.url, icon: IconFactory.drive(size: 16, kind: $0.kind), expandable: true)
            }
        case .drive, .folder, .pinned:
            guard let url else { children = []; return }
            children = DirectoryLoader.subfolders(of: url, showHidden: Settings.shared.showHidden).map {
                NavNode(.folder, title: $0.lastPathComponent, url: $0.dirNormalized, icon: Location.icon(for: $0), expandable: true)
            }
        default:
            children = []
        }
        if children?.isEmpty == true { expandable = false }
    }
}

protocol NavigationPaneDelegate: AnyObject {
    func navPaneNavigate(_ location: Location)
    func navPaneMenu(for node: NavNode) -> NSMenu?
    func navPaneDrop(_ urls: [URL], into folder: URL, copy: Bool) -> Bool
    func navPaneKeyDown(_ event: NSEvent) -> Bool
}

final class NavOutlineView: NSOutlineView {
    var keyHandler: ((NSEvent) -> Bool)?
    var menuProvider: ((Int) -> NSMenu?)?
    private(set) var hoveredRow = -1
    private var hoverArea: NSTrackingArea?

    override func makeView(withIdentifier identifier: NSUserInterfaceItemIdentifier, owner: Any?) -> NSView? {
        let v = super.makeView(withIdentifier: identifier, owner: owner)
        if identifier == NSOutlineView.disclosureButtonIdentifier, let b = v as? NSButton {
            b.image = Sym.image("chevron.right", size: 9, weight: .medium)
            b.alternateImage = Sym.image("chevron.down", size: 9, weight: .medium)
            b.isBordered = false
            b.contentTintColor = Theme.secondaryText
        }
        return v
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t)
        hoverArea = t
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        setHover(row(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHover(-1)
    }

    private func setHover(_ r: Int) {
        guard r != hoveredRow else { return }
        (rowView(atRow: hoveredRow, makeIfNecessary: false) as? NavRowView)?.isHovered = false
        hoveredRow = r
        (rowView(atRow: r, makeIfNecessary: false) as? NavRowView)?.isHovered = true
    }

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?(row(at: convert(event.locationInWindow, from: nil)))
    }

    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        var r = super.frameOfOutlineCell(atRow: row)
        r.origin.x += 4
        return r
    }
}

final class NavRowView: NSTableRowView {
    var isHovered = false { didSet { if oldValue != isHovered { needsDisplay = true } } }
    var isSeparatorRow = false
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func drawBackground(in dirtyRect: NSRect) {
        Theme.content.setFill()
        bounds.fill()
        if isSeparatorRow {
            Theme.separator.setFill()
            NSRect(x: 12, y: (bounds.height / 2).rounded(), width: bounds.width - 24, height: 1).fill()
        } else if isHovered && !isSelected {
            Draw.rounded(bounds.insetBy(dx: 4, dy: 1), 4, fill: Theme.navHover)
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        Draw.rounded(bounds.insetBy(dx: 4, dy: 1), 4, fill: Theme.navSelected)
    }

    override func drawDraggingDestinationFeedback(in dirtyRect: NSRect) {
        Draw.rounded(bounds.insetBy(dx: 4, dy: 1), 4, fill: Theme.itemDrop)
    }
}

final class NavCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("NavCell")
    let icon = NSImageView()
    let label = NSTextField(labelWithString: "")
    let pin = NSImageView()

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        for v in [icon, label, pin] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        icon.imageScaling = .scaleProportionallyDown
        label.font = Theme.font(12)
        label.textColor = Theme.text
        label.lineBreakMode = .byTruncatingTail
        pin.image = Sym.image("pin", size: 10)
        pin.contentTintColor = Theme.tertiaryText
        imageView = icon
        textField = label
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: pin.leadingAnchor, constant: -4),
            pin.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            pin.centerYAnchor.constraint(equalTo: centerYAnchor),
            pin.widthAnchor.constraint(equalToConstant: 12),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

final class NavigationPane: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    weak var delegate: NavigationPaneDelegate?
    let outline = NavOutlineView()
    private let scroll = NSScrollView()
    private var roots: [NavNode] = []
    private let homeNode = NavNode(.home, title: "Home", icon: IconFactory.navIcon(.home))
    private let galleryNode = NavNode(.gallery, title: "Gallery", icon: IconFactory.navIcon(.gallery))
    private let thisPCNode = NavNode(.thisPC, title: "This PC", icon: IconFactory.navIcon(.thisPC), expandable: true)
    private let recycleNode = NavNode(.recycleBin, title: "Recycle Bin", url: trashURL, icon: IconFactory.navIcon(.recycleBin))
    private var suppress = false

    init() {
        super.init(frame: .zero)
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("nav"))
        col.resizingMask = .autoresizingMask
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.style = .plain
        outline.backgroundColor = Theme.content
        outline.intercellSpacing = NSSize(width: 0, height: 0)
        outline.indentationPerLevel = 14
        outline.focusRingType = .none
        outline.floatsGroupRows = false
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(clicked)
        outline.registerForDraggedTypes([.fileURL])
        outline.setDraggingSourceOperationMask(.every, forLocal: false)
        outline.keyHandler = { [weak self] e in self?.handleKey(e) ?? false }
        outline.menuProvider = { [weak self] r in
            guard let self, let node = self.outline.item(atRow: r) as? NavNode, node.kind != .separator else { return nil }
            return self.delegate?.navPaneMenu(for: node)
        }
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.content
        scroll.borderType = .noBorder
        scroll.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        addSubview(scroll)
        scroll.pinEdges(to: self)
        rebuild()
        outline.reloadData()
        NotificationCenter.default.addObserver(self, selector: #selector(pinsChanged), name: .pinsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(volumesChanged), name: .volumesChanged, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { NotificationCenter.default.removeObserver(self) }

    private func rebuild() {
        let pinned = Settings.shared.pinned.filter { FileManager.default.fileExists(atPath: $0.path) }.map { u -> NavNode in
            let title = KnownFolder.match(u)?.title ?? Location.displayName(for: u)
            return NavNode(.pinned, title: title, url: u.dirNormalized, icon: Location.icon(for: u), expandable: true)
        }
        roots = [homeNode, galleryNode, NavNode(.separator)] + pinned + [NavNode(.separator), thisPCNode, recycleNode]
    }

    @objc private func pinsChanged() {
        let expanded = outline.isItemExpanded(thisPCNode)
        rebuild()
        outline.reloadData()
        if expanded { outline.expandItem(thisPCNode) }
    }

    @objc private func volumesChanged() {
        thisPCNode.children = nil
        thisPCNode.expandable = true
        outline.reloadItem(thisPCNode, reloadChildren: true)
    }

    func refreshTree() {
        let expanded = outline.isItemExpanded(thisPCNode)
        thisPCNode.children = nil
        rebuild()
        outline.reloadData()
        if expanded { outline.expandItem(thisPCNode) }
    }

    func select(_ loc: Location) {
        suppress = true
        defer { suppress = false }
        for r in 0..<outline.numberOfRows {
            guard let n = outline.item(atRow: r) as? NavNode, let l = n.location else { continue }
            if l == loc {
                outline.selectRowIndexes([r], byExtendingSelection: false)
                outline.scrollRowToVisible(r)
                return
            }
        }
        outline.deselectAll(nil)
    }

    @objc private func clicked() {
        let r = outline.clickedRow
        guard r >= 0, let n = outline.item(atRow: r) as? NavNode, let loc = n.location else { return }
        delegate?.navPaneNavigate(loc)
    }

    private func handleKey(_ e: NSEvent) -> Bool {
        if e.keyCode == 36 || e.keyCode == 76 {
            if let n = outline.item(atRow: outline.selectedRow) as? NavNode, let loc = n.location { delegate?.navPaneNavigate(loc) }
            return true
        }
        return delegate?.navPaneKeyDown(e) ?? false
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let n = item as? NavNode else { return roots.count }
        let wasLoaded = n.children != nil
        n.loadChildren()
        if !wasLoaded && !n.expandable {
            DispatchQueue.main.async { outlineView.reloadItem(n) }
        }
        return n.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let n = item as? NavNode else { return roots[index] }
        return n.children?[index] ?? NavNode(.separator)
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? NavNode)?.expandable ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        if (item as? NavNode)?.kind == .separator { return 13 }
        return Settings.shared.compactView ? 24 : 28
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let v = NavRowView()
        v.isSeparatorRow = (item as? NavNode)?.kind == .separator
        return v
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let n = item as? NavNode else { return nil }
        if n.kind == .separator { return NSView() }
        let cell = outlineView.makeView(withIdentifier: NavCell.id, owner: nil) as? NavCell ?? NavCell()
        cell.icon.image = n.icon
        cell.label.stringValue = n.title
        cell.pin.isHidden = n.kind != .pinned
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? NavNode)?.kind != .separator
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppress, let e = NSApp.currentEvent, e.type == .keyDown,
              let n = outline.item(atRow: outline.selectedRow) as? NavNode, let loc = n.location else { return }
        // Keyboard navigation in the tree navigates after a short pause (like Windows).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.outline.item(atRow: self.outline.selectedRow) as? NavNode === n else { return }
            self.delegate?.navPaneNavigate(loc)
        }
    }

    func outlineView(_ outlineView: NSOutlineView, toolTipFor cell: NSCell, rect: NSRectPointer, tableColumn: NSTableColumn?,
                     item: Any, mouseLocation: NSPoint) -> String {
        (item as? NavNode)?.url?.path ?? ""
    }

    // MARK: Drag & drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let n = item as? NavNode, n.kind == .folder || n.kind == .pinned, let u = n.url else { return nil }
        return u as NSURL
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        let urls = DragUtil.urls(info)
        guard index == NSOutlineViewDropOnItemIndex, let n = item as? NavNode, let target = n.url, !urls.isEmpty else { return [] }
        return DragUtil.operation(info, urls: urls, target: target)
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let n = item as? NavNode, let target = n.url else { return false }
        let urls = DragUtil.urls(info)
        if target.path == trashURL.path {
            FileOperations.shared.recycle(urls)
            return true
        }
        let op = DragUtil.operation(info, urls: urls, target: target)
        guard !op.isEmpty else { return false }
        return delegate?.navPaneDrop(urls, into: target, copy: op == .copy) ?? false
    }
}
