import AppKit

protocol FileListDelegate: AnyObject {
    func listOpen(_ items: [FileItem])
    func listSelectionChanged()
    func listMenu(for items: [FileItem]) -> NSMenu?
    func listRename(_ item: FileItem, to name: String)
    func listDrop(_ urls: [URL], into folder: URL, copy: Bool) -> Bool
    func listKeyDown(_ event: NSEvent) -> Bool
    func listSortClicked(_ key: SortKey)
    func listZoom(_ delta: Int)
    var listCurrentFolder: URL? { get }
}

protocol FileListView: AnyObject {
    var view: NSView { get }
    var delegate: FileListDelegate? { get set }
    func reload(_ groups: [ItemGroup], state: FolderViewState, search: Bool)
    var selectedItems: [FileItem] { get }
    func select(paths: Set<String>, scroll: Bool)
    func selectAllItems()
    func selectNone()
    func invertSelection()
    func beginRename(path: String)
    func focus()
    func refreshVisible()
}

enum DragUtil {
    static func urls(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    /// Windows rules: same drive = move, other drive = copy. Option forces copy, Command forces move.
    static func operation(_ info: NSDraggingInfo, urls: [URL], target: URL) -> NSDragOperation {
        let mask = info.draggingSourceOperationMask
        if urls.contains(where: { $0.path == target.path }) { return [] }
        if mask == .copy || (mask.contains(.copy) && !mask.contains(.move) && !mask.contains(.generic)) { return .copy }
        if mask.contains(.generic) && !mask.contains(.copy) { return .move }
        let allSameParent = urls.allSatisfy { $0.deletingLastPathComponent().path == target.path }
        if allSameParent { return [] }
        let same = urls.allSatisfy { FileOperations.sameVolume($0, target) }
        if same && (mask.contains(.move) || mask.contains(.generic)) { return .move }
        if mask.contains(.copy) { return .copy }
        return mask.contains(.move) ? .move : []
    }
}

// MARK: - Shared cell drawing helpers

enum ItemStyle {
    static func background(selected: Bool, hovered: Bool, focused: Bool, drop: Bool) -> NSColor? {
        if drop { return Theme.itemDrop }
        if selected { return focused ? (hovered ? Theme.itemSelectedHover : Theme.itemSelected) : Theme.itemSelectedInactive }
        if hovered { return Theme.itemHover }
        return nil
    }

    static func tooltip(_ item: FileItem) -> String {
        var lines = ["Type: \(item.typeDescription)"]
        if !item.isDirectory { lines.append("Size: \(Fmt.size(item.size))") }
        if let d = item.modified { lines.append("Date modified: \(Fmt.date(d))") }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Details view (NSTableView)

final class ExplorerTableView: NSTableView {
    var keyHandler: ((NSEvent) -> Bool)?
    var menuProvider: ((Int) -> NSMenu?)?
    var zoomHandler: ((Int) -> Void)?
    private(set) var hoveredRow = -1
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self)
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

    func setHover(_ r: Int) {
        guard r != hoveredRow else { return }
        (rowView(atRow: hoveredRow, makeIfNecessary: false) as? ExplorerRowView)?.isHovered = false
        hoveredRow = r
        (rowView(atRow: r, makeIfNecessary: false) as? ExplorerRowView)?.isHovered = true
    }

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let r = row(at: convert(event.locationInWindow, from: nil))
        if r >= 0 {
            if !selectedRowIndexes.contains(r) { selectRowIndexes([r], byExtendingSelection: false) }
        } else {
            deselectAll(nil)
        }
        window?.makeFirstResponder(self)
        return menuProvider?(r)
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command), abs(event.scrollingDeltaY) > 0.5 {
            zoomHandler?(event.scrollingDeltaY > 0 ? 1 : -1)
            return
        }
        super.scrollWheel(with: event)
    }

    override func drawGrid(inClipRect clipRect: NSRect) {}
}

final class ExplorerRowView: NSTableRowView {
    var isHovered = false { didSet { if oldValue != isHovered { needsDisplay = true } } }
    var isGroup = false

    override var isEmphasized: Bool { didSet { needsDisplay = true } }
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func drawBackground(in dirtyRect: NSRect) {
        Theme.content.setFill()
        bounds.fill()
        if isHovered && !isSelected && !isGroup {
            Draw.rounded(bounds.insetBy(dx: 4, dy: 1), 4, fill: Theme.itemHover)
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard !isGroup else { return }
        let c = ItemStyle.background(selected: true, hovered: isHovered, focused: isEmphasized, drop: false)
        Draw.rounded(bounds.insetBy(dx: 4, dy: 1), 4, fill: c)
    }

    override func drawDraggingDestinationFeedback(in dirtyRect: NSRect) {
        Draw.rounded(bounds.insetBy(dx: 4, dy: 1), 4, fill: Theme.itemDrop, stroke: Theme.accent)
    }
}

final class WinHeaderCell: NSTableHeaderCell {
    var sortAscending: Bool?
    var alignRight = false

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        Theme.content.setFill()
        cellFrame.fill()
        Theme.separator.setFill()
        NSRect(x: cellFrame.maxX - 1, y: cellFrame.minY + 5, width: 1, height: cellFrame.height - 10).fill()
        drawInterior(withFrame: cellFrame, in: controlView)
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        let r = NSRect(x: cellFrame.minX + 10, y: cellFrame.minY, width: cellFrame.width - 20, height: cellFrame.height)
        Draw.text(stringValue, in: r, font: Theme.font(12), color: Theme.secondaryText, align: alignRight ? .right : .left)
        if let asc = sortAscending {
            let img = Sym.image(asc ? "chevron.up" : "chevron.down", size: 7, weight: .semibold)
            Draw.symbol(img, in: NSRect(x: cellFrame.midX - 5, y: cellFrame.minY + 1, width: 10, height: 7), color: Theme.tertiaryText)
        }
    }

    override func highlight(_ flag: Bool, withFrame cellFrame: NSRect, in controlView: NSView) {
        draw(withFrame: cellFrame, in: controlView)
        if flag { Draw.rounded(cellFrame.insetBy(dx: 1, dy: 2), 3, fill: Theme.buttonHover) }
    }
}

final class WinHeaderView: NSTableHeaderView {
    override func draw(_ dirtyRect: NSRect) {
        Theme.content.setFill()
        dirtyRect.intersection(bounds).fill()
        super.draw(dirtyRect)
        if let t = tableView, let last = t.tableColumns.lastIndex(where: { !$0.isHidden }) {
            let maxX = t.rect(ofColumn: last).maxX
            if maxX < bounds.width {
                Theme.content.setFill()
                NSRect(x: maxX, y: 0, width: bounds.width - maxX, height: bounds.height).fill()
            }
        }
    }
}

/// Windows style column header drawn outside the scroll view.
final class DetailsHeaderBar: FlippedView {
    weak var table: NSTableView?
    var onClick: ((String) -> Void)?
    var sortKey = ""
    var ascending = true
    var offsetX: CGFloat = 0 { didSet { needsDisplay = true; window?.invalidateCursorRects(for: self) } }
    private var pressed: Int?
    private var hovered: Int?
    private var tracking: NSTrackingArea?

    private var columns: [(index: Int, col: NSTableColumn, rect: NSRect)] {
        guard let t = table else { return [] }
        return t.tableColumns.enumerated().compactMap { i, c in
            guard !c.isHidden else { return nil }
            let r = t.rect(ofColumn: i)
            return (i, c, NSRect(x: r.minX - offsetX, y: 0, width: r.width, height: bounds.height))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.content.setFill()
        bounds.fill()
        for (i, c, r) in columns {
            if hovered == i || pressed == i {
                Draw.rounded(r.insetBy(dx: 1, dy: 3), 4, fill: pressed == i ? Theme.buttonPressed : Theme.buttonHover)
            }
            Theme.separator.setFill()
            NSRect(x: r.maxX - 1, y: 6, width: 1, height: r.height - 12).fill()
            let id = c.identifier.rawValue
            Draw.text(c.title, in: NSRect(x: r.minX + 10, y: 0, width: r.width - 20, height: r.height),
                      font: Theme.font(12), color: Theme.secondaryText, align: id == "size" ? .right : .left)
            if id == sortKey {
                let img = Sym.image(ascending ? "chevron.up" : "chevron.down", size: 7, weight: .semibold)
                Draw.symbol(img, in: NSRect(x: r.midX - 5, y: 1, width: 10, height: 7), color: Theme.tertiaryText)
            }
        }
    }

    override func resetCursorRects() {
        for (_, _, r) in columns { addCursorRect(NSRect(x: r.maxX - 4, y: 0, width: 8, height: bounds.height), cursor: .resizeLeftRight) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    private func hit(_ p: NSPoint) -> (Int, NSTableColumn, NSRect)? { columns.first { $0.rect.contains(p) } }

    override func mouseMoved(with event: NSEvent) {
        let h = hit(convert(event.locationInWindow, from: nil))?.0
        if h != hovered { hovered = h; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) { hovered = nil; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let edge = columns.first(where: { abs($0.rect.maxX - p.x) <= 4 }) {
            // Drag to resize; double-click sizes to fit is handled by the header menu.
            let startW = edge.col.width
            let startX = p.x
            while let e = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                let x = convert(e.locationInWindow, from: nil).x
                edge.col.width = max(edge.col.minWidth, startW + x - startX)
                needsDisplay = true
                if e.type == .leftMouseUp { break }
            }
            window?.invalidateCursorRects(for: self)
            return
        }
        pressed = hit(p)?.0
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = nil; needsDisplay = true }
        guard let pr = pressed, let h = hit(convert(event.locationInWindow, from: nil)), h.0 == pr else { return }
        onClick?(h.1.identifier.rawValue)
    }
}

final class NameCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("NameCell")
    let icon = NSImageView()
    let field = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        field.translatesAutoresizingMaskIntoConstraints = false
        field.font = Theme.font(12)
        field.textColor = Theme.text
        field.lineBreakMode = .byTruncatingTail
        field.cell?.truncatesLastVisibleLine = true
        addSubview(icon)
        addSubview(field)
        imageView = icon
        textField = field
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

final class TextCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("TextCell")
    let field = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        field.translatesAutoresizingMaskIntoConstraints = false
        field.font = Theme.font(12)
        field.textColor = Theme.secondaryText
        field.lineBreakMode = .byTruncatingTail
        addSubview(field)
        textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

final class GroupHeaderView: FlippedView {
    var title = "" { didSet { needsDisplay = true } }
    var leftInset: CGFloat = 14

    override func draw(_ dirtyRect: NSRect) {
        Theme.content.setFill()
        bounds.fill()
        let font = Theme.font(12.5)
        let w = Draw.textWidth(title, font: font)
        let midY = bounds.height / 2 + 2
        Draw.text(title, in: NSRect(x: leftInset, y: midY - 10, width: w + 2, height: 20), font: font, color: Theme.groupHeader)
        Theme.separator.setFill()
        let x = leftInset + w + 10
        if x < bounds.width - 12 { NSRect(x: x, y: midY.rounded(), width: bounds.width - x - 12, height: 1).fill() }
    }
}

final class DetailsListView: NSView, FileListView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    weak var delegate: FileListDelegate?
    var view: NSView { self }
    let scroll = NSScrollView()
    let table = ExplorerTableView()

    private enum Row { case header(ItemGroup), item(FileItem) }
    private var rows: [Row] = []
    private var state = FolderViewState()
    private var isSearch = false
    private var renaming: (item: FileItem, field: NSTextField)?
    private var renameCancelled = false
    private var suppressSelection = false

    static let columnSpecs: [(id: String, title: String, width: CGFloat)] = [
        ("name", "Name", 260), ("modified", "Date modified", 150), ("type", "Type", 150),
        ("size", "Size", 90), ("created", "Date created", 165), ("folder", "Folder", 280),
    ]

    init() {
        super.init(frame: .zero)
        for spec in Self.columnSpecs {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.id))
            let cell = WinHeaderCell(textCell: spec.title)
            cell.alignRight = spec.id == "size"
            c.headerCell = cell
            c.title = spec.title
            c.width = spec.width
            c.minWidth = spec.id == "name" ? 120 : 50
            c.resizingMask = .userResizingMask
            table.addTableColumn(c)
        }
        table.headerView = nil
        table.cornerView = nil
        table.style = .plain
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.backgroundColor = Theme.content
        table.gridStyleMask = []
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.allowsColumnReordering = false
        table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.focusRingType = .none
        table.floatsGroupRows = false
        table.allowsTypeSelect = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask(.every, forLocal: true)
        table.setDraggingSourceOperationMask([.copy, .move, .link, .generic, .delete], forLocal: false)
        table.draggingDestinationFeedbackStyle = .regular
        table.keyHandler = { [weak self] e in self?.delegate?.listKeyDown(e) ?? false }
        table.zoomHandler = { [weak self] d in self?.delegate?.listZoom(d) }
        table.menuProvider = { [weak self] _ in
            guard let self else { return nil }
            self.delegate?.listSelectionChanged()
            return self.delegate?.listMenu(for: self.selectedItems)
        }

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.content
        header.table = table
        header.onClick = { [weak self] id in if let k = SortKey(rawValue: id) { self?.delegate?.listSortClicked(k) } }
        addSubview(header)
        addSubview(scroll)
        header.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 30),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.header.offsetX = self.scroll.contentView.bounds.origin.x
        }
        NotificationCenter.default.addObserver(forName: NSTableView.columnDidResizeNotification, object: table, queue: .main) { [weak self] _ in
            self?.header.needsDisplay = true
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    let header = DetailsHeaderBar()

    private var rowHeight: CGFloat { Settings.shared.compactView ? 24 : 30 }

    func reload(_ groups: [ItemGroup], state: FolderViewState, search: Bool) {
        self.state = state
        isSearch = search
        var r: [Row] = []
        let grouped = state.groupBy != .none
        for g in groups where !g.items.isEmpty || !grouped {
            if grouped { r.append(.header(g)) }
            r += g.items.map { .item($0) }
        }
        let selected = Set(selectedItems.map(\.path))
        suppressSelection = true
        rows = r
        table.reloadData()
        updateColumns()
        select(paths: selected, scroll: false)
        suppressSelection = false
    }

    private func updateColumns() {
        var visible = Set(Settings.shared.visibleColumns)
        visible.insert("name")
        for c in table.tableColumns {
            let id = c.identifier.rawValue
            c.isHidden = id == "folder" ? !isSearch : !visible.contains(id)
            if let h = c.headerCell as? WinHeaderCell {
                h.sortAscending = SortKey(rawValue: id) == state.sortKey ? state.ascending : nil
            }
        }
        header.sortKey = state.sortKey.rawValue
        header.ascending = state.ascending
        header.needsDisplay = true
        header.menu = headerMenu()
    }

    private func headerMenu() -> NSMenu {
        var items: [NSMenuItem] = [
            ClosureMenuItem("Size column to fit") { [weak self] in self?.sizeToFit(all: false) },
            ClosureMenuItem("Size all columns to fit") { [weak self] in self?.sizeToFit(all: true) },
            .separator(),
        ]
        for spec in Self.columnSpecs where spec.id != "folder" {
            let on = spec.id == "name" || Settings.shared.visibleColumns.contains(spec.id)
            items.append(ClosureMenuItem(spec.title, checked: on, enabled: spec.id != "name") { [weak self] in
                var v = Settings.shared.visibleColumns
                if v.contains(spec.id) { v.removeAll { $0 == spec.id } } else { v.append(spec.id) }
                Settings.shared.visibleColumns = v
                self?.updateColumns()
            })
        }
        return NSMenu(items: items)
    }

    private func sizeToFit(all: Bool) {
        for (i, c) in table.tableColumns.enumerated() where !c.isHidden && (all || c.identifier.rawValue == "name") {
            var w: CGFloat = Draw.textWidth(c.title, font: Theme.font(12)) + 28
            for r in 0..<min(rows.count, 2000) {
                if case .item(let it) = rows[safe: r] {
                    w = max(w, Draw.textWidth(text(for: it, column: c.identifier.rawValue), font: Theme.font(12)) + (i == 0 ? 44 : 24))
                }
            }
            c.width = min(w, 600)
        }
    }

    private func text(for it: FileItem, column: String) -> String {
        switch column {
        case "name": return it.displayName(showExtensions: Settings.shared.showExtensions)
        case "modified": return Fmt.date(it.modified)
        case "created": return Fmt.date(it.created)
        case "type": return it.typeDescription
        case "size": return it.isDirectory ? "" : Fmt.kb(it.size)
        case "folder": return Fmt.abbreviatePath(it.parent.path)
        default: return ""
        }
    }

    // MARK: Selection API

    var selectedItems: [FileItem] {
        table.selectedRowIndexes.compactMap { i -> FileItem? in
            if case .item(let it) = rows[safe: i] { return it }
            return nil
        }
    }

    func select(paths: Set<String>, scroll: Bool) {
        var set = IndexSet()
        for (i, r) in rows.enumerated() {
            if case .item(let it) = r, paths.contains(it.path) { set.insert(i) }
        }
        table.selectRowIndexes(set, byExtendingSelection: false)
        if scroll, let f = set.first { table.scrollRowToVisible(f) }
    }

    func selectAllItems() { table.selectAll(nil) }
    func selectNone() { table.deselectAll(nil) }

    func invertSelection() {
        var set = IndexSet()
        for (i, r) in rows.enumerated() where !table.selectedRowIndexes.contains(i) {
            if case .item = r { set.insert(i) }
        }
        table.selectRowIndexes(set, byExtendingSelection: false)
    }

    func focus() { window?.makeFirstResponder(table) }

    func refreshVisible() {
        let range = table.rows(in: table.visibleRect)
        guard range.length > 0 else { return }
        table.reloadData(forRowIndexes: IndexSet(integersIn: range.location..<(range.location + range.length)),
                         columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
    }

    // MARK: Rename

    func beginRename(path: String) {
        guard let row = rows.firstIndex(where: { if case .item(let it) = $0 { return it.path == path }; return false }),
              case .item(let item) = rows[row] else { return }
        let col = table.column(withIdentifier: NSUserInterfaceItemIdentifier("name"))
        guard col >= 0 else { return }
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
        guard let cell = table.view(atColumn: col, row: row, makeIfNecessary: true) as? NameCell else { return }
        let f = cell.field
        renaming = (item, f)
        renameCancelled = false
        f.isEditable = true
        f.isSelectable = true
        f.isBordered = true
        f.drawsBackground = true
        f.backgroundColor = Theme.field
        f.focusRingType = .none
        f.delegate = self
        f.stringValue = item.displayName(showExtensions: Settings.shared.showExtensions)
        window?.makeFirstResponder(f)
        if let ed = f.currentEditor() {
            let base = item.isDirectory || item.ext.isEmpty || !Settings.shared.showExtensions
                ? f.stringValue : (f.stringValue as NSString).deletingPathExtension
            ed.selectedRange = NSRange(location: 0, length: (base as NSString).length)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            renameCancelled = true
            window?.makeFirstResponder(table)
            return true
        }
        if sel == #selector(NSResponder.insertNewline(_:)) {
            window?.makeFirstResponder(table)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let (item, f) = renaming, (obj.object as? NSTextField) === f else { return }
        renaming = nil
        let newName = f.stringValue
        f.isEditable = false
        f.isSelectable = false
        f.isBordered = false
        f.drawsBackground = false
        f.delegate = nil
        if renameCancelled || newName == item.displayName(showExtensions: Settings.shared.showExtensions) {
            f.stringValue = item.displayName(showExtensions: Settings.shared.showExtensions)
        } else {
            delegate?.listRename(item, to: newName)
        }
    }

    // MARK: Data source

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[safe: row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = rows[safe: row] { return 34 }
        return rowHeight
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let v = ExplorerRowView()
        if case .header = rows[safe: row] { v.isGroup = true }
        v.isHovered = row == table.hoveredRow
        return v
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let r = rows[safe: row] else { return nil }
        switch r {
        case .header(let g):
            let v = GroupHeaderView()
            v.title = "\(g.title) (\(g.items.count))"
            return v
        case .item(let it):
            guard let col = tableColumn else { return nil }
            let id = col.identifier.rawValue
            let dim: CGFloat = (Clipboard.isCut(it.path) || it.isHidden) ? 0.5 : 1
            if id == "name" {
                let cell = tableView.makeView(withIdentifier: NameCell.id, owner: nil) as? NameCell ?? NameCell()
                cell.icon.image = FileIcons.shared.icon(for: it, size: 16)
                cell.icon.alphaValue = dim
                if renaming?.field !== cell.field {
                    cell.field.stringValue = text(for: it, column: id)
                    cell.field.isEditable = false
                    cell.field.isBordered = false
                    cell.field.drawsBackground = false
                }
                cell.field.textColor = dim < 1 ? Theme.tertiaryText : Theme.text
                cell.toolTip = ItemStyle.tooltip(it)
                return cell
            }
            let cell = tableView.makeView(withIdentifier: TextCell.id, owner: nil) as? TextCell ?? TextCell()
            cell.field.stringValue = text(for: it, column: id)
            cell.field.alignment = id == "size" ? .right : .left
            return cell
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .header(let g) = rows[safe: row] {
            // Clicking a group header selects the whole group, like Windows.
            select(paths: Set(g.items.map(\.path)), scroll: false)
            return false
        }
        return true
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if !suppressSelection { delegate?.listSelectionChanged() }
    }

    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        if let k = SortKey(rawValue: tableColumn.identifier.rawValue) { delegate?.listSortClicked(k) }
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        if case .item(let it) = rows[safe: row], tableColumn?.identifier.rawValue == "name" {
            return it.displayName(showExtensions: Settings.shared.showExtensions)
        }
        return nil
    }

    @objc private func doubleClicked() {
        let r = table.clickedRow
        guard case .item = rows[safe: r] else { return }
        delegate?.listOpen(selectedItems)
    }

    // MARK: Drag & drop

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        if case .item(let it) = rows[safe: row] { return it.url as NSURL }
        return nil
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        let urls = DragUtil.urls(info)
        guard !urls.isEmpty else { return [] }
        if op == .on, case .item(let it) = rows[safe: row], it.isDirectory {
            return DragUtil.operation(info, urls: urls, target: it.url)
        }
        guard let cur = delegate?.listCurrentFolder else { return [] }
        tableView.setDropRow(-1, dropOperation: .on)
        return DragUtil.operation(info, urls: urls, target: cur)
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        let urls = DragUtil.urls(info)
        var target = delegate?.listCurrentFolder
        if row >= 0, case .item(let it) = rows[safe: row], it.isDirectory { target = it.url }
        guard let target else { return false }
        let op = DragUtil.operation(info, urls: urls, target: target)
        guard !op.isEmpty else { return false }
        return delegate?.listDrop(urls, into: target, copy: op == .copy) ?? false
    }
}

// MARK: - Icon views (NSCollectionView)

final class LeftFlowLayout: NSCollectionViewFlowLayout {
    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        let attrs = super.layoutAttributesForElements(in: rect).compactMap { $0.copy() as? NSCollectionViewLayoutAttributes }
        guard scrollDirection == .vertical else { return attrs }
        var x = sectionInset.left
        var rowMaxY: CGFloat = -1
        for a in attrs where a.representedElementCategory == .item {
            if a.frame.minY >= rowMaxY { x = sectionInset.left }
            a.frame.origin.x = x
            x += a.frame.width + minimumInteritemSpacing
            rowMaxY = max(rowMaxY, a.frame.maxY)
        }
        return attrs
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard let base = super.layoutAttributesForItem(at: indexPath) else { return nil }
        guard scrollDirection == .vertical else { return base }
        let rowRect = NSRect(x: 0, y: base.frame.minY, width: collectionViewContentSize.width, height: base.frame.height)
        return layoutAttributesForElements(in: rowRect).first {
            $0.representedElementCategory == .item && $0.indexPath == indexPath
        } ?? base
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool { true }
}

final class ExplorerCollectionView: NSCollectionView {
    var keyHandler: ((NSEvent) -> Bool)?
    var menuProvider: ((IndexPath?) -> NSMenu?)?
    var doubleClick: ((IndexPath) -> Void)?
    var zoomHandler: ((Int) -> Void)?
    var typeSelect: ((String) -> Void)?
    var focusChanged: (() -> Void)?
    private var typed = ""
    private var lastType = Date.distantPast

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let ip = indexPathForItem(at: p)
        super.mouseDown(with: event)
        if event.clickCount == 2, let ip { doubleClick?(ip) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let ip = indexPathForItem(at: convert(event.locationInWindow, from: nil))
        window?.makeFirstResponder(self)
        return menuProvider?(ip)
    }

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        if mods.isEmpty, let chars = event.characters, let c = chars.first, c.isLetter || c.isNumber || c == "." || c == "_" {
            if Date().timeIntervalSince(lastType) > 1 { typed = "" }
            typed += chars.lowercased()
            lastType = Date()
            typeSelect?(typed)
            return
        }
        super.keyDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command), abs(event.scrollingDeltaY) > 0.5 {
            zoomHandler?(event.scrollingDeltaY > 0 ? 1 : -1)
            return
        }
        super.scrollWheel(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        focusChanged?()
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        focusChanged?()
        return ok
    }
}

final class FileCellView: FlippedView {
    var item: FileItem?
    var mode: ViewMode = .large
    var icon: NSImage?
    var isSelected = false { didSet { if oldValue != isSelected { needsDisplay = true } } }
    var isHovered = false { didSet { if oldValue != isHovered { needsDisplay = true } } }
    var isDropTarget = false { didSet { if oldValue != isDropTarget { needsDisplay = true } } }
    var isFocusedList = true { didSet { if oldValue != isFocusedList { needsDisplay = true } } }
    var renameField: NSTextField?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    func configure(_ it: FileItem, mode: ViewMode) {
        item = it
        self.mode = mode
        toolTip = ItemStyle.tooltip(it)
        let size = mode.iconSize
        icon = FileIcons.shared.icon(for: it, size: size)
        if size >= 32, FileIcons.shared.canThumbnail(it) {
            let thumb = FileIcons.shared.thumbnail(for: it, size: size) { [weak self] img in
                guard let self, self.item === it else { return }
                self.icon = img
                self.needsDisplay = true
            }
            if let thumb { icon = thumb }
        }
        needsDisplay = true
    }

    var iconRect: NSRect {
        let s = mode.iconSize
        switch mode {
        case .extraLarge, .large, .medium:
            return NSRect(x: (bounds.width - s) / 2, y: 6, width: s, height: s)
        case .small, .list, .details:
            return NSRect(x: 6, y: (bounds.height - 16) / 2, width: 16, height: 16)
        case .tiles:
            return NSRect(x: 8, y: (bounds.height - 48) / 2, width: 48, height: 48)
        case .content:
            return NSRect(x: 12, y: (bounds.height - 32) / 2, width: 32, height: 32)
        }
    }

    var nameRect: NSRect {
        switch mode {
        case .extraLarge, .large, .medium:
            let top = iconRect.maxY + 4
            return NSRect(x: 4, y: top, width: bounds.width - 8, height: bounds.height - top - 2)
        case .small, .list, .details:
            return NSRect(x: 28, y: 0, width: bounds.width - 32, height: bounds.height)
        case .tiles:
            return NSRect(x: 64, y: bounds.height / 2 - 25, width: bounds.width - 70, height: 17)
        case .content:
            return NSRect(x: 56, y: bounds.height / 2 - 18, width: bounds.width * 0.5 - 56, height: 17)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let it = item else { return }
        let bgRect = mode == .content ? bounds.insetBy(dx: 2, dy: 1) : bounds.insetBy(dx: 1, dy: 1)
        if let bg = ItemStyle.background(selected: isSelected, hovered: isHovered, focused: isFocusedList, drop: isDropTarget) {
            Draw.rounded(bgRect, 4, fill: bg)
        }
        if mode == .content && !isSelected && !isHovered {
            Theme.separator.setFill()
            NSRect(x: 8, y: bounds.height - 1, width: bounds.width - 16, height: 1).fill()
        }
        let dim: CGFloat = (Clipboard.isCut(it.path) || it.isHidden) ? 0.5 : 1
        if let icon { Draw.image(icon, in: iconRect, alpha: dim) }
        guard renameField == nil else { return }

        let name = it.displayName(showExtensions: Settings.shared.showExtensions)
        let font = Theme.font(12)
        let fg = dim < 1 ? Theme.tertiaryText : Theme.text
        switch mode {
        case .extraLarge, .large, .medium:
            Draw.wrapped(name, in: nameRect, font: font, color: fg, align: .center, maxLines: isSelected ? 3 : 2)
        case .small, .list, .details:
            Draw.text(name, in: nameRect, font: font, color: fg)
        case .tiles:
            let x = nameRect.minX, w = nameRect.width
            Draw.text(name, in: nameRect, font: font, color: fg)
            Draw.text(it.typeDescription, in: NSRect(x: x, y: nameRect.maxY, width: w, height: 17), font: Theme.font(11), color: Theme.secondaryText)
            if !it.isDirectory {
                Draw.text(Fmt.size(it.size), in: NSRect(x: x, y: nameRect.maxY + 17, width: w, height: 17), font: Theme.font(11), color: Theme.secondaryText)
            }
        case .content:
            Draw.text(name, in: nameRect, font: Theme.font(12.5), color: fg)
            Draw.text(it.isDirectory ? Fmt.abbreviatePath(it.parent.path) : it.typeDescription,
                      in: NSRect(x: nameRect.minX, y: nameRect.maxY + 2, width: nameRect.width, height: 17),
                      font: Theme.font(11), color: Theme.secondaryText)
            let rx = bounds.width * 0.55, rw = bounds.width * 0.45 - 16
            Draw.text("Date modified: \(Fmt.date(it.modified))", in: NSRect(x: rx, y: nameRect.minY, width: rw, height: 17),
                      font: Theme.font(11), color: Theme.secondaryText)
            if !it.isDirectory {
                Draw.text("Size: \(Fmt.size(it.size))", in: NSRect(x: rx, y: nameRect.maxY + 2, width: rw, height: 17),
                          font: Theme.font(11), color: Theme.secondaryText)
            }
        }
    }

    func beginRename(delegate: NSTextFieldDelegate) -> NSTextField? {
        guard let it = item else { return nil }
        let f = NSTextField()
        f.font = Theme.font(12)
        f.isBordered = true
        f.drawsBackground = true
        f.backgroundColor = Theme.field
        f.textColor = Theme.text
        f.focusRingType = .none
        f.delegate = delegate
        f.stringValue = it.displayName(showExtensions: Settings.shared.showExtensions)
        var r = nameRect
        switch mode {
        case .extraLarge, .large, .medium:
            f.alignment = .center
            r = NSRect(x: 2, y: r.minY - 1, width: bounds.width - 4, height: 20)
        default:
            r = NSRect(x: r.minX - 2, y: (bounds.height - 20) / 2, width: max(140, r.width), height: 20)
            if mode == .tiles || mode == .content { r.origin.y = nameRect.minY - 2 }
        }
        f.frame = r
        addSubview(f)
        renameField = f
        needsDisplay = true
        return f
    }

    func endRename() {
        renameField?.removeFromSuperview()
        renameField = nil
        needsDisplay = true
    }
}

final class FileGridItem: NSCollectionViewItem {
    static let id = NSUserInterfaceItemIdentifier("FileGridItem")
    var cell: FileCellView { view as! FileCellView }

    override func loadView() { view = FileCellView() }

    override var isSelected: Bool { didSet { cell.isSelected = isSelected } }

    override func prepareForReuse() {
        super.prepareForReuse()
        cell.isHovered = false
        cell.isDropTarget = false
        cell.endRename()
    }
}

final class GridHeader: NSView, NSCollectionViewElement {
    static let id = NSUserInterfaceItemIdentifier("GridHeader")
    let header = GroupHeaderView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(header)
        header.pinEdges(to: self)
    }

    required init?(coder: NSCoder) { fatalError() }
}

final class GridListView: NSView, FileListView, NSCollectionViewDataSource, NSCollectionViewDelegate,
    NSCollectionViewDelegateFlowLayout, NSTextFieldDelegate {
    weak var delegate: FileListDelegate?
    var view: NSView { self }
    let scroll = NSScrollView()
    let collection = ExplorerCollectionView()
    private let flow = LeftFlowLayout()
    private(set) var groups: [ItemGroup] = []
    private(set) var mode: ViewMode = .large
    private var grouped = false
    private var renaming: (item: FileItem, cell: FileCellView, field: NSTextField)?
    private var renameCancelled = false
    private var dropPath: String?
    private var lastWidth: CGFloat = 0

    init() {
        super.init(frame: .zero)
        flow.minimumInteritemSpacing = 2
        flow.minimumLineSpacing = 2
        flow.sectionInset = NSEdgeInsets(top: 6, left: 10, bottom: 10, right: 10)
        collection.collectionViewLayout = flow
        collection.dataSource = self
        collection.delegate = self
        collection.isSelectable = true
        collection.allowsMultipleSelection = true
        collection.allowsEmptySelection = true
        collection.backgroundColors = [Theme.content]
        collection.register(FileGridItem.self, forItemWithIdentifier: FileGridItem.id)
        collection.register(GridHeader.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                            withIdentifier: GridHeader.id)
        collection.setDraggingSourceOperationMask(.every, forLocal: true)
        collection.setDraggingSourceOperationMask([.copy, .move, .link, .generic, .delete], forLocal: false)
        collection.keyHandler = { [weak self] e in self?.delegate?.listKeyDown(e) ?? false }
        collection.zoomHandler = { [weak self] d in self?.delegate?.listZoom(d) }
        collection.doubleClick = { [weak self] ip in
            guard let self, let it = self.item(at: ip) else { return }
            let sel = self.selectedItems
            self.delegate?.listOpen(sel.contains(it) ? sel : [it])
        }
        collection.menuProvider = { [weak self] ip in
            guard let self else { return nil }
            if let ip {
                if !self.collection.selectionIndexPaths.contains(ip) { self.collection.selectionIndexPaths = [ip] }
            } else {
                self.collection.selectionIndexPaths = []
            }
            self.syncSelection()
            return self.delegate?.listMenu(for: self.selectedItems)
        }
        collection.typeSelect = { [weak self] prefix in self?.typeSelect(prefix) }
        collection.focusChanged = { [weak self] in self?.updateFocusLook() }

        scroll.documentView = collection
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.content
        addSubview(scroll)
        scroll.pinEdges(to: self)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        if (mode == .content || mode == .details) && abs(bounds.width - lastWidth) > 0.5 {
            lastWidth = bounds.width
            flow.invalidateLayout()
        }
    }

    func setMode(_ m: ViewMode) {
        mode = m
        flow.scrollDirection = m == .list ? .horizontal : .vertical
        flow.minimumLineSpacing = (m == .list) ? 0 : 2
        flow.minimumInteritemSpacing = (m == .content) ? 0 : 2
    }

    private func itemSize() -> NSSize {
        let compact = Settings.shared.compactView
        switch mode {
        case .extraLarge: return NSSize(width: 272, height: 306)
        case .large: return NSSize(width: 118, height: compact ? 136 : 142)
        case .medium: return NSSize(width: 86, height: compact ? 88 : 94)
        case .small: return NSSize(width: 230, height: compact ? 22 : 26)
        case .list: return NSSize(width: 250, height: compact ? 22 : 24)
        case .tiles: return NSSize(width: 270, height: compact ? 66 : 74)
        case .content, .details:
            return NSSize(width: max(200, scroll.contentSize.width - 20), height: compact ? 50 : 58)
        }
    }

    func reload(_ groups: [ItemGroup], state: FolderViewState, search: Bool) {
        let selected = Set(selectedItems.map(\.path))
        self.groups = groups
        grouped = state.groupBy != .none
        if state.mode != mode { setMode(state.mode) }
        flow.invalidateLayout()
        collection.reloadData()
        select(paths: selected, scroll: false)
    }

    private func item(at ip: IndexPath) -> FileItem? { groups[safe: ip.section]?.items[safe: ip.item] }

    var selectedItems: [FileItem] { collection.selectionIndexPaths.sorted().compactMap { item(at: $0) } }

    func select(paths: Set<String>, scroll: Bool) {
        var set = Set<IndexPath>()
        for (s, g) in groups.enumerated() {
            for (i, it) in g.items.enumerated() where paths.contains(it.path) { set.insert(IndexPath(item: i, section: s)) }
        }
        collection.selectionIndexPaths = set
        if scroll, let first = set.sorted().first {
            collection.scrollToItems(at: [first], scrollPosition: mode == .list ? .nearestVerticalEdge : .nearestHorizontalEdge)
        }
        syncSelection()
    }

    private func syncSelection() {
        for ip in collection.indexPathsForVisibleItems() {
            (collection.item(at: ip) as? FileGridItem)?.cell.isSelected = collection.selectionIndexPaths.contains(ip)
        }
    }

    func selectAllItems() {
        collection.selectAll(nil)
        delegate?.listSelectionChanged()
    }

    func selectNone() {
        collection.deselectAll(nil)
        syncSelection()
        delegate?.listSelectionChanged()
    }

    func invertSelection() {
        var set = Set<IndexPath>()
        for (s, g) in groups.enumerated() {
            for i in g.items.indices {
                let ip = IndexPath(item: i, section: s)
                if !collection.selectionIndexPaths.contains(ip) { set.insert(ip) }
            }
        }
        collection.selectionIndexPaths = set
        syncSelection()
        delegate?.listSelectionChanged()
    }

    func focus() { window?.makeFirstResponder(collection) }

    func refreshVisible() {
        for ip in collection.indexPathsForVisibleItems() {
            (collection.item(at: ip) as? FileGridItem)?.cell.needsDisplay = true
        }
    }

    private func updateFocusLook() {
        let focused = window?.firstResponder === collection
        for ip in collection.indexPathsForVisibleItems() {
            (collection.item(at: ip) as? FileGridItem)?.cell.isFocusedList = focused
        }
    }

    private func typeSelect(_ prefix: String) {
        let show = Settings.shared.showExtensions
        for (s, g) in groups.enumerated() {
            if let i = g.items.firstIndex(where: { $0.displayName(showExtensions: show).lowercased().hasPrefix(prefix) }) {
                select(paths: [g.items[i].path], scroll: true)
                delegate?.listSelectionChanged()
                _ = s
                return
            }
        }
    }

    // MARK: Rename

    func beginRename(path: String) {
        var target: IndexPath?
        for (s, g) in groups.enumerated() {
            if let i = g.items.firstIndex(where: { $0.path == path }) { target = IndexPath(item: i, section: s) }
        }
        guard let ip = target, let it = item(at: ip) else { return }
        collection.selectionIndexPaths = [ip]
        collection.scrollToItems(at: [ip], scrollPosition: mode == .list ? .nearestVerticalEdge : .nearestHorizontalEdge)
        collection.layoutSubtreeIfNeeded()
        syncSelection()
        guard let gi = collection.item(at: ip) as? FileGridItem, let f = gi.cell.beginRename(delegate: self) else { return }
        renaming = (it, gi.cell, f)
        renameCancelled = false
        window?.makeFirstResponder(f)
        if let ed = f.currentEditor() {
            let base = it.isDirectory || it.ext.isEmpty || !Settings.shared.showExtensions
                ? f.stringValue : (f.stringValue as NSString).deletingPathExtension
            ed.selectedRange = NSRange(location: 0, length: (base as NSString).length)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            renameCancelled = true
            window?.makeFirstResponder(collection)
            return true
        }
        if sel == #selector(NSResponder.insertNewline(_:)) {
            window?.makeFirstResponder(collection)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let (it, cell, f) = renaming, (obj.object as? NSTextField) === f else { return }
        renaming = nil
        let newName = f.stringValue
        cell.endRename()
        if !renameCancelled && newName != it.displayName(showExtensions: Settings.shared.showExtensions) {
            delegate?.listRename(it, to: newName)
        }
    }

    // MARK: Data source

    func numberOfSections(in collectionView: NSCollectionView) -> Int { groups.count }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        groups[section].items.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let gi = collectionView.makeItem(withIdentifier: FileGridItem.id, for: indexPath) as! FileGridItem
        if let it = item(at: indexPath) { gi.cell.configure(it, mode: mode) }
        gi.cell.isSelected = collectionView.selectionIndexPaths.contains(indexPath)
        gi.cell.isFocusedList = window?.firstResponder === collection
        gi.cell.isDropTarget = item(at: indexPath)?.path == dropPath
        return gi
    }

    func collectionView(_ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
                        at indexPath: IndexPath) -> NSView {
        let v = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: GridHeader.id, for: indexPath) as! GridHeader
        let g = groups[indexPath.section]
        v.header.title = "\(g.title) (\(g.items.count))"
        v.header.leftInset = 12
        return v
    }

    func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> NSSize { itemSize() }

    func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout,
                        referenceSizeForHeaderInSection section: Int) -> NSSize {
        grouped && mode != .list && !groups[section].items.isEmpty ? NSSize(width: scroll.contentSize.width, height: 34) : .zero
    }

    func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout,
                        insetForSectionAt section: Int) -> NSEdgeInsets {
        if groups[section].items.isEmpty { return NSEdgeInsets() }
        return mode == .content ? NSEdgeInsets(top: 4, left: 10, bottom: 6, right: 10) : NSEdgeInsets(top: 6, left: 10, bottom: 10, right: 10)
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        syncSelection()
        delegate?.listSelectionChanged()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        syncSelection()
        delegate?.listSelectionChanged()
    }

    // MARK: Drag source

    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool {
        renaming == nil
    }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        item(at: indexPath)?.url as NSURL?
    }

    // MARK: Drop destination (handled on the container so we control the highlight)

    private func resolveDrop(_ info: NSDraggingInfo) -> (URL?, NSDragOperation) {
        let urls = DragUtil.urls(info)
        guard !urls.isEmpty else { return (nil, []) }
        let p = collection.convert(info.draggingLocation, from: nil)
        if let ip = collection.indexPathForItem(at: p), let it = item(at: ip), it.isDirectory,
           !urls.contains(where: { $0.path == it.path }) {
            setDropTarget(it.path)
            return (it.url, DragUtil.operation(info, urls: urls, target: it.url))
        }
        setDropTarget(nil)
        guard let cur = delegate?.listCurrentFolder else { return (nil, []) }
        return (cur, DragUtil.operation(info, urls: urls, target: cur))
    }

    private func setDropTarget(_ path: String?) {
        guard path != dropPath else { return }
        dropPath = path
        for ip in collection.indexPathsForVisibleItems() {
            (collection.item(at: ip) as? FileGridItem)?.cell.isDropTarget = item(at: ip)?.path == path && path != nil
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { resolveDrop(sender).1 }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { resolveDrop(sender).1 }
    override func draggingExited(_ sender: NSDraggingInfo?) { setDropTarget(nil) }
    override func draggingEnded(_ sender: NSDraggingInfo) { setDropTarget(nil) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let (target, op) = resolveDrop(sender)
        setDropTarget(nil)
        guard let target, !op.isEmpty else { return false }
        return delegate?.listDrop(DragUtil.urls(sender), into: target, copy: op == .copy) ?? false
    }
}
