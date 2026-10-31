import AppKit

/// Windows breadcrumb address bar. Click empty space to type a path.
final class AddressBar: NSView, NSTextFieldDelegate {
    struct Crumb {
        let title: String
        let location: Location
        let menuURL: URL?          // children listed in the chevron after this crumb
        var drives = false         // chevron lists drives (This PC)
    }

    var onNavigate: ((Location) -> Void)?
    var onSubmitText: ((String) -> Void)?
    var onEndEditing: (() -> Void)?
    var rootMenuProvider: (() -> [NSMenuItem])?

    private(set) var location: Location = .home
    private var crumbs: [Crumb] = []
    private let iconView = NSImageView()
    private var crumbViews: [NSView] = []
    private let field = NSTextField()
    private(set) var isEditing = false
    private var progressTimer: Timer?
    private var phase: CGFloat = 0

    var searching = false {
        didSet {
            guard searching != oldValue else { return }
            progressTimer?.invalidate()
            progressTimer = nil
            if searching {
                let t = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    self.phase += 0.012
                    if self.phase > 1.3 { self.phase = 0 }
                    self.needsDisplay = true
                }
                RunLoop.main.add(t, forMode: .common)
                progressTimer = t
            }
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Theme.font(12)
        field.textColor = Theme.text
        field.isHidden = true
        field.delegate = self
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.cell?.usesSingleLineMode = true
        addSubview(field)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setLocation(_ loc: Location) {
        location = loc
        crumbs = AddressBar.crumbs(for: loc)
        iconView.image = loc.icon
        if isEditing { endEditing(commit: false, notify: false) }
        rebuild()
    }

    static func crumbs(for loc: Location) -> [Crumb] {
        switch loc {
        case .home: return [Crumb(title: "Home", location: .home, menuURL: nil)]
        case .gallery: return [Crumb(title: "Gallery", location: .gallery, menuURL: nil)]
        case .thisPC: return [Crumb(title: "This PC", location: .thisPC, menuURL: nil, drives: true)]
        case .folder(let u): return pathCrumbs(u)
        case .search(let u, _):
            return pathCrumbs(u) + [Crumb(title: "Search Results in \(Location.displayName(for: u))", location: loc, menuURL: nil)]
        }
    }

    static func pathCrumbs(_ u: URL) -> [Crumb] {
        if u.path == trashURL.path { return [Crumb(title: "Recycle Bin", location: .folder(u), menuURL: nil)] }
        var vol = (try? u.resourceValues(forKeys: [.volumeURLKey]))?.volume ?? URL(fileURLWithPath: "/")
        if !(u.path == vol.path || u.path.hasPrefix(vol.path == "/" ? "/" : vol.path + "/")) { vol = URL(fileURLWithPath: "/") }
        vol = vol.dirNormalized
        var result = [Crumb(title: "This PC", location: .thisPC, menuURL: nil, drives: true),
                      Crumb(title: VolumeInfo.name(for: vol), location: .folder(vol), menuURL: vol)]
        var cur = vol
        let rel = u.path.dropFirst(vol.path.count)
        for comp in rel.split(separator: "/") {
            cur = cur.appendingPathComponent(String(comp), isDirectory: true)
            result.append(Crumb(title: String(comp), location: .dir(cur), menuURL: cur))
        }
        return result
    }

    // MARK: Layout

    private var builtWidth: CGFloat = -1

    private func rebuild() {
        builtWidth = -1
        needsLayout = true
    }

    private func chevronButton(_ items: @escaping () -> [NSMenuItem], overflow: Bool = false) -> HoverButton {
        let b = HoverButton(symbol: overflow ? "chevron.left.2" : "chevron.right", size: 9)
        b.menuOpenImage = overflow ? nil : Sym.image("chevron.down", size: 9)
        b.imageBox = 12
        b.fixedSize = NSSize(width: 18, height: 26)
        b.height = 26
        b.imageColor = Theme.secondaryText
        b.menuProvider = { NSMenu(items: items()) }
        return b
    }

    private func crumbButton(_ c: Crumb) -> HoverButton {
        let b = HoverButton(title: c.title)
        b.hPadding = 5
        b.height = 26
        b.action = { [weak self] in self?.onNavigate?(c.location) }
        return b
    }

    private func menuItems(for c: Crumb) -> [NSMenuItem] {
        if c.drives {
            return VolumeInfo.list().map { v in
                ClosureMenuItem(v.name, image: IconFactory.drive(size: 16, kind: v.kind)) { [weak self] in self?.onNavigate?(.dir(v.url)) }
            }
        }
        guard let u = c.menuURL else { return [] }
        let subs = DirectoryLoader.subfolders(of: u, showHidden: Settings.shared.showHidden)
        if subs.isEmpty { return [ClosureMenuItem("(No subfolders)")] }
        return subs.map { s in
            ClosureMenuItem(s.lastPathComponent, image: Location.icon(for: s)) { [weak self] in self?.onNavigate?(.dir(s)) }
        }
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        iconView.frame = NSRect(x: 9, y: (h - 16) / 2, width: 16, height: 16)
        if isEditing {
            field.frame = NSRect(x: 32, y: (h - 17) / 2, width: bounds.width - 40, height: 17)
            crumbViews.forEach { $0.isHidden = true }
            return
        }
        guard builtWidth != bounds.width else { return }
        builtWidth = bounds.width
        crumbViews.forEach { $0.removeFromSuperview() }
        crumbViews = []

        let font = Theme.font(12)
        let available = bounds.width - 30 - 8
        let chevW: CGFloat = 18
        var used = chevW
        var start = crumbs.count
        for i in stride(from: crumbs.count - 1, through: 0, by: -1) {
            let w = Draw.textWidth(crumbs[i].title, font: font) + 10 + chevW
            if used + w > available && i < crumbs.count - 1 { break }
            used += w
            start = i
        }
        let hidden = Array(crumbs[0..<start])

        var x: CGFloat = 28
        let lead = chevronButton({ [weak self] in
            guard let self else { return [] }
            var items: [NSMenuItem] = hidden.reversed().map { c in
                ClosureMenuItem(c.title, image: c.location.icon) { [weak self] in self?.onNavigate?(c.location) }
            }
            if !items.isEmpty { items.append(.separator()) }
            items += self.rootMenuProvider?() ?? []
            return items
        }, overflow: !hidden.isEmpty)
        addCrumbView(lead, x: &x, width: chevW)

        for i in start..<crumbs.count {
            let c = crumbs[i]
            let b = crumbButton(c)
            let natural = Draw.textWidth(c.title, font: font) + 10
            let maxW = bounds.width - x - chevW - 8
            addCrumbView(b, x: &x, width: max(30, min(natural, maxW)))
            if c.menuURL != nil || c.drives {
                let chev = chevronButton({ [weak self] in self?.menuItems(for: c) ?? [] })
                addCrumbView(chev, x: &x, width: chevW)
            }
        }
    }

    private func addCrumbView(_ v: NSView, x: inout CGFloat, width: CGFloat) {
        v.translatesAutoresizingMaskIntoConstraints = true
        v.frame = NSRect(x: x, y: (bounds.height - 26) / 2, width: width, height: 26)
        addSubview(v)
        crumbViews.append(v)
        x += width
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        Draw.rounded(r, 5, fill: Theme.field, stroke: Theme.fieldBorder)
        if searching {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).addClip()
            Theme.searchProgress.setFill()
            NSRect(x: 0, y: 0, width: bounds.width * min(1, phase), height: bounds.height).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        if isEditing {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).addClip()
            Theme.accent.setFill()
            NSRect(x: 0, y: bounds.height - 2, width: bounds.width, height: 2).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    // MARK: Editing

    override func mouseDown(with event: NSEvent) { beginEditing() }

    func beginEditing() {
        guard !isEditing else { return }
        isEditing = true
        field.stringValue = editText
        field.isHidden = false
        needsLayout = true
        layoutSubtreeIfNeeded()
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        needsDisplay = true
    }

    private var editText: String {
        switch location {
        case .home: return "Home"
        case .thisPC: return "This PC"
        case .gallery: return "Gallery"
        case .folder(let u): return u.path
        case .search(let u, _): return u.path
        }
    }

    private func endEditing(commit: Bool, notify: Bool = true) {
        guard isEditing else { return }
        isEditing = false
        let text = field.stringValue
        field.isHidden = true
        crumbViews.forEach { $0.isHidden = false }
        needsLayout = true
        needsDisplay = true
        if commit { onSubmitText?(text) }
        if notify { onEndEditing?() }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) {
            endEditing(commit: true)
            return true
        }
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            endEditing(commit: false)
            return true
        }
        if sel == #selector(NSResponder.insertTab(_:)) {
            complete(textView)
            return true
        }
        return false
    }

    /// Tab completes the path like the Windows address bar.
    private func complete(_ tv: NSTextView) {
        let text = (field.stringValue as NSString).expandingTildeInPath
        let dir = text.hasSuffix("/") ? text : (text as NSString).deletingLastPathComponent
        let prefix = text.hasSuffix("/") ? "" : (text as NSString).lastPathComponent
        let subs = DirectoryLoader.subfolders(of: URL(fileURLWithPath: dir), showHidden: Settings.shared.showHidden)
        if let m = subs.first(where: { $0.lastPathComponent.lowercased().hasPrefix(prefix.lowercased()) }) {
            field.stringValue = m.path + "/"
            tv.moveToEndOfDocument(nil)
        } else {
            NSSound.beep()
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if isEditing { endEditing(commit: false) }
    }
}

/// Windows search box ("Search Documents").
final class SearchBox: NSView, NSTextFieldDelegate {
    let field = FocusTextField()
    var onSearch: ((String) -> Void)?
    var onClear: (() -> Void)?
    private let icon = HoverButton(symbol: "magnifyingglass", size: 12)
    private let clear = HoverButton(symbol: "xmark", size: 10)
    private var debounce: Timer?
    private var focused = false

    override var isFlipped: Bool { true }

    var placeholder: String = "" {
        didSet {
            field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
                .font: Theme.font(12), .foregroundColor: Theme.tertiaryText,
            ])
        }
    }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Theme.font(12)
        field.textColor = Theme.text
        field.delegate = self
        field.cell?.isScrollable = true
        field.cell?.usesSingleLineMode = true
        field.onFocusChange = { [weak self] f in self?.focused = f; self?.needsDisplay = true }
        addSubview(field)
        icon.imageColor = Theme.secondaryText
        icon.fixedSize = NSSize(width: 26, height: 24)
        icon.action = { [weak self] in self?.submit() }
        clear.fixedSize = NSSize(width: 24, height: 24)
        clear.imageColor = Theme.secondaryText
        clear.isHidden = true
        clear.action = { [weak self] in self?.clearSearch() }
        for b in [icon, clear] { b.translatesAutoresizingMaskIntoConstraints = true; addSubview(b) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h = bounds.height
        icon.frame = NSRect(x: bounds.width - 30, y: (h - 24) / 2, width: 26, height: 24)
        clear.frame = NSRect(x: bounds.width - 54, y: (h - 24) / 2, width: 24, height: 24)
        field.frame = NSRect(x: 10, y: (h - 17) / 2, width: bounds.width - (clear.isHidden ? 44 : 66), height: 17)
    }

    override func mouseDown(with event: NSEvent) { focus() }

    func focus() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func setText(_ s: String) {
        field.stringValue = s
        clear.isHidden = s.isEmpty
        needsLayout = true
    }

    private func submit() {
        debounce?.invalidate()
        let q = field.stringValue.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { onClear?() } else { onSearch?(q) }
    }

    func clearSearch() {
        debounce?.invalidate()
        setText("")
        onClear?()
    }

    func controlTextDidChange(_ obj: Notification) {
        clear.isHidden = field.stringValue.isEmpty
        needsLayout = true
        debounce?.invalidate()
        let t = Timer(timeInterval: 0.6, repeats: false) { [weak self] _ in self?.submit() }
        RunLoop.main.add(t, forMode: .common)
        debounce = t
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        focused = false
        needsDisplay = true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) { submit(); return true }
        if sel == #selector(NSResponder.cancelOperation(_:)) { clearSearch(); return true }
        return false
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        Draw.rounded(r, 5, fill: Theme.field, stroke: Theme.fieldBorder)
        if focused {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).addClip()
            Theme.accent.setFill()
            NSRect(x: 0, y: bounds.height - 2, width: bounds.width, height: 2).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}
