import AppKit

/// Flat Windows 11 style button: transparent until hovered.
class HoverButton: NSView {
    var image: NSImage? { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var menuOpenImage: NSImage?
    var imageColor: NSColor? { didSet { needsDisplay = true } }
    var imageBox: CGFloat = 16
    var title: String? { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var font = Theme.font(12) { didSet { invalidateIntrinsicContentSize() } }
    var titleColor: NSColor?
    var showsChevron = false { didSet { invalidateIntrinsicContentSize() } }
    var isEnabled = true { didSet { if oldValue != isEnabled { needsDisplay = true } } }
    var isToggled = false { didSet { if oldValue != isToggled { needsDisplay = true } } }
    var fixedSize: NSSize? { didSet { invalidateIntrinsicContentSize() } }
    var hPadding: CGFloat = 8 { didSet { invalidateIntrinsicContentSize() } }
    var height: CGFloat = 32
    var cornerRadius: CGFloat = 4
    var hoverColor: NSColor = Theme.buttonHover
    var alignLeft = false

    var action: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?
    var rightMenuProvider: (() -> NSMenu?)?

    private(set) var hovered = false
    private var pressed = false
    private var menuOpen = false
    private var tracking: NSTrackingArea?

    init(symbol: String? = nil, size: CGFloat = 15, title: String? = nil, chevron: Bool = false,
         tip: String? = nil, action: (() -> Void)? = nil) {
        super.init(frame: .zero)
        if let symbol { image = Sym.image(symbol, size: size) }
        self.title = title
        self.showsChevron = chevron
        self.action = action
        toolTip = tip
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private var titleWidth: CGFloat {
        guard let title, !title.isEmpty else { return 0 }
        return Draw.textWidth(title, font: font)
    }

    override var intrinsicContentSize: NSSize {
        if let fixedSize { return fixedSize }
        var w = hPadding * 2
        if image != nil { w += imageBox }
        if titleWidth > 0 { w += (image != nil ? 6 : 0) + titleWidth }
        if showsChevron { w += 14 }
        return NSSize(width: ceil(w), height: height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        if let menu = menuProvider?() {
            showMenu(menu)
            return
        }
        pressed = true
        needsDisplay = true
    }

    func showMenu(_ menu: NSMenu) {
        menuOpen = true
        pressed = true
        needsDisplay = true
        displayIfNeeded()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 2), in: self)
        menuOpen = false
        pressed = false
        if let w = window {
            let p = convert(w.mouseLocationOutsideOfEventStream, from: nil)
            hovered = bounds.contains(p)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled, menuProvider == nil else { return }
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        if inside != pressed { pressed = inside; needsDisplay = true }
    }

    override func mouseUp(with event: NSEvent) {
        guard pressed else { return }
        pressed = false
        needsDisplay = true
        if isEnabled && bounds.contains(convert(event.locationInWindow, from: nil)) { action?() }
    }

    override func rightMouseDown(with event: NSEvent) {
        if let m = rightMenuProvider?() { NSMenu.popUpContextMenu(m, with: event, for: self) } else { super.rightMouseDown(with: event) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let bg: NSColor?
        if pressed && isEnabled { bg = Theme.buttonPressed }
        else if hovered && isEnabled { bg = hoverColor }
        else if isToggled { bg = Theme.buttonToggled }
        else { bg = nil }
        if let bg { Draw.rounded(bounds, cornerRadius, fill: bg) }

        let fg = isEnabled ? (titleColor ?? Theme.text) : Theme.disabledText
        let iconColor = isEnabled ? (imageColor ?? Theme.text) : Theme.disabledText
        var contentW: CGFloat = 0
        if image != nil { contentW += imageBox }
        if titleWidth > 0 { contentW += (image != nil ? 6 : 0) + titleWidth }
        if showsChevron { contentW += 14 }
        var x = alignLeft ? hPadding : max(hPadding, (bounds.width - contentW) / 2)
        if let img = (menuOpen ? (menuOpenImage ?? image) : image) {
            Draw.symbol(img, in: NSRect(x: x, y: (bounds.height - imageBox) / 2, width: imageBox, height: imageBox), color: iconColor)
            x += imageBox + 6
        }
        if let title, titleWidth > 0 {
            let maxW = bounds.width - x - (showsChevron ? 14 : 0) - hPadding / 2
            Draw.text(title, in: NSRect(x: x, y: 0, width: max(0, min(titleWidth + 1, maxW)), height: bounds.height), font: font, color: fg)
            x += titleWidth
        }
        if showsChevron {
            let c = Sym.image("chevron.down", size: 8, weight: .semibold)
            Draw.symbol(c, in: NSRect(x: x + 4, y: (bounds.height - 10) / 2, width: 10, height: 10), color: fg)
        }
    }
}

/// Vertical hairline used between command bar groups.
final class VLine: ColorView {
    init() {
        super.init(Theme.strongSeparator)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 1).isActive = true
        heightAnchor.constraint(equalToConstant: 24).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// Green Windows copy progress bar.
final class WinProgressBar: FlippedView {
    var value: Double = 0 { didSet { needsDisplay = true } }   // 0...1
    var indeterminate = false { didSet { needsDisplay = true } }
    var phase: CGFloat = 0 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        Draw.rounded(bounds, 2, fill: Theme.progressTrack)
        if indeterminate {
            let w = bounds.width * 0.3
            let x = -w + (bounds.width + w) * phase
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: bounds, xRadius: 2, yRadius: 2).addClip()
            Theme.progressGreen.setFill()
            NSRect(x: x, y: 0, width: w, height: bounds.height).fill()
            NSGraphicsContext.restoreGraphicsState()
        } else {
            let w = bounds.width * CGFloat(max(0, min(1, value)))
            if w > 0 { Draw.rounded(NSRect(x: 0, y: 0, width: w, height: bounds.height), 2, fill: Theme.progressGreen) }
        }
    }
}

/// Text field that reports focus changes (used to draw Win11 focus underline).
final class FocusTextField: NSTextField {
    var onFocusChange: ((Bool) -> Void)?
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocusChange?(true) }
        return ok
    }
}
