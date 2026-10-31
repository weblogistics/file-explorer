import AppKit

protocol TabStripDelegate: AnyObject {
    func tabStripSelect(_ index: Int)
    func tabStripClose(_ index: Int)
    func tabStripNewTab()
    func tabStripMove(from: Int, to: Int)
    func tabStripMenu(for index: Int) -> NSMenu?
}

struct TabInfo {
    var title: String
    var icon: NSImage
}

/// Windows 11 File Explorer title bar: tabs, "+" button and the minimize / maximize / close caption buttons.
final class TabStripView: NSView {
    weak var delegate: TabStripDelegate?
    var tabs: [TabInfo] = [] { didSet { needsDisplay = true } }
    var selected = 0 { didSet { needsDisplay = true } }

    private enum Target: Equatable { case tab(Int), close(Int), plus, caption(Int), background }

    private var hover: Target?
    private var pressed: Target?
    private var dragIndex: Int?
    private var dragX: CGFloat = 0
    private var grabOffset: CGFloat = 0
    private var downPoint: NSPoint = .zero
    private var tracking: NSTrackingArea?

    private let leftInset: CGFloat = 10
    private let tabTop: CGFloat = 8
    private let captionWidth: CGFloat = 46
    private let captionHeight: CGFloat = 32

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Geometry

    private var tabWidth: CGFloat {
        let avail = bounds.width - leftInset - 44 - captionWidth * 3 - 60
        return max(64, min(240, avail / CGFloat(max(tabs.count, 1))))
    }

    private func tabRect(_ i: Int) -> NSRect {
        NSRect(x: leftInset + CGFloat(i) * tabWidth, y: tabTop, width: tabWidth, height: bounds.height - tabTop)
    }

    private func closeRect(_ i: Int) -> NSRect {
        let r = tabRect(i)
        return NSRect(x: r.maxX - 32, y: r.minY + (r.height - 24) / 2, width: 24, height: 24)
    }

    private var plusRect: NSRect {
        let x = leftInset + CGFloat(tabs.count) * tabWidth + 4
        return NSRect(x: x, y: tabTop + (bounds.height - tabTop - 28) / 2, width: 32, height: 28)
    }

    private func captionRect(_ k: Int) -> NSRect {
        NSRect(x: bounds.width - captionWidth * CGFloat(3 - k), y: 0, width: captionWidth, height: captionHeight)
    }

    private var isFullScreen: Bool { window?.styleMask.contains(.fullScreen) ?? false }

    private func showsClose(_ i: Int) -> Bool { i == selected || tabWidth > 110 || hover == .tab(i) || hover == .close(i) }

    private func target(at p: NSPoint) -> Target {
        if !isFullScreen {
            for k in 0..<3 where captionRect(k).contains(p) { return .caption(k) }
        }
        for i in tabs.indices where tabRect(i).contains(p) {
            if showsClose(i) && closeRect(i).insetBy(dx: -2, dy: -2).contains(p) { return .close(i) }
            return .tab(i)
        }
        if plusRect.contains(p) { return .plus }
        return .background
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        Theme.tabStrip.setFill()
        bounds.fill()

        let order = tabs.indices.filter { $0 != dragIndex } + (dragIndex.map { [$0] } ?? [])
        for i in order {
            var r = tabRect(i)
            if i == dragIndex { r.origin.x = dragX }
            drawTab(i, in: r)
        }

        // "+" new tab button
        if hover == .plus { Draw.rounded(plusRect, 4, fill: Theme.buttonHover) }
        Draw.symbol(Sym.image("plus", size: 13), in: plusRect, color: Theme.text)

        if !isFullScreen { drawCaptions() }
    }

    private func selectedPath(_ r: NSRect) -> NSBezierPath {
        let rad: CGFloat = 8, ear: CGFloat = 6
        let top = r.minY, bottom = r.maxY
        let p = NSBezierPath()
        p.move(to: NSPoint(x: r.minX - ear, y: bottom))
        p.curve(to: NSPoint(x: r.minX, y: bottom - ear), controlPoint1: NSPoint(x: r.minX, y: bottom), controlPoint2: NSPoint(x: r.minX, y: bottom))
        p.line(to: NSPoint(x: r.minX, y: top + rad))
        p.curve(to: NSPoint(x: r.minX + rad, y: top), controlPoint1: NSPoint(x: r.minX, y: top), controlPoint2: NSPoint(x: r.minX, y: top))
        p.line(to: NSPoint(x: r.maxX - rad, y: top))
        p.curve(to: NSPoint(x: r.maxX, y: top + rad), controlPoint1: NSPoint(x: r.maxX, y: top), controlPoint2: NSPoint(x: r.maxX, y: top))
        p.line(to: NSPoint(x: r.maxX, y: bottom - ear))
        p.curve(to: NSPoint(x: r.maxX + ear, y: bottom), controlPoint1: NSPoint(x: r.maxX, y: bottom), controlPoint2: NSPoint(x: r.maxX, y: bottom))
        p.close()
        return p
    }

    private func drawTab(_ i: Int, in r: NSRect) {
        let tab = tabs[i]
        let isSel = i == selected
        let body = NSRect(x: r.minX, y: r.minY, width: r.width, height: r.height)
        if isSel {
            Theme.chrome.setFill()
            selectedPath(body).fill()
        } else {
            if hover == .tab(i) || hover == .close(i) {
                Draw.rounded(NSRect(x: r.minX + 2, y: r.minY + 2, width: r.width - 4, height: r.height - 8), 6, fill: Theme.buttonHover)
            } else if i + 1 != selected && i + 1 < tabs.count && hover != .tab(i + 1) && dragIndex == nil {
                Theme.strongSeparator.setFill()
                NSRect(x: r.maxX - 0.5, y: r.minY + 9, width: 1, height: r.height - 22).fill()
            }
        }
        let midY = r.minY + (r.height - (isSel ? 0 : 4)) / 2
        Draw.image(tab.icon, in: NSRect(x: r.minX + 12, y: midY - 8, width: 16, height: 16))
        let textRight = showsClose(i) ? closeRect(i).minX - 4 : r.maxX - 10
        Draw.text(tab.title, in: NSRect(x: r.minX + 36, y: midY - 10, width: max(0, textRight - r.minX - 36), height: 20),
                  font: Theme.font(12), color: Theme.text)
        if showsClose(i) {
            var c = closeRect(i)
            c.origin.x += r.minX - tabRect(i).minX
            if hover == .close(i) { Draw.rounded(c, 4, fill: Theme.buttonHover) }
            Draw.symbol(Sym.image("xmark", size: 10, weight: .medium), in: c, color: Theme.text)
        }
    }

    private func drawCaptions() {
        let zoomed = window?.isZoomed ?? false
        for k in 0..<3 {
            let r = captionRect(k)
            let hot = hover == .caption(k)
            let down = pressed == .caption(k) && hot
            if hot {
                let color: NSColor = k == 2 ? (down ? Theme.closeHover.withAlphaComponent(0.85) : Theme.closeHover)
                                            : (down ? Theme.buttonPressed : Theme.buttonHover)
                color.setFill()
                r.fill()
            }
            let fg: NSColor = (k == 2 && hot) ? .white : Theme.text
            fg.setStroke()
            fg.setFill()
            let cx = r.midX.rounded() + 0.5, cy = r.midY.rounded() + 0.5
            let p = NSBezierPath()
            p.lineWidth = 1
            switch k {
            case 0:
                p.move(to: NSPoint(x: cx - 5, y: cy))
                p.line(to: NSPoint(x: cx + 5, y: cy))
            case 1:
                if zoomed {
                    p.appendRoundedRect(NSRect(x: cx - 5, y: cy - 3, width: 8, height: 8), xRadius: 1.5, yRadius: 1.5)
                    p.move(to: NSPoint(x: cx - 3, y: cy - 5))
                    p.line(to: NSPoint(x: cx + 3.5, y: cy - 5))
                    p.curve(to: NSPoint(x: cx + 5, y: cy - 3.5), controlPoint1: NSPoint(x: cx + 5, y: cy - 5), controlPoint2: NSPoint(x: cx + 5, y: cy - 5))
                    p.line(to: NSPoint(x: cx + 5, y: cy + 3))
                } else {
                    p.appendRoundedRect(NSRect(x: cx - 5, y: cy - 5, width: 10, height: 10), xRadius: 1.5, yRadius: 1.5)
                }
            default:
                p.move(to: NSPoint(x: cx - 5, y: cy - 5))
                p.line(to: NSPoint(x: cx + 5, y: cy + 5))
                p.move(to: NSPoint(x: cx + 5, y: cy - 5))
                p.line(to: NSPoint(x: cx - 5, y: cy + 5))
            }
            p.stroke()
        }
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseMoved(with event: NSEvent) {
        let t = target(at: convert(event.locationInWindow, from: nil))
        let h: Target? = t == .background ? nil : t
        if h != hover {
            hover = h
            needsDisplay = true
            if case .tab(let i) = h { toolTip = tabs[safe: i]?.title } else { toolTip = nil }
        }
    }

    override func mouseExited(with event: NSEvent) {
        hover = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        downPoint = p
        let t = target(at: p)
        pressed = t
        switch t {
        case .tab(let i):
            delegate?.tabStripSelect(i)
            grabOffset = p.x - tabRect(i).minX
        case .background:
            pressed = nil
            if event.clickCount == 2 {
                window?.zoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        default:
            break
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard case .tab(let i) = pressed, tabs.count > 1 else {
            let h = target(at: p)
            if h != hover { hover = h; needsDisplay = true }
            return
        }
        if dragIndex == nil && abs(p.x - downPoint.x) < 5 { return }
        dragIndex = i
        let maxX = leftInset + CGFloat(tabs.count - 1) * tabWidth
        dragX = max(leftInset, min(maxX, p.x - grabOffset))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        defer {
            pressed = nil
            dragIndex = nil
            needsDisplay = true
        }
        if let d = dragIndex {
            let to = max(0, min(tabs.count - 1, Int(((dragX - leftInset) + tabWidth / 2) / tabWidth)))
            if to != d { delegate?.tabStripMove(from: d, to: to) }
            return
        }
        let t = target(at: p)
        guard t == pressed else { return }
        switch t {
        case .close(let i): delegate?.tabStripClose(i)
        case .plus: delegate?.tabStripNewTab()
        case .caption(0): window?.miniaturize(nil)
        case .caption(1): window?.zoom(nil)
        case .caption(2): window?.performClose(nil)
        default: break
        }
    }

    override func otherMouseUp(with event: NSEvent) {
        if case .tab(let i) = target(at: convert(event.locationInWindow, from: nil)) { delegate?.tabStripClose(i) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        if case .tab(let i) = target(at: convert(event.locationInWindow, from: nil)) { return delegate?.tabStripMenu(for: i) }
        return nil
    }
}
