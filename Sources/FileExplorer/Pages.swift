import AppKit
import Quartz

// MARK: - Tiles page (Home & This PC)

struct Tile {
    enum Kind { case folder, file, drive }
    let url: URL
    let title: String
    var subtitle = ""
    var icon: NSImage
    var kind: Kind
    var capacity: (used: Int64, total: Int64)?
    var columns: [String] = []
    var pinned = false
}

struct TileSection {
    enum Style { case tiles, rows }
    let id: String
    let title: String
    let style: Style
    var tiles: [Tile]
    var columnTitles: [String] = []
    var emptyText = ""
}

protocol TilesPageDelegate: AnyObject {
    func tilesOpen(_ tile: Tile)
    func tilesMenu(_ tiles: [Tile]) -> NSMenu?
    func tilesSelectionChanged()
    func tilesKeyDown(_ e: NSEvent) -> Bool
}

final class TilesDocView: FlippedView {
    weak var delegate: TilesPageDelegate?
    var sections: [TileSection] = [] { didSet { relayout() } }
    private var collapsed: Set<String> = []
    private(set) var selected: Set<[Int]> = []
    private var hovered: [Int]?
    private var tileRects: [([Int], NSRect)] = []
    private var headerRects: [(String, NSRect)] = []
    private var tracking: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }

    var selectedTiles: [Tile] {
        selected.sorted { $0.lexicographicallyPrecedes($1) }.compactMap { sections[safe: $0[0]]?.tiles[safe: $0[1]] }
    }

    func relayout() {
        tileRects = []
        headerRects = []
        let width = max(300, superview?.bounds.width ?? bounds.width)
        var y: CGFloat = 10
        for (si, s) in sections.enumerated() {
            headerRects.append((s.id, NSRect(x: 16, y: y, width: width - 32, height: 32)))
            y += 36
            if collapsed.contains(s.id) { continue }
            if s.tiles.isEmpty {
                y += 30
                continue
            }
            switch s.style {
            case .tiles:
                let tw: CGFloat = s.id == "drives" ? 270 : 230, th: CGFloat = s.id == "drives" ? 74 : 66, gap: CGFloat = 8
                let cols = max(1, Int((width - 32 + gap) / (tw + gap)))
                for (ti, _) in s.tiles.enumerated() {
                    let c = ti % cols, r = ti / cols
                    tileRects.append(([si, ti], NSRect(x: 16 + CGFloat(c) * (tw + gap), y: y + CGFloat(r) * (th + gap), width: tw, height: th)))
                }
                let rows = (s.tiles.count + cols - 1) / cols
                y += CGFloat(rows) * (th + gap) + 10
            case .rows:
                y += 30   // column header
                let rh: CGFloat = Settings.shared.compactView ? 26 : 32
                for (ti, _) in s.tiles.enumerated() {
                    tileRects.append(([si, ti], NSRect(x: 16, y: y, width: width - 32, height: rh)))
                    y += rh
                }
                y += 10
            }
        }
        setFrameSize(NSSize(width: width, height: max(y + 20, superview?.bounds.height ?? 0)))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.content.setFill()
        dirtyRect.intersection(bounds).fill()
        let focused = window?.firstResponder === self
        for (si, s) in sections.enumerated() {
            guard let hr = headerRects.first(where: { $0.0 == s.id })?.1 else { continue }
            let chev = Sym.image(collapsed.contains(s.id) ? "chevron.right" : "chevron.down", size: 10, weight: .semibold)
            Draw.symbol(chev, in: NSRect(x: hr.minX, y: hr.minY + 8, width: 16, height: 16), color: Theme.text)
            Draw.text(s.title, in: NSRect(x: hr.minX + 22, y: hr.minY, width: hr.width - 22, height: hr.height),
                      font: Theme.font(14, .semibold), color: Theme.text)
            if collapsed.contains(s.id) { continue }
            if s.tiles.isEmpty {
                Draw.text(s.emptyText, in: NSRect(x: hr.minX + 22, y: hr.maxY, width: hr.width, height: 28), font: Theme.font(12), color: Theme.secondaryText)
                continue
            }
            if s.style == .rows, let first = tileRects.first(where: { $0.0[0] == si })?.1 {
                let hy = first.minY - 30
                let xs = columnXs(first)
                for (i, t) in (["Name"] + s.columnTitles).enumerated() {
                    Draw.text(t, in: NSRect(x: xs[i] + 10, y: hy, width: (xs[safe: i + 1] ?? first.maxX) - xs[i] - 16, height: 28),
                              font: Theme.font(12), color: Theme.secondaryText)
                    if i > 0 {
                        Theme.separator.setFill()
                        NSRect(x: xs[i], y: hy + 6, width: 1, height: 16).fill()
                    }
                }
            }
            for (key, r) in tileRects where key[0] == si {
                guard r.intersects(dirtyRect), let t = s.tiles[safe: key[1]] else { continue }
                let bg = ItemStyle.background(selected: selected.contains(key), hovered: hovered == key, focused: focused, drop: false)
                if let bg { Draw.rounded(r, 5, fill: bg) }
                s.style == .tiles ? drawTile(t, in: r) : drawRow(t, in: r)
            }
        }
    }

    private func columnXs(_ r: NSRect) -> [CGFloat] {
        [r.minX, r.minX + r.width * 0.42, r.minX + r.width * 0.62]
    }

    private func drawTile(_ t: Tile, in r: NSRect) {
        let iconSize: CGFloat = t.kind == .drive ? 48 : 40
        Draw.image(t.icon, in: NSRect(x: r.minX + 12, y: r.midY - iconSize / 2, width: iconSize, height: iconSize))
        let x = r.minX + 12 + iconSize + 12
        let w = r.maxX - x - 12
        if let cap = t.capacity {
            Draw.text(t.title, in: NSRect(x: x, y: r.minY + 10, width: w, height: 18), font: Theme.font(12.5), color: Theme.text)
            let bar = NSRect(x: x, y: r.minY + 32, width: w, height: 12)
            Draw.rounded(bar, 2, fill: Theme.progressTrack)
            let frac = cap.total > 0 ? CGFloat(cap.used) / CGFloat(cap.total) : 0
            Draw.rounded(NSRect(x: bar.minX, y: bar.minY, width: bar.width * frac, height: bar.height), 2,
                         fill: frac > 0.9 ? Theme.driveBarFull : Theme.driveBar)
            Draw.text(t.subtitle, in: NSRect(x: x, y: r.minY + 48, width: w, height: 16), font: Theme.font(11), color: Theme.secondaryText)
        } else {
            Draw.text(t.title, in: NSRect(x: x, y: r.midY - 19, width: w, height: 18), font: Theme.font(12.5), color: Theme.text)
            Draw.text(t.subtitle, in: NSRect(x: x, y: r.midY + 1, width: w - 16, height: 16), font: Theme.font(11), color: Theme.secondaryText)
            if t.pinned {
                Draw.symbol(Sym.image("pin", size: 10), in: NSRect(x: r.maxX - 22, y: r.midY + 1, width: 14, height: 16), color: Theme.tertiaryText)
            }
        }
    }

    private func drawRow(_ t: Tile, in r: NSRect) {
        let xs = columnXs(r)
        Draw.image(t.icon, in: NSRect(x: r.minX + 10, y: r.midY - 8, width: 16, height: 16))
        Draw.text(t.title, in: NSRect(x: r.minX + 34, y: r.minY, width: xs[1] - r.minX - 40, height: r.height), font: Theme.font(12), color: Theme.text)
        for (i, c) in t.columns.enumerated() where i + 1 < xs.count {
            let x = xs[i + 1] + 10
            let maxX = (xs[safe: i + 2] ?? r.maxX) - 10
            Draw.text(c, in: NSRect(x: x, y: r.minY, width: maxX - x, height: r.height), font: Theme.font(12), color: Theme.secondaryText)
        }
    }

    // MARK: Interaction

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    private func hit(_ p: NSPoint) -> [Int]? { tileRects.first { $0.1.contains(p) }?.0 }

    override func mouseMoved(with event: NSEvent) {
        let h = hit(convert(event.locationInWindow, from: nil))
        if h != hovered {
            hovered = h
            if let h, let t = sections[safe: h[0]]?.tiles[safe: h[1]] { toolTip = t.url.path } else { toolTip = nil }
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        if let h = headerRects.first(where: { $0.1.contains(p) }) {
            if collapsed.contains(h.0) { collapsed.remove(h.0) } else { collapsed.insert(h.0) }
            relayout()
            return
        }
        guard let key = hit(p) else {
            setSelection([])
            return
        }
        if event.modifierFlags.contains(.command) {
            var s = selected
            if s.contains(key) { s.remove(key) } else { s.insert(key) }
            setSelection(s)
        } else {
            setSelection([key])
        }
        if event.clickCount == 2, let t = sections[safe: key[0]]?.tiles[safe: key[1]] { delegate?.tilesOpen(t) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        if let key = hit(p) {
            if !selected.contains(key) { setSelection([key]) }
        } else {
            setSelection([])
        }
        return delegate?.tilesMenu(selectedTiles)
    }

    func setSelection(_ s: Set<[Int]>) {
        selected = s
        needsDisplay = true
        delegate?.tilesSelectionChanged()
    }

    override func keyDown(with event: NSEvent) {
        if delegate?.tilesKeyDown(event) == true { return }
        let ordered = tileRects.map(\.0)
        let cur = selected.sorted { $0.lexicographicallyPrecedes($1) }.first.flatMap { k in ordered.firstIndex(of: k) }
        switch event.keyCode {
        case 36, 76:
            if let t = selectedTiles.first { delegate?.tilesOpen(t) }
        case 123, 126:
            if let next = ordered[safe: max(0, (cur ?? 1) - 1)] { setSelection([next]); scrollTo(next) }
        case 124, 125:
            if let next = ordered[safe: min(ordered.count - 1, (cur ?? -1) + 1)] { setSelection([next]); scrollTo(next) }
        default:
            super.keyDown(with: event)
        }
    }

    private func scrollTo(_ key: [Int]) {
        if let r = tileRects.first(where: { $0.0 == key })?.1 { scrollToVisible(r.insetBy(dx: 0, dy: -10)) }
    }

    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
}

final class TilesPageView: NSView {
    let scroll = NSScrollView()
    let doc = TilesDocView()

    init() {
        super.init(frame: .zero)
        scroll.documentView = doc
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.content
        scroll.borderType = .noBorder
        addSubview(scroll)
        scroll.pinEdges(to: self)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        if abs(doc.frame.width - scroll.contentSize.width) > 0.5 { doc.relayout() }
    }
}

// MARK: - Details / preview pane

final class SidePane: ColorView {
    private let stack = NSStackView()
    private let scroll = NSScrollView()
    private var qlView: QLPreviewView?
    private let message = makeLabel("", size: 12, color: Theme.secondaryText)
    private(set) var mode: SidePaneMode = .details
    private var currentKey = ""

    init() {
        super.init(Theme.content)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        let docView = FlippedView()
        docView.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: docView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: docView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: docView.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: docView.bottomAnchor),
        ])
        scroll.documentView = docView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        addSubview(scroll)
        scroll.pinEdges(to: self)
        docView.translatesAutoresizingMaskIntoConstraints = false
        docView.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        docView.topAnchor.constraint(equalTo: scroll.contentView.topAnchor).isActive = true

        message.alignment = .center
        message.maximumNumberOfLines = 3
        addSubview(message)
        NSLayoutConstraint.activate([
            message.centerXAnchor.constraint(equalTo: centerXAnchor),
            message.centerYAnchor.constraint(equalTo: centerYAnchor),
            message.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -30),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(mode: SidePaneMode, items: [FileItem], location: Location, total: Int) {
        let key = "\(mode)|\(location.title)|\(items.map(\.path).joined(separator: "|"))|\(items.first?.modified?.timeIntervalSince1970 ?? 0)|\(total)"
        guard key != currentKey else { return }
        currentKey = key
        self.mode = mode
        if mode == .preview { showPreview(items) } else { showDetails(items, location: location, total: total) }
    }

    private func showPreview(_ items: [FileItem]) {
        scroll.isHidden = true
        guard items.count == 1, let it = items.first, !it.isDirectory else {
            qlView?.isHidden = true
            message.isHidden = false
            message.stringValue = items.isEmpty ? "Select a file to preview." : (items.count > 1 ? "No preview available." : "No preview available.")
            return
        }
        if qlView == nil, let q = QLPreviewView(frame: bounds, style: .normal) {
            q.autostarts = true
            q.autoresizingMask = [.width, .height]
            addSubview(q, positioned: .below, relativeTo: message)
            qlView = q
        }
        qlView?.frame = bounds
        qlView?.isHidden = false
        message.isHidden = true
        qlView?.previewItem = it.url as NSURL
    }

    private func showDetails(_ items: [FileItem], location: Location, total: Int) {
        qlView?.isHidden = true
        qlView?.previewItem = nil
        message.isHidden = true
        scroll.isHidden = false
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.heightAnchor.constraint(equalToConstant: 150).isActive = true
        let imageHolder = NSView()
        imageHolder.translatesAutoresizingMaskIntoConstraints = false
        imageHolder.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: imageHolder.centerXAnchor),
            imageView.topAnchor.constraint(equalTo: imageHolder.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: imageHolder.bottomAnchor),
            imageView.widthAnchor.constraint(lessThanOrEqualTo: imageHolder.widthAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 220).withPriority(.defaultLow),
        ])
        stack.addArrangedSubview(imageHolder)
        imageHolder.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36).isActive = true

        let title = makeLabel("", size: 15, weight: .semibold)
        title.lineBreakMode = .byWordWrapping
        title.maximumNumberOfLines = 3
        title.preferredMaxLayoutWidth = 240
        let subtitle = makeLabel("", size: 12, color: Theme.secondaryText)
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(subtitle)
        stack.setCustomSpacing(14, after: imageHolder)

        var rows: [(String, String)] = []
        if items.isEmpty {
            imageView.image = location.scopeURL.map { FileIcons.shared.icon(for: FileItem(url: $0), size: 128) } ?? bigIcon(for: location)
            title.stringValue = location.title
            subtitle.stringValue = Fmt.count(total, "item")
            if let u = location.scopeURL {
                let it = FileItem(url: u)
                rows = [("Date modified", Fmt.date(it.modified)), ("Date created", Fmt.date(it.created)), ("Location", Fmt.abbreviatePath(u.path))]
            }
        } else if items.count == 1, let it = items.first {
            imageView.image = FileIcons.shared.icon(for: it, size: 128)
            if FileIcons.shared.canThumbnail(it) {
                if let t = FileIcons.shared.thumbnail(for: it, size: 220, completion: { [weak imageView] img in imageView?.image = img }) {
                    imageView.image = t
                }
            }
            title.stringValue = it.displayName(showExtensions: Settings.shared.showExtensions)
            subtitle.stringValue = it.typeDescription
            if !it.isDirectory { rows.append(("Size", Fmt.size(it.size))) }
            rows.append(("Date modified", Fmt.date(it.modified)))
            rows.append(("Date created", Fmt.date(it.created)))
            if let a = it.accessed { rows.append(("Date accessed", Fmt.date(a))) }
            if it.isImage, let dims = imageDimensions(it.url) { rows.insert(("Dimensions", dims), at: 0) }
            rows.append(("Location", Fmt.abbreviatePath(it.parent.path)))
            if !it.isDirectory, let app = NSWorkspace.shared.urlForApplication(toOpen: it.url) {
                rows.append(("Opens with", FileManager.default.displayName(atPath: app.path)))
            }
        } else {
            imageView.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
            imageView.contentTintColor = Theme.secondaryText
            title.stringValue = "\(items.count) items selected"
            let files = items.filter { !$0.isDirectory }
            subtitle.stringValue = files.isEmpty ? "Folders" : Fmt.size(files.reduce(0) { $0 + $1.size })
            let dates = items.compactMap(\.modified)
            if let mn = dates.min(), let mx = dates.max() {
                rows.append(("Date modified", mn == mx ? Fmt.date(mn) : "\(Fmt.date(mn)) - \(Fmt.date(mx))"))
            }
        }

        if !rows.isEmpty {
            let header = makeLabel("Details", size: 13, weight: .semibold)
            stack.addArrangedSubview(header)
            stack.setCustomSpacing(18, after: subtitle)
            stack.setCustomSpacing(10, after: header)
            for (k, v) in rows {
                let kl = makeLabel(k, size: 11, color: Theme.secondaryText)
                let vl = makeLabel(v, size: 12)
                vl.lineBreakMode = .byTruncatingMiddle
                vl.isSelectable = true
                stack.addArrangedSubview(kl)
                stack.addArrangedSubview(vl)
                stack.setCustomSpacing(1, after: kl)
                stack.setCustomSpacing(9, after: vl)
                vl.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -36).isActive = true
            }
        }
    }

    private func bigIcon(for loc: Location) -> NSImage {
        switch loc {
        case .home: return Sym.colored("house.fill", size: 80, color: NSColor(hex: 0xE0A030))
        case .thisPC: return Sym.colored("desktopcomputer", size: 80, color: NSColor(hex: 0x2B88D8))
        case .gallery: return Sym.colored("photo.on.rectangle.angled", size: 80, color: NSColor(hex: 0x2B88D8))
        default: return IconFactory.folder(size: 128)
        }
    }

    private func imageDimensions(_ url: URL) -> String? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return "\(w) x \(h)"
    }
}

extension NSLayoutConstraint {
    func withPriority(_ p: NSLayoutConstraint.Priority) -> NSLayoutConstraint {
        priority = p
        return self
    }
}

// MARK: - Status bar

final class StatusBar: ColorView {
    private let label = makeLabel("", size: 11.5, color: Theme.text)
    let detailsButton = HoverButton(symbol: "list.bullet", size: 12, tip: "Display information about each item in the window.")
    let iconsButton = HoverButton(symbol: "square.grid.2x2", size: 12, tip: "Display items by using large thumbnails.")

    init() {
        super.init(Theme.content)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        for b in [detailsButton, iconsButton] {
            b.fixedSize = NSSize(width: 26, height: 22)
            b.imageBox = 14
            addSubview(b)
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: detailsButton.leadingAnchor, constant: -10),
            iconsButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            iconsButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            detailsButton.trailingAnchor.constraint(equalTo: iconsButton.leadingAnchor, constant: -2),
            detailsButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(_ parts: [String]) {
        label.stringValue = parts.filter { !$0.isEmpty }.joined(separator: "    |    ")
    }

    func setMode(_ m: ViewMode?) {
        detailsButton.isToggled = m == .details
        iconsButton.isToggled = m == .large
    }
}

// MARK: - Command bar

final class CommandBar: ColorView {
    let newButton = HoverButton(symbol: "plus.circle", size: 15, title: "New", chevron: true, tip: "Create a new item in the current location.")
    let cutButton = HoverButton(symbol: "scissors", tip: "Cut (⌘X)")
    let copyButton = HoverButton(symbol: "doc.on.doc", tip: "Copy (⌘C)")
    let pasteButton = HoverButton(symbol: "doc.on.clipboard", tip: "Paste (⌘V)")
    let renameButton = HoverButton(symbol: "character.cursor.ibeam", tip: "Rename (F2)")
    let shareButton = HoverButton(symbol: "square.and.arrow.up", tip: "Share")
    let deleteButton = HoverButton(symbol: "trash", tip: "Delete (⌘⌫)")
    let sortButton = HoverButton(symbol: "arrow.up.arrow.down", size: 14, title: "Sort", chevron: true, tip: "Sort items")
    let viewButton = HoverButton(symbol: "rectangle.grid.1x2", size: 14, title: "View", chevron: true, tip: "Change how items are displayed")
    let extractButton = HoverButton(symbol: "archivebox", size: 14, title: "Extract all", tip: "Extract all items from the compressed folder")
    let backgroundButton = HoverButton(symbol: "photo", size: 14, title: "Set as background", tip: "Use the selected picture as desktop background")
    let moreButton = HoverButton(symbol: "ellipsis", size: 14, tip: "See more")
    let detailsButton = HoverButton(symbol: "info.circle", size: 14, title: "Details", tip: "Show the details pane (⌥⇧P)")
    private let stack = NSStackView()

    init() {
        super.init(Theme.chrome)
        translatesAutoresizingMaskIntoConstraints = false
        newButton.imageColor = Theme.accent
        for b in [cutButton, copyButton, pasteButton, renameButton, shareButton, deleteButton, moreButton] {
            b.fixedSize = NSSize(width: 38, height: 32)
            b.imageBox = 18
        }
        let views: [NSView] = [newButton, VLine(), cutButton, copyButton, pasteButton, renameButton, shareButton, deleteButton,
                               VLine(), sortButton, viewButton, VLine(), extractButton, backgroundButton, moreButton]
        views.forEach { stack.addArrangedSubview($0) }
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(8, after: views[0])
        stack.setHuggingPriority(.defaultLow, for: .horizontal)
        stack.detachesHiddenViews = true
        stack.setClippingResistancePriority(.defaultLow, for: .horizontal)
        addSubview(stack)
        addSubview(detailsButton)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: detailsButton.leadingAnchor, constant: -8),
            detailsButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            detailsButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}
